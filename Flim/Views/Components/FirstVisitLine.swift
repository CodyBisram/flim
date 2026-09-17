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
    @State private var line: String?

    var body: some View {
        Group {
            if let line {
                Text(line)
                    .flimFont(13, relativeTo: .footnote)
                    .foregroundStyle(FlimTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .transition(.opacity)
                    .accessibilityLabel(line)
            }
        }
        .onAppear {
            line = NewAccountIntro.lineToShow(surface, userId: auth.currentUser?.id,
                                              createdAt: auth.currentUser?.createdAt, text: text)
            if line != nil { NewAccountIntro.shownThisLaunch.insert(surface) }
        }
        // Seen once it has had time to be read, not when it scrolls off: inside a LazyVStack
        // `onDisappear` fires the moment the line leaves the screen, which marked it seen and
        // made it vanish when the person scrolled back up (nightly review, 2026-09-10). The
        // line stays for the rest of this launch either way (`shownThisLaunch`).
        .task {
            guard line != nil else { return }
            try? await Task.sleep(for: .seconds(5))
            if let uid = auth.currentUser?.id { NewAccountIntro.markSeen(surface, userId: uid) }
        }
    }
}
