import TipKit

/// Teaches the non-obvious multi-select gesture in the Darkroom.
struct SelectTip: Tip {
    var title: Text { Text("Select several") }
    var message: Text? { Text("Tap Select — or long-press any photo — to pick multiple at once.") }
    var image: Image? { Image(systemName: "checkmark.circle") }
}

/// Teaches how to react with any emoji on the feed / rolls.
struct ReactTip: Tip {
    var title: Text { Text("React with anything") }
    var message: Text? { Text("Tap + for the full emoji picker, or double-tap a photo to like.") }
    var image: Image? { Image(systemName: "face.smiling") }
}
