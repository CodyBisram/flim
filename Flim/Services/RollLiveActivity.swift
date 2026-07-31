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
    static func sync(rollId: UUID, rollName: String, revealAt: Date, shotCount: Int) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let newState = RollRevealAttributes.ContentState(shotCount: shotCount, revealAt: revealAt)
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

    /// Called opportunistically once a roll is seen to have developed, there's no push-driven
    /// lifecycle here, so a roll's Live Activity only ends the next time the app is opened after
    /// it develops, not the instant it does. A no-op if nothing is running (never started, or
    /// already ended on another device/session).
    static func end(rollId: UUID) {
        guard let activity = running(rollId) else { return }
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    private static func running(_ rollId: UUID) -> Activity<RollRevealAttributes>? {
        Activity<RollRevealAttributes>.activities.first { $0.attributes.rollId == rollId.uuidString }
    }
}
