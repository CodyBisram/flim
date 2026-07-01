import Foundation
import Observation
import Supabase

private let redirectURL = URL(string: "com.lapse.app://login-callback")!

/// Auth failures we surface to the user with a friendly message.
enum AuthError: LocalizedError {
    case notInvited

    var errorDescription: String? {
        switch self {
        case .notInvited:
            return "This email isn’t on the invite list yet. FLIM is invite-only — ask whoever invited you to add you."
        }
    }
}

@Observable
final class AuthService {
    var currentUser: AppUser?
    var isAuthenticated = false
    var isLoading = true
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
        isAuthenticated = true
        currentUser = try? await fetchUserProfile(id: session.user.id)
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

    func setUsername(_ username: String) async throws {
        let session = try await supabase.auth.session
        let userId = session.user.id
        let email = session.user.email ?? ""

        struct UpsertUser: Encodable {
            let id: UUID
            let email: String
            let username: String
            let inviteCode: String
            enum CodingKeys: String, CodingKey {
                case id, email, username
                case inviteCode = "invite_code"
            }
        }

        currentUser = try await supabase
            .from("users")
            .upsert(UpsertUser(id: userId, email: email, username: username, inviteCode: Self.randomCode()))
            .select()
            .single()
            .execute()
            .value
    }

    func signOut() async throws {
        try await supabase.auth.signOut()
        currentUser = nil
        isAuthenticated = false
    }

    /// Permanently deletes the account + all associated data (App Store Guideline 5.1.1(v)).
    /// The `delete_account` RPC removes the auth user, which cascades to the profile, rolls,
    /// memberships, photos, and reports. Then we clear the local session.
    func deleteAccount() async throws {
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
                    isAuthenticated = true
                    currentUser = try? await fetchUserProfile(id: session.user.id)
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
