import SwiftUI

/// Comment text with its @mentions tinted and tappable, optionally with a bold, tappable handle
/// prefixed onto the same paragraph, and the plain body itself made tappable to a third
/// destination.
///
/// Mentions become links on a private scheme and are intercepted by an `OpenURLAction`, rather
/// than being laid out as separate views: a comment has to wrap as one paragraph, and splitting it
/// into a row of buttons would break wrapping mid-sentence. `handle` and `onBodyTap` reuse the
/// exact same mechanism for the same reason, and because it's the one already proven to hand a tap
/// to the right destination without an ancestor `onTapGesture` racing a link inside this `Text` for
/// the same touch, which is not reliable.
struct MentionText: View {
    @Environment(\.flimAccent) private var accent
    let text: String
    /// Scaled with Dynamic Type.
    ///
    /// This renders the BODY of every comment in all four comment surfaces, so leaving it fixed
    /// meant the comments sheet's own chrome grew with the user's text size while the comments
    /// themselves stayed 14pt: the single most visible inconsistency the type pass could have
    /// left behind, on the most text-heavy screen in the app.
    ///
    /// Held as `@ScaledMetric` rather than styled with `.flimFont` because the size goes into an
    /// AttributedString run, not onto a view, so a view modifier can't reach it.
    @ScaledMetric private var size: CGFloat
    var color: Color = .white
    /// A bold handle prefixed onto the same paragraph, ahead of `text`, so a wrapped second line
    /// returns to the leading edge instead of indenting under a separately-laid-out body. Only the
    /// feed card's comment preview needs this (its own row puts handle and body side by side); the
    /// three other comment surfaces already put the handle on its own line above the body and pass
    /// nothing here.
    var handle: String? = nil
    /// Tapped handle, when `handle` is set.
    var onHandleTap: (() -> Void)? = nil
    /// Tapped body text outside any mention, when the host has a destination for it (the feed
    /// card opens the comments sheet; the sheet itself doesn't, and leaves this nil).
    var onBodyTap: (() -> Void)? = nil
    /// The tapped mention's lowercased username.
    let onMention: (String) -> Void

    init(text: String, size: CGFloat = 14, color: Color = .white,
         handle: String? = nil, onHandleTap: (() -> Void)? = nil, onBodyTap: (() -> Void)? = nil,
         onMention: @escaping (String) -> Void) {
        self.text = text
        _size = ScaledMetric(wrappedValue: size, relativeTo: .body)
        self.color = color
        self.handle = handle
        self.onHandleTap = onHandleTap
        self.onBodyTap = onBodyTap
        self.onMention = onMention
    }

    private static let mentionScheme = "flim-mention"
    private static let handleScheme = "flim-handle"
    private static let bodyScheme = "flim-body"

    var body: some View {
        Text(attributed)
            .environment(\.openURL, OpenURLAction { url in
                switch url.scheme {
                case Self.mentionScheme:
                    guard let username = url.host() else { return .systemAction }
                    onMention(username)
                    return .handled
                case Self.handleScheme:
                    guard let onHandleTap else { return .systemAction }
                    onHandleTap()
                    return .handled
                case Self.bodyScheme:
                    guard let onBodyTap else { return .systemAction }
                    onBodyTap()
                    return .handled
                default:
                    return .systemAction
                }
            })
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        if let handle {
            var piece = AttributedString("\(handle) ")
            piece.font = .system(size: size, weight: .semibold)
            piece.foregroundColor = .white
            if onHandleTap != nil {
                piece.link = URL(string: "\(Self.handleScheme)://tap")
            }
            result += piece
        }
        for run in mentionRuns(in: text) {
            var piece = AttributedString(run.text)
            piece.font = .system(size: size)
            if let username = run.username {
                piece.foregroundColor = accent
                // A URL is the only way to make a slice of a Text tappable while keeping the
                // paragraph a single laid-out string. Percent-encoded so an odd username can't
                // produce a malformed URL and silently drop the link.
                let encoded = username.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? username
                piece.link = URL(string: "\(Self.mentionScheme)://\(encoded)")
            } else {
                piece.foregroundColor = color
                if onBodyTap != nil {
                    piece.link = URL(string: "\(Self.bodyScheme)://tap")
                }
            }
            result += piece
        }
        return result
    }
}
