import SwiftUI

/// The two ways to answer a photograph, labelled, at every width and text size.
///
/// v2 foundations (2026-09-14). Existing reactions sit left as chips, at most two, the most
/// given first; React opens the tray (the six defaults, then the whole catalogue); Comment
/// opens the thread and carries its count. The controls never lose their words: below the
/// compact breakpoint the chips are what give way, and past AX2 the row becomes a column of
/// full-width rows. A reaction is written optimistically by the host and rolled back if the
/// server refuses; `failed` is the emoji whose write was refused, and the row says so with a
/// Retry on this frame rather than leaving a count nobody agreed to.
///
/// Presentation only: the host decides what a tap means (`FeedService.reactToPost` already
/// handles the optimistic write, the queue and the rollback).
struct ResponseRow: View {
    @Environment(\.flimAccent) private var accent
    @Environment(\.dynamicTypeSize) private var typeSize

    /// emoji → count, every reaction on the frame.
    let counts: [String: Int]
    /// The emojis the current person reacted with.
    let mine: Set<String>
    /// The six-slot default tray for this frame (`PostEmoji.defaults(suggested:)`).
    var quick: [String] = PostEmoji.all
    var commentCount: Int = 0
    /// The emoji whose last write was refused, if any; drawn as a line with Retry.
    var failed: String? = nil
    let onReact: (String) -> Void
    let onComment: () -> Void

    @State private var trayOpen = false
    @State private var pressed: String?

    /// At most two chips, most given first, ties by emoji so the order is stable. Everything
    /// else lives in the tray.
    static func chipOrder(counts: [String: Int], limit: Int = 2) -> [String] {
        counts.filter { $0.value > 0 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit)
            .map(\.key)
    }

    private var stacked: Bool { typeSize > .accessibility2 }

    var body: some View {
        VStack(alignment: .leading, spacing: FlimSpace.m) {
            if stacked {
                VStack(alignment: .leading, spacing: FlimSpace.m) {
                    chips
                    reactControl.frame(maxWidth: .infinity)
                    commentControl.frame(maxWidth: .infinity)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: FlimSpace.m) { chips; reactControl; commentControl; Spacer(minLength: 0) }
                    HStack(spacing: FlimSpace.m) { reactControl; commentControl; Spacer(minLength: 0) }
                }
            }
            if let failed {
                HStack(spacing: FlimSpace.m) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(FlimTheme.warning(accent))
                    Text("That reaction didn't save.")
                        .flimType(.label)
                        .foregroundStyle(FlimTheme.textSecondary)
                    Button("Retry") { onReact(failed) }
                        .flimType(.label)
                        .foregroundStyle(accent)
                        .frame(minHeight: 44)
                        .accessibilityLabel("Retry reacting \(failed)")
                }
            }
        }
        .sheet(isPresented: $trayOpen) {
            EmojiPickerSheet(mine: mine, quick: quick) { emoji in
                trayOpen = false
                react(emoji)
            }
        }
    }

    @ViewBuilder
    private var chips: some View {
        ForEach(Self.chipOrder(counts: counts), id: \.self) { emoji in
            chip(emoji)
        }
    }

    private func chip(_ emoji: String) -> some View {
        let count = counts[emoji] ?? 0
        let isMine = mine.contains(emoji)
        let glyph = reactionGlyph(for: emoji, renders: ReactionRenderabilityCache.shared.renders)
        return Button { react(glyph.toggleValue) } label: {
            HStack(spacing: FlimSpace.xs) {
                switch glyph {
                case .emoji(let text): Text(text).flimFont(16)
                case .placeholder:
                    Image(systemName: "questionmark.square.dashed")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
                Text("\(count)")
                    .flimType(.label)
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, FlimSpace.l)
            .frame(minHeight: 44)
            // Selection is a fill AND a border, never fill alone; the border is not the only cue.
            .background(isMine ? accent.opacity(0.16) : FlimTheme.row, in: Capsule())
            .overlay(Capsule().strokeBorder(isMine ? accent.opacity(0.45) : FlimTheme.divider, lineWidth: 1))
            .scaleEffect(pressed == emoji ? 1.12 : 1)
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.26), value: count)
        .animation(.spring(response: 0.26, dampingFraction: 0.55), value: pressed)
        .accessibilityLabel({
            switch glyph {
            case .emoji(let text): return isMine ? "Remove your \(text) reaction, \(count) so far" : "React \(text), \(count) so far"
            case .placeholder: return "a reaction this phone cannot show, \(count) so far"
            }
        }())
    }

    private var reactControl: some View {
        Button { trayOpen = true } label: {
            Label("React", systemImage: "face.smiling")
                .labelStyle(ControlLabelStyle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("React")
        .accessibilityHint("Opens the emoji tray")
    }

    private var commentControl: some View {
        Button(action: onComment) {
            Label(commentCount > 0 ? "Comment · \(commentCount)" : "Comment", systemImage: "bubble.left")
                .labelStyle(ControlLabelStyle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(commentCount == 0 ? "Comment" : (commentCount == 1 ? "Comment, 1 comment" : "Comment, \(commentCount) comments"))
    }

    private func react(_ emoji: String) {
        pressed = emoji
        Haptics.tap()
        Task { try? await Task.sleep(for: .milliseconds(140)); pressed = nil }
        onReact(emoji)
    }
}

/// The 44pt outlined control: glyph and word, in the row fill with a divider border. Shared by
/// React and Comment so the two are never drawn differently.
struct ControlLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: FlimSpace.s) {
            configuration.icon.font(.system(size: 15, weight: .medium))
            configuration.title.flimType(.control)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, FlimSpace.l + 2)
        .frame(minHeight: 44)
        .background(FlimTheme.row, in: RoundedRectangle(cornerRadius: FlimRadius.control))
        .overlay(RoundedRectangle(cornerRadius: FlimRadius.control).strokeBorder(FlimTheme.divider, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: FlimRadius.control))
    }
}

/// Where you are in a day of two frames: "1 of 2" in words plus two dots, below the
/// photograph, never a pill on it. Three frames or more get the film strip instead.
struct PositionCue: View {
    @Environment(\.flimAccent) private var accent
    let index: Int
    let count: Int

    var body: some View {
        HStack(spacing: FlimSpace.m) {
            HStack(spacing: FlimSpace.xs) {
                ForEach(0..<count, id: \.self) { i in
                    Circle()
                        .fill(i == index ? accent : FlimTheme.divider)
                        .frame(width: 6, height: 6)
                }
            }
            Text("\(index + 1) of \(count)")
                .flimType(.meta)
                .foregroundStyle(FlimTheme.textTertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Photo \(index + 1) of \(count)")
    }
}
