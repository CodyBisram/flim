import SwiftUI
import UIKit

/// A gentle, dismissible nudge at the top of the feed for someone who never turned notifications
/// on, because without them the reveal has no way to reach anyone: the roll develops and they
/// simply never find out.
///
/// This is DELIBERATELY not the onboarding primer, which fires once during onboarding and is
/// documented as fragile enough that its timing must not be disturbed. This is a separate,
/// standing surface for the people who slipped past that one moment. It shows only to established,
/// active accounts (anyone opening the feed is active; the age gate keeps it from stacking on top
/// of the primer for a signup from an hour ago), goes quiet for a fortnight when dismissed, and
/// disappears the instant permission is granted.
struct NotificationNudgeBanner: View {
    @Environment(NotificationService.self) private var notifications
    @Environment(AuthService.self) private var auth
    @Environment(\.flimAccent) private var accent
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    /// Suppressed until this instant after a dismiss. A long cooldown, not forever: someone who
    /// waves it away once may still want it later, but must never feel nagged.
    @AppStorage("notifNudgeDismissedUntil") private var dismissedUntil: Double = 0

    @State private var working = false

    private var shouldShow: Bool {
        // No account, no age to reason about: fail closed rather than nag a signed-out or
        // just-launched state. Otherwise the whole decision lives in the pure helper.
        guard let created = auth.currentUser?.createdAt else { return false }
        return NotificationNudge.shouldShow(
            authorized: notifications.authorizationState == .authorized,
            accountAge: Date().timeIntervalSince(created),
            dismissedUntil: dismissedUntil,
            now: .now)
    }

    var body: some View {
        if shouldShow {
            HStack(spacing: 12) {
                Image(systemName: "bell.badge")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(accent)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Know the moment your roll develops")
                        .flimFont(14, weight: .medium, relativeTo: .subheadline)
                        .foregroundStyle(FlimTheme.textPrimary)
                    Text("A reveal has no way to reach you without notifications.")
                        .flimFont(12, relativeTo: .caption)
                        .foregroundStyle(FlimTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button(action: turnOn) {
                    Text(notifications.authorizationState == .denied ? "Settings" : "Turn on")
                        .flimFont(13, weight: .semibold, relativeTo: .subheadline)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(working)
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .padding(.vertical, 12)
            .overlay(alignment: .topTrailing) {
                // Small, quiet dismiss. A gentle nudge has to be easy to wave away.
                Button {
                    Haptics.tap()
                    dismissedUntil = Date().addingTimeInterval(NotificationNudge.dismissCooldown).timeIntervalSince1970
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(FlimTheme.textTertiary)
                        .padding(8)
                }
                .buttonStyle(.plain)
                .expandTapTarget(by: 8)
            }
            .background(FlimTheme.bgElevated)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(FlimTheme.stroke, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .task { await notifications.refreshAuthorizationState() }
            // Returning from Settings is a scene reactivation, not a re-appear, so refresh there
            // too or a granted permission would leave the banner up until the next launch.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { await notifications.refreshAuthorizationState() }
                }
            }
        }
    }

    private func turnOn() {
        Haptics.tap()
        Task {
            working = true
            defer { working = false }
            switch notifications.authorizationState {
            case .notDetermined:
                // iOS still allows the real system prompt for someone it never asked.
                await notifications.requestAuthorizationIfNeeded()
            case .denied:
                // The system prompt is spent; Settings is the only remaining path.
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            case .authorized:
                break
            }
            await notifications.refreshAuthorizationState()
        }
    }
}


/// When the notification nudge is allowed to show, as a pure decision so the gating cannot
/// silently regress: never to someone already opted in, never in the fortnight after a dismiss,
/// and never in the first day, which is still the onboarding primer's moment.
enum NotificationNudge {
    /// An account younger than this is still in onboarding's window and gets no second ask.
    static let establishedAfter: TimeInterval = 24 * 3600
    /// How long a dismiss quiets it. Long, but not forever: a later change of heart is allowed.
    static let dismissCooldown: TimeInterval = 14 * 86400

    static func shouldShow(authorized: Bool,
                           accountAge: TimeInterval,
                           dismissedUntil: TimeInterval,
                           now: Date) -> Bool {
        guard !authorized else { return false }
        guard accountAge > establishedAfter else { return false }
        return now.timeIntervalSince1970 > dismissedUntil
    }
}
