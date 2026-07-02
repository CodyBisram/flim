import Foundation
import Observation
import Supabase

private let redirectURL = URL(string: "com.lapse.app://login-callback")!

/// Auth failures we surface to the user with a friendly message.
enum AuthError: LocalizedError {
    case notInvited
    case usernameTaken

    var errorDescription: String? {
        switch self {
        case .notInvited:
            return "This email isn’t on the invite list yet. FLIM is invite-only — ask whoever invited you to add you."
        case .usernameTaken:
            return "That username’s taken — try another."
        }
    }
}

@Observable
final class AuthService {
    var currentUser: AppUser?
    var isAuthenticated = false
    var isLoading = true
    /// True while we're fetching the profile right after sign-in, so the router shows the
    /// splash instead of briefly flashing the "pick a username" screen for existing users.
    var isResolvingProfile = false
    var error: String?

    private(set) var pendingEmail: String?

    init() {
        Task { await bootstrap() }
    }

    // MARK: - Bootstrap

    private func bootstrap() async {
        do {
            let session = try await supabase.auth.session
            isAuthenticated = true
            currentUser = try? await fetchUserProfile(id: session.user.id)
        } catch {
            // No active session
        }
        isLoading = false
        await listenForAuthChanges()
    }

    // MARK: - Email OTP

    func sendOTP(email: String) async throws {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Invite gate: only allow-listed emails may request a code. Checked server-side
        // via the `is_email_allowed` RPC (reachable by the anon role before sign-in).
        guard try await isEmailAllowed(normalized) else {
            throw AuthError.notInvited
        }
        try await supabase.auth.signInWithOTP(email: normalized, redirectTo: redirectURL)
        pendingEmail = normalized
    }

    /// Returns whether `email` is on the invite allowlist.
    private func isEmailAllowed(_ email: String) async throws -> Bool {
        try await supabase
            .rpc("is_email_allowed", params: ["p_email": email])
            .execute()
            .value
    }

    func verifyOTP(token: String) async throws {
        guard let email = pendingEmail else { return }
        try await supabase.auth.verifyOTP(email: email, token: token, type: .email)
        let session = try await supabase.auth.session
        isResolvingProfile = true
        isAuthenticated = true
        currentUser = try? await fetchUserProfile(id: session.user.id)
        isResolvingProfile = false
        pendingEmail = nil
    }

    // Handles magic link tap on real device
    func handle(url: URL) async {
        do {
            try await supabase.auth.session(from: url)
            let session = try await supabase.auth.session
            currentUser = try? await fetchUserProfile(id: session.user.id)
        } catch {
            self.error = "Sign-in link expired. Please request a new one."
        }
    }

    // MARK: - Username Setup

    /// Valid usernames: 3–20 chars, letters/numbers/underscore only.
    static func isValidUsername(_ username: String) -> Bool {
        let chars = CharacterSet.alphanumerics.union(.init(charactersIn: "_"))
        return (3...20).contains(username.count)
            && username.unicodeScalars.allSatisfy(chars.contains)
    }

    func setUsername(_ username: String, displayName: String? = nil) async throws {
        let session = try await supabase.auth.session
        let userId = session.user.id
        let email = session.user.email ?? ""
        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)

        struct UpsertUser: Encodable {
            let id: UUID
            let email: String
            let username: String
            let inviteCode: String
            let displayName: String?
            enum CodingKeys: String, CodingKey {
                case id, email, username
                case inviteCode = "invite_code"
                case displayName = "display_name"
            }
        }

        do {
            currentUser = try await supabase
                .from("users")
                .upsert(UpsertUser(id: userId, email: email, username: username,
                                   inviteCode: Self.randomCode(),
                                   displayName: (name?.isEmpty ?? true) ? nil : name))
                .select()
                .single()
                .execute()
                .value
        } catch {
            // Postgres unique_violation (23505) → the username is taken by someone else.
            let desc = "\(error)".lowercased()
            if desc.contains("23505") || desc.contains("duplicate") {
                throw AuthError.usernameTaken
            }
            throw error
        }
    }

    /// Updates the optional display name and refreshes `currentUser`.
    func setDisplayName(_ name: String) async throws {
        let session = try await supabase.auth.session
        struct Update: Encodable { let display_name: String }
        currentUser = try await supabase
            .from("users")
            .update(Update(display_name: name.trimmingCharacters(in: .whitespacesAndNewlines)))
            .eq("id", value: session.user.id.uuidString)
            .select().single().execute().value
    }

    /// Updates the profile bio and refreshes `currentUser`.
    func setBio(_ bio: String) async throws {
        let session = try await supabase.auth.session
        struct Update: Encodable { let bio: String }
        currentUser = try await supabase
            .from("users")
            .update(Update(bio: bio.trimmingCharacters(in: .whitespacesAndNewlines)))
            .eq("id", value: session.user.id.uuidString)
            .select()
            .single()
            .execute()
            .value
    }

    /// Sets the profile avatar to one of the user's own photos (its storage path).
    func setAvatar(path: String) async {
        guard let session = try? await supabase.auth.session else { return }
        struct Update: Encodable { let avatar_path: String }
        if let updated: AppUser = try? await supabase
            .from("users")
            .update(Update(avatar_path: path))
            .eq("id", value: session.user.id.uuidString)
            .select()
            .single()
            .execute()
            .value {
            currentUser = updated
        }
    }

    func signOut() async throws {
        try await supabase.auth.signOut()
        currentUser = nil
        isAuthenticated = false
    }

    /// Password sign-in for invited testers, so they can get in while email OTP delivery isn't
    /// set up yet. Accounts are created in the Supabase dashboard (email + password, auto-
    /// confirmed). TEMPORARY — remove/re-gate before public launch once SMTP is live.
    func signInWithPassword(email: String, password: String) async throws {
        try await supabase.auth.signIn(
            email: email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            password: password
        )
        let session = try await supabase.auth.session
        isResolvingProfile = true
        isAuthenticated = true
        currentUser = try? await fetchUserProfile(id: session.user.id)
        isResolvingProfile = false
    }

    /// Permanently deletes the account + all associated data (App Store Guideline 5.1.1(v)).
    /// The `delete_account` RPC removes the auth user, which cascades to the profile, rolls,
    /// memberships, photos, and reports. Then we clear the local session.
    func deleteAccount() async throws {
        // Remove the user's stored image files first — the RPC cascades the DB rows but
        // not the physical objects in Storage, which would otherwise be orphaned.
        if let session = try? await supabase.auth.session {
            struct PathRow: Decodable { let storage_path: String }
            let rows: [PathRow] = (try? await supabase
                .from("photos")
                .select("storage_path")
                .eq("user_id", value: session.user.id.uuidString)
                .execute()
                .value) ?? []
            let paths = rows.map(\.storage_path)
            if !paths.isEmpty {
                _ = try? await supabase.storage.from("photos").remove(paths: paths)
            }
        }

        try await supabase.rpc("delete_account").execute()
        try? await supabase.auth.signOut()
        currentUser = nil
        isAuthenticated = false
    }

    // MARK: - Helpers

    private func fetchUserProfile(id: UUID) async throws -> AppUser? {
        let rows: [AppUser] = try await supabase
            .from("users")
            .select()
            .eq("id", value: id.uuidString)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    private func listenForAuthChanges() async {
        for await (event, _) in supabase.auth.authStateChanges {
            switch event {
            case .signedIn:
                if let session = try? await supabase.auth.session {
                    isResolvingProfile = true
                    isAuthenticated = true
                    currentUser = try? await fetchUserProfile(id: session.user.id)
                    isResolvingProfile = false
                }
            case .signedOut:
                currentUser = nil
                isAuthenticated = false
            default:
                break
            }
        }
    }

    static func randomCode(length: Int = 6) -> String {
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<length).map { _ in chars.randomElement()! })
    }
}
