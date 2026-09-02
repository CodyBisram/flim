import ActivityKit
import Foundation

/// Starts, updates, and ends the Live Activity that counts down to a roll's reveal. Stateless by
/// design (matches Haptics), the system, via Activity<RollRevealAttributes>.activities, is
/// already the source of truth for what's running, so looking it up fresh on every call means
/// this works correctly even after the app was relaunched since a roll started counting down,
/// with nothing local to fall out of sync.
///
/// The countdown itself never needs an update call: the widget renders it with
/// Text(timerInterval:), which ticks on-device driven by the fixed revealAt date, not by us
/// pushing new state. sync() only exists to keep shotCount current and to (re)start the activity
///, safe to call repeatedly, including for a roll someone joined rather than created, since
/// there's nothing to start a Live Activity for until they've actually opened the roll once.
enum RollLiveActivity {
    /// The system ends a Live Activity after roughly 8 hours and clears it from the lock screen
    /// by about 12. A roll develops in 12. So an activity started when the roll was created goes
    /// dark somewhere around hour 8 and is gone for the final stretch, which is the only part
    /// anyone is actually waiting through: it counted down to a moment it was never alive to see.
    ///
    /// There is no push lifecycle here to fix that from the server, so the app re-requests
    /// instead, whenever it is opened (see `syncActive`). Cheap, because `sync` is a no-op when
    /// an activity is already running and unchanged.
    static func sync(rollId: UUID, rollName: String, revealAt: Date, shotCount: Int,
                     developFrom: Date, accent: String = UserDefaults.standard.string(forKey: "accentColor") ?? FlimAccentPalette.fallback) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // Nothing to count down to. Requesting one here would put a card on the lock screen that
        // is already expired, and the system would end it moments later.
        guard !RollRevealAttributes.hasRevealed(revealAt) else { return }
        let newState = RollRevealAttributes.ContentState(shotCount: shotCount, revealAt: revealAt,
                                                        developFrom: developFrom, accent: accent)
        if let activity = running(rollId) {
            guard activity.content.state != newState else { return }
            Task { await activity.update(.init(state: newState, staleDate: revealAt)) }
        } else {
            let attributes = RollRevealAttributes(rollId: rollId.uuidString, rollName: rollName)
            do {
                _ = try Activity.request(attributes: attributes, content: .init(state: newState, staleDate: revealAt))
            } catch {
                // Live Activities can fail to start for reasons entirely outside our control
                // (the user disabled them, a system-wide limit), the roll works exactly the
                // same without one, so there's nothing to recover from here.
            }
        }
    }

    /// Ends and re-requests this roll's activity so a fresh `rollName` takes effect.
    ///
    /// `rollName` lives on `RollRevealAttributes`, not `ContentState`, and ActivityKit attributes
    /// are immutable for the life of an activity: `update()` can only touch `content.state`. So a
    /// rename of a still-developing roll has exactly one way to reach the lock screen, ending the
    /// old activity and requesting a new one, which is what this does, carrying over every other
    /// field from the running activity's own state (shot count, reveal time, develop-from, accent)
    /// so nothing but the name changes.
    ///
    /// A no-op if nothing is currently running for this roll: there is no card to fix, and
    /// starting one fresh here would show a lock-screen card for a roll nobody has opened since it
    /// started developing, which `sync` already deliberately avoids doing on its own.
    static func rename(rollId: UUID, to newName: String) {
        guard let activity = running(rollId) else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = activity.content.state
        guard !RollRevealAttributes.hasRevealed(state.revealAt) else { return }
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
            let attributes = RollRevealAttributes(rollId: rollId.uuidString, rollName: newName)
            do {
                _ = try Activity.request(attributes: attributes,
                                         content: .init(state: state, staleDate: state.revealAt))
            } catch {
                // Same as sync(): nothing to recover from if the system declines a fresh request.
            }
        }
    }

    /// Called opportunistically once a roll is seen to have developed, there's no push-driven
    /// lifecycle here, so a roll's Live Activity only ends the next time the app is opened after
    /// it develops, not the instant it does. A no-op if nothing is running (never started, or
    /// already ended on another device/session).
    static func end(rollId: UUID) {
        guard let activity = running(rollId) else { return }
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// Ends every Live Activity this app currently has running, for any roll.
    ///
    /// A Live Activity is scoped to a roll, not an account, so a lock-screen card started while
    /// one account was signed in stays live after that account signs out, showing the departed
    /// account's roll name to whoever signs in next on the same device. Call this on sign-out and
    /// on switching accounts, mirroring `NotificationService.cancelAllRollDevelopNotifications()`.
    static func endAll() {
        for activity in Activity<RollRevealAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// Ends any card whose roll is no longer one of yours.
    ///
    /// The safety net for a roll that disappears. `end(rollId:)` is called at the point of a
    /// delete or a leave, which covers the device that did it — but not a member whose roll was
    /// deleted by its creator, or a device that was asleep at the time, or a delete that failed
    /// partway. There is no push lifecycle here to tell them, so the card would count down to a
    /// reveal that is never coming, on a roll that no longer exists to open.
    ///
    /// Called from the Rolls list, which already re-syncs the activities for the rolls that DO
    /// exist; this is the other half of the same pass, and it costs one set lookup per card.
    static func reconcile(activeRollIds: [UUID]) {
        let live = Set(activeRollIds.map(\.uuidString))
        for activity in Activity<RollRevealAttributes>.activities where !live.contains(activity.attributes.rollId) {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// Whether a card is currently live for this roll. Callers use it to avoid paying for a shot
    /// count they only need when they are about to (re)start one.
    static func isRunning(_ rollId: UUID) -> Bool { running(rollId) != nil }

    /// How many rolls may hold a lock-screen card at once.
    ///
    /// The system caps concurrent activities, and past a couple of cards this stops being a
    /// countdown and becomes a lock screen full of FLIM. The rolls closest to revealing win,
    /// because those are the ones worth watching.
    static let maxConcurrent = 2

    /// The rolls that should hold a card right now: still developing, soonest first, capped.
    ///
    /// Pure, so the selection rule is testable without ActivityKit, which cannot run under test.
    static func rollsNeedingActivity<T>(_ rolls: [T], now: Date = .now,
                                        revealAt: (T) -> Date) -> [T] {
        rolls
            .filter { !RollRevealAttributes.hasRevealed(revealAt($0), now: now) }
            .sorted { revealAt($0) < revealAt($1) }
            .prefix(maxConcurrent)
            .map { $0 }
    }

    private static func running(_ rollId: UUID) -> Activity<RollRevealAttributes>? {
        Activity<RollRevealAttributes>.activities.first { $0.attributes.rollId == rollId.uuidString }
    }
}
