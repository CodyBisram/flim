import SwiftUI

/// A reaction row, Lapse-style: the emojis people actually used float left (with counts) in a
/// horizontal scroll that never clips, and a "+" opens a picker led by your recently-used
/// emojis. Used on posts, roll photos, and the carousel.
struct ReactionBar: View {
    /// A few default emojis offered up front when a photo has no reactions yet.
    var defaults: [String] = PostEmoji.all
    /// emoji → number of reactions.
    let counts: [String: Int]
    /// Emojis the current user reacted with (highlighted).
    let mine: Set<String>
    let onReact: (String) -> Void

    @State private var expanded = false
    @AppStorage("recentEmojis") private var recentsRaw = ""

    private var recents: [String] {
        recentsRaw.split(separator: ",").map(String.init)
    }

    /// Reacted emojis first (most-used → least), then any not-yet-used defaults.
    private var chipEmojis: [String] {
        let reacted = counts.filter { $0.value > 0 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map(\.key)
        let extraDefaults = defaults.filter { (counts[$0] ?? 0) == 0 }
        return reacted + extraDefaults
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(chipEmojis, id: \.self) { chip($0) }
                    plusButton
                }
                .padding(.trailing, 4)
            }

            if expanded {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(pickerEmojis, id: \.self) { emoji in
                            Button { pick(emoji) } label: {
                                Text(emoji)
                                    .font(.system(size: 26))
                                    .padding(6)
                                    .background(mine.contains(emoji) ? FlimTheme.accent.opacity(0.28) : .clear, in: Circle())
                            }
                        }
                    }
                    .padding(.horizontal, 4).padding(.vertical, 6)
                }
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
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
        return Button { onReact(emoji) } label: {
            HStack(spacing: 4) {
                Text(emoji).font(.system(size: 16))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(isMine ? FlimTheme.accent.opacity(0.28) : Color.white.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(isMine ? FlimTheme.accent : .clear, lineWidth: 1))
        }
        .accessibilityLabel("React \(emoji)")
    }

    private func pick(_ emoji: String) {
        recordRecent(emoji)
        onReact(emoji)
        withAnimation(.snappy(duration: 0.25)) { expanded = false }
    }

    private func recordRecent(_ emoji: String) {
        var list = recents.filter { $0 != emoji }
        list.insert(emoji, at: 0)
        recentsRaw = list.prefix(16).joined(separator: ",")
    }
}
