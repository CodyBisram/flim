import SwiftUI

struct MainTabView: View {
    @State private var selected = 0
    /// Per-tab counter — bumped when you re-tap the tab you're already on, so that tab scrolls to top.
    @State private var scrollSignal: [Int: Int] = [:]
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @AppStorage("accentColor") private var accentColor = "amber"   // re-tints on change
    @AppStorage("didShowNotifPrimer") private var didShowNotifPrimer = false
    @State private var showNotifPrimer = false
    @State private var inviteCode: String?
    @Environment(NotificationService.self) private var notifications
    @Environment(NetworkMonitor.self) private var network
    #if DEBUG
    @Environment(AuthService.self) private var auth
    @Environment(RollService.self) private var rolls
    @Environment(PhotoService.self) private var photos
    /// Owned here (not in RollsView) so `-openRollId` can push straight into a roll's detail
    /// at launch, for App Store screenshots the sim can't reach by tapping.
    @State private var rollsPath = NavigationPath()
    /// Drives `-openPhotoFullscreen`: presents the same full-screen viewer used from the
    /// darkroom/roll grids, without needing a tap to get there.
    @State private var debugFullscreenPhoto: Photo?
    #endif

    /// Selection binding that adds a haptic on tab change and a scroll-to-top on re-tap.
    private var selection: Binding<Int> {
        Binding(
            get: { selected },
            set: { newValue in
                if newValue == selected {
                    scrollSignal[newValue, default: 0] += 1
                } else {
                    Haptics.tap()
                }
                selected = newValue
            }
        )
    }

    var body: some View {
        TabView(selection: selection) {
            Tab("Camera", systemImage: "camera.aperture", value: 0) {
                CameraView()
            }
            Tab("Darkroom", systemImage: "photo.stack", value: 1) {
                NavigationStack {
                    DarkroomView(scrollToTop: scrollSignal[1, default: 0])
                }
            }
            Tab("Rolls", systemImage: "film.stack", value: 2) {
                #if DEBUG
                // `-openRollId` needs a path it can push onto; Release keeps the plain stack.
                NavigationStack(path: $rollsPath) {
                    RollsView(scrollToTop: scrollSignal[2, default: 0])
                }
                #else
                NavigationStack {
                    RollsView(scrollToTop: scrollSignal[2, default: 0])
                }
                #endif
            }
            Tab("Feed", systemImage: "house", value: 3) {
                NavigationStack {
                    FeedView(scrollToTop: scrollSignal[3, default: 0])
                }
            }
        }
        // Tint via the OBSERVED accentColor (not the static FlimTheme.accent) so the tab bar
        // re-tints the moment the user picks a new accent — the static read never invalidates
        // this view, which left the old color until a relaunch.
        .tint((FlimAccent(rawValue: accentColor) ?? .amber).color)
        .overlay(alignment: .top) {
            if !network.isConnected {
                Label("No connection", systemImage: "wifi.slash")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: network.isConnected)
        .fullScreenCover(isPresented: Binding(get: { !hasOnboarded }, set: { _ in })) {
            OnboardingView()
        }
        #if DEBUG
        // `-openPhotoFullscreen` — same viewer the darkroom/roll grids use.
        .fullScreenCover(item: $debugFullscreenPhoto) { photo in
            FullScreenPhotoView(photo: photo, url: nil)
        }
        #endif
        .sheet(isPresented: $showNotifPrimer, onDismiss: { didShowNotifPrimer = true }) {
            NotificationPrimerSheet()
        }
        .sheet(isPresented: Binding(get: { inviteCode != nil }, set: { if !$0 { inviteCode = nil } })) {
            JoinRollView(initialCode: inviteCode ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .openRollInvite)) { note in
            selected = 2   // Rolls tab
            inviteCode = note.object as? String
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
            DiskImageCache.trim()   // keep the on-disk image cache bounded

            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            // Deterministic Simulator verification (no camera in the sim):
            //   -seedDemo : jump to the Darkroom, which auto-seeds personal photos.
            //   -seedRoll : jump to Rolls and seed the first roll (for cover thumbnails).
            if args.contains("-seedDemo") { selected = 1 }
            if args.contains("-tabFeed") { selected = 3 }   // jump to Feed for screenshots
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
            //   -openRollId <uuid>          : push straight into that roll's detail.
            //   -openPhotoFullscreen <uuid> : present the full-screen viewer for that photo.
            // Both are for screenshotting screens the sim can't tap into; a roll/photo the
            // account can't see is a graceful no-op, not a crash.
            if let rollIdArg = Self.launchArgValue("-openRollId", in: args),
               let rollId = UUID(uuidString: rollIdArg) {
                selected = 2
                Task {
                    guard let uid = auth.currentUser?.id else { return }
                    try? await rolls.fetchRolls(for: uid)
                    if let roll = rolls.rolls.first(where: { $0.id == rollId }) {
                        rollsPath.append(roll)
                    }
                }
            }
            if let photoIdArg = Self.launchArgValue("-openPhotoFullscreen", in: args),
               let photoId = UUID(uuidString: photoIdArg) {
                Task {
                    debugFullscreenPhoto = await photos.fetchPhoto(id: photoId)
                }
            }
            #endif
        }
    }

    #if DEBUG
    /// Reads the value following a `-flag value` launch argument pair (Xcode scheme launch
    /// arguments come through as separate elements of `ProcessInfo.arguments`).
    private static func launchArgValue(_ flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }
    #endif

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
