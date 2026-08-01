import SwiftUI

/// Comment text with its @mentions tinted and tappable.
///
/// Mentions become links on a private scheme and are intercepted by an `OpenURLAction`, rather
/// than being laid out as separate views: a comment has to wrap as one paragraph, and splitting it
/// into a row of buttons would break wrapping mid-sentence.
struct MentionText: View {
    let text: String
    var size: CGFloat = 14
    var color: Color = .white
    /// The tapped mention's lowercased username.
    let onMention: (String) -> Void

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
