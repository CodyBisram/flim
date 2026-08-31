import Foundation
import Supabase

/// The five repeated-occurrence events the product tracks for frequency/retention, as opposed to
/// `ActivationEvent`'s one-time-ever milestones. Raw values are exactly the five strings the
/// server's CHECK constraint allows.
///
/// This is a SEPARATE table and enum from `ActivationEvent`, not more cases on it, because the
/// two have opposite dedupe semantics and share nothing that would make combining them safe.
/// `activation_events` has a unique index on `(user_id, event)`, which is what lets `Activation`
/// fire carelessly on every capture/join/share: the server silently drops every call after the
/// first. `usage_events` instead dedupes by `(user_id, event, day)` and INCREMENTS a counter on
/// each call, precisely so it CAN be told about the same event happening again today. Adding
/// `.postShared` here as another `ActivationEvent` case would put it under the once-ever unique
/// index and permanently cap it at one row per user, silently discarding every count this file
/// exists to collect. See `supabase/migrations/2026-08-17_usage_events.sql` for the full
/// server-side contract.
enum UsageEvent: String {
    case appOpen = "app_open"
    case photoCaptured = "photo_captured"
    case postShared = "post_shared"
    case feedViewed = "feed_viewed"
    case revealWatched = "reveal_watched"
    // The invite share, tagged by the surface it happened on. `invite_sent` (activation) still
    // fires the once-ever milestone alongside these; these carry the volume and the source, which
    // is what tells us whether the reveal's closing invite converts against the profile and feed.
    case inviteSharedProfile = "invite_shared_profile"
    case inviteSharedFeed = "invite_shared_feed"
    case inviteSharedReveal = "invite_shared_reveal"
}

/// Fire-and-forget frequency/retention instrumentation, mirroring `Activation.log(_:)` exactly
/// except for what it means to call it twice: every genuine occurrence should call this, not just
/// the first, since `log_usage_event`'s per-day counter is the whole point of this table. A photo
/// captured five times today should call `.log(.photoCaptured)` five times; the server, not this
/// client, is what turns that into "5" for today's row.
///
/// A plain enum, not `@MainActor` or `@Observable`, same reasoning as `Activation`: this holds no
/// UI state for any view to read, so any caller (a `@MainActor` view model, a background capture
/// task) can log an event with no actor hop.
enum Usage {
    /// Fires and returns immediately; never awaited by the caller. Never throws and never
    /// retries: a dropped event only undercounts today's total by one, and this must never be
    /// able to slow down or fail the real action it rides along with (a capture, a share, a
    /// reveal open, …). Safe to call before the migration that defines `log_usage_event` ships:
    /// like `Activation.log`, a missing RPC just fails the `try?` silently.
    static func log(_ event: UsageEvent) {
        Task {
            _ = try? await supabase
                .rpc("log_usage_event", params: ["p_event": event.rawValue])
                .execute()
        }
    }

    /// Stamps this account's current app version server-side (`client_versions`, one row per
    /// user, latest wins), so "how many users are on 1.4.2" is a census query instead of App
    /// Store Connect's opt-in sample. Fired once per launch beside `log(.appOpen)`; every
    /// launch rather than only on version change, because `updated_at` doubling as "last seen
    /// running this version" is what makes the dashboard's number trustworthy. Same contract
    /// as `log`: fire-and-forget, never throws, safe before its migration ships.
    static func reportClientVersion() {
        Task {
            _ = try? await supabase
                .rpc("report_client_version",
                     params: ["p_version": AppInfo.shortVersion, "p_build": AppInfo.buildNumber])
                .execute()
        }
    }
}
