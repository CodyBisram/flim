import SwiftUI

/// A hard, undismissable block for a build below `app_release_gate.minimum_version`.
///
/// Presented as a `fullScreenCover` from `ContentView`, the one place that decides between the
/// auth flow and `MainTabView`: a cover attached there sits above whichever of the two is
/// currently showing, so a blocked build can't reach sign-in either. There is exactly one way
/// out, the App Store listing.
struct VersionGateBlockingView: View {
    @Environment(\.flimAccent) private var accent
    @Environment(\.openURL) private var openURL
    let message: String?

    var body: some View {
        ZStack {
            FlimTheme.bg.ignoresSafeArea()
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "arrow.up.circle")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(accent)
                Text("Update required")
                    .flimFont(24, weight: .light, relativeTo: .title2)
                    .foregroundStyle(.white)
                Text(message ?? "This version of \(AppInfo.appName) is no longer supported. Update to keep using the app.")
                    .flimFont(15, relativeTo: .subheadline)
                    .foregroundStyle(FlimTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 34)
                Spacer()
                PrimaryButton(title: "Update \(AppInfo.appName)") {
                    openURL(AppInfo.appStoreURL)
                }
                .padding(.bottom, 24)
            }
            .padding(.horizontal, 24)
        }
    }
}
