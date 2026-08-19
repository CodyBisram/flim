import WidgetKit
import SwiftUI

/// A shutter on the Lock Screen. One tap into FLIM's camera, and a readout of what is waiting.
///
/// The only widget here that is an action rather than a glance. It also sits directly on the
/// product's measured problem: cohort-scoped to the accounts that signed up on or after
/// 2026-08-12, twenty of twenty-one reached a camera the app itself confirmed was authorized and
/// eleven took a photograph. Reaching the camera is not the barrier; deciding to is. A shutter on
/// the Lock Screen makes that decision one tap from wherever somebody already is.
///
/// Four states, in priority order: a roll ready to reveal, a roll developing, prints waiting to
/// be sorted, idle. That order is the product decision — the only state ASKING for something
/// outranks the only state with a deadline, which outranks a standing count.
///
/// The ring and the sparkle come only from shared Rolls; the badge counts personal instants,
/// which develop immediately and so have a pile rather than a clock. Keeping those two signals
/// visually separate is what stops the tile from implying your own shots are on a timer.
///
/// `.accessoryCircular` only. Rectangular and inline are for information; this is a button, and a
/// button that renders a line of text is a button pretending to be a readout.
struct ShutterWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Shutter", provider: ShutterProvider()) { entry in
            ShutterView(state: entry.state, accent: entry.accent)
                .widgetURL(URL(string: entry.link))
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Shoot")
        .description("Open the camera, and see what's waiting.")
        .supportedFamilies([.accessoryCircular])
    }
}

struct ShutterEntry: TimelineEntry {
    let date: Date
    let state: WidgetSnapshot.ShutterState
    let accent: String
    let link: String
}

struct ShutterProvider: TimelineProvider {
    func placeholder(in context: Context) -> ShutterEntry {
        ShutterEntry(date: .now, state: .idle, accent: FlimAccentPalette.fallback,
                     link: WidgetLink.camera)
    }

    func getSnapshot(in context: Context, completion: @escaping (ShutterEntry) -> Void) {
        completion(entry(at: .now))
    }

    /// A developing ring is the only state that changes on its own, so it is the only one worth
    /// waking for. Everything else moves when the app moves it, and the app reloads this timeline
    /// when it does.
    func getTimeline(in context: Context, completion: @escaping (Timeline<ShutterEntry>) -> Void) {
        let now = Date()
        let current = entry(at: now)
        let next: Date
        if case .developing = current.state,
           let reveal = (WidgetStore.read() ?? .empty).developingRoll?.revealAt, reveal > now {
            // Often enough that the ring visibly moves across a twelve-hour develop, and pinned
            // to the reveal itself so the sparkle is not late.
            next = min(reveal, now.addingTimeInterval(30 * 60))
        } else {
            next = now.addingTimeInterval(60 * 60)
        }
        completion(Timeline(entries: [current], policy: .after(next)))
    }

    private func entry(at now: Date) -> ShutterEntry {
        let snapshot = WidgetStore.read() ?? .empty
        let state = snapshot.shutterState(now: now)
        // Where the tap goes follows what the tile is showing. A shutter that always opened the
        // camera would be showing you a reveal is ready and then not taking you to it.
        let link: String
        switch state {
        case .readyToReveal:
            link = snapshot.developingRoll.map { WidgetLink.reveal($0.id) } ?? WidgetLink.darkroom
        case .unsorted:
            link = WidgetLink.sortDeck
        case .developing, .idle:
            link = WidgetLink.camera
        }
        return ShutterEntry(date: now, state: state, accent: snapshot.accent, link: link)
    }
}

// MARK: - The tile

/// A shutter drawn rather than an SF Symbol.
///
/// `camera.aperture` was the obvious choice and is wrong at this size: its blades turn into grey
/// mush at 24 points on a Lock Screen, and every app that has ever used it looks the same. Two
/// concentric rings and a solid centre survive the size, read instantly as a shutter release, and
/// match the camera control the app already draws.
///
/// On the Lock Screen the system renders accessory widgets in its own tinted or monochrome style,
/// so the accent survives as brightness rather than as hue there; it shows in full on the Home
/// Screen's small-circle placement and in StandBy. `.widgetAccentable()` marks the parts that
/// should take the system tint, which is why the shutter itself is marked and the ring is not.
struct ShutterView: View {
    let state: WidgetSnapshot.ShutterState
    var accent: String = FlimAccentPalette.fallback

    private var accentColor: Color { FlimAccentPalette.color(accent) }

    var body: some View {
        ZStack {
            switch state {
            case .readyToReveal:
                Circle().fill(WidgetTheme.soft(accentColor))
                shutter(ring: accentColor, fill: nil)
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .light))
                    .foregroundStyle(accentColor)
                    .widgetAccentable()

            case .developing(let progress):
                shutter(ring: .white.opacity(0.55), fill: .white)
                // The ring lives OUTSIDE the shutter rather than replacing it, so the tile never
                // stops being a shutter while a roll happens to be developing.
                Circle()
                    .strokeBorder(.white.opacity(0.18), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: max(0.02, progress))
                    .stroke(accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(1.25)

            case .unsorted(let count):
                shutter(ring: .white.opacity(0.55), fill: .white)
                badge(count)

            case .idle:
                shutter(ring: .white.opacity(0.55), fill: .white)
            }
        }
    }

    private func shutter(ring: Color, fill: Color?) -> some View {
        ZStack {
            Circle().strokeBorder(ring, lineWidth: 2).padding(4)
            if let fill { Circle().fill(fill).padding(10) }
        }
        .widgetAccentable()
    }

    /// Top-trailing, overlapping the ring, the way a notification badge sits on an app icon. The
    /// count is capped so a big pile cannot push the digits down to an unreadable size.
    private func badge(_ count: Int) -> some View {
        Text(count > 9 ? "9+" : "\(count)")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.black)
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 16)
            .background(Capsule().fill(accentColor))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .offset(x: 2, y: -2)
    }
}
