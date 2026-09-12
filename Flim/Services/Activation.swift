import Foundation
import Supabase

/// The ten activation milestones the product can act on. Each is a one-time-per-user
/// "did this ever happen" milestone, not an event stream: the server's unique index on
/// (user_id, event) is what makes it safe to fire this on every capture/join/share rather than
/// something the client has to locally remember not to repeat. See
/// `supabase/migrations/2026-08-08_activation_events.sql` for the full server-side contract.
///
/// Raw values are exactly the strings the server's CHECK constraint allows. Nothing
/// outside `Activation.log(_:)` should ever hand the RPC a bare string: a typo there is a loud
/// server-side rejection, not a silently poisoned row, and routing every call through this enum
/// is what keeps a typo from ever reaching that call in the first place.
enum ActivationEvent: String {
    case firstLaunch = "first_launch"
    case firstShot = "first_shot"
    case rollCreated = "roll_created"
    case rollJoined = "roll_joined"
    case inviteSent = "invite_sent"
    case inviteRedeemed = "invite_redeemed"
    case postShared = "post_shared"
    case revealWatched = "reveal_watched"
    /// Fires once onboarding ends, from either its own CTA or Skip (see
    /// `OnboardingView.finishOnboarding()`). Sits between `firstLaunch` and `firstShot` so the
    /// funnel can tell "abandoned onboarding" apart from "reached the camera and left".
    case onboardingFinished = "onboarding_finished"
    /// Fires the moment the app confirms it HAS camera authorization (`CameraViewModel.start()`'s
    /// `.authorized` branch), not merely that it asked. Also sits between `firstLaunch` and
    /// `firstShot`, distinguishing a permission denial from someone who reached a working camera
    /// and simply never shot.
    case cameraAuthorized = "camera_authorized"
    /// Fires when the capture session is actually RUNNING, which is not the same as being
    /// authorized. A black viewfinder on an authorized camera is a bug this app has genuinely
    /// shipped before, and `cameraAuthorized` cannot tell that apart from a working camera
    /// somebody walked away from.
    case cameraReady = "camera_ready"
    /// Fires the first time someone actually presses the shutter, whatever happens next. Sitting
    /// between `cameraReady` and `firstShot`, it separates "never tried" from "tried and the
    /// capture failed", which look identical from the funnel today and want opposite fixes.
    case shutterTapped = "shutter_tapped"
    /// The notification permission decision, as the OS reports it.
    ///
    /// Neither event is logged for `notDetermined`, and that is the whole design: the ABSENCE of
    /// both is what identifies somebody who was never asked. The prompt only fires from four
    /// places (post-capture, an undeveloped roll, the settings toggle, the primer), so a path that
    /// misses all four never asks, and until now that was indistinguishable from a refusal.
    ///
    /// Measured 2026-08-19: 42 accounts had `cameraAuthorized` and 25 held a device token. Those
    /// 17 are either a lost cause or 17 people one prompt away, and nothing could say which.
    case notificationsAuthorized = "notifications_authorized"
    case notificationsDenied = "notifications_denied"
}

/// Fire-and-forget activation instrumentation. `log_activation_event` is safe to call this
/// carelessly on purpose: it no-ops server-side when signed out, and its unique index dedupes a
/// repeat call from a retried capture, a second share, or a reinstalled app, so the client never
/// has to track "have I already sent this" itself.
///
/// A plain enum, not `@MainActor` or `@Observable`: unlike the services in this directory it
/// holds no UI state for any view to read, so nothing here needs isolating, and any caller (a
/// `@MainActor` view model, a background capture task) can log an event with no actor hop.
enum Activation {
    /// Fires and returns immediately; never awaited by the caller, never throws, and must never
    /// slow down or fail the real action it rides along with (a capture, a roll join, a reveal
    /// open). It used to never retry either, on the reasoning that a dropped event only delays a
    /// milestone until the next action of that kind. That is not true of the firsts that matter
    /// most: `first_launch` on a bad connection has no next time, and the funnel we plan from
    /// undercounted exactly the people it most needs to see. An event that fails to send is now
    /// queued (UserDefaults, deduped) and flushed on the next launch. The server keeps one row
    /// per person per event, so a retry after a lost response is harmless.
    static var store: UserDefaults = .standard
    private static let pendingKey = "activation.pending"

    /// The account the queue belongs to. Entries are keyed by it, so a milestone that failed
    /// to send under one account is never flushed under the next, and a pre-sign-in milestone
    /// (first launch, onboarding) waits under a neutral key until an account exists and is then
    /// attributed to it: those events happen before there is a user, and the first account
    /// on this phone is the one they belong to.
    static var activeUserId: UUID? = nil
    private static let neutralOwner = "none"
    private static var owner: String { activeUserId?.uuidString.lowercased() ?? neutralOwner }
    private static let flushLock = NSLock()
    private static var flushing = false

    static func log(_ event: ActivationEvent) {
        let key = owner
        Task {
            if await send(event.rawValue) { return }
            enqueue(event.rawValue, owner: key)
        }
    }

    /// Sends what is queued for the current account, and anything queued before sign-in, one
    /// entry at a time, removing each entry from the SAME queue it was read from only once its
    /// own send succeeded. Serialized: a flush already running is not started twice, and an
    /// event logged mid-flush lands in the store untouched because entries are removed one by
    /// one rather than by writing back a snapshot. Entries from before this queue was keyed
    /// (the old unscoped key) are adopted as pre-sign-in entries the first time.
    static func flushPending() {
        flushLock.lock()
        if flushing { flushLock.unlock(); return }
        flushing = true
        flushLock.unlock()
        migrateLegacyQueue()
        guard let user = activeUserId else {
            flushLock.lock(); flushing = false; flushLock.unlock()
            return   // nothing can be attributed yet; the neutral queue waits
        }
        let owners = [user.uuidString.lowercased(), neutralOwner]
        Task {
            defer { flushLock.lock(); flushing = false; flushLock.unlock() }
            for key in owners {
                for raw in pending(owner: key) {
                    // Still the same account? The queue is keyed by it; a switch mid-flush
                    // stops here and the rest waits for that account's next flush.
                    guard activeUserId == user else { return }
                    guard await send(raw) else { return }
                    remove(raw, owner: key)
                }
            }
        }
    }

    private static func migrateLegacyQueue() {
        guard let legacy = store.stringArray(forKey: pendingKey), !legacy.isEmpty else { return }
        for raw in legacy { enqueue(raw, owner: neutralOwner) }
        store.removeObject(forKey: pendingKey)
    }

    private static func send(_ raw: String) async -> Bool {
        do {
            _ = try await supabase.rpc("log_activation_event", params: ["p_event": raw]).execute()
            return true
        } catch {
            return false
        }
    }

    private static func key(for owner: String) -> String { "\(pendingKey).\(owner)" }
    static func pending(owner: String? = nil) -> [String] {
        store.stringArray(forKey: key(for: owner ?? Self.owner)) ?? []
    }

    static func enqueue(_ raw: String, owner: String? = nil) {
        let k = key(for: owner ?? Self.owner)
        var list = store.stringArray(forKey: k) ?? []
        guard !list.contains(raw) else { return }
        list.append(raw)
        store.set(list, forKey: k)
    }

    private static func remove(_ raw: String, owner: String) {
        let k = key(for: owner)
        var list = store.stringArray(forKey: k) ?? []
        list.removeAll { $0 == raw }
        if list.isEmpty { store.removeObject(forKey: k) } else { store.set(list, forKey: k) }
    }
}
