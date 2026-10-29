import SwiftUI

/// "Rolls" under the shutter: the shelf of rolls opens from Personal's foot (board 10a). A word,
/// with the red dot when a developed roll's reveal has not been watched.
struct V2RollsButton: View {
    let hasUnwatched: Bool
    let open: () -> Void

    @Environment(\.v2Palette) private var palette

    var body: some View {
        Button(action: open) {
            Text("Rolls")
                .font(V2Type.control())
                .foregroundStyle(palette.ink2)
                .overlay(alignment: .topTrailing) {
                    if hasUnwatched {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 7, height: 7)
                            .offset(x: 8, y: -3)
                    }
                }
                .frame(minWidth: 64, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Rolls")
        .accessibilityValue(hasUnwatched ? "New" : "")
    }
}
