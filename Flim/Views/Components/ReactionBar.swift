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
        .onAppear { rebuildOrder() }
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

    /// A browsable grid of the full 108-emoji palette, grouped into labelled sections with
    /// recents promoted to the front. A sheet, not an overlay: see the note above `body`.
    private var emojiPickerSheet: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                ForEach(emojiPickerSections(categories: PostEmoji.categories, recents: recents)) { section in
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
        .background(FlimTheme.bg)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(FlimTheme.bg)
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
        return Button { react(emoji) } label: {
            HStack(spacing: 4) {
                Text(emoji).flimFont(16)
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
        .accessibilityLabel("React \(emoji)")
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
