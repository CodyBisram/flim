import SwiftUI

/// A friendly, in-app "ask" shown before the one-shot iOS permission prompt. Framing the value
/// first (the reveal + reactions) lifts opt-in rates, and the real system prompt only fires if
/// they tap "Turn on," so a "Not now" never burns the single OS request.
struct NotificationPrimerSheet: View {
    @Environment(\.flimAccent) private var accent
    @Environment(NotificationService.self) private var notifications
    @Environment(\.dismiss) private var dismiss
    /// Called only when the person actually chooses "Turn on notifications" or "Not now", never
    /// on a swipe-away. Lets the caller (`MainTabView`) tell a genuine decision, which should
    /// never ask again, apart from an interrupted presentation, which may retry later. See
    /// `shouldPresentNotifPrimer`.
    var onDecision: () -> Void = {}

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(accent)
            Text("Don't miss the reveal")
                .flimFont(24, weight: .light, relativeTo: .title2)
                .foregroundStyle(.white)
            Text("We'll ping you the moment your roll develops, and when friends react or comment on your shots.")
                .flimFont(15, relativeTo: .subheadline)
                .foregroundStyle(FlimTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 34)
            Spacer()
            Button {
                Task { await notifications.requestAuthorizationIfNeeded(); onDecision(); dismiss() }
            } label: {
                Text("Turn on notifications")
                    .flimFont(16, weight: .semibold, relativeTo: .body)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(accent, in: Capsule())
            }
            Button { onDecision(); dismiss() } label: {
                Text("Not now")
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
