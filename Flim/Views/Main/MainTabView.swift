import SwiftUI

struct MainTabView: View {
    @State private var selected = 0
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
        }
        .tint(FlimTheme.accent)
        .onAppear {
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
}
