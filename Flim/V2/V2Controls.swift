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

/// The start-of-app notification ask (`NotificationPrimerSheet`'s rules exactly: the system
/// dialog fires only on "Turn on notifications", either button is the decision, a swipe-away is
/// not), drawn on the desk. The words differ in one place: in v2 the people whose posts it tells
/// you about are friends.
struct V2NotificationPrimerSheet: View {
    var onDecision: () -> Void = {}

    @Environment(NotificationService.self) private var notifications
    @Environment(\.dismiss) private var dismiss
    @Environment(\.v2Palette) private var palette
    @State private var height: CGFloat = 360

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Know when a friend replies")
                    .font(V2Type.serif(24, relativeTo: .title2))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text("We'll tell you when someone reacts to or writes on your prints, when a roll you're in opens, and now and then when friends have posted.")
                    .font(V2Type.serif(15, italic: true, relativeTo: .body))
                    .foregroundStyle(palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                V2AuthButton(title: "Turn on notifications") {
                    await notifications.requestAuthorizationIfNeeded()
                    onDecision()
                    dismiss()
                }
                .padding(.top, 26)
                Button { onDecision(); dismiss() } label: {
                    Text("Not now")
                        .font(V2Type.control(.body))
                        .foregroundStyle(palette.ink3)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }
            .padding(V2Metrics.margin)
            .padding(.top, 8)
            .frame(maxWidth: 520, alignment: .leading)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 + 20 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .foregroundStyle(palette.ink)
        .presentationDetents([.height(height)])
        .presentationBackground { V2Desktop(palette: palette) }
    }
}

/// "developing…" in the desk's quiet italic, after a short wait: a read still on its way.
struct V2Developing: View {
    @Environment(\.v2Palette) private var palette
    @State private var shown = false

    var body: some View {
        Text("developing…")
            .font(V2Type.serif(15, italic: true, relativeTo: .body))
            .foregroundStyle(palette.ink3)
            .frame(maxWidth: .infinity)
            .opacity(shown ? 1 : 0)
            .task {
                try? await Task.sleep(for: .milliseconds(450))
                withAnimation(.easeIn(duration: 0.4)) { shown = true }
            }
            .accessibilityLabel("Loading")
    }
}
