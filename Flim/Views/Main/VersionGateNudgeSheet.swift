import SwiftUI

/// A soft, dismissible "update available" nudge for `VersionGateDecision.nudge` (below
/// `latest_version`, but not below `minimum_version`).
///
/// Unlike `NotificationPrimerSheet`'s decided/undecided split, there is no OS-level side effect
/// a dismissal here needs to be distinguished from, so every way of closing this — "Update",
/// "Later", or a swipe-away — is treated the same: `ContentView`'s `.sheet(onDismiss:)` records
/// the version once the sheet is gone, which is what keeps it from resurfacing until
/// `latest_version` genuinely changes (see `shouldPresentVersionNudge`).
struct VersionGateNudgeSheet: View {
    @Environment(\.flimAccent) private var accent
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    let message: String?

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(accent)
            Text("A new version is here")
                .flimFont(24, weight: .light, relativeTo: .title2)
                .foregroundStyle(.white)
            Text(message ?? "Update \(AppInfo.appName) for the latest fixes and features.")
                .flimFont(15, relativeTo: .subheadline)
                .foregroundStyle(FlimTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 34)
            Spacer()
            PrimaryButton(title: "Update \(AppInfo.appName)") {
                openURL(AppInfo.appStoreURL)
                dismiss()
            }
            Button { dismiss() } label: {
                Text("Later")
                    .flimFont(15, relativeTo: .subheadline)
                    .foregroundStyle(FlimTheme.textTertiary)
            }
            .padding(.top, 2)
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .presentationDetents([.medium])
        .flimSheetSurface()
    }
}
