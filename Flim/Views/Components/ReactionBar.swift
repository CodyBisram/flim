import SwiftUI

/// Reacted emojis first (most-reacted first, ties broken alphabetically so the order is stable),
/// then whichever defaults nobody has used. A free function, like
/// `rollDeleteConfirmationMessage`, so the rule itself is testable without standing up a view.
func reactionDisplayOrder(counts: [String: Int], defaults: [String]) -> [String] {
    let reacted = counts.filter { $0.value > 0 }
        .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        .map(\.key)
    return reacted + defaults.filter { !reacted.contains($0) }
}

/// One section of the browsable emoji grid: a labelled category, or "Recents" up front.
struct EmojiPickerSection: Equatable, Identifiable {
    let name: String
    let emojis: [String]
    var id: String { name }
}

/// Groups `categories` into the grid's sections, promoting `recents` (already ordered
/// newest-first) into a section of their own up front and removing them from wherever they'd
/// otherwise appear. Dedupes globally, not just against recents: 🙌 is deliberately listed in
/// both "Faces" and "Hearts + Hands" in the source palette (it reads naturally in either), and
/// without this every OTHER emoji in the grid still shows up exactly once, but 🙌 would show up
/// twice. First occurrence wins, so it stays in whichever section it's listed in first.
func emojiPickerSections(categories: [EmojiCategory], recents: [String]) -> [EmojiPickerSection] {
    var seen = Set<String>()
    var sections: [EmojiPickerSection] = []
    let dedupedRecents = recents.filter { seen.insert($0).inserted }
    if !dedupedRecents.isEmpty {
        sections.append(EmojiPickerSection(name: "Recents", emojis: dedupedRecents))
    }
    for category in categories {
        let remaining = category.emojis.filter { seen.insert($0).inserted }
        if !remaining.isEmpty {
            sections.append(EmojiPickerSection(name: category.name, emojis: remaining))
        }
    }
    return sections
}

/// Ranks one emoji's match against `query` using its precomputed search tokens
/// (`EmojiCatalog.searchTokens()`): `0` for an exact whole-word match (some token equals `query`
/// exactly), `1` for a prefix-only match (some token starts with `query` but isn't equal to it),
/// `nil` for no match. Whole-word by prefix, never substring, so typing "dog" finds DOG FACE (a
/// "dog" token) but "og" finds nothing (no token in the catalog starts with "og"). Exact matches
/// rank first so typing "fire" puts 🔥, whose only token IS "fire", ahead of multi-word entries
/// where "fire" is merely a prefix of one word, like "fire engine" or "fireworks".
func emojiSearchRank(_ tokens: [String], query: String) -> Int? {
    let query = query.lowercased()
    guard !query.isEmpty else { return nil }
    if tokens.contains(query) { return 0 }
    if tokens.contains(where: { $0.hasPrefix(query) }) { return 1 }
    return nil
}

/// Search results as a single labelled section, ranked exact-whole-word matches first and
/// prefix-only matches after (stable within each rank, so ties keep the palette's own category
/// order). Returns `[]` for an empty query so callers can tell "not searching" (show the normal
/// browsable grid) apart from "searched and found nothing" (show a real empty state); browsing via
/// `emojiPickerSections` never needs that distinction since it has no "no results" case.
func emojiSearchResults(categories: [EmojiCategory], tokens: [String: [String]], query: String) -> [EmojiPickerSection] {
    guard !query.isEmpty else { return [] }
    var seen = Set<String>()
    var ranked: [(rank: Int, emoji: String)] = []
    for category in categories {
        for emoji in category.emojis where seen.insert(emoji).inserted {
            if let rank = emojiSearchRank(tokens[emoji] ?? [], query: query) {
                ranked.append((rank, emoji))
            }
        }
    }
    guard !ranked.isEmpty else { return [] }
    let sorted = ranked.sorted { $0.rank < $1.rank }
    return [EmojiPickerSection(name: "Results", emojis: sorted.map(\.emoji))]
}

/// A reaction row: chips (with counts) in a horizontal scroll that never clips, and a "+" opens a
/// sheet with a browsable grid of recents + the full palette, grouped into labelled sections. The
/// order stays stable while you're looking (tapping never reshuffles it) and re-sorts
/// reacted-to-front on the next appear.
struct ReactionBar: View {
    @Environment(\.flimAccent) private var accent
    /// A few default emojis offered up front when a photo has no reactions yet.
    var defaults: [String] = PostEmoji.all
    /// emoji → number of reactions.
    let counts: [String: Int]
    /// Emojis the current user reacted with (highlighted).
    let mine: Set<String>
    let onReact: (String) -> Void

    @State private var expanded = false
    @State private var displayOrder: [String] = []
    /// The full generated palette's sections, empty until `EmojiCatalog` finishes (usually already
    /// done by the time anyone opens the sheet, since `warm()` fires on every appear below).
    @State private var catalogSections: [EmojiCategory] = []
    /// Every generated emoji's search tokens, keyed by the emoji itself. Produced by the exact same
    /// background pass as `catalogSections`; see `EmojiCatalog.searchTokens()`.
    @State private var searchTokens: [String: [String]] = [:]
    /// The picker sheet's search field. Empty means "browsing", not "searching for nothing": see
    /// `emojiSearchResults`.
    @State private var query = ""
    /// True once `displayOrder` has been built from a real (non-empty) `counts`, or once you've
    /// tapped something. Gates the one-shot re-sort in `onChange(of: counts)` below.
    @State private var orderSeeded = false
    @State private var pressed: String?
    @AppStorage("recentEmojis") private var recentsRaw = ""

    private var recents: [String] { recentsRaw.split(separator: ",").map(String.init) }

    var body: some View {
        // The picker used to be a second VStack row, included only `if expanded`, which meant
        // this whole view's reported height changed the instant it opened. Every host of this
        // bar (RollCarouselView, PhotoPagerView, FeedView, PostDetailView) sits it in a container
        // that gives a swipeable photo pager "whatever height is left", so opening the picker
        // while a TabView drag was live changed the pager's height mid-transition, the same
        // class of bug that already corrupted roll-carousel paging twice before (a page-width
        // fix, then a footer-height fix). The picker is a `.sheet` now: a real presentation that
        // never touches this view's own layout size, so opening it can't destabilize a paging
        // gesture in progress, and unlike the old overlay tray it can't leave a hidden control
        // for a swipe to land on underneath it either.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(displayOrder, id: \.self) { chip($0) }
                plusButton
            }
            .padding(.trailing, 4)
        }
        .sheet(isPresented: $expanded) { emojiPickerSheet }
        .onAppear {
            rebuildOrder()
            // Fire-and-forget: gets the (relatively expensive, thousands of scalar + font checks)
            // full palette generated well before anyone can reach the "+" button, so opening the
            // sheet almost never has to wait on it. Safe to call from every bar's appear; only the
            // first call in the process actually does anything.
            EmojiCatalog.shared.warm()
        }
        .onChange(of: counts) { _, new in
            // Per-photo hosts (the roll carousel, the photo pager) fetch a photo's reactions
            // ASYNCHRONOUSLY, so `counts` was still empty when this bar appeared and the rebuild
            // above promoted nothing, leaving a reacted emoji at its default index. With
            // PostEmoji.all being five entries, a single 😂 sat dead centre forever, which is how
            // this was spotted. Re-sort once, when the real counts actually land.
            //
            // The feed never hit this: FeedService batch-loads reactions before its cards render,
            // so its bars appear with `counts` already populated.
            //
            // Strictly once. After seeding, the order must hold still while you're looking at it,
            // so tapping a chip never reshuffles the row under your finger, and `react()` seeds
            // too, so a count change caused by your OWN tap can't trigger this either.
            guard !orderSeeded, !new.isEmpty else { return }
            rebuildOrder()
        }
    }

    /// Reacted emojis first (by count), then the remaining defaults. Recomputed on each appear, so
    /// re-entering promotes what people reacted with, but it holds still while you're looking.
    private func rebuildOrder() {
        displayOrder = reactionDisplayOrder(counts: counts, defaults: defaults)
        if !counts.isEmpty { orderSeeded = true }
    }

    private static let gridColumns = [GridItem(.adaptive(minimum: 44), spacing: 10)]

    /// The sections the grid actually shows: the normal browsable grouping (recents promoted up
    /// front) when `query` is empty, ranked search results when it isn't. Search is additive, never
    /// a replacement for browsing: an empty query must show exactly what the picker showed before
    /// this existed.
    private var displayedSections: [EmojiPickerSection] {
        query.isEmpty
            ? emojiPickerSections(categories: catalogSections, recents: recents)
            : emojiSearchResults(categories: catalogSections, tokens: searchTokens, query: query)
    }

    /// A browsable grid of the full device-renderable palette `EmojiCatalog` generates, grouped
    /// into labelled sections with recents promoted to the front, with a search field up top to
    /// narrow it down. A sheet, not an overlay: see the note above `body`.
    private var emojiPickerSheet: some View {
        VStack(spacing: 0) {
            PeopleSearchField(query: $query, prompt: "Search emoji")
            ScrollView {
                if catalogSections.isEmpty {
                    // Only reachable if the sheet opened before `warm()` (fired on every bar's
                    // appear) finished generating; a brief loading state rather than an empty sheet.
                    ProgressView()
                        .padding(.top, 60)
                } else if displayedSections.isEmpty {
                    // Only reachable while searching: browsing always has at least one section
                    // once `catalogSections` has loaded, so this is specifically "searched, found
                    // nothing", not a blank grid.
                    searchEmptyState
                } else {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(displayedSections) { section in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(section.name)
                                    .flimFont(13, weight: .semibold)
                                    .foregroundStyle(FlimTheme.textTertiary)
                                    .textCase(.uppercase)
                                LazyVGrid(columns: Self.gridColumns, spacing: 10) {
                                    ForEach(section.emojis, id: \.self) { emoji in
                                        Button { pick(emoji) } label: {
                                            Text(emoji).flimFont(26)
                                                .frame(width: 44, height: 44)
                                                .background(mine.contains(emoji) ? accent.opacity(0.28) : Color.white.opacity(0.08), in: Circle())
                                        }
                                        .accessibilityLabel("React \(emoji)")
                                    }
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .task {
            async let loadedSections = EmojiCatalog.shared.sections()
            async let loadedTokens = EmojiCatalog.shared.searchTokens()
            (catalogSections, searchTokens) = await (loadedSections, loadedTokens)
        }
        .onDisappear { query = "" }   // next open starts back on the browsable grid, not a stale search
        .background(FlimTheme.bg)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(FlimTheme.bg)
    }

    /// Shown only while actively searching for something that matched nothing, as opposed to the
    /// picker's loading state or the normal browsable grid.
    private var searchEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .ultraLight))
                .foregroundStyle(FlimTheme.textTertiary)
            Text("No matches.")
                .flimFont(14, relativeTo: .subheadline)
                .foregroundStyle(FlimTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private var plusButton: some View {
        Button {
            expanded = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 32)
                .background(Color.white.opacity(0.12), in: Capsule())
        }
        .accessibilityLabel("More emoji")
    }

    private func chip(_ emoji: String) -> some View {
        let count = counts[emoji] ?? 0
        let isMine = mine.contains(emoji)
        // `emoji` can be a reaction someone else sent from a newer OS than this device's; see
        // `ReactionGlyph.swift`. The fixed/default slots and anything reacted from this device's
        // own picker always resolve to `.emoji` here (they're already render-filtered or ancient),
        // so this never adds visible cost there, only when a chip carries something unfamiliar.
        let glyph = reactionGlyph(for: emoji, renders: ReactionRenderabilityCache.shared.renders)
        return Button { react(glyph.toggleValue) } label: {
            HStack(spacing: 4) {
                chipGlyph(glyph)
                if count > 0 {
                    Text("\(count)")
                        .flimFont(13, weight: .semibold, relativeTo: .footnote)
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())          // digits roll when the count changes
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(isMine ? accent.opacity(0.28) : Color.white.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(isMine ? accent : .clear, lineWidth: 1))
            .scaleEffect(pressed == emoji ? 1.18 : 1)               // little bounce on tap
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.28), value: count)
        .animation(.spring(response: 0.28, dampingFraction: 0.5), value: pressed)
        .accessibilityLabel(accessibilityLabel(for: glyph))
    }

    /// The chip's leading glyph: the emoji itself, or a neutral placeholder (same treatment as the
    /// "+" button's SF Symbol elsewhere in this bar) when this device can't draw what arrived.
    @ViewBuilder
    private func chipGlyph(_ glyph: ReactionGlyph) -> some View {
        switch glyph {
        case .emoji(let text):
            Text(text).flimFont(16)
        case .placeholder:
            Image(systemName: "questionmark.square.dashed")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    private func accessibilityLabel(for glyph: ReactionGlyph) -> String {
        switch glyph {
        case .emoji(let text): return "React \(text)"
        case .placeholder: return "a reaction this phone cannot show"
        }
    }

    private func pick(_ emoji: String) {
        react(emoji, fromPicker: true)
    }

    /// React, and make sure the emoji is visible in the row (appended if new) WITHOUT reshuffling
    /// existing chips, the reacted-to-front re-sort only happens on the next appear.
    private func react(_ emoji: String, fromPicker: Bool = false) {
        orderSeeded = true   // your own tap must never trigger the one-shot re-sort above
        if !displayOrder.contains(emoji) { displayOrder.append(emoji) }
        // Bounce feedback, pop the chip, then settle.
        pressed = emoji
        Haptics.tap()
        Task { try? await Task.sleep(for: .milliseconds(140)); pressed = nil }
        if fromPicker {
            recordRecent(emoji)
            withAnimation(.snappy(duration: 0.25)) { expanded = false }
        }
        onReact(emoji)
    }

    private func recordRecent(_ emoji: String) {
        var list = recents.filter { $0 != emoji }
        list.insert(emoji, at: 0)
        recentsRaw = list.prefix(24).joined(separator: ",")
    }
}
