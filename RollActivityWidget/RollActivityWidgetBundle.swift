import WidgetKit
import SwiftUI

/// ⚠️ `LatestFrameWidget` and `ShutterWidget` are built, but deliberately NOT listed here yet.
///
/// Both are finished and both compile into this extension. What they need is the App Group
/// `group.com.flim.app`, created in the developer account and added to the entitlements of BOTH
/// `com.flim.app` and `com.flim.app.RollActivityWidget`, with both AppStore profiles regenerated
/// through match. Until that exists, `WidgetStore.container` is nil, every snapshot read returns
/// nothing, and `LatestFrameWidget` can only ever render "your first frame goes here" — on every
/// phone, forever. A widget that is permanently empty in the gallery is worse than one that is
/// not there, and it is the kind of thing people add once and never trust again.
///
/// The entitlement is also deliberately not in `project.yml` yet: adding an App Group the match
/// profiles do not carry would fail signing on the very next Release build, which is a broken
/// TestFlight for a feature nobody can use.
///
/// So when the App Group lands, it is two changes:
///   1. add the group to both targets' entitlements in project.yml
///   2. add `LatestFrameWidget()` and `ShutterWidget()` to the body below
///
/// Everything else — the tiles, the shared store, the snapshot writer and its call sites, the
/// `flim://camera` route the shutter taps into — is already in place and already runs.
@main
struct RollActivityWidgetBundle: WidgetBundle {
    var body: some Widget {
        RollRevealLiveActivity()
    }
}
