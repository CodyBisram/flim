import Foundation
import Observation
import Supabase
import os

private let redirectURL = URL(string: "com.lapse.app://login-callback")!

/// Auth failures we surface to the user with a friendly message.
enum AuthError: LocalizedError {
    case notInvited
    case usernameTaken
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .notInvited:
            // The sign-in screen no longer shows this: needing an invite is the expected state for
            // a new person, so it opens the code field and says what to do next instead. Kept as a
            // sane fallback for any other caller, and reworded, because the old text ("ask whoever
            // invited you to add you") sent people to fetch the code they were already holding.
            return "\(AppInfo.appName) is invite-only. Enter the invite code a friend sent you to join."
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
    /// Set when the profile could not be FETCHED, as distinct from not existing.
    ///
    /// Collapsing those two into "currentUser is nil" is the whole bug: a signed-in user with no
    /// connection was routed to the SIGN-UP screen, and typing the name they already owned
    /// answered "That username's taken". There was no sign-out, no retry and no back, so
    /// force-quitting was the only way out.
    var profileUnavailable = false
    var error: String?

    private(set) var pendingEmail: String?

    /// The session the caches and `currentUser` currently belong to.
    ///
    /// Compared rather than blindly bumped, so calling `noteSession` repeatedly for the same
    /// account is free. Over-bumping would be its own bug: it would invalidate the very fetch a
    /// sign-in just started and leave the user on the username screen.
    private var lastSessionUserId: UUID?

    // Whether a code was actually redeemed for the email currently signing up lives in
    // `PendingInviteRedeemed`, not here: see that type's own doc for why an in-memory flag isn't
    // enough (it doesn't survive the app being reclaimed while the person is away checking email
    // for the OTP `verifyOTP` below is waiting on).

    /// Records which account is live, bumping the epoch when it actually changes.
    private func noteSession(_ id: UUID?) {
        guard id != lastSessionUserId else { return }
        lastSessionUserId = id
        AccountEpoch.bump()
    }

    /// Fetches the profile and assigns it, discarding the result if the account changed while the
    /// request was in flight.
    ///
    /// The discard has to wrap the ASSIGNMENT, not just the fetch. Returning nil from a stale call
    /// and assigning it would clobber a profile the new sign-in had already set correctly, turning
    /// "shows the wrong account" into "shows no account", which is better but still wrong.
    private func refreshCurrentUser(id: UUID) async {
        let epoch = AccountEpoch.current
        do {
            let profile = try await fetchUserProfile(id: id)
            guard AccountEpoch.isCurrent(epoch) else { return }
            currentUser = profile
            profileUnavailable = false
        } catch {
            guard AccountEpoch.isCurrent(epoch) else { return }
            // Only unavailable if we have nothing to show. A cached profile from earlier in the
            // session is better than an error screen, and stays on screen.
            profileUnavailable = currentUser == nil
        }
    }

    /// Retries the profile fetch after a failure, for the error state the router shows.
    func retryProfileLoad() async {
        guard let session = try? await supabase.auth.session else { return }
        isResolvingProfile = true
        await refreshCurrentUser(id: session.user.id)
        isResolvingProfile = false
    }

    init() {
        Task { await bootstrap() }
    }

    // MARK: - Bootstrap

    private func bootstrap() async {
        do {
            let session = try await supabase.auth.session
            noteSession(session.user.id)
            isAuthenticated = true
            // Held on the splash while this resolves, so a slow launch never flashes sign-up.
            isResolvingProfile = true
            await refreshCurrentUser(id: session.user.id)
            isResolvingProfile = false
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
    ///
    /// `nonisolated` because `isReviewerEmail` below is, and reads this. The class is `@MainActor`,
    /// so without this the read crosses isolation: a warning in Swift 5 and an ERROR in Swift 6.
    /// An immutable string constant is safe to read from anywhere, which is what makes the
    /// annotation honest rather than a silencer.
    nonisolated static let reviewerEmail = "review@flim-app.com"

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
        noteSession(session.user.id)
        // Captured AFTER noteSession, which is the call that bumps. Capturing before it means
        // this sign-in's own bump immediately invalidates its own generation, so the guard below
        // can never pass and the flag is never lowered.
        let epoch = AccountEpoch.current
        isResolvingProfile = true
        isAuthenticated = true
        await refreshCurrentUser(id: session.user.id)
        // Only the sign-in that is still current may lower this flag. Otherwise a superseded
        // sign-in clears it while a NEWER one is still resolving, and the router briefly shows the
        // username screen, which is the exact flash the flag exists to prevent.
        guard AccountEpoch.isCurrent(epoch) else { return }
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

    /// How many invites the signed-in account has left.
    ///
    /// Three states, and the difference between the last two matters to the UI: a real count, an
    /// account deliberately granted unlimited (the server stores NULL for that), and "we do not
    /// know", which is what a network failure or a server that has not run the quota migration
    /// yet both look like.
    enum InviteQuota: Equatable {
        case remaining(Int)
        case unlimited
        /// Never render a number for this. Not zero: showing "0 invites left" to someone whose
        /// request merely failed would tell them they are out when they are not.
        case unknown
    }

    /// One invite the caller has already spent, and who it went to.
    ///
    /// `handle` is nil when the person was allowlisted but has not created an account yet. The
    /// server NEVER returns the email an invite was sent to: `allowed_emails` is otherwise
    /// unreadable by clients and this read path must not become the hole that exposes it.
    struct SentInvite: Decodable, Identifiable, Equatable {
        let handle: String?
        let sentAt: Date
        /// Whether they have taken a photo, which is what earns the inviter one back.
        let activated: Bool

        /// `sentAt` is the stable identity here, not the handle: a pending invite has no handle,
        /// and two of them would collide into one row.
        var id: Date { sentAt }

        enum CodingKeys: String, CodingKey {
            case handle
            case sentAt = "sent_at"
            case activated
        }
    }

    /// The people this account has invited, oldest first.
    ///
    /// FAILS SOFT to an empty list for the same reason `ownInviteQuota` does: the server must run
    /// the migration that adds `get_own_invites_sent()` before this can succeed, and a client that
    /// shipped first would otherwise throw. An empty list is also a perfectly ordinary answer, so
    /// the screen already has to render it well.
    func ownInvitesSent() async -> [SentInvite] {
        (try? await supabase.rpc("get_own_invites_sent").execute().value) ?? []
    }

    /// Reads the caller's OWN remaining invites.
    ///
    /// An RPC rather than a column read on purpose: `invite_uses_remaining` is not in the
    /// `GRANT SELECT` column list on `users`, so it is unreadable by direct select even for the
    /// row's own owner. `get_own_invite_quota()` is pinned to `auth.uid()` inside its body and
    /// takes no parameters, so there is nothing to point at another account.
    ///
    /// FAILS SOFT, deliberately. The server must run the quota migration before this function
    /// exists, and a client that shipped first would otherwise throw on a missing function. Any
    /// failure returns `.unknown` and the invite screen simply says nothing about counts, which
    /// makes the deploy order between this build and that migration a non-issue.
    func ownInviteQuota() async -> InviteQuota {
        do {
            let remaining: Int? = try await supabase.rpc("get_own_invite_quota").execute().value
            guard let remaining else { return .unlimited }
            return .remaining(max(0, remaining))
        } catch {
            return .unknown
        }
    }

    /// Redeems an invite code for `email`, allowlisting it server-side. Returns `true` if the
    /// code was valid (also `true`, idempotently, if the email was already allowlisted).
    /// `false` means the code doesn't exist. The caller is responsible for proceeding via
    /// `sendOTP(email:)` on success, `is_email_allowed` stays the single source of truth there.
    func redeemInvite(code: String, email: String) async throws -> Bool {
        let normalizedCode = Self.normalizeInviteCode(code)
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        do {
            let redeemed: Bool = try await supabase
                .rpc("redeem_invite", params: ["p_code": normalizedCode, "p_email": normalizedEmail])
                .execute()
                .value
            // Consumed by the `verifyOTP` that completes this same sign-up, once a session
            // actually exists for the activation RPC to attribute the event to. Persisted (see
            // `PendingInviteRedeemed`), not just held in memory, so it survives the app being
            // reclaimed while the person is off reading the code out of their email.
            if redeemed { PendingInviteRedeemed.markRedeemed(for: normalizedEmail) }
            return redeemed
        } catch let error as PostgrestError where Self.isRateLimited(code: error.code, message: error.message) {
            throw AuthError.rateLimited
        }
    }

    func verifyOTP(token: String) async throws {
        guard let email = pendingEmail else { return }
        try await supabase.auth.verifyOTP(email: email, token: token, type: .email)
        let session = try await supabase.auth.session
        noteSession(session.user.id)
        // Keyed by `email`, not a bare flag: only a redemption that actually belongs to THIS
        // email can complete here, so a code redeemed for one address and abandoned can never
        // attach itself to a later, unrelated sign-in. See `PendingInviteRedeemed`.
        if PendingInviteRedeemed.take(for: email) {
            Activation.log(.inviteRedeemed)
        }
        let epoch = AccountEpoch.current   // after the bump, see signInWithPassword
        isResolvingProfile = true
        isAuthenticated = true
        await refreshCurrentUser(id: session.user.id)
        // Only the sign-in that is still current may lower this flag. Otherwise a superseded
        // sign-in clears it while a NEWER one is still resolving, and the router briefly shows the
        // username screen, which is the exact flash the flag exists to prevent.
        guard AccountEpoch.isCurrent(epoch) else { return }
        isResolvingProfile = false
        pendingEmail = nil
    }

    // Handles magic link tap on real device
    func handle(url: URL) async {
        let epoch = AccountEpoch.current
        do {
            try await supabase.auth.session(from: url)
            let session = try await supabase.auth.session
            noteSession(session.user.id)
            await refreshCurrentUser(id: session.user.id)
        } catch {
            guard AccountEpoch.isCurrent(epoch) else { return }
            self.error = "Sign-in link expired. Please request a new one."
        }
    }

    // MARK: - Username Setup

    /// Why a username is rejected, or nil if it is fine.
    ///
    /// Exists because the sign-up screen only disabled the Continue button, so typing something
    /// like "apple-review" left a person staring at a dead button with no idea which of the rules
    /// they had broken. The static hint above the field was also wrong: it said "letters and
    /// numbers only" while underscores have always been allowed.
    ///
    /// Empty returns nil deliberately. Nagging someone before they have typed anything is noise,
    /// not help.
    ///
    /// Character problems are reported BEFORE length problems: a too-short name fixes itself as
    /// you keep typing, whereas an illegal character never will, so it is the more useful thing to
    /// say first when a name is both.
    nonisolated static func usernameRejection(_ username: String) -> String? {
        guard !username.isEmpty else { return nil }
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "_"))
        guard username.unicodeScalars.allSatisfy(allowed.contains) else {
            return "Letters, numbers and underscores only."
        }
        if username.count < 3 { return "A little longer: at least 3 characters." }
        if username.count > 20 { return "A little shorter: 20 characters at most." }
        return nil
    }

    /// Valid usernames: 3–20 chars, letters/numbers/underscore only.
    nonisolated static func isValidUsername(_ username: String) -> Bool {
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
        await refreshCurrentUser(id: userId)
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
        await refreshCurrentUser(id: session.user.id)
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
        await refreshCurrentUser(id: session.user.id)
    }

    /// Sets (or clears) the signed-in account's chosen badge selection, via the zero-trust
    /// `set_displayed_badges` RPC (own row only, no user-id argument exists). Passing `nil`
    /// reverts to the server's rarest-four default; passing `[]` stores the deliberate
    /// "show none" state; passing a non-empty ordered list stores that exact order.
    ///
    /// The RPC itself enforces the cap, rejects duplicates and unearned ids, so a rejection here
    /// is always a real refusal, not this client's own bug — the caller (`BadgePickerSheet`)
    /// surfaces the thrown error and leaves the sheet open so the pick is retryable, mirroring
    /// `setBio`/`setDisplayName`'s dismiss-only-on-success shape.
    func setDisplayedBadges(_ badgeIds: [String]?) async throws {
        let session = try await supabase.auth.session
        // NOT a plain `struct Params: Encodable { let p_badge_ids: [String]? }`: Codable
        // synthesis encodes an Optional property with `encodeIfPresent`, which DROPS the key
        // entirely when the value is nil rather than writing JSON `null`. The RPC has no default
        // for `p_badge_ids` (see the migration), so a dropped key is a missing argument, not
        // "pass null" — Postgrest would 404 with "function ... does not exist" instead of
        // reaching the SQL function's own `IF p_badge_ids IS NULL` branch. This writes the key
        // unconditionally, `null` or the array, so "revert to automatic" actually reaches SQL.
        struct Params: Encodable {
            let p_badge_ids: [String]?
            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                if let p_badge_ids {
                    try container.encode(p_badge_ids, forKey: .p_badge_ids)
                } else {
                    try container.encodeNil(forKey: .p_badge_ids)
                }
            }
            enum CodingKeys: String, CodingKey { case p_badge_ids }
        }
        _ = try await supabase.rpc("set_displayed_badges", params: Params(p_badge_ids: badgeIds)).execute()
        await refreshCurrentUser(id: session.user.id)
    }

    /// Sets the profile avatar from one of the user's photos. Copies the image into its own
    /// Storage object so the avatar survives the source photo being deleted.
    /// Returns whether it landed, like its `fromImageData` sibling. Returning Void here meant a
    /// failure was swallowed at the source, so even the caller that wanted to report it could not.
    @discardableResult
    func setAvatar(fromPhotoPath sourcePath: String) async -> Bool {
        guard let raw = await imageData(atPath: sourcePath) else { return false }
        return await setAvatar(fromImageData: raw)
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
    /// Returns false when the upload or the row update failed, so the caller can say so. It used
    /// to return Void, which made a failed avatar indistinguishable from the user imagining it.
    @discardableResult
    func setAvatar(fromImageData raw: Data) async -> Bool {
        guard let session = try? await supabase.auth.session,
              let dest = await uploadOwnedImage(raw, prefix: "avatar", userId: session.user.id, longEdge: 512)
        else { return false }
        let old = currentUser?.avatarPath
        struct Update: Encodable { let avatar_path: String }
        guard (try? await supabase
            .from("users").update(Update(avatar_path: dest), returning: .minimal)
            .eq("id", value: session.user.id.uuidString).execute()) != nil
        else { return false }
        await refreshCurrentUser(id: session.user.id)
        cleanupOldCopy(old, keeping: dest, prefix: "avatar")
        return true
    }

    /// Sets the profile cover/header from one of the user's photos (its own Storage copy).
    @discardableResult
    func setCover(fromPhotoPath sourcePath: String) async -> Bool {
        guard let raw = try? await supabase.storage.from("photos").download(path: sourcePath) else { return false }
        return await setCover(fromImageData: raw)
    }

    /// Sets the cover from a picked library photo. Same reasoning as `setAvatar(fromImageData:)`:
    /// no FLIM grade on an imported picture, and downscaled to the cover's own 640pt cap.
    /// Returns false when the upload or the row update failed, so the caller can say so. It used
    /// to return Void, which made a failed cover indistinguishable from the user imagining it.
    @discardableResult
    func setCover(fromImageData raw: Data) async -> Bool {
        guard let session = try? await supabase.auth.session,
              let dest = await uploadOwnedImage(raw, prefix: "cover", userId: session.user.id, longEdge: 1280)
        else { return false }
        let old = currentUser?.coverPath
        struct Update: Encodable { let cover_path: String }
        guard (try? await supabase
            .from("users").update(Update(cover_path: dest), returning: .minimal)
            .eq("id", value: session.user.id.uuidString).execute()) != nil
        else { return false }
        await refreshCurrentUser(id: session.user.id)
        cleanupOldCopy(old, keeping: dest, prefix: "cover")
        return true
    }

    /// Writes image data into a fresh object in the user's own folder, returning its path.
    ///
    /// Shared by both sources: a Darkroom shot (downloaded first, so the avatar survives the
    /// source photo being deleted) and a photo picked from the library. Neither is graded, and
    /// both land at the same size cap, so where a profile picture came from makes no difference
    /// to what gets stored.
    /// `longEdge` is in PIXELS. It used to be a point size that `thumbnail` silently doubled, so
    /// the call sites passed 256 and 640 and stored 512 and 1280. The doubling is gone; the
    /// numbers below are the same stored sizes, written out.
    private func uploadOwnedImage(_ raw: Data, prefix: String, userId: UUID, longEdge: CGFloat) async -> String? {
        // Downscale, an avatar/cover never needs the full image (saves storage + egress).
        //
        // Refuses rather than falling back to the raw bytes, which is what it used to do. A
        // profile picture comes from the photo library, so unlike everything else in the bucket
        // its bytes are the user's file in the user's format: a PNG screenshot, an HEIC from the
        // camera, whatever they picked. ImageIO reads all of those and re-encodes, which is why
        // the INPUT format has never mattered.
        //
        // When that conversion fails, `?? raw` uploaded the ORIGINAL instead — undownscaled, and
        // labelled `image/jpeg` under a `.jpg` name whatever it actually was. That is the only
        // path in the app that can put a multi-megabyte file in the bucket, and it stores a lie
        // about its own type. Failing is better: the caller already returns false and the UI
        // already says so.
        //
        // `thumbnail` always encodes JPEG (`thumbEncoding`, HEIC was measured and rejected), but
        // the content type and path suffix below are still derived from whatever it actually
        // produced rather than assumed, so a future change to that encoding can't silently
        // mislabel the object it just uploaded.
        guard let encoded = InstantFilmProcessor.thumbnail(from: raw, longEdge: longEdge) else { return nil }
        let dest = "\(userId.uuidString.lowercased())/\(prefix)-\(UUID().uuidString.lowercased()).\(encoded.format.pathExtension)"
        do {
            try await supabase.storage.from("photos")
                .upload(dest, data: encoded.data, options: FileOptions(contentType: encoded.format.contentType))
            return dest
        } catch { return nil }
    }

    /// Whether a redeem failure was the server refusing for rate limiting, rather than a bad code.
    ///
    /// Two shapes because the RPC signals it two ways depending on how it raises: a SQLSTATE
    /// (`P0003`) and a message. Extracted so the rule can be tested at all: inside a `catch where`
    /// clause it was reachable only by provoking a real 429 from the live server, and getting it
    /// wrong turns "slow down for a minute" into "your invite code is invalid", which sends
    /// someone off to ask for a new code that will fail exactly the same way.
    nonisolated static func isRateLimited(code: String?, message: String?) -> Bool {
        code == "P0003" || message == "rate_limited"
    }

    /// Whether an old avatar/cover copy is safe to delete.
    ///
    /// This is the only delete in the app that runs without asking, so it is the one worth
    /// pinning. It must be true ONLY for a resized copy this code made (those paths carry an
    /// `avatar-` or `cover-` segment). A real capture never does, and deleting one would destroy
    /// a photograph to save a few kilobytes.
    nonisolated static func shouldCleanUpOldCopy(_ old: String?, keeping newPath: String, prefix: String) -> Bool {
        guard let old, !old.isEmpty, old != newPath else { return false }
        return old.contains("/\(prefix)-")
    }

    /// Best-effort delete of a previous avatar/cover copy (only our own copies, never a real photo).
    private func cleanupOldCopy(_ old: String?, keeping newPath: String, prefix: String) {
        guard let old, Self.shouldCleanUpOldCopy(old, keeping: newPath, prefix: prefix) else { return }
        Task { _ = try? await supabase.storage.from("photos").remove(paths: [old]) }
    }

    func signOut() async throws {
        // Local state is cleared in a `defer`, so it happens even if the network call throws.
        //
        // It used to come after, and the only caller uses `try?`: a sign-out that failed on a
        // flaky connection therefore left the app fully signed in with the error swallowed, and
        // left a session behind that a later sign-in had to displace. Signing out is a local
        // intention first and a server round trip second; the round trip failing must not mean
        // the user stays signed in.
        defer {
            currentUser = nil
            isAuthenticated = false
            pendingEmail = nil
            noteSession(nil)
            NotificationCenter.default.post(name: .flimAccountDidChange, object: nil)
        }
        // Before the session goes, not after: the device_tokens row is only deletable
        // by the account that owns it, so once signOut() lands there is no longer any
        // way to detach this device. Leaving it attached meant the next digest for
        // this account was delivered to whoever signed in here afterwards, carrying
        // this account's follow list with it.
        await RemotePush.unregisterCurrentDevice()
        try await supabase.auth.signOut()
    }

    /// What the account-deletion page shows before the held confirm: server-side counts of
    /// the caller's photos, created rolls, and posts (the `account_inventory` RPC, pinned to
    /// auth.uid()). Server counts on purpose: the client's photo list is paginated and any
    /// local count would understate exactly when the number matters most. `nil` on any
    /// failure; the page then says it couldn't load the numbers rather than showing zeros.
    struct AccountInventory: Codable {
        let photos: Int
        let rollsCreated: Int
        let posts: Int
        enum CodingKeys: String, CodingKey {
            case photos
            case rollsCreated = "rolls_created"
            case posts
        }
    }

    func accountInventory() async -> AccountInventory? {
        try? await supabase.rpc("account_inventory").single().execute().value
    }

    /// Permanently deletes the account + all associated data (App Store Guideline 5.1.1(v)).
    /// The `delete_account` RPC removes the auth user, which cascades to the profile, rolls,
    /// memberships, photos, and reports. Then we clear the local session.
    func deleteAccount() async throws {
        // Remove the user's stored image files first, the RPC cascades the DB rows but
        // not the physical objects in Storage, which would otherwise be orphaned.
        //
        // Everything in their folder, not a list derived from the photos table.
        //
        // This used to select `storage_path` alone and delete only that, which left every
        // thumbnail, every 1400px card, and the avatar and cover behind. On a promise to delete
        // an account that is worse than a leak: someone asks to be forgotten and their
        // photographs stay in the bucket at two of the three sizes. It is also the exact shape of
        // the bug that stranded 160 MB of feed cards, written a second time in a second place.
        //
        // Enumerating the folder cannot drift the way a hand-written column list does: a fourth
        // rendition, or anything else ever written under the user's prefix, is covered without
        // anyone remembering to come back here.
        if let session = try? await supabase.auth.session {
            let uid = session.user.id.uuidString.lowercased()
            while true {
                guard let objects = try? await supabase.storage.from("photos")
                    .list(path: uid, options: SearchOptions(limit: 1000)), !objects.isEmpty else { break }
                _ = try? await supabase.storage.from("photos")
                    .remove(paths: objects.map { "\(uid)/\($0.name)" })
                if objects.count < 1000 { break }
            }
        }

        try await supabase.rpc("delete_account").execute()
        try? await supabase.auth.signOut()
        currentUser = nil
        isAuthenticated = false
        // Same reason signOut bumps: clearing the account without advancing the generation leaves
        // an in-flight profile fetch from the departing session able to repopulate currentUser.
        noteSession(nil)
    }

    // MARK: - Helpers

    /// The signed-in user's FULL row, email + invite_code are hidden from plain table selects
    /// by column-level grants, so the own row comes through the locked-down get_own_profile RPC.
    /// The signed-in user's profile, verified to actually BE the signed-in user's.
    ///
    /// `get_own_profile()` is `SELECT * FROM users WHERE id = auth.uid()`, so it is correct by
    /// construction on the server. What it cannot defend against is being asked with the wrong
    /// token: if a request goes out carrying a previous session's JWT, the server answers
    /// truthfully for THAT user and the app displays the wrong account with no error anywhere.
    ///
    /// This is not theoretical. Signing in as the App Review account produced a session for that
    /// account, confirmed by its `last_sign_in_at`, while the app showed the previous user's
    /// profile. Whatever the exact cause on the client, the guard below turns a wrong-account
    /// display into no account at all, which routes to the username screen instead of silently
    /// presenting someone else's identity.
    ///
    /// The `id` parameter used to be ignored entirely, which is what made the mismatch invisible:
    /// the function took the thing it needed to check and then didn't check it.
    private func fetchUserProfile(id: UUID) async throws -> AppUser? {
        let profile: AppUser
        do {
            profile = try await supabase.rpc("get_own_profile").single().execute().value
        } catch let error as URLError {
            // Could not reach the server at all. Deliberately rethrown rather than folded into
            // nil: nil means "this account has no profile yet", which routes a person to sign-up,
            // and doing that to someone who simply has no signal is how they get locked out.
            throw error
        } catch {
            // The server answered and had nothing for us. That is the genuine new-user path, and
            // it must keep working, which is why only URLError is treated as unavailable rather
            // than every error.
            return nil
        }

        guard profile.id == id else {
            // Loud, because it means the client and the server disagree about who is signed in.
            Logger(subsystem: "com.flim.app", category: "auth")
                .fault("profile identity mismatch: session \(id, privacy: .public) got profile \(profile.id, privacy: .public)")
            assertionFailure("get_own_profile returned a different user than the session")
            return nil
        }
        return profile
    }

    private func listenForAuthChanges() async {
        for await (event, _) in supabase.auth.authStateChanges {
            switch event {
            case .signedIn:
                if let session = try? await supabase.auth.session {
                    noteSession(session.user.id)
                    let epoch = AccountEpoch.current
                    isResolvingProfile = true
                    isAuthenticated = true
                    await refreshCurrentUser(id: session.user.id)
                    guard AccountEpoch.isCurrent(epoch) else { continue }
                    isResolvingProfile = false
                }
            case .signedOut:
                // Fires for causes the app did not initiate too, an expired or revoked session,
                // so it cannot rely on signOut()'s own bump.
                noteSession(nil)
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
