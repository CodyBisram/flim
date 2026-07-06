import SwiftUI
import TipKit

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
    /// Show the one-time "react with anything" tip on the + button. Enabled on a single stable
    /// instance only (the first feed card) so TipKit doesn't fight across every scrolling card.
    var showTip: Bool = false

    @State private var expanded = false
    @State private var displayOrder: [String] = []
    @State private var pressed: String?
    @State private var typed = ""
    @FocusState private var keyboardFocused: Bool
    @AppStorage("recentEmojis") private var recentsRaw = ""

    private var recents: [String] { recentsRaw.split(separator: ",").map(String.init) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(displayOrder, id: \.self) { chip($0) }
                    plusButton
                }
                .padding(.trailing, 4)
            }
            if expanded { picker }
        }
        // Hidden field the system keyboard feeds — tap 🌐 to switch to emoji and pick ANYTHING.
        .background(
            TextField("", text: $typed)
                .focused($keyboardFocused)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
        )
        .onAppear { rebuildOrder() }
        .onChange(of: typed) { _, new in
            guard !new.isEmpty else { return }
            if let emoji = new.first(where: Self.isEmoji) { react(String(emoji), fromPicker: true) }
            typed = ""
            keyboardFocused = false
        }
    }

    /// Reacted emojis first (by count), then the remaining defaults. Recomputed on each appear — so
    /// re-entering promotes what people reacted with, but it holds still while you're looking.
    private func rebuildOrder() {
        let reacted = counts.filter { $0.value > 0 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map(\.key)
        displayOrder = reacted + defaults.filter { !reacted.contains($0) }
    }

    private var picker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                // Any emoji — opens the keyboard so you can pick literally anything.
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
            .padding(.horizontal, 4).padding(.vertical, 6)
        }
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// Recently-used first, then the rest of the palette (deduped).
    private var pickerEmojis: [String] {
        var seen = Set<String>()
        return (recents + PostEmoji.palette).filter { seen.insert($0).inserted }
    }

    @ViewBuilder private var plusButton: some View {
        if showTip {
            plusButtonBody.popoverTip(ReactTip())
        } else {
            plusButtonBody
        }
    }

    private var plusButtonBody: some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) { expanded.toggle() }
            if expanded { ReactTip().invalidate(reason: .actionPerformed) }   // opened it → dismiss the tip
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
    /// existing chips — the reacted-to-front re-sort only happens on the next appear.
    private func react(_ emoji: String, fromPicker: Bool = false) {
        if !displayOrder.contains(emoji) { displayOrder.append(emoji) }
        // Bounce feedback — pop the chip, then settle.
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
