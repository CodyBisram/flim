import SwiftUI
import AVFoundation

/// The first run, after sign-in and the username screen: one screen, shaped like the viewfinder
/// it is about to become, with one sentence and one button. Tapping the button requests camera
/// permission, so the system dialog always follows directly from this screen's own message
/// (Apple 5.1.1(iv); FLIM was rejected once for a Skip that let people past without the dialog).
///
/// This replaced three swipeable cards ("Shoot now." / "Sort your shots." / "Share the moment.")
/// with a Next button and a Skip, on 2026-09-08. Measured on the 38 accounts created since
/// August: 8 of 36 never finished the cards, and the median time from account to first shot was
/// 130 minutes. The cards explained the product; this screen hands over the camera. What the
/// cards used to say is now said by the surfaces themselves: `NewAccountIntro` gives each one a
/// single first-visit line, and the first Darkroom and first roll are designed as real states.
///
/// There is deliberately no Skip. There is nothing to skip: the only way forward is the camera,
/// and the camera needs the permission ask. `hasOnboarded` keeps its exact meaning and timing
/// (see `CameraView`'s gating on it and the standing checklist in the project notes).
struct OnboardingView: View {
    @Environment(\.flimAccent) private var accent
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @State private var isOpening = false

    /// Ends onboarding. If camera permission hasn't been decided yet, this requests it first so
    /// the system dialog always follows directly from the one CTA. Mirrors the same-API call in
    /// `CameraViewModel.start()`, which then sees the decided status and proceeds without asking
    /// again.
    private func openCamera() {
        guard !isOpening else { return }
        isOpening = true
        Haptics.tap()
        Task { @MainActor in
            if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
            }
            hasOnboarded = true
            Activation.log(.onboardingFinished)
        }
    }

    var body: some View {
        ZStack {
            FlimTheme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 24)

                // The viewfinder's own box, dark, at the camera screen's proportions: the
                // permission ask lives where the picture will, not on a card about it.
                ZStack {
                    // Near-black, not grey: on a device the first cut read as a lighter slab
                    // sitting on the page. A dark viewfinder is black with a hairline edge and
                    // the faintest warm centre, which is what a real one shows before the feed
                    // starts.
                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            RadialGradient(colors: [Color(red: 0.055, green: 0.045, blue: 0.035), Color(red: 0.012, green: 0.012, blue: 0.012)],
                                           center: UnitPoint(x: 0.5, y: 0.42), startRadius: 0, endRadius: 360)
                        )
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                    VStack(spacing: 12) {
                        Text("\(AppInfo.appName) is a camera.")
                            .flimFont(26, weight: .thin, relativeTo: .title2)
                            .foregroundStyle(.white)
                        Text("Point and shoot. The frame comes back with the look already on it.")
                            .flimFont(15, relativeTo: .body)
                            .foregroundStyle(FlimTheme.textSecondary)
                            .multilineTextAlignment(.center)
                            .lineSpacing(3)
                            .padding(.horizontal, 40)

                        Button(action: openCamera) {
                            Text("Open the camera")
                                .flimFont(16, weight: .semibold, relativeTo: .body)
                                .foregroundStyle(.black)
                                .padding(.horizontal, 28)
                                .padding(.vertical, 14)
                                .background(accent, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(isOpening)
                        .padding(.top, 24)
                        .accessibilityHint("Asks for camera access, then opens the camera")
                    }
                }
                .aspectRatio(FlimTheme.frameAspect, contentMode: .fit)
                .padding(.horizontal, 16)

                Spacer(minLength: 24)

                // A dark shutter, so the screen reads as the camera it is about to be. Not a
                // control: the button above is the only way on, because it is the one that asks.
                Circle()
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 4)
                    .frame(width: 78, height: 78)
                    .overlay(Circle().fill(Color.white.opacity(0.06)).padding(8))
                    .padding(.bottom, 48)
                    .accessibilityHidden(true)
            }
        }
    }
}
