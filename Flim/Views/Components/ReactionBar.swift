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

/// A reaction row: chips (with counts) in a horizontal scroll that never clips, and a "+" opens a
/// picker of recents + a big palette + an "any emoji" keyboard entry. The order stays stable while
/// you're looking (tapping never reshuffles it) and re-sorts reacted-to-front on the next appear.
struct ReactionBar: View {
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
    @State private var typed = ""
    @FocusState private var keyboardFocused: Bool
    @AppStorage("recentEmojis") private var recentsRaw = ""

    private var recents: [String] { recentsRaw.split(separator: ",").map(String.init) }

    var body: some View {
        // The picker used to be a second VStack row, included only `if expanded`, which meant
        // this whole view's reported height changed the instant it opened. Every host of this
        // bar (RollCarouselView, FullScreenPhotoView, FeedView, PostDetailView) sits it in a
        // container that gives a swipeable photo pager "whatever height is left", so opening
        // the picker while a TabView drag was live changed the pager's height mid-transition,
        // the same class of bug that already corrupted roll-carousel paging twice before (a
        // page-width fix, then a footer-height fix). The picker is an overlay now instead: it
        // draws on top of whatever's below without ever changing this view's own layout size,
        // so expanding it can no longer destabilize a paging gesture in progress.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(displayOrder, id: \.self) { chip($0) }
                plusButton
            }
            .padding(.trailing, 4)
        }
        .overlay(alignment: .bottomLeading) {
            if expanded {
                picker
                    // Opens UPWARD as an overlay (never changes this bar's own height, which
                    // would corrupt the photo pager it sits under), floating just above the chip
                    // row. It's an OPAQUE elevated tray, so while open it cleanly covers the
                    // photographer handle + date sitting behind it instead of letting them bleed
                    // through (the old near-transparent row read as a collision with the caption).
                    .padding(.bottom, 44)
                    .zIndex(1)
            }
        }
        // Hidden field the system keyboard feeds, tap 🌐 to switch to emoji and pick ANYTHING.
        .background(
            TextField("", text: $typed)
                .focused($keyboardFocused)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
        )
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
        .onChange(of: typed) { _, new in
            guard !new.isEmpty else { return }
            if let emoji = new.first(where: Self.isEmoji) { react(String(emoji), fromPicker: true) }
            typed = ""
            keyboardFocused = false
        }
    }

    /// Reacted emojis first (by count), then the remaining defaults. Recomputed on each appear, so
    /// re-entering promotes what people reacted with, but it holds still while you're looking.
    private func rebuildOrder() {
        displayOrder = reactionDisplayOrder(counts: counts, defaults: defaults)
        if !counts.isEmpty { orderSeeded = true }
    }

    private var picker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                // Any emoji, opens the keyboard so you can pick literally anything.
                Button { keyboardFocused = true } label: {
                    Image(systemName: "keyboard")
                        .font(.system(size: 18)).foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Color.white.opacity(0.14), in: Circle())
                }
                .accessibilityLabel("Pick any emoji")

                ForEach(pickerEmojis, id: \.self) { emoji in
                    Button { pick(emoji) } label: {
                        Text(emoji).font(.system(size: 26)).padding(6)
                            .background(mine.contains(emoji) ? FlimTheme.accent.opacity(0.28) : .clear, in: Circle())
                    }
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 8)
        }
        // An OPAQUE, elevated tray: a solid dark fill (not the old ~6% white wash) so the handle
        // and date behind it are fully hidden while the picker is open, a hairline border and
        // shadow so it reads as a panel floating above the photo, and a fixed width cap so it
        // doesn't stretch edge-to-edge on wide screens.
        .frame(maxWidth: 320, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(FlimTheme.bgElevated)
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
        )
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    /// Recently-used first, then the rest of the palette (deduped).
    private var pickerEmojis: [String] {
        var seen = Set<String>()
        return (recents + PostEmoji.palette).filter { seen.insert($0).inserted }
    }

    private var plusButton: some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) { expanded.toggle() }
        } label: {
            Image(systemName: expanded ? "xmark" : "plus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 32)
                .background(Color.white.opacity(0.12), in: Capsule())
        }
        .accessibilityLabel(expanded ? "Close emoji picker" : "More emoji")
    }

    private func chip(_ emoji: String) -> some View {
        let count = counts[emoji] ?? 0
        let isMine = mine.contains(emoji)
        return Button { react(emoji) } label: {
            HStack(spacing: 4) {
                Text(emoji).font(.system(size: 16))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())          // digits roll when the count changes
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(isMine ? FlimTheme.accent.opacity(0.28) : Color.white.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(isMine ? FlimTheme.accent : .clear, lineWidth: 1))
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

    /// True for real emoji graphemes (not typed letters/digits).
    private static func isEmoji(_ char: Character) -> Bool {
        if char.unicodeScalars.count > 1 {
            return char.unicodeScalars.contains { $0.properties.isEmoji }
        }
        return char.unicodeScalars.first?.properties.isEmojiPresentation ?? false
    }
}
