import Foundation

/// @mention parsing, shared by comment rendering, the composer's autocomplete, and the
/// notification path.
///
/// The character set is kept in lockstep with `AuthService.isValidUsername` (letters, digits and
/// underscore). Parsing more permissively than a username can actually be would highlight text
/// that resolves to nobody; parsing more strictly would silently drop real people.
private let usernameCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))

/// One piece of a comment: either plain text, or a mention with the username it refers to.
struct MentionRun: Equatable {
    /// Exactly as it appears in the source text, including the leading `@` for a mention.
    let text: String
    /// Lowercased (usernames are stored lowercased); nil for plain text.
    let username: String?
}

/// Splits `text` into alternating plain and mention runs, preserving the original characters
/// exactly, so joining every `text` back together reproduces the input.
///
/// An `@` only starts a mention at a word boundary, so an email address doesn't turn its domain
/// into a mention, and `@` with nothing after it stays plain text.
func mentionRuns(in text: String) -> [MentionRun] {
    let scalars = Array(text.unicodeScalars)
    var runs: [MentionRun] = []
    var plain = String.UnicodeScalarView()
    var i = 0

    func flushPlain() {
        guard !plain.isEmpty else { return }
        runs.append(MentionRun(text: String(plain), username: nil))
        plain = String.UnicodeScalarView()
    }

    while i < scalars.count {
        let scalar = scalars[i]
        let startsToken = i == 0 || CharacterSet.whitespacesAndNewlines.contains(scalars[i - 1])
        guard scalar == "@", startsToken else {
            plain.append(scalar)
            i += 1
            continue
        }
        var j = i + 1
        var name = String.UnicodeScalarView()
        while j < scalars.count, usernameCharacters.contains(scalars[j]) {
            name.append(scalars[j])
            j += 1
        }
        guard !name.isEmpty else {           // a bare "@" is just text
            plain.append(scalar)
            i += 1
            continue
        }
        flushPlain()
        runs.append(MentionRun(text: "@" + String(name), username: String(name).lowercased()))
        i = j
    }
    flushPlain()
    return runs
}

/// Every username mentioned in `text`, lowercased and de-duplicated, in the order they appear.
/// Drives who gets notified.
func mentionedUsernames(in text: String) -> [String] {
    var seen = Set<String>()
    return mentionRuns(in: text).compactMap(\.username).filter { seen.insert($0).inserted }
}

/// The partial username being typed at the very END of `text`, if the caret sits inside a mention.
///
/// Returns "" for a just-typed `@` (the picker should open immediately, showing everyone), the
/// partial for `@ali`, and nil as soon as the token is finished or the text ends in anything else,
/// so the picker is only on screen while it is actually relevant.
func mentionQuery(in text: String) -> String? {
    let scalars = Array(text.unicodeScalars)
    var i = scalars.count - 1
    var name: [Unicode.Scalar] = []
    while i >= 0 {
        let scalar = scalars[i]
        if usernameCharacters.contains(scalar) {
            name.append(scalar)
            i -= 1
        } else if scalar == "@" {
            let startsToken = i == 0 || CharacterSet.whitespacesAndNewlines.contains(scalars[i - 1])
            guard startsToken else { return nil }
            var view = String.UnicodeScalarView()
            for s in name.reversed() { view.append(s) }
            return String(view).lowercased()
        } else {
            return nil
        }
    }
    return nil
}

/// Replaces the partial mention at the end of `text` with a complete `@username `, ready for the
/// next word. Returns `text` unchanged when there's no mention in progress.
func completingMention(in text: String, with username: String) -> String {
    guard let query = mentionQuery(in: text) else { return text }
    return String(text.dropLast(query.count)) + username + " "
}

/// Prefills a comment composer for replying to someone: puts `handle` (already including the
/// leading `@`, as `UserProfile.handle` does) at the START of `draft`, followed by a space so
/// typing continues naturally.
///
/// A reply is just a mention someone didn't have to type, not a separate structure, so this is
/// plain string composition rather than anything that touches `mentionRuns`. Existing text is
/// preserved, never overwritten, so someone half way through a thought who taps Reply doesn't
/// lose it. Tapping Reply again on the same person doesn't duplicate the mention.
func prefillingReply(to handle: String, in draft: String) -> String {
    let mention = "\(handle) "
    guard !draft.hasPrefix(mention) else { return draft }
    return mention + draft
}

/// Whether `draft` is nothing more than an unmodified `prefillingReply` result: a single mention
/// followed by exactly one trailing space and nothing else.
///
/// Drives auto-clearing an abandoned reply on blur. Deliberately structural rather than comparing
/// against the exact string `prefillingReply` produced for a specific handle: anyone who taps Reply,
/// looks at the box, and looks away without typing a single character has left the same shape
/// behind regardless of who they were replying to, and this is cheap to check without every host
/// having to remember what it prefilled. The moment a single character is added or removed, the
/// shape breaks and this returns false, so real typing is never at risk.
func isUntouchedReplyPrefill(_ draft: String) -> Bool {
    guard draft.hasSuffix(" ") else { return false }
    let runs = mentionRuns(in: String(draft.dropLast()))
    return runs.count == 1 && runs[0].username != nil
}
