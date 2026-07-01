import SwiftUI

/// A reaction row: default emoji chips (with counts) plus a "+" that slides open a
/// scrollable tray to react with any emoji from the palette. Used on posts and roll photos.
struct ReactionBar: View {
    /// Emojis always shown as chips, in order.
    var defaults: [String] = PostEmoji.all
    /// emoji → number of reactions.
    let counts: [String: Int]
    /// Emojis the current user has reacted with (highlighted).
    let mine: Set<String>
    let onReact: (String) -> Void

    @State private var expanded = false

    // Defaults first, then any other reacted emoji so its chip + count still shows.
    private var chipEmojis: [String] {
        var list = defaults
        for emoji in counts.keys.sorted() where !list.contains(emoji) { list.append(emoji) }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(chipEmojis, id: \.self) { chip($0) }

                Button {
                    withAnimation(.snappy(duration: 0.28)) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "xmark" : "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 32)
                        .background(Color.white.opacity(0.12), in: Capsule())
                }
                .accessibilityLabel(expanded ? "Close emoji picker" : "More emoji")
            }

            if expanded {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(PostEmoji.palette, id: \.self) { emoji in
                            Button {
                                onReact(emoji)
                                withAnimation(.snappy(duration: 0.28)) { expanded = false }
                            } label: {
                                Text(emoji)
                                    .font(.system(size: 26))
                                    .padding(6)
                                    .background(mine.contains(emoji) ? FlimTheme.accent.opacity(0.28) : .clear, in: Circle())
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 4)
                }
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
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
}
