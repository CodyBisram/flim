import WidgetKit
import SwiftUI

/// A shutter on the Lock Screen. One tap into FLIM's camera.
///
/// The only widget here that is an action rather than a glance, and the only one that can never
/// go stale or empty. It also sits directly on the product's measured problem: cohort-scoped to
/// the accounts that signed up on or after 2026-08-12, twenty of twenty-one reached a camera the
/// app itself confirmed was authorized and eleven took a photograph. Reaching the camera is not
/// the barrier; deciding to is. A shutter on the Lock Screen makes that decision one tap from
/// wherever somebody already is.
///
/// The honest counter-argument, recorded because it may still win: this competes with the muscle
/// memory of the system camera button, and iOS 18's Control Center controls and the Action Button
/// may serve the same intent better than a widget does. Shipping it as the small companion to a
/// content widget rather than as the main event is the hedge.
///
/// `.accessoryCircular` only. Rectangular and inline are for information, and this has none to
/// give: a shutter that renders text is a button pretending to be a readout.
struct ShutterWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Shutter", provider: ShutterProvider()) { _ in
            ShutterView()
                .widgetURL(URL(string: WidgetLink.camera))
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Shoot")
        .description("Open the camera.")
        .supportedFamilies([.accessoryCircular])
    }
}

struct ShutterEntry: TimelineEntry { let date: Date }

/// Nothing to schedule. The tile never changes, so it asks to be left alone rather than being
/// woken on a timer to redraw the same shape.
struct ShutterProvider: TimelineProvider {
    func placeholder(in context: Context) -> ShutterEntry { ShutterEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (ShutterEntry) -> Void) {
        completion(ShutterEntry(date: .now))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ShutterEntry>) -> Void) {
        completion(Timeline(entries: [ShutterEntry(date: .now)], policy: .never))
    }
}

/// A shutter drawn rather than an SF Symbol.
///
/// `camera.aperture` was the obvious choice and is wrong at this size: its blades turn into grey
/// mush at 24 points on a Lock Screen, and every app that has ever used it looks the same. Two
/// concentric rings and a solid centre survive the size, read instantly as a shutter release, and
/// match the camera control the app already draws.
struct ShutterView: View {
    var body: some View {
        ZStack {
            Circle().strokeBorder(.white.opacity(0.55), lineWidth: 2)
            Circle().fill(.white).padding(6)
        }
        .widgetAccentable()
    }
}
