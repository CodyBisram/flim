import SwiftUI

/// A small, quiet "still developing" indicator — the hourglass eases through a 180° flip every
/// few seconds, like sand being turned over. Used in place of a per-tile countdown wherever a
/// header elsewhere already states the actual time remaining, so the tile just needs to read as
/// "in progress" without repeating a number.
struct AnimatedHourglass: View {
    var size: CGFloat = 14
    var color: Color = FlimTheme.textTertiary

    @State private var flipped = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "hourglass")
            .font(.system(size: size, weight: .ultraLight))
            .foregroundStyle(color)
            .rotationEffect(.degrees(flipped ? 180 : 0))
            // A sleeping loop, not a per-second timer — it only wakes to flip every ~3s, and
            // stops the moment the tile leaves the screen (the task is cancelled with the view).
            .task {
                guard !reduceMotion else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { break }
                    withAnimation(.easeInOut(duration: 0.6)) { flipped.toggle() }
                }
            }
            .accessibilityHidden(true)
    }
}
