import Testing
import Foundation
@testable import Flim

/// The feed's one-time line for invites never sent (1.6.3): what it says for each count, and when
/// it shows.
struct InviteReminderTests {
    private typealias Reminder = NewAccountIntro.InviteReminder

    @Test("the line counts what is left, and says nothing for none, unknown or unlimited")
    func wording() {
        #expect(Reminder.line(for: .remaining(3))?.headline == "You have 3 invites left.")
        #expect(Reminder.line(for: .remaining(1))?.headline == "You have 1 invite left.")
        #expect(Reminder.line(for: .remaining(3))?.detail == "Who should be here? Tap to send one.")
        #expect(Reminder.line(for: .remaining(0)) == nil)
        #expect(Reminder.line(for: .unknown) == nil)
        #expect(Reminder.line(for: .unlimited) == nil)
    }

    @Test("shows once per account, waits behind another top line, and stays up for the launch once shown")
    func showsOnce() {
        let suite = "InviteReminderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let previous = NewAccountIntro.store
        NewAccountIntro.store = defaults
        defer { NewAccountIntro.store = previous }

        let me = UUID()
        #expect(!Reminder.shouldShow(userId: nil, quota: .remaining(3), otherTopLineShowing: false))
        #expect(!Reminder.shouldShow(userId: me, quota: .remaining(3), otherTopLineShowing: true))
        #expect(!Reminder.shouldShow(userId: me, quota: .unknown, otherTopLineShowing: false))
        #expect(Reminder.shouldShow(userId: me, quota: .remaining(3), otherTopLineShowing: false))

        // On screen this launch: it keeps its place even if another line comes up later.
        NewAccountIntro.shownThisLaunch.insert(Reminder.shownKey(userId: me))
        defer { NewAccountIntro.shownThisLaunch.remove(Reminder.shownKey(userId: me)) }
        Reminder.markSeen(userId: me)
        #expect(Reminder.shouldShow(userId: me, quota: .remaining(2), otherTopLineShowing: true))
        // Out of invites: gone, even mid-launch.
        #expect(!Reminder.shouldShow(userId: me, quota: .remaining(0), otherTopLineShowing: false))

        // Next launch: seen, so never again. Another account is untouched.
        NewAccountIntro.shownThisLaunch.remove(Reminder.shownKey(userId: me))
        #expect(!Reminder.shouldShow(userId: me, quota: .remaining(3), otherTopLineShowing: false))
        #expect(Reminder.shouldShow(userId: UUID(), quota: .remaining(3), otherTopLineShowing: false))
    }
}
