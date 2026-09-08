import SwiftUI

/// One sentence, once, for a new account: see `NewAccountIntro`. Reads the current account from
/// the environment, decides on appear whether it has anything to say, and marks the surface seen
/// when it leaves so the line is present for the whole first visit and absent from the second.
/// Renders nothing at all for everyone else, so call sites can place it unconditionally.
struct FirstVisitLine: View {
    let surface: NewAccountIntro.Surface
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
                                              createdAt: auth.currentUser?.createdAt)
        }
        .onDisappear {
            if line != nil, let uid = auth.currentUser?.id { NewAccountIntro.markSeen(surface, userId: uid) }
        }
    }
}
