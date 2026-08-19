import WidgetKit
import SwiftUI

/// The extension's four surfaces: the Live Activity that counts a roll down to its reveal, the
/// Darkroom tile, the look-back tile, and the Lock Screen shutter.
///
/// The three home-screen ones need the App Group `group.com.flim.app` on BOTH `com.flim.app` and
/// `com.flim.app.RollActivityWidget`, declared in project.yml for each. If a build ever ships
/// without it, `WidgetStore.container` is nil and every snapshot read comes back empty on every
/// phone regardless of what its owner has shot.
///
/// That failure used to be invisible: it rendered as an ordinary empty state, so a provisioning
/// mistake and a brand new account looked identical on screen. The tiles now distinguish them —
/// see `WidgetSnapshot.neverWritten` — because it is the one bug here that survives a reinstall
/// and cannot be reproduced in the simulator.
@main
struct RollActivityWidgetBundle: WidgetBundle {
    var body: some Widget {
        RollRevealLiveActivity()
        DarkroomWidget()
        MemoryWidget()
        ShutterWidget()
    }
}
