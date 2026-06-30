import SwiftUI

struct MainTabView: View {
    @State private var selected = 0

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
            // Deterministic Simulator verification: launch with `-seedDemo` to jump
            // straight to the Darkroom (which then auto-seeds — see DarkroomView).
            if ProcessInfo.processInfo.arguments.contains("-seedDemo") { selected = 1 }
            #endif
        }
    }
}
