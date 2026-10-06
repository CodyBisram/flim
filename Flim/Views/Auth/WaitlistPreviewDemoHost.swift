#if DEBUG
import SwiftUI

/// Simulator-only harness for the waitlist sheet, launched with `-waitlistPreviewDemo`.
///
/// The sheet opens from a tap the Simulator's own CLI cannot deliver, so this shows the real
/// sign-in screen with `WaitlistSheet` already presented over it. `join` is a stub that answers
/// `joined` without the network. `-waitlistDemoJoined`, alongside it, opens the sheet for an
/// email planted as already joined in a suite of its own, which is the reopened state.
struct WaitlistPreviewDemoHost: View {
    @State private var auth = AuthService()
    @State private var showSheet = true

    private static let demoEmail = "sam@example.com"
    private static let store = UserDefaults(suiteName: "WaitlistPreviewDemo") ?? .standard
    private let showsJoined = ProcessInfo.processInfo.arguments.contains("-waitlistDemoJoined")

    /// Planted here, before the sheet's own init reads the store.
    init() {
        if showsJoined {
            Waitlist.remember(Self.demoEmail, in: Self.store)
        } else {
            Self.store.removePersistentDomain(forName: "WaitlistPreviewDemo")
        }
    }

    var body: some View {
        NavigationStack {
            EmailAuthView()
        }
        .environment(auth)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSheet) {
            WaitlistSheet(prefilledEmail: showsJoined ? Self.demoEmail : "", store: Self.store) { _, _ in
                try? await Task.sleep(for: .milliseconds(600))
                return .joined
            }
        }
    }
}
#endif
