import SwiftUI

/// One sentence, once, for a new account: see `NewAccountIntro`. Reads the current account from
/// the environment, decides on appear whether it has anything to say, and marks the surface seen
/// when it leaves so the line is present for the whole first visit and absent from the second.
/// Renders nothing at all for everyone else, so call sites can place it unconditionally.
struct FirstVisitLine: View {
    let surface: NewAccountIntro.Surface
    /// A sentence built at the call site, when the surface has a fact to put in it (a roll's
    /// develop time). Nil uses the surface's own line.
    var text: String? = nil
    @Environment(AuthService.self) private var auth

    // Decided while drawing, not in `onAppear`: modifiers on a Group attach to its children,
    // so an `onAppear` on a Group whose line was not yet decided had nothing to attach to, never
    // ran, and the line never showed (found 2026-09-26 on the iOS 18.5 simulator). Wrapping it
    // in a stack instead left a zero-height row that, for a new account whose top rows were all
    // empty, sent the feed's scroll-to-top onto a blank screen. Now a hidden line is no view at
    // all, and a shown line does its own bookkeeping.
    var body: some View {
        Group {
            if let uid = auth.currentUser?.id,
               let line = NewAccountIntro.lineToShow(surface, userId: uid,
                                                     createdAt: auth.currentUser?.createdAt, text: text) {
                Text(line)
                    .flimFont(13, relativeTo: .footnote)
                    .foregroundStyle(FlimTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .transition(.opacity)
                    .accessibilityLabel(line)
                    .onAppear { NewAccountIntro.shownThisLaunch.insert(NewAccountIntro.shownKey(surface, userId: uid)) }
                    // Seen once it has had time to be read, not when it scrolls off: inside a
                    // LazyVStack `onDisappear` fires the moment the line leaves the screen, which
                    // marked it seen and made it vanish when the person scrolled back up (nightly
                    // review, 2026-09-10). The line stays for the rest of this launch either way
                    // (`shownThisLaunch`).
                    .task(id: uid) {
                        try? await Task.sleep(for: .seconds(5))
                        guard !Task.isCancelled, auth.currentUser?.id == uid else { return }
                        NewAccountIntro.markSeen(surface, userId: uid)
                    }
            }
        }
    }
}

/// What's new, once per account, for everyone: see `NewAccountIntro.Announcement`. The same quiet
/// line as `FirstVisitLine`, with its lead in the accent so an existing member notices something
/// changed, and decided the same way: while drawing, so a hidden line is no view at all. Marked
/// seen after five seconds on screen. The caller marks it seen when the account turns out to have
/// used the feature already (a hidden view cannot watch for that itself).
struct AnnouncementLine: View {
    let announcement: NewAccountIntro.Announcement
    /// The surface's own first-visit line is up; wait for a later visit.
    var firstVisitLineShowing: Bool
    /// The account has used the feature; it needs no introduction.
    var alreadyUsed: Bool
    @Environment(AuthService.self) private var auth
    @Environment(\.flimAccent) private var accent

    var body: some View {
        Group {
            if let uid = auth.currentUser?.id,
               NewAccountIntro.announcementToShow(announcement, userId: uid,
                                                  firstVisitLineShowing: firstVisitLineShowing,
                                                  alreadyUsed: alreadyUsed) != nil {
                (Text(announcement.headline).foregroundStyle(accent)
                 + Text(" " + announcement.detail).foregroundStyle(FlimTheme.textSecondary))
                    .flimFont(13, relativeTo: .footnote)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .transition(.opacity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(announcement.line)
                    .onAppear { NewAccountIntro.shownThisLaunch.insert(NewAccountIntro.shownKey(announcement, userId: uid)) }
                    .task(id: uid) {
                        try? await Task.sleep(for: .seconds(5))
                        guard !Task.isCancelled, auth.currentUser?.id == uid else { return }
                        NewAccountIntro.markSeen(announcement, userId: uid)
                    }
            }
        }
    }
}
