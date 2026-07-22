import SwiftUI
import AVFoundation

struct OnboardingView: View {
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @State private var page = 0

    private struct Card: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let body: String
    }

    private let cards = [
        Card(icon: "camera.aperture",
             title: "Shoot now.",
             body: "Capture the moment, disposable-camera style. Every shot gets \(AppInfo.appName)'s film look baked in. No filters to pick. Just tap the shutter."),
        Card(icon: "square.stack.3d.up",
             title: "Sort your shots.",
             body: "Instants are ready right away. Swipe to keep them in your Darkroom or publish to your feed. Shared rolls develop together at the 12-hour mark."),
        Card(icon: "sparkles",
             title: "Share the moment.",
             body: "Post your favorites to your page, follow friends, and react to theirs. \(AppInfo.appName) is invite-only. It's just your people.")
    ]

    /// Ends onboarding. If camera permission hasn't been decided yet, this requests it
    /// first so the system dialog always follows directly from the onboarding CTA or
    /// Skip -- mirrors the same-API call in `CameraViewModel.start()`, which will simply
    /// see the now-decided status and proceed without prompting again.
    private func finishOnboarding() {
        Task { @MainActor in
            if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
            }
            hasOnboarded = true
        }
    }

    var body: some View {
        ZStack {
            FlimTheme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                TabView(selection: $page) {
                    ForEach(Array(cards.enumerated()), id: \.offset) { index, card in
                        VStack(spacing: 22) {
                            Spacer()
                            Image(systemName: card.icon)
                                .font(.system(size: 52, weight: .ultraLight))
                                .foregroundStyle(FlimTheme.accent)
                            Text(card.title)
                                .font(.system(size: 30, weight: .thin))
                                .foregroundStyle(.white)
                            Text(card.body)
                                .font(.system(size: 15))
                                .foregroundStyle(FlimTheme.textSecondary)
                                .multilineTextAlignment(.center)
                                .lineSpacing(3)
                                .padding(.horizontal, 44)
                            Spacer()
                            Spacer()
                        }
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                Button {
                    if page < cards.count - 1 {
                        withAnimation { page += 1 }
                    } else {
                        Haptics.tap()
                        finishOnboarding()
                    }
                } label: {
                    Text(page < cards.count - 1 ? "Next" : "Take your first shot")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(FlimTheme.accent, in: Capsule())
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 20)

                Button("Skip") { finishOnboarding() }
                    .font(.system(size: 13))
                    .foregroundStyle(FlimTheme.textTertiary)
                    .padding(.bottom, 24)
            }
        }
    }
}
