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
        /// Inside one roll that has not developed. Its sentence is built at the call site,
        /// because it names the develop time; `line` here is the fallback with no time in it.
        case rollDetail

        /// One sentence each. What the screen is, in the app's own words, with the one fact a
        /// newcomer cannot see from the screen itself.
        var line: String {
            switch self {
            case .feed: "Your feed is the people you follow, newest first. Nothing is ranked."
            case .rolls: "A roll is one camera for a group. Nobody sees a frame until it develops for everyone."
            case .profile: "This is your page. Post from the Darkroom and it lands here, a chapter for every month."
            case .darkroom: "Your own shots live here. Only you can see them until you post."
            case .rollDetail: "Every frame anyone shoots into this roll appears here when it develops, for everyone at once. Until then the roll is dark, for you too."
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
    /// `text` overrides the surface's own sentence when the call site has a better one.
    static func lineToShow(_ surface: Surface, userId: UUID?, createdAt: Date?, text: String? = nil) -> String? {
        guard let userId, isNewAccount(createdAt: createdAt), !hasSeen(surface, userId: userId) else { return nil }
        return text ?? surface.line
    }

    // MARK: - Who brought you

    struct Inviter: Equatable {
        let id: UUID
        /// What the sign-in screen called them: display name, else "@handle".
        let name: String
    }

    /// Kept per account once the account exists, so the first Darkroom can offer "Start a roll
    /// with Maya" by name without a fetch. Written by `UsernameView.save`, read by `DarkroomView`.
    static func rememberInviter(_ inviter: Inviter, userId: UUID) {
        store.set(inviter.id.uuidString, forKey: "invitedBy.id.\(userId.uuidString)")
        store.set(inviter.name, forKey: "invitedBy.name.\(userId.uuidString)")
    }

    static func inviter(for userId: UUID) -> Inviter? {
        guard let raw = store.string(forKey: "invitedBy.id.\(userId.uuidString)"), let id = UUID(uuidString: raw),
              let name = store.string(forKey: "invitedBy.name.\(userId.uuidString)") else { return nil }
        return Inviter(id: id, name: name)
    }

    // MARK: - One-shot states

    /// The first Darkroom (one frame at print size) shows until "Keep it here" or a post, or until
    /// a second frame exists, whichever first. Per account.
    static func firstFrameDismissed(userId: UUID) -> Bool { store.bool(forKey: "firstFrame.dismissed.\(userId.uuidString)") }
    static func dismissFirstFrame(userId: UUID) { store.set(true, forKey: "firstFrame.dismissed.\(userId.uuidString)") }

    /// The roll-time notification ask is a real decision either way and is asked once per account.
    static func rollAskDecided(userId: UUID) -> Bool { store.bool(forKey: "rollAsk.decided.\(userId.uuidString)") }
    static func markRollAskDecided(userId: UUID) { store.set(true, forKey: "rollAsk.decided.\(userId.uuidString)") }
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
