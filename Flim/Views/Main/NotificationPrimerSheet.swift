import SwiftUI

/// A friendly, in-app "ask" shown before the one-shot iOS permission prompt. Framing the value
/// first (the reveal + reactions) lifts opt-in rates — and the real system prompt only fires if
/// they tap "Turn on," so a "Not now" never burns the single OS request.
struct NotificationPrimerSheet: View {
    @Environment(NotificationService.self) private var notifications
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(FlimTheme.accent)
            Text("Don't miss the reveal")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.white)
            Text("We'll ping you the moment your roll develops — and when friends react or comment on your shots.")
                .font(.system(size: 15))
                .foregroundStyle(FlimTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 34)
            Spacer()
            Button {
                Task { await notifications.requestAuthorizationIfNeeded(); dismiss() }
            } label: {
                Text("Turn on notifications")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(FlimTheme.accent, in: Capsule())
            }
            Button { dismiss() } label: {
                Text("Not now")
                    .font(.system(size: 15))
                    .foregroundStyle(FlimTheme.textTertiary)
            }
            .padding(.top, 2)
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FlimTheme.bg)
        .presentationDetents([.medium])
        .presentationBackground(FlimTheme.bg)
    }
}
