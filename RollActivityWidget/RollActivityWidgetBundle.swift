import WidgetKit
import SwiftUI

/// The extension's widgets: the Live Activity that counts a roll down to its reveal, the
/// home-screen tile showing your last frame and what it has collected, and the Lock Screen
/// shutter.
///
/// The two additions here need the App Group `group.com.flim.app` on BOTH `com.flim.app` and
/// `com.flim.app.RollActivityWidget`, which is declared in project.yml for each. If a build ever
/// ships without it, `WidgetStore.container` is nil, every snapshot read comes back empty, and
/// `LatestFrameWidget` renders "your first frame goes here" on every phone regardless of what its
/// owner has shot. That failure is silent, so it is worth knowing the shape of it.
@main
struct RollActivityWidgetBundle: WidgetBundle {
    var body: some Widget {
        RollRevealLiveActivity()
        LatestFrameWidget()
        ShutterWidget()
    }
}
