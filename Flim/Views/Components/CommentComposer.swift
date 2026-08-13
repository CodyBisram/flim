import SwiftUI

/// The one comment composer: mention autocomplete, a growing field, and a send button.
///
/// There used to be four of these, hand-written in the feed card, the comments sheet, post detail
/// and roll-photo comments. They drifted, and the drift had teeth: when mentions shipped, the
/// autocomplete was wired into one of the four and the feature looked finished while being broken
/// in three places. The point of this type is that the next comment feature lands everywhere by
/// construction rather than by remembering to visit four files.
///
/// Deliberately renders only the suggestions and the input row. Each host still owns its own outer
/// padding and background, because those genuinely differ, a sheet sits on `.ultraThinMaterial`
/// over a list while the feed card is inside an elevated rounded rectangle, and pulling them in
/// here would mean a style parameter per host, which is how four copies start again.
struct CommentComposer: View {
    @Environment(\.flimAccent) private var accent

    /// The two shapes this takes. Not cosmetic: the inline card sits inside a feed post and has to
    /// stay visually quieter and physically smaller than a dedicated comments surface.
    enum Style {
        /// A full comment surface (sheets, post detail): larger text, a send button that is always
        /// present so the affordance never moves, and room for four lines.
        case surface
        /// Inside a feed card: smaller, a quieter pill, and a send button that appears only when
        /// there is something to send, so an untouched card carries no extra chrome.
        case inlineCard

        var textSize: CGFloat { self == .surface ? 15 : 14 }
        var buttonSize: CGFloat { self == .surface ? 30 : 26 }
        /// The clear ("x") button next to it. Smaller than the send button, it's a way out, not
        /// the primary action, and shouldn't compete with it for weight.
        var clearButtonSize: CGFloat { self == .surface ? 22 : 20 }
        var lineLimit: ClosedRange<Int> { self == .surface ? 1...4 : 1...3 }
        var horizontalPadding: CGFloat { self == .surface ? 14 : 12 }
        var verticalPadding: CGFloat { self == .surface ? 10 : 8 }
        var rowSpacing: CGFloat { self == .surface ? 10 : 8 }
        /// Whether the send button is present when the draft is empty.
        var showsDisabledSendButton: Bool { self == .surface }

        @ViewBuilder var fieldBackground: some View {
            switch self {
            case .surface:    Capsule().fill(FlimTheme.bgElevated)
            case .inlineCard: Capsule().fill(Color.white.opacity(0.06))
            }
        }
    }

    @Binding var draft: String
    var style: Style = .surface
    var placeholder: String = "Add a comment…"
    /// Blocks send while a previous one is still in flight, so a double tap can't post twice.
    var isSending: Bool = false
    /// Whether to render mention autocomplete above the field. Off only where the host already
    /// places `MentionSuggestions` itself for layout reasons (it sits outside the composer's
    /// background in the comments sheet, above the material).
    var showsMentionSuggestions: Bool = true
    var focus: FocusState<Bool>.Binding
    let onSend: () -> Void

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    /// Clears the draft and drops focus. The way out for someone who typed something (a reply
    /// prefill or otherwise) and changed their mind, rather than backspacing it by hand.
    private func clear() {
        Haptics.tap()
        draft = ""
        focus.wrappedValue = false
    }

    var body: some View {
        VStack(spacing: 8) {
            if showsMentionSuggestions {
                MentionSuggestions(draft: $draft)
            }
            HStack(spacing: style.rowSpacing) {
                TextField(placeholder, text: $draft, axis: .vertical)
                    .lineLimit(style.lineLimit)
                    .flimFont(style.textSize, relativeTo: .body)
                    .foregroundStyle(.white)
                    .tint(accent)
                    .focused(focus)
                    .padding(.horizontal, style.horizontalPadding)
                    .padding(.vertical, style.verticalPadding)
                    .background { style.fieldBackground }

                if !draft.isEmpty {
                    Button(action: clear) {
                        Image(systemName: "xmark.circle.fill")
                            // Same fixed-size reasoning as the send button below: it sits in the
                            // same row and shouldn't grow the row when the field needs the space.
                            .font(.system(size: style.clearButtonSize))
                            .foregroundStyle(FlimTheme.textTertiary)
                    }
                    .accessibilityLabel("Clear comment")
                    .transition(.scale.combined(with: .opacity))
                }

                if canSend || style.showsDisabledSendButton {
                    Button(action: onSend) {
                        Image(systemName: "arrow.up.circle.fill")
                            // Icon size is fixed, not Dynamic Type scaled: it sits opposite a
                            // growing field in a fixed-height row, and scaling it would push the
                            // field narrower exactly when someone needs more room to read.
                            .font(.system(size: style.buttonSize))
                            .foregroundStyle(canSend ? accent : FlimTheme.textTertiary)
                    }
                    .disabled(!canSend)
                    .accessibilityLabel("Send comment")
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.2), value: canSend)
            .animation(.snappy(duration: 0.2), value: draft.isEmpty)
        }
        // An abandoned reply (an untouched `@handle ` prefill) shouldn't outlive the tap that
        // made it: losing focus without a single character typed clears it, so the next tap into
        // the box starts clean instead of carrying a half-finished mention forward. Real typing,
        // of any length, is never touched by this.
        .onChange(of: focus.wrappedValue) { _, isFocused in
            if !isFocused, isUntouchedReplyPrefill(draft) {
                draft = ""
            }
        }
    }
}
