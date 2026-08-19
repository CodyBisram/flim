import Foundation
import Supabase

/// The ten activation milestones the product can act on. Each is a one-time-per-user
/// "did this ever happen" milestone, not an event stream: the server's unique index on
/// (user_id, event) is what makes it safe to fire this on every capture/join/share rather than
/// something the client has to locally remember not to repeat. See
/// `supabase/migrations/2026-08-08_activation_events.sql` for the full server-side contract.
///
/// Raw values are exactly the ten strings the server's CHECK constraint allows. Nothing
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
    /// Fires and returns immediately; never awaited by the caller. Never throws and never
    /// retries: a dropped event only delays a milestone until the user's next action of that
    /// kind, and this must never be able to slow down or fail the real action it rides along
    /// with (a capture, a roll join, a reveal open, …).
    static func log(_ event: ActivationEvent) {
        Task {
            _ = try? await supabase
                .rpc("log_activation_event", params: ["p_event": event.rawValue])
                .execute()
        }
    }
}
