import SwiftUI

/// 1.7's notification ask (Blend 2, 7e): our screen first, then the system's, so the reason is
/// read before the one-time ask. Three sample notifications show what turning them on gets you.
/// Same decision contract as 1.6's `NotificationPrimerSheet`: only the two buttons report one.
struct DeskNotificationPrimer: View {
    @Environment(\.flimAccent) private var accent
    @Environment(NotificationService.self) private var notifications
    @Environment(\.dismiss) private var dismiss
    var onDecision: () -> Void = {}

    private let samples: [(String, String)] = [
        ("now", "Bali week is open. 7 shots from six of you."),
        ("2m", "@mira said yes. You're friends now."),
        ("1h", "@noor commented: the chairs going up is such a detail"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Scrolls at large text sizes; the two buttons stay put below.
            ScrollView {
            VStack(alignment: .leading, spacing: 0) {
            Text("Know when a roll opens")
                .font(DeskType.serif(30, relativeTo: .largeTitle))
                .foregroundStyle(FlimTheme.textPrimary)
                .padding(.top, 36)
                .accessibilityAddTraits(.isHeader)
            Text("We'll tell you when a roll opens, a friend says yes, or someone comments on your shots.")
                .flimFont(15, relativeTo: .body)
                .foregroundStyle(FlimTheme.textSecondary)
                .padding(.top, 10)
            VStack(spacing: 10) {
                ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                    HStack(alignment: .top, spacing: 12) {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(DeskColor.solid)
                            .frame(width: 30, height: 30)
                            .overlay(Text("F").font(DeskType.serif(15)).foregroundStyle(DeskColor.onSolid))
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(AppInfo.appName).font(.system(size: 13, weight: .semibold))
                                Spacer()
                                Text(sample.0).font(.system(size: 12)).foregroundStyle(FlimTheme.textTertiary)
                            }
                            Text(sample.1).font(.system(size: 14))
                        }
                        .foregroundStyle(FlimTheme.textPrimary)
                    }
                    .padding(12)
                    .background(FlimTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .padding(.top, 24)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Examples: a roll opening, a friend saying yes, a comment on your shot.")
            }
            }
            .scrollBounceBehavior(.basedOnSize)
            // The scroll view takes all the room the buttons leave; a flexible spacer beside it
            // split that room in half and squeezed the samples (nightly review, 2026-11-12).
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.bottom, 12)
            Button {
                Task { await notifications.requestAuthorizationIfNeeded(); onDecision(); dismiss() }
            } label: {
                Text("Turn on notifications")
                    .flimFont(16, weight: .semibold, relativeTo: .body)
                    .foregroundStyle(Color(white: 0.1))
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(accent, in: Capsule())
            }
            Button { onDecision(); dismiss() } label: {
                Text("Not now")
                    .flimFont(15, weight: .semibold, relativeTo: .body)
                    .foregroundStyle(FlimTheme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .background(DeskGround())
    }
}
