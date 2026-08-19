import WidgetKit
import SwiftUI

/// The home-screen widget: your last frame, and what happened to it.
///
/// Why this and not a countdown. A roll countdown was the obvious widget and the measurement
/// killed it: at a randomly chosen moment, zero of 48 production accounts had a roll developing,
/// so it would have been a blank tile on every phone in the userbase. What actually moves is
/// reactions, at 119 a day across 48 people, about 32 a week for anyone who posts. So the default
/// state is the photograph you posted with what it has collected since: something that changes
/// several times a day without you doing anything, which is the difference between a widget people
/// glance at and one they stop seeing by week two.
///
/// The countdown survives as the interrupt. Rare is what makes it read as an event.
///
/// Rendering notes, since a widget is not a normal SwiftUI view:
///  - No animation, no gradients that need a GPU pass per update, no `.blur`. WidgetKit renders
///    these archived and out of process; anything expensive is paid for on every timeline entry.
///  - The photograph is drawn edge to edge with a scrim only where text sits. A widget that
///    letterboxes a photo looks like a screenshot of an app; one that bleeds looks like a print.
///  - Timeline entries are cheap and few: one now, one at the next reaction-agnostic refresh.
///    Reactions arrive by the app rewriting the snapshot, not by the widget polling.
struct LatestFrameWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LatestFrame", provider: LatestFrameProvider()) { entry in
            LatestFrameView(entry: entry)
                .containerBackground(for: .widget) { Color.black }
        }
        .configurationDisplayName("Your last frame")
        .description("The frame you shot most recently, and what people made of it.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct LatestFrameEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    let image: Data?
}

struct LatestFrameProvider: TimelineProvider {
    func placeholder(in context: Context) -> LatestFrameEntry {
        LatestFrameEntry(date: .now, snapshot: .empty, image: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (LatestFrameEntry) -> Void) {
        completion(entry())
    }

    /// One entry now, and a refresh an hour out. The app is what pushes real change here (it
    /// rewrites the snapshot and calls `WidgetCenter.reloadTimelines` when a frame is shot or
    /// reactions land), so this schedule exists only to keep relative times honest and to recover
    /// if the app has not run in a while. A developing roll asks for a tighter one, because its
    /// countdown is the only thing on screen that has to be right to the minute.
    func getTimeline(in context: Context, completion: @escaping (Timeline<LatestFrameEntry>) -> Void) {
        let entry = entry()
        let next: Date
        if case .developing(_, let revealAt) = entry.snapshot.state {
            next = min(revealAt, Date().addingTimeInterval(15 * 60))
        } else {
            next = Date().addingTimeInterval(60 * 60)
        }
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func entry() -> LatestFrameEntry {
        let snapshot = WidgetStore.read() ?? .empty
        let image = snapshot.imageName.flatMap { WidgetStore.image(named: $0) }
        return LatestFrameEntry(date: .now, snapshot: snapshot, image: image)
    }
}

// MARK: - The tile

struct LatestFrameView: View {
    let entry: LatestFrameEntry
    @Environment(\.widgetFamily) private var family

    private var accent: Color {
        FlimAccentPalette.color(UserDefaults(suiteName: WidgetStore.appGroup)?
            .string(forKey: "accentColor") ?? FlimAccentPalette.fallback)
    }

    var body: some View {
        switch entry.snapshot.state {
        case .developing(let name, let revealAt):
            DevelopingTile(rollName: name, revealAt: revealAt, accent: accent)
        case .posted(let reactions, let postedAt):
            FrameTile(image: entry.image, accent: accent, reactions: reactions,
                      caption: Self.relative(postedAt), family: family)
        case .shot(let takenAt):
            FrameTile(image: entry.image, accent: accent, reactions: [],
                      caption: "In your darkroom \u{00B7} " + Self.relative(takenAt), family: family)
        case .empty:
            EmptyPlateTile(accent: accent)
        }
    }

    /// "2h" rather than "2 hours ago": at widget size the unit is what carries the meaning and
    /// the rest is noise competing with the photograph.
    static func relative(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        switch seconds {
        case ..<3600:   return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        default:        return "\(Int(seconds / 86_400))d"
        }
    }
}

/// The photograph, bled to every edge, with a scrim only under the text.
///
/// The scrim is a two-stop gradient over the bottom third rather than a flat overlay across the
/// whole tile: a uniform scrim dims the picture to make room for six characters, which is the
/// wrong trade when the picture is the product.
private struct FrameTile: View {
    let image: Data?
    let accent: Color
    let reactions: [WidgetSnapshot.ReactionCount]
    let caption: String
    let family: WidgetFamily

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let image, let ui = UIImage(data: image) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
            } else {
                // A frame whose bytes did not survive, which is not the same as having no frames.
                // Kept quiet rather than apologetic: the tile still reads as a print.
                Rectangle().fill(Color(white: 0.10))
            }

            LinearGradient(colors: [.clear, .black.opacity(0.75)],
                           startPoint: .center, endPoint: .bottom)

            HStack(alignment: .bottom, spacing: 6) {
                ForEach(reactions.prefix(family == .systemSmall ? 2 : 4), id: \.emoji) { r in
                    HStack(spacing: 3) {
                        Text(r.emoji).font(.system(size: 12))
                        Text("\(r.count)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.35), in: Capsule())
                }
                Spacer(minLength: 0)
                Text(caption)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(10)
        }
        .clipped()
    }
}

/// The countdown, for the rare and good day when something is developing.
private struct DevelopingTile: View {
    let rollName: String
    let revealAt: Date
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(rollName.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(accent)
                .lineLimit(1)
            // `Text(timerInterval:)` ticks on device from a fixed date, so the countdown stays
            // right between timeline entries without the extension being woken to update it. Same
            // mechanism the Live Activity already relies on.
            Text(timerInterval: Date()...revealAt, countsDown: true)
                .font(.system(size: 30, weight: .thin, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text("until it develops")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// For the fourteen of forty-eight who have never shot anything.
///
/// An empty film frame rather than a call to action with a button in it. This is the only place
/// in the product that reaches somebody who never got past the camera, and the tone that suits
/// that is an empty plate waiting for them, not an app asking for something.
private struct EmptyPlateTile: View {
    let accent: Color

    var body: some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .foregroundStyle(accent.opacity(0.45))
                .frame(width: 42, height: 54)
            Text("Your first frame\ngoes here")
                .font(.system(size: 11, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
