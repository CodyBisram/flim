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
    @State private var typed = ""
    @FocusState private var keyboardFocused: Bool

    // Defaults first, then any other reacted emoji so its chip + count still shows.
    private var chipEmojis: [String] {
        var list = defaults
        for emoji in counts.keys.sorted() where !list.contains(emoji) { list.append(emoji) }
        return list
    }

    private func react(_ emoji: String) {
        onReact(emoji)
        typed = ""
        keyboardFocused = false
        withAnimation(.snappy(duration: 0.28)) { expanded = false }
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
                HStack(spacing: 8) {
                    // Opens the full system emoji keyboard to react with anything.
                    Button { keyboardFocused = true } label: {
                        Image(systemName: "keyboard")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Color.white.opacity(0.12), in: Circle())
                    }
                    .accessibilityLabel("Emoji keyboard")

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(PostEmoji.palette, id: \.self) { emoji in
                                Button { react(emoji) } label: {
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
                }
                .padding(.horizontal, 6)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                // Invisible field: focusing it raises the keyboard; the first emoji typed reacts.
                .overlay(
                    TextField("", text: $typed)
                        .focused($keyboardFocused)
                        .frame(width: 1, height: 1)
                        .opacity(0.01)
                        .onChange(of: typed) { _, new in
                            if let emoji = new.reversed().first(where: { $0.isEmoji }) {
                                react(String(emoji))
                            } else if !new.isEmpty {
                                typed = ""
                            }
                        }
                )
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

private extension Character {
    /// Whether this character is an emoji (so we can pick it out of keyboard input).
    var isEmoji: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        return scalar.properties.isEmojiPresentation
            || (scalar.properties.isEmoji && unicodeScalars.count > 1)
            || (0x1F000...0x1FAFF).contains(scalar.value)
            || (0x2600...0x27BF).contains(scalar.value)
    }
}
