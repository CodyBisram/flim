import Foundation
import Observation
import Supabase

private let redirectURL = URL(string: "com.lapse.app://login-callback")!

/// Auth failures we surface to the user with a friendly message.
enum AuthError: LocalizedError {
    case notInvited
    case usernameTaken
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .notInvited:
            return "This email isn’t on the invite list yet. \(AppInfo.appName) is invite-only, so ask whoever invited you to add you."
        case .usernameTaken:
            return "That username’s taken. Try another."
        case .rateLimited:
            return "Too many attempts right now. Try again in a bit."
        }
    }
}

@MainActor
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

    // MARK: - App Review sign-in
    //
    // FLIM is invite-only and signs in with an emailed code, so App Review cannot get in on its
    // own: a reviewer reaches the email screen and stops. Apple reviews EVERY update, not just the
    // first, and an app a reviewer can't enter is rejected. 1.0 shipped a hardcoded code branch to
    // solve this, which was stripped after approval, leaving nothing for 1.2.
    //
    // This replaces that with one address that signs in by PASSWORD instead of a mailed code.
    //
    // What is in the binary: the address. An email address is not a credential, and it has to be
    // here anyway because it is what the gate compares against.
    //
    // What is NOT in the binary: the password. It lives in Supabase Auth and in App Review
    // Information. `strings` on the shipped app yields an address and nothing usable, unlike 1.0
    // where the code itself was extractable. Revoking access is changing that password.
    //
    // The gate is the security-relevant part. Password sign-in is offered for this ONE address and
    // no other, so it never becomes a way to guess passwords against real accounts; every other
    // email keeps the invite check plus emailed code, untouched.

    /// The single address permitted to sign in with a password.
    static let reviewerEmail = "review@flim-app.com"

    /// Whether `email` is the App Review address. `nonisolated` so it is callable from anywhere,
    /// including tests, without hopping to the main actor for a string comparison.
    nonisolated static func isReviewerEmail(_ email: String) -> Bool {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == reviewerEmail
    }

    /// Signs the App Review account in with a password.
    ///
    /// Re-checks the address rather than trusting the caller. The UI only offers this path for the
    /// reviewer address, but a guard that exists in one place is a guard that moves when the UI is
    /// refactored, and the whole safety argument rests on this being unreachable for real accounts.
    func signInWithPassword(email: String, password: String) async throws {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.isReviewerEmail(normalized) else { throw AuthError.notInvited }
        try await supabase.auth.signIn(email: normalized, password: password)
        let session = try await supabase.auth.session
        isResolvingProfile = true
        isAuthenticated = true
        currentUser = try? await fetchUserProfile(id: session.user.id)
        isResolvingProfile = false
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

    /// Redeems an invite code for `email`, allowlisting it server-side. Returns `true` if the
    /// code was valid (also `true`, idempotently, if the email was already allowlisted).
    /// `false` means the code doesn't exist. The caller is responsible for proceeding via
    /// `sendOTP(email:)` on success, `is_email_allowed` stays the single source of truth there.
    func redeemInvite(code: String, email: String) async throws -> Bool {
        let normalizedCode = Self.normalizeInviteCode(code)
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        do {
            return try await supabase
                .rpc("redeem_invite", params: ["p_code": normalizedCode, "p_email": normalizedEmail])
                .execute()
                .value
        } catch let error as PostgrestError where error.code == "P0003" || error.message == "rate_limited" {
            throw AuthError.rateLimited
        }
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
        let trimmedName = (name?.isEmpty ?? true) ? nil : name

        struct InsertUser: Encodable {
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
        struct UpdateUsername: Encodable {
            let username: String
            let displayName: String?
            enum CodingKeys: String, CodingKey {
                case username
                case displayName = "display_name"
            }
        }

        // Table-level SELECT on `users` is revoked (column-scoped grants only), which the
        // ON CONFLICT machinery behind `.upsert()` needs even with `return=minimal`, it 403s.
        // So: insert first (this is the first-ever write for a new account). If the row
        // already exists (id PK conflict, e.g. re-running onboarding), fall back to a plain
        // update. Both use `return=minimal` and never chain `.select()`, that too needs
        // table-level SELECT and 403s.
        do {
            _ = try await supabase
                .from("users")
                .insert(InsertUser(id: userId, email: email, username: username,
                                   inviteCode: Self.randomCode(), displayName: trimmedName),
                        returning: .minimal)
                .execute()
        } catch let error as PostgrestError where error.code == "23505" {
            if Self.isPrimaryKeyConflict(error) {
                do {
                    _ = try await supabase
                        .from("users")
                        .update(UpdateUsername(username: username, displayName: trimmedName),
                                returning: .minimal)
                        .eq("id", value: userId.uuidString)
                        .execute()
                } catch let updateError as PostgrestError where updateError.code == "23505" {
                    // The username unique constraint, this time on the update path.
                    throw AuthError.usernameTaken
                }
            } else {
                // Postgres unique_violation on the username unique constraint.
                throw AuthError.usernameTaken
            }
        }
        // Refetch via the RPC, plain selects can't read email/invite_code (column grants).
        currentUser = try await fetchUserProfile(id: userId)
    }

    /// Distinguishes a 23505 on the `users` PK (`id`, meaning the row already exists) from one
    /// on the `username` unique constraint, using the constraint name Postgres reports.
    static func isPrimaryKeyConflict(_ error: PostgrestError) -> Bool {
        let text = "\(error.detail ?? "") \(error.message)".lowercased()
        return text.contains("users_pkey") || text.contains("(id)")
    }

    /// Updates the optional display name and refreshes `currentUser`.
    func setDisplayName(_ name: String) async throws {
        let session = try await supabase.auth.session
        struct Update: Encodable { let display_name: String }
        _ = try await supabase
            .from("users")
            .update(Update(display_name: name.trimmingCharacters(in: .whitespacesAndNewlines)),
                    returning: .minimal)
            .eq("id", value: session.user.id.uuidString)
            .execute()
        currentUser = try await fetchUserProfile(id: session.user.id)
    }

    /// Updates the profile bio and refreshes `currentUser`.
    func setBio(_ bio: String) async throws {
        let session = try await supabase.auth.session
        struct Update: Encodable { let bio: String }
        _ = try await supabase
            .from("users")
            .update(Update(bio: bio.trimmingCharacters(in: .whitespacesAndNewlines)),
                    returning: .minimal)
            .eq("id", value: session.user.id.uuidString)
            .execute()
        currentUser = try await fetchUserProfile(id: session.user.id)
    }

    /// Sets the profile avatar from one of the user's photos. Copies the image into its own
    /// Storage object so the avatar survives the source photo being deleted.
    func setAvatar(fromPhotoPath sourcePath: String) async {
        guard let raw = await imageData(atPath: sourcePath) else { return }
        await setAvatar(fromImageData: raw)
    }

    /// Downloads a stored image so a caller can work with the bytes before setting them, which is
    /// what the profile cropper needs: it has to show the photo before it can crop it. Kept on the
    /// service rather than reached for from a view, so nothing outside a service talks to Storage.
    func imageData(atPath path: String) async -> Data? {
        try? await supabase.storage.from("photos").download(path: path)
    }

    /// Sets the profile avatar from raw image data the user picked out of their photo library.
    ///
    /// Deliberately does NOT run the FLIM look over it. The grade is fitted against our own
    /// capture pipeline, so a camera-roll photo that some other app already processed would be
    /// graded twice and come out wrong. It also keeps "a FLIM photo" meaning something specific
    /// rather than a filter anything can be pushed through.
    ///
    /// Downscaled to the same 256pt an avatar copied from a Darkroom shot gets, so an imported
    /// picture can't quietly become the largest object in the bucket.
    func setAvatar(fromImageData raw: Data) async {
        guard let session = try? await supabase.auth.session,
              let dest = await uploadOwnedImage(raw, prefix: "avatar", userId: session.user.id, maxPixel: 256)
        else { return }
        let old = currentUser?.avatarPath
        struct Update: Encodable { let avatar_path: String }
        guard (try? await supabase
            .from("users").update(Update(avatar_path: dest), returning: .minimal)
            .eq("id", value: session.user.id.uuidString).execute()) != nil
        else { return }
        currentUser = try? await fetchUserProfile(id: session.user.id)
        cleanupOldCopy(old, keeping: dest, prefix: "avatar")
    }

    /// Sets the profile cover/header from one of the user's photos (its own Storage copy).
    func setCover(fromPhotoPath sourcePath: String) async {
        guard let raw = try? await supabase.storage.from("photos").download(path: sourcePath) else { return }
        await setCover(fromImageData: raw)
    }

    /// Sets the cover from a picked library photo. Same reasoning as `setAvatar(fromImageData:)`:
    /// no FLIM grade on an imported picture, and downscaled to the cover's own 640pt cap.
    func setCover(fromImageData raw: Data) async {
        guard let session = try? await supabase.auth.session,
              let dest = await uploadOwnedImage(raw, prefix: "cover", userId: session.user.id, maxPixel: 640)
        else { return }
        let old = currentUser?.coverPath
        struct Update: Encodable { let cover_path: String }
        guard (try? await supabase
            .from("users").update(Update(cover_path: dest), returning: .minimal)
            .eq("id", value: session.user.id.uuidString).execute()) != nil
        else { return }
        currentUser = try? await fetchUserProfile(id: session.user.id)
        cleanupOldCopy(old, keeping: dest, prefix: "cover")
    }

    /// Writes image data into a fresh object in the user's own folder, returning its path.
    ///
    /// Shared by both sources: a Darkroom shot (downloaded first, so the avatar survives the
    /// source photo being deleted) and a photo picked from the library. Neither is graded, and
    /// both land at the same size cap, so where a profile picture came from makes no difference
    /// to what gets stored.
    private func uploadOwnedImage(_ raw: Data, prefix: String, userId: UUID, maxPixel: CGFloat) async -> String? {
        // Downscale, an avatar/cover never needs the full image (saves storage + egress).
        let data = InstantFilmProcessor.thumbnail(from: raw, maxPixel: maxPixel) ?? raw
        let dest = "\(userId.uuidString.lowercased())/\(prefix)-\(UUID().uuidString.lowercased()).jpg"
        do {
            try await supabase.storage.from("photos")
                .upload(dest, data: data, options: FileOptions(contentType: "image/jpeg"))
            return dest
        } catch { return nil }
    }

    /// Best-effort delete of a previous avatar/cover copy (only our own copies, never a real photo).
    private func cleanupOldCopy(_ old: String?, keeping newPath: String, prefix: String) {
        guard let old, old != newPath, old.contains("/\(prefix)-") else { return }
        Task { _ = try? await supabase.storage.from("photos").remove(paths: [old]) }
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
        // Remove the user's stored image files first, the RPC cascades the DB rows but
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

    /// The signed-in user's FULL row, email + invite_code are hidden from plain table selects
    /// by column-level grants, so the own row comes through the locked-down get_own_profile RPC.
    private func fetchUserProfile(id: UUID) async throws -> AppUser? {
        try? await supabase.rpc("get_own_profile").single().execute().value
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

    /// Trims and uppercases an invite code before sending it to `redeem_invite`. The server
    /// normalizes too, this is purely for consistent client-side UX (e.g. matching what the
    /// user sees echoed back on a failure).
    static func normalizeInviteCode(_ code: String) -> String {
        code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}
