import SwiftUI

/// Comment text with its @mentions tinted and tappable.
///
/// Mentions become links on a private scheme and are intercepted by an `OpenURLAction`, rather
/// than being laid out as separate views: a comment has to wrap as one paragraph, and splitting it
/// into a row of buttons would break wrapping mid-sentence.
struct MentionText: View {
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
    /// The tapped mention's lowercased username.
    let onMention: (String) -> Void

    init(text: String, size: CGFloat = 14, color: Color = .white,
         onMention: @escaping (String) -> Void) {
        self.text = text
        _size = ScaledMetric(wrappedValue: size, relativeTo: .body)
        self.color = color
        self.onMention = onMention
    }

    private static let scheme = "flim-mention"

    var body: some View {
        Text(attributed)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == Self.scheme, let username = url.host() else { return .systemAction }
                onMention(username)
                return .handled
            })
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        for run in mentionRuns(in: text) {
            var piece = AttributedString(run.text)
            piece.font = .system(size: size)
            if let username = run.username {
                piece.foregroundColor = FlimTheme.accent
                // A URL is the only way to make a slice of a Text tappable while keeping the
                // paragraph a single laid-out string. Percent-encoded so an odd username can't
                // produce a malformed URL and silently drop the link.
                let encoded = username.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? username
                piece.link = URL(string: "\(Self.scheme)://\(encoded)")
            } else {
                piece.foregroundColor = color
            }
            result += piece
        }
        return result
    }
}
