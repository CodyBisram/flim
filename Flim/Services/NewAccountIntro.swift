import Foundation

/// How FLIM introduces itself to an account that is new, and only to those.
///
/// The first-run redesign (2026-09-08) removed the three onboarding cards and replaced them with
/// the thing itself: the camera asks for itself, the first Darkroom shows one frame at print
/// size, the first roll shows one dark slot. Beyond those, every surface gets ONE sentence the
/// first time a new account opens it, in the quiet chrome style, and never again. Not a coach
/// mark, not an overlay, not a step counter: a line where the screen's own copy already lives.
///
/// Gated two ways. `isNewAccount` keeps every existing member from ever seeing a line they do
/// not need, by account creation date rather than by install, so a reinstall does not re-teach
/// someone who has been here since July. `hasSeen`/`markSeen` are per account and per surface,
/// in `UserDefaults`, so the line shows for one visit and is gone on the next.
enum NewAccountIntro {
    /// Accounts created from this instant on are "new". The date the first-run redesign shipped.
    static let cutoff: Date = ISO8601DateFormatter().date(from: "2026-09-08T00:00:00Z")!

    static func isNewAccount(createdAt: Date?, cutoff: Date = cutoff) -> Bool {
        guard let createdAt else { return false }
        return createdAt >= cutoff
    }

    enum Surface: String, CaseIterable {
        case feed, rolls, profile, darkroom

        /// One sentence each. What the screen is, in the app's own words, with the one fact a
        /// newcomer cannot see from the screen itself.
        var line: String {
            switch self {
            case .feed: "Your feed is the people you follow, newest first. Nothing is ranked."
            case .rolls: "A roll is one camera for a group. Nobody sees a frame until it develops for everyone."
            case .profile: "This is your page. Post from the Darkroom and it lands here, a chapter for every month."
            case .darkroom: "Your own shots live here. Only you can see them until you post."
            }
        }
    }

    static var store: UserDefaults = .standard

    private static func key(_ surface: Surface, userId: UUID) -> String {
        "firstVisit.\(surface.rawValue).\(userId.uuidString)"
    }

    static func hasSeen(_ surface: Surface, userId: UUID) -> Bool {
        store.bool(forKey: key(surface, userId: userId))
    }

    static func markSeen(_ surface: Surface, userId: UUID) {
        store.set(true, forKey: key(surface, userId: userId))
    }

    /// The line to show right now, or nil: only for a new account, only on a first visit.
    static func lineToShow(_ surface: Surface, userId: UUID?, createdAt: Date?) -> String? {
        guard let userId, isNewAccount(createdAt: createdAt), !hasSeen(surface, userId: userId) else { return nil }
        return surface.line
    }
}

/// A username offered from an email address, so the sign-up screen arrives filled in rather
/// than empty: the local part, lowercased, stripped to the characters a username allows, cut to
/// the maximum length. Never empty on a plausible email; empty when there is nothing usable, in
/// which case the field simply stays blank as before. Uniqueness is the server's call at save.
enum UsernameSuggestion {
    static let maxLength = 20

    static func from(email: String) -> String {
        guard let at = email.firstIndex(of: "@") else { return "" }
        let local = email[..<at].lowercased()
        // Plus-addressing carries a tag, not a name: "cody+flim@" is cody.
        let base = local.split(separator: "+", maxSplits: 1).first.map(String.init) ?? ""
        let allowed = base.map { ch -> Character in
            if ch.isLetter && ch.isASCII || ch.isNumber && ch.isASCII || ch == "_" { return ch }
            return "_"
        }
        var out = String(allowed)
        while out.contains("__") { out = out.replacingOccurrences(of: "__", with: "_") }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return String(out.prefix(maxLength))
    }
}
