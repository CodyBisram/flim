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
/// ## The Lock Screen does not render your colours, and cannot be made to
///
/// `.accessoryCircular` is composited by the system as a vibrancy mask: what survives is
/// LUMINANCE and ALPHA, not hue. A widget cannot opt out, and there is no API that lets it —
/// setting an accent here is not overridden so much as never consulted. So the accent is real on
/// the Home Screen's small-circle placement and in StandBy, and on the Lock Screen it is not.
///
/// That is designed around rather than fought: every state below is distinguishable by SHAPE
/// alone — a bare shutter, a shutter with an arc around it, a shutter with a filled badge, a
/// shutter with a sparkle. Drop the colour out of any of them and they are still four different
/// tiles. `AccessoryWidgetBackground` supplies the same translucent disc the system's own
/// accessory widgets sit on, which is what makes this look native there rather than like a dark
/// circle pasted onto the wallpaper.
struct ShutterView: View {
    let state: WidgetSnapshot.ShutterState
    var accent: String = FlimAccentPalette.fallback

    private var accentColor: Color { FlimAccentPalette.color(accent) }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                AccessoryWidgetBackground()

                switch state {
                case .readyToReveal:
                    shutter(ring: accentColor, filled: false, side: side)
                    Image(systemName: "sparkles")
                        .font(.system(size: side * 0.30, weight: .light))
                        .foregroundStyle(accentColor)

                case .developing(let progress):
                    shutter(ring: .white.opacity(0.9), filled: true, side: side)
                    // strokeBorder, and inset: a plain `stroke` centres the line ON the path, so
                    // half of it lands outside the circular mask and gets shaved off.
                    Circle()
                        .strokeBorder(.white.opacity(0.25), lineWidth: side * 0.055)
                    Circle()
                        .inset(by: side * 0.0275)
                        .trim(from: 0, to: max(0.02, progress))
                        .stroke(accentColor, style: StrokeStyle(lineWidth: side * 0.055, lineCap: .round))
                        .rotationEffect(.degrees(-90))

                case .unsorted(let count):
                    shutter(ring: .white.opacity(0.9), filled: true, side: side)
                    badge(count, side: side)

                case .idle:
                    shutter(ring: .white.opacity(0.9), filled: true, side: side)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .widgetAccentable()
    }

    /// Sized from the tile rather than in points. An accessory circle is not one fixed size across
    /// devices, and the previous fixed paddings put the ring in a different place on a mini than
    /// on a Pro Max.
    private func shutter(ring: Color, filled: Bool, side: CGFloat) -> some View {
        ZStack {
            Circle()
                .strokeBorder(ring, lineWidth: side * 0.05)
                .padding(side * 0.16)
            if filled {
                Circle().fill(.white).padding(side * 0.30)
            }
        }
    }

    /// Inside the circle, not at the bounding box's corner.
    ///
    /// This is the clipping bug: `.frame(alignment: .topTrailing)` puts a badge in the corner of
    /// the SQUARE, and an accessory widget is masked to the inscribed CIRCLE, so the corner is
    /// exactly the part that is thrown away — the badge came out sliced in half. Placing it on
    /// the 45° diagonal at 0.30 of the side keeps the whole badge inside the mask at every size.
    private func badge(_ count: Int, side: CGFloat) -> some View {
        let radius = side * 0.30
        let offset = radius * 0.7071            // cos/sin of 45°
        return Text(count > 9 ? "9+" : "\(count)")
            .font(.system(size: side * 0.22, weight: .bold))
            .foregroundStyle(.black)
            .padding(.horizontal, side * 0.055)
            .frame(minWidth: side * 0.30, minHeight: side * 0.30)
            .background(Capsule().fill(accentColor))
            // A hairline of the tile's own backdrop around the badge, so it reads as sitting ON
            // the shutter rather than merging into the ring it overlaps.
            .overlay(Capsule().strokeBorder(.black.opacity(0.35), lineWidth: side * 0.02))
            .offset(x: offset, y: -offset)
    }
}
