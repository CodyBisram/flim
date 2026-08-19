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
        let now = Date()
        let snapshot = WidgetStore.read() ?? .empty
        // A developing roll does not rotate: it has a deadline, and cycling away from a countdown
        // to show a photograph is losing the one thing on screen that is time-critical.
        if case .developing(_, let revealAt) = snapshot.state {
            let next = min(revealAt, now.addingTimeInterval(15 * 60))
            completion(Timeline(entries: [entry()], policy: .after(next)))
            return
        }
        let entries = rotating(snapshot, from: now)
        let next = entries.last.map { $0.date.addingTimeInterval(Self.rotation) }
            ?? now.addingTimeInterval(60 * 60)
        completion(Timeline(entries: entries, policy: .after(next)))
    }

    private func entry() -> LatestFrameEntry {
        let snapshot = WidgetStore.read() ?? .empty
        let image = snapshot.imageName.flatMap { WidgetStore.image(named: $0) }
        return LatestFrameEntry(date: .now, snapshot: snapshot, image: image)
    }

    /// One entry per stored frame, spaced apart, so the tile cycles through recent work instead of
    /// showing one photograph until its owner next shoots. WidgetKit renders these ahead of time
    /// from a single wake, so a rotation costs no more refresh budget than a static tile: the
    /// entries are prepared once and swapped by the system on schedule.
    private func rotating(_ snapshot: WidgetSnapshot, from start: Date) -> [LatestFrameEntry] {
        let names = snapshot.imageNames
        guard names.count > 1 else { return [entry()] }
        return names.enumerated().map { index, name in
            LatestFrameEntry(date: start.addingTimeInterval(Double(index) * Self.rotation),
                             snapshot: snapshot,
                             image: WidgetStore.image(named: name))
        }
    }

    /// Twenty minutes a frame. Long enough that the tile is not busy, short enough that five
    /// frames are a couple of hours of variety rather than a day of it.
    private static let rotation: TimeInterval = 20 * 60
}

// MARK: - The tile

struct LatestFrameView: View {
    let entry: LatestFrameEntry
    @Environment(\.widgetFamily) private var family

    /// From the snapshot, not from any UserDefaults. The extension cannot see the app's standard
    /// defaults, and the App Group suite this used to read is written by nothing, so every tile
    /// rendered in the fallback amber no matter what its owner had chosen. Same fix the Live
    /// Activity already had: the accent travels with the data.
    private var accent: Color { FlimAccentPalette.color(entry.snapshot.accent) }

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

/// FLIM's grain, rebuilt small enough to live in a widget.
///
/// The app's own `GrainOverlay` sits in `PhotoGridCell.swift`, which drags half the Darkroom in
/// with it, so this is a local twin rather than a shared file: one pre-rendered noise tile,
/// screen-blended, generated once per process. Grain is the single cheapest thing that makes a
/// rectangle read as FLIM rather than as any photo app's widget.
private struct WidgetGrain: View {
    var body: some View {
        Image(uiImage: Self.tile)
            .resizable(resizingMode: .tile)
            .blendMode(.screen)
            .opacity(0.5)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private static let tile: UIImage = {
        let side: CGFloat = 120
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { ctx in
            for _ in 0..<Int(side * side / 90) {
                let alpha = CGFloat.random(in: 0.02...0.10)
                ctx.cgContext.setFillColor(UIColor(white: 1, alpha: alpha).cgColor)
                ctx.cgContext.fill(CGRect(x: .random(in: 0..<side), y: .random(in: 0..<side),
                                          width: 1, height: 1))
            }
        }
    }()
}

/// The photograph.
///
/// SMALL bleeds to every edge with a scrim only under the text: a uniform scrim dims the picture
/// to make room for six characters, which is the wrong trade when the picture is the product.
///
/// MEDIUM does NOT bleed, and that is the fix for what it looked like first. Every FLIM frame is
/// 3:4 portrait and the medium family is roughly 2:1 landscape, so filling it threw away about
/// three quarters of the image height and left a letterboxed strip that read as a bug. It is a
/// print on a shelf instead: the frame at its true aspect on the left, in a paper-white border,
/// with what happened to it set beside it. The wasted space stops being wasted once it is holding
/// something.
private struct FrameTile: View {
    let image: Data?
    let accent: Color
    let reactions: [WidgetSnapshot.ReactionCount]
    let caption: String
    let family: WidgetFamily

    var body: some View {
        if family == .systemMedium {
            HStack(spacing: 14) {
                print
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                details
                Spacer(minLength: 0)
            }
            .padding(14)
        } else {
            ZStack(alignment: .bottomLeading) {
                photograph.scaledToFill()
                WidgetGrain()
                LinearGradient(colors: [.clear, .black.opacity(0.75)],
                               startPoint: .center, endPoint: .bottom)
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(reactions.prefix(2), id: \.emoji) { chip($0) }
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

    /// The frame as a print: a hairline paper border, which is what separates "a photograph" from
    /// "an image filling a box" at this size.
    private var print: some View {
        photograph
            .scaledToFill()
            .overlay { WidgetGrain() }
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(caption.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(accent)
                .lineLimit(1)
            if reactions.isEmpty {
                Text("No reactions yet")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(reactions.prefix(4), id: \.emoji) { chip($0) }
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func chip(_ r: WidgetSnapshot.ReactionCount) -> some View {
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

    @ViewBuilder
    private var photograph: some View {
        if let image, let ui = UIImage(data: image) {
            Image(uiImage: ui).resizable()
        } else {
            // A frame whose bytes did not survive, which is not the same as having no frames.
            // Kept quiet rather than apologetic: the tile still reads as a print.
            Rectangle().fill(Color(white: 0.10))
        }
    }
}

/// The countdown, for the rare and good day when something is developing.
///
/// The hourglass is the one piece of iconography the product has that is not a photograph, and
/// waiting is the thing FLIM asks of people, so it belongs here. It is tinted with the owner's own
/// accent, like every other piece of chrome in the app.
///
/// Not animated, because a widget cannot animate: WidgetKit renders each entry archived and out of
/// process, so anything moving would be a flipbook of scheduled redraws paid for out of a refresh
/// budget. The one thing that genuinely moves is the countdown itself, and it moves for free.
private struct DevelopingTile: View {
    let rollName: String
    let revealAt: Date
    let accent: Color

    var body: some View {
        ZStack {
            // A faint wash of the accent behind everything, so a developing roll is recognisable
            // across the room as "the FLIM one", the way the Live Activity's card is.
            LinearGradient(colors: [accent.opacity(0.20), .clear],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            WidgetGrain()
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "hourglass")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(accent)
                    Text(rollName.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(accent)
                        .lineLimit(1)
                }
                // Ticks on device from a fixed date, so the countdown stays right between timeline
                // entries without waking the extension. Same mechanism the Live Activity uses.
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
}

/// For the fourteen of forty-eight who have never shot anything.
///
/// An empty film frame rather than a call to action with a button in it. This is the only place
/// in the product that reaches somebody who never got past the camera, and the tone that suits
/// that is an empty plate waiting for them, not an app asking for something.
private struct EmptyPlateTile: View {
    let accent: Color

    var body: some View {
        ZStack {
        WidgetGrain()
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
}
