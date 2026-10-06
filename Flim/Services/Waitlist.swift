import Foundation

/// The way forward for someone who installed the app without an invite code.
///
/// Sign-up is invite-only, and before this the sign-in screen offered a person with no code
/// nothing at all: they read "Invite only" and left. This holds the rules behind the two answers
/// the screen now gives them (ask a friend, join the waitlist): what counts as a name and an
/// email, what the server's reply means, and which emails have already joined on this phone.
/// Pure on purpose, so `WaitlistSheet` only draws it and `WaitlistTests` pins it.
enum Waitlist {
    /// Matches the server's own limit in `join_waitlist`.
    static let nameLimit = 60

    /// The trimmed name, or `nil` when it is empty or longer than `nameLimit`.
    static func normalizedName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...nameLimit).contains(name.count) else { return nil }
        return name
    }

    /// The trimmed, lowercased email, or `nil` when it does not have the shape of one.
    ///
    /// Only a shape check: one "@", something before it, and a dotted domain with no empty
    /// parts. The server has the final word (`invalid`); this only keeps Join off for text that
    /// could never be an address.
    static func normalizedEmail(_ raw: String) -> String? {
        let email = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard email.count <= 254, !email.contains(where: \.isWhitespace) else { return nil }
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, let local = parts.first, let domain = parts.last, !local.isEmpty else { return nil }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return nil }
        return email
    }

    static func canSubmit(name: String, email: String) -> Bool {
        normalizedName(name) != nil && normalizedEmail(email) != nil
    }

    // MARK: - The server's answer

    /// What `join_waitlist` said. `unreachable` covers everything that is not one of its three
    /// words: no network, a body that would not decode, or a word this build does not know.
    enum Outcome: Equatable {
        case joined
        case invalid
        case rateLimited
        case unreachable

        init(serverValue: String?) {
            switch serverValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "joined": self = .joined
            case "invalid": self = .invalid
            case "rate_limited": self = .rateLimited
            default: self = .unreachable
            }
        }

        /// Reads the RPC's response body.
        ///
        /// PostgREST answers a function returning `text` with a bare JSON string (`"joined"`).
        /// Read defensively anyway, because a wrong guess here tells a person who DID join that
        /// it failed: a one-element array, a row keyed by the function's name, and an unquoted
        /// body all read as the word they carry.
        static func parse(_ data: Data) -> Outcome {
            let decoder = JSONDecoder()
            if let word = try? decoder.decode(String.self, from: data) {
                return Outcome(serverValue: word)
            }
            if let words = try? decoder.decode([String].self, from: data) {
                return Outcome(serverValue: words.first)
            }
            if let rows = try? decoder.decode([[String: String]].self, from: data) {
                return Outcome(serverValue: rows.first?["join_waitlist"])
            }
            if let row = try? decoder.decode([String: String].self, from: data) {
                return Outcome(serverValue: row["join_waitlist"])
            }
            let raw = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))
            return Outcome(serverValue: raw)
        }

        /// What the sheet says for this outcome; `nil` for `joined`, which replaces the form.
        var message: String? {
            switch self {
            case .joined: nil
            case .invalid: Copy.invalidEmail
            case .rateLimited: Copy.rateLimited
            case .unreachable: Copy.unreachable
            }
        }

        /// `invalid` is about the address, so it sits under the email field rather than below
        /// the form.
        var isAboutEmail: Bool { self == .invalid }
    }

    // MARK: - Joined on this phone

    private static let keyPrefix = "waitlistJoined."

    private static func key(for email: String) -> String {
        keyPrefix + email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Notes that `email` joined, so reopening the sheet for it shows "You're on the list."
    /// instead of a form that would only ask again.
    static func remember(_ email: String, in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: key(for: email))
    }

    static func hasJoined(_ email: String, in defaults: UserDefaults = .standard) -> Bool {
        guard !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return defaults.bool(forKey: key(for: email))
    }

    // MARK: - Copy

    /// Drafts pending the owner's approval. No em dashes, per the house copy rule.
    enum Copy {
        static let noCode = "No code yet?"
        static let askFriend = "Ask a friend for one"
        static let askFriendHint = "Opens the share sheet with a message asking for an invite code."
        static let joinWaitlist = "Join the waitlist"
        static let joinWaitlistHint = "Opens a short form to join the waitlist."
        static let shareMessage = "Are you on \(AppInfo.appName)? Send me an invite code so I can join.\nhttps://flim-app.com"

        static let title = "Join the waitlist"
        static let body = "Leave your name and email. We'll write when there's a spot for you."
        static let nameField = "First name"
        static let emailField = "Email"
        static let join = "Join"
        static let joinedTitle = "You're on the list."
        static func joinedBody(email: String) -> String { "We'll email \(email) when there's a spot." }
        static let done = "Done"

        static let invalidEmail = "That email doesn't look right."
        static let rateLimited = "Too many tries. Give it a few minutes."
        static let unreachable = "Couldn't reach \(AppInfo.appName). Try again."
    }
}
