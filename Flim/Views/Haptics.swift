import UIKit

/// The app's haptic vocabulary. Every tactile moment goes through one of these, so the same KIND
/// of event feels the same wherever it happens: an ordinary button is never a success chime, and
/// committing something irreversible never feels like an ordinary button.
///
/// Generators are held and kept warm rather than created per call. `UIFeedbackGenerator` spins the
/// Taptic Engine up lazily, so a freshly-allocated generator fired immediately can land late or be
/// dropped outright, which is why haptics that fire rarely (the first shutter press of a session,
/// a delete confirmation) used to feel mushier than ones that fire constantly. Each call re-arms
/// its generator afterwards so a repeat is instant too.
@MainActor
enum Haptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let notification = UINotificationFeedbackGenerator()

    /// Warms the Taptic Engine so the first haptic of a session isn't the laggy one. Called at
    /// launch and when the camera appears (the shutter is the one place latency is obvious).
    static func prepare() {
        light.prepare()
        rigid.prepare()
        notification.prepare()
    }

    // MARK: - Neutral

    /// An ordinary control: a button, a tab, a toggle, opening a sheet.
    static func tap() {
        light.impactOccurred()
        light.prepare()
    }

    /// A firmer bump for a mode change, entering multi-select via long-press.
    static func select() {
        medium.impactOccurred()
        medium.prepare()
    }

    // MARK: - Outcomes

    /// An action completed: a post shared, a roll created or joined, an invite code accepted.
    static func success() {
        notification.notificationOccurred(.success)
        notification.prepare()
    }

    /// Committing something irreversible or with reach beyond you: deleting a photo, post or
    /// roll, leaving a roll, blocking someone, wiping your data. Deliberately distinct from
    /// `tap()`, the confirmation button should not feel like the button that opened it.
    ///
    /// Reversible, self-contained removals (deleting your own comment, unfollowing) stay `tap()`,
    /// a warning buzz for those would cry wolf.
    static func warning() {
        notification.notificationOccurred(.warning)
        notification.prepare()
    }

    /// Something went wrong (a send failed, an action didn't stick).
    static func error() {
        notification.notificationOccurred(.error)
        notification.prepare()
    }

    // MARK: - Signature moments

    /// The shutter press.
    static func shutter() {
        rigid.impactOccurred(intensity: 0.9)
        rigid.prepare()
    }

    /// Photos finishing developing. The app's marquee moment, so it gets its own two-beat cue
    /// (a soft knock, then the success chime) rather than the same buzz as any other completed
    /// action, it should feel like something ARRIVED, not merely that a request went through.
    static func reveal() {
        light.impactOccurred(intensity: 0.7)
        light.prepare()
        Task {
            try? await Task.sleep(for: .milliseconds(90))
            notification.notificationOccurred(.success)
            notification.prepare()
        }
    }
}
