import WidgetKit
import SwiftUI

/// A frame from further back, on a ladder of horizons.
///
/// The design asked for "one year ago". FLIM 1.0 shipped 2026-06-30, so no account can have a
/// genuine one-year-ago frame until mid-2027: built as specified, this tile would show its
/// fallback to every user for ten months while printing a label that was false about it. That is
/// the same failure as a countdown tile that is blank for everybody, and the fix is the same —
/// let the data decide what the tile is about.
///
/// So the writer walks a ladder (a year, a month, a week, yesterday, newest) and contributes one
/// card per horizon that actually HAS a frame. The tile rotates through them oldest-first, which
/// gets both things worth having: the strongest memory leads, and the tile still changes through
/// the day. Rotation is deterministic rather than random, because random content would depend on
/// when WidgetKit happened to wake and could not be tested.
struct MemoryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Memory", provider: MemoryProvider()) { entry in
            MemoryTile(memory: entry.memory, image: entry.image, accent: entry.accent,
                       neverWritten: entry.neverWritten)
                .containerBackground(for: .widget) { WidgetTheme.card }
        }
        .configurationDisplayName("Look back")
        .description("A frame from a year, a month, or a week ago.")
        .supportedFamilies([.systemSmall])
    }
}

struct MemoryEntry: TimelineEntry {
    let date: Date
    let memory: WidgetSnapshot.Memory?
    let image: Data?
    let accent: String
    let neverWritten: Bool
}

struct MemoryProvider: TimelineProvider {
    /// Twenty minutes a card. Long enough that the tile is not busy, short enough that a handful
    /// of horizons is a couple of hours of variety rather than a day of it.
    private static let rotation: TimeInterval = 20 * 60

    func placeholder(in context: Context) -> MemoryEntry {
        MemoryEntry(date: .now, memory: nil, image: nil, accent: FlimAccentPalette.fallback,
                    neverWritten: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (MemoryEntry) -> Void) {
        completion(entries(from: WidgetStore.read() ?? .empty, at: .now).first
                   ?? placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MemoryEntry>) -> Void) {
        let now = Date()
        let snapshot = WidgetStore.read() ?? .empty
        let entries = entries(from: snapshot, at: now)
        let next = (entries.last?.date ?? now).addingTimeInterval(Self.rotation)
        completion(Timeline(entries: entries, policy: .after(next)))
    }

    /// One entry per memory, spaced apart. WidgetKit renders these ahead of time from a single
    /// wake, so a rotation costs no more refresh budget than a static tile: the entries are
    /// prepared once and swapped by the system on schedule.
    private func entries(from snapshot: WidgetSnapshot, at start: Date) -> [MemoryEntry] {
        guard !snapshot.memories.isEmpty else {
            return [MemoryEntry(date: start, memory: nil, image: nil, accent: snapshot.accent,
                                neverWritten: snapshot.neverWritten)]
        }
        return snapshot.memories.enumerated().map { index, memory in
            MemoryEntry(date: start.addingTimeInterval(Double(index) * Self.rotation),
                        memory: memory,
                        image: WidgetStore.image(named: memory.imageName),
                        accent: snapshot.accent,
                        neverWritten: false)
        }
    }
}

// MARK: - The tile

struct MemoryTile: View {
    let memory: WidgetSnapshot.Memory?
    let image: Data?
    let accent: String
    let neverWritten: Bool

    private var accentColor: Color { FlimAccentPalette.color(accent) }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            photograph
            WidgetGrain()
            // Only where the text sits. A uniform scrim dims the picture to make room for two
            // lines, which is the wrong trade when the picture is the product.
            LinearGradient(colors: [.clear, .black.opacity(0.72)],
                           startPoint: UnitPoint(x: 0.5, y: 0.4), endPoint: .bottom)
            caption
        }
        .widgetURL(URL(string: memory?.link ?? WidgetLink.camera))
    }

    @ViewBuilder
    private var photograph: some View {
        if let image, let ui = UIImage(data: image) {
            Image(uiImage: ui)
                .resizable()
                .scaledToFill()
        } else {
            // The image is missing but the memory is not: the snapshot names a frame whose bytes
            // never arrived. A hue derived from the frame's own name keeps it looking deliberate
            // and keeps two different missing frames from looking identical.
            RollHueTile(seed: memory?.imageName ?? "flim", corner: 0)
        }
    }

    @ViewBuilder
    private var caption: some View {
        if let memory {
            VStack(alignment: .leading, spacing: 3) {
                WidgetTheme.eyebrow(memory.horizon.label, accent: accentColor)
                Text(memory.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(WidgetTheme.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
            .padding(14)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                WidgetTheme.eyebrow(neverWritten ? "Not set up" : "Nothing yet", accent: accentColor)
                Text(neverWritten ? "Open FLIM to set this up" : "Shoot something to look back on")
                    .font(.system(size: 12))
                    .foregroundStyle(WidgetTheme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
        }
    }
}
