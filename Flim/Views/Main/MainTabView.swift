import SwiftUI

struct MainTabView: View {
    @State private var selected = 0
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @AppStorage("accentColor") private var accentColor = "amber"   // re-tints on change
    @AppStorage("didShowNotifPrimer") private var didShowNotifPrimer = false
    @State private var showNotifPrimer = false
    @Environment(NotificationService.self) private var notifications
    #if DEBUG
    @Environment(AuthService.self) private var auth
    @Environment(RollService.self) private var rolls
    @Environment(PhotoService.self) private var photos
    #endif

    var body: some View {
        TabView(selection: $selected) {
            Tab("Camera", systemImage: "camera.aperture", value: 0) {
                CameraView()
            }
            Tab("Darkroom", systemImage: "photo.stack", value: 1) {
                NavigationStack {
                    DarkroomView()
                }
            }
            Tab("Rolls", systemImage: "film.stack", value: 2) {
                NavigationStack {
                    RollsView()
                }
            }
            Tab("Feed", systemImage: "house", value: 3) {
                NavigationStack {
                    FeedView()
                }
            }
        }
        .tint(FlimTheme.accent)
        .fullScreenCover(isPresented: Binding(get: { !hasOnboarded }, set: { _ in })) {
            OnboardingView()
        }
        .sheet(isPresented: $showNotifPrimer, onDismiss: { didShowNotifPrimer = true }) {
            NotificationPrimerSheet()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openDarkroom)) { _ in
            selected = 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .openCamera)) { _ in
            selected = 0
        }
        // Show the soft primer once — after onboarding, with context — instead of a cold
        // system prompt on first launch (which gets denied far more often).
        .onChange(of: hasOnboarded) { _, done in if done { maybeShowNotifPrimer() } }
        .onAppear {
            maybeShowNotifPrimer()
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            // Deterministic Simulator verification (no camera in the sim):
            //   -seedDemo : jump to the Darkroom, which auto-seeds personal photos.
            //   -seedRoll : jump to Rolls and seed the first roll (for cover thumbnails).
            if args.contains("-seedDemo") { selected = 1 }
            if args.contains("-seedRoll") {
                selected = 2
                Task {
                    guard let uid = auth.currentUser?.id else { return }
                    try? await rolls.fetchRolls(for: uid)
                    if let first = rolls.rolls.first {
                        await photos.seedDemoPhotos(userId: uid, rollId: first.id)
                        try? await rolls.fetchRolls(for: uid)   // refresh coverPaths
                    }
                }
            }
            #endif
        }
    }

    private func maybeShowNotifPrimer() {
        guard hasOnboarded, !didShowNotifPrimer else { return }
        Task {
            if await notifications.isUndetermined() {
                try? await Task.sleep(for: .seconds(1))   // let them land on the app first
                showNotifPrimer = true
            } else {
                didShowNotifPrimer = true   // already decided elsewhere; don't ask again
            }
        }
    }
}
