import SwiftUI

/// The notification ask, for a new account, at the one moment there is a time to be told about:
/// a frame of theirs has gone into a roll that has not developed yet. Names the develop time in
/// the title and on the button, so what is being asked for is a fact, not a category.
///
/// The general primer (`NotificationPrimerSheet`, on the feed) keeps its own softer pattern for
/// everyone who was already here; new accounts (`NewAccountIntro.isNewAccount`) get this one
/// instead and never see that one. "I will check" is a real decision and is never re-asked; the
/// permission is still reachable from Settings, and the feed's standing nudge still hides itself
/// once notifications are on, exactly as before.
struct RollDevelopAskSheet: View {
    @Environment(\.flimAccent) private var accent
    @Environment(NotificationService.self) private var notifications
    @Environment(\.dismiss) private var dismiss

    let rollName: String
    let revealAt: Date
    /// Called on either button, never on a swipe-away, with whether the person said yes.
    var onDecision: (_ accepted: Bool) -> Void = { _ in }

    /// "9:14 PM", in the phone's own locale. Pure and internal so the copy can be pinned.
    static func timeLabel(for date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        // Same day: the time alone. Another day: the weekday and the time, so "Develops at
        // 9:14 PM" can never mean tomorrow when it means Saturday.
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: .now) ? "h:mm a" : "EEEE 'at' h:mm a"
        return formatter.string(from: date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(rollName.uppercased())
                .flimFont(11, weight: .medium, relativeTo: .caption2)
                .tracking(2)
                .foregroundStyle(FlimTheme.textTertiary)
            Text("Develops at \(Self.timeLabel(for: revealAt)).")
                .flimFont(24, weight: .light, relativeTo: .title2)
                .foregroundStyle(.white)
                .padding(.top, 2)
            Text("Get told the moment it does. Nothing else, unless you ask for more later.")
                .flimFont(15, relativeTo: .subheadline)
                .foregroundStyle(FlimTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Haptics.tap()
                Task {
                    await notifications.requestAuthorizationIfNeeded()
                    onDecision(true)
                    dismiss()
                }
            } label: {
                Text("Tell me at \(Self.timeLabel(for: revealAt))")
                    .flimFont(16, weight: .semibold, relativeTo: .body)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 18)

            Button { onDecision(false); dismiss() } label: {
                Text("I will check")
                    .flimFont(15, relativeTo: .subheadline)
                    .foregroundStyle(FlimTheme.textTertiary)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 24)
        .padding(.top, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .presentationDetents([.height(300)])
        .flimSheetSurface()
    }
}
