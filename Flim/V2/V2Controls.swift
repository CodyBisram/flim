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

/// A first read that failed, in place of the empty state it would otherwise be mistaken for
/// ("Nothing yet" when the truth is "couldn't ask"). The words are the app's own for an
/// unreachable server; Try again reads again.
struct V2LoadFailed: View {
    let retry: () async -> Void
    @Environment(\.v2Palette) private var palette
    @State private var retrying = false

    var body: some View {
        VStack(spacing: 10) {
            Text(UserFacingError.genericMessage)
                .font(V2Type.serif(15, italic: true, relativeTo: .body))
                .foregroundStyle(palette.ink2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                guard !retrying else { return }
                retrying = true
                Task { await retry(); retrying = false }
            } label: {
                ZStack {
                    Text("Try again").opacity(retrying ? 0 : 1)
                    if retrying { ProgressView().tint(palette.ink) }
                }
                .font(V2Type.control(.subheadline))
                .foregroundStyle(palette.ink)
                .underline()
                .frame(minWidth: 88, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Try again")
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
        .transition(.opacity)
    }
}
