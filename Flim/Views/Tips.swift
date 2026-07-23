import TipKit

/// Teaches the non-obvious multi-select gesture in the Darkroom.
struct SelectTip: Tip {
    var title: Text { Text("Select several") }
    var message: Text? { Text("Tap Select or long-press any photo to pick multiple at once.") }
    var image: Image? { Image(systemName: "checkmark.circle") }
}

/// Teaches how to react with any emoji on the feed / rolls.
struct ReactTip: Tip {
    var title: Text { Text("React with anything") }
    var message: Text? { Text("Tap + for the full emoji picker, or double-tap a photo to like.") }
    var image: Image? { Image(systemName: "face.smiling") }
}

/// Teaches the invisible viewfinder gestures. Shown on the first camera visit; the other
/// camera tips below use event rules so the three never appear at once.
struct FocusTip: Tip {
    var title: Text { Text("Tap to focus") }
    var message: Text? { Text("Tap the frame to focus and expose there. Pinch to zoom.") }
    var image: Image? { Image(systemName: "viewfinder") }
}

/// Teaches the double-tap flip shortcut, and only to people who actually use the flip
/// button (second press) so it lands as "here's a faster way", not noise.
struct FlipTip: Tip {
    static let flippedViaButton = Tips.Event(id: "flippedViaButton")
    var title: Text { Text("Flip faster") }
    var message: Text? { Text("Double-tap the frame to switch cameras.") }
    var image: Image? { Image(systemName: "arrow.triangle.2.circlepath") }
    var rules: [Rule] { #Rule(Self.flippedViaButton) { $0.donations.count >= 2 } }
}

/// Teaches the hardware volume-button shutter once someone has taken a few shots and
/// clearly likes shooting.
struct VolumeShutterTip: Tip {
    static let photoCaptured = Tips.Event(id: "photoCaptured")
    var title: Text { Text("Shoot with a button") }
    var message: Text? { Text("Either volume button snaps a photo, like a real camera.") }
    var image: Image? { Image(systemName: "camera.shutter.button") }
    var rules: [Rule] { #Rule(Self.photoCaptured) { $0.donations.count >= 3 } }
}
