import UIKit

/// Lightweight haptic helpers for the moments that should feel tactile —
/// the shutter press and a photo reveal.
enum Haptics {
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func shutter() {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.9)
    }

    static func reveal() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
