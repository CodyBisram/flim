import WidgetKit
import SwiftUI

/// The Darkroom tile: how many prints are waiting to be sorted, and the roll that is developing.
///
/// The headline is a COUNT, not a countdown, and that is the whole design. Personal instants
/// develop immediately, so they have no clock of their own — what they have is a pile that grows
/// while you are out and stops growing when you deal with it. A number that goes up when you
/// shoot and down when you sort is a thing worth glancing at; a timer that reads the same all day
/// is not.
///
/// The countdown survives as the second line, and only when it is real. Measured across
/// production, zero of 48 accounts had a roll developing at a randomly chosen moment, so a tile
/// built around that line would be a blank strip on every phone in the userbase. Here it appears
/// when there is something to say and takes no room when there isn't.
///
/// Rendering notes, since a widget is not a normal SwiftUI view:
///  - No animation and nothing that needs a GPU pass per update. WidgetKit renders these archived
///    and out of process; anything expensive is paid for on every timeline entry.
///  - The countdown is a `Text(timerInterval:)`, which ticks on-device from a fixed date, so the
///    tile stays right between refreshes rather than going stale between them.
struct DarkroomWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Darkroom", provider: DarkroomProvider()) { entry in
            DarkroomTile(snapshot: entry.snapshot)
                .containerBackground(for: .widget) { WidgetTheme.card }
        }
        .configurationDisplayName("Darkroom")
        .description("Prints waiting to be sorted, and the roll that's developing.")
        .supportedFamilies([.systemSmall])
    }
}

struct DarkroomEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct DarkroomProvider: TimelineProvider {
    func placeholder(in context: Context) -> DarkroomEntry {
        DarkroomEntry(date: .now, snapshot: .empty)
    }

    func getSnapshot(in context: Context, completion: @escaping (DarkroomEntry) -> Void) {
        completion(DarkroomEntry(date: .now, snapshot: WidgetStore.read() ?? .empty))
    }

    /// One entry, and a refresh scheduled against the only thing here that expires.
    ///
    /// The count changes when the app changes it, and the app rewrites the snapshot and reloads
    /// the timeline when it does, so there is nothing to poll for. A developing roll is the
    /// exception: its line has to stop being true the moment it reveals, so the refresh is pinned
    /// just past that.
    func getTimeline(in context: Context, completion: @escaping (Timeline<DarkroomEntry>) -> Void) {
        let now = Date()
        let snapshot = WidgetStore.read() ?? .empty
        let entry = DarkroomEntry(date: now, snapshot: snapshot)
        let next: Date
        if let reveal = snapshot.developingRoll?.revealAt, reveal > now {
            next = min(reveal.addingTimeInterval(60), now.addingTimeInterval(60 * 60))
        } else {
            next = now.addingTimeInterval(60 * 60)
        }
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

// MARK: - The tile

struct DarkroomTile: View {
    let snapshot: WidgetSnapshot

    private var accent: Color { FlimAccentPalette.color(snapshot.accent) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // A wash from the bottom-right corner rather than a flat fill, so the tile has a
            // direction to it and the accent is present without being a block of colour.
            RadialGradient(colors: [WidgetTheme.soft(accent), .clear],
                           center: UnitPoint(x: 0.8, y: 1.0), startRadius: 0, endRadius: 150)
            WidgetGrain(opacity: 0.35)

            VStack(alignment: .leading, spacing: 0) {
                WidgetTheme.eyebrow("Darkroom", accent: accent)
                Spacer(minLength: 4)
                headline
                Spacer(minLength: 0)
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .widgetURL(URL(string: link))
    }

    /// The tap target follows what the tile is actually offering. With prints waiting that is the
    /// sort deck; with none it is the Darkroom itself, because sending someone to an empty deck
    /// is sending them to a dead end.
    private var link: String {
        snapshot.unsortedCount > 0 ? WidgetLink.sortDeck : WidgetLink.darkroom
    }

    @ViewBuilder
    private var headline: some View {
        if snapshot.neverWritten {
            // Not the same as an empty darkroom, and it must not look like one. This is what a
            // shared container that never worked looks like from in here — an App Group missing
            // from a provisioning profile, which is silent and survives a reinstall. Saying so
            // is both the honest user-facing state and the only way the failure is ever visible.
            VStack(alignment: .leading, spacing: 3) {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 22, weight: .thin))
                    .foregroundStyle(accent)
                Text("Open FLIM\nto set this up")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(WidgetTheme.textSecondary)
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if snapshot.unsortedCount > 0 {
            VStack(alignment: .leading, spacing: -2) {
                WidgetTheme.figure("\(snapshot.unsortedCount)")
                Text(snapshot.unsortedCount == 1 ? "print to sort" : "prints to sort")
                    .font(.system(size: 11))
                    .foregroundStyle(WidgetTheme.textSecondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Image(systemName: "checkmark")
                    .font(.system(size: 20, weight: .thin))
                    .foregroundStyle(accent.opacity(0.85))
                Text("All sorted")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(WidgetTheme.textSecondary)
            }
        }
    }

    /// Only drawn when a shared roll is actually developing. An empty strip reserved for a line
    /// that is usually absent would cost the headline its room for nothing.
    @ViewBuilder
    private var footer: some View {
        if let roll = snapshot.developingRoll {
            HStack(spacing: 4) {
                Image(systemName: "film.stack")
                    .font(.system(size: 9))
                Text(roll.name)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                Text("·")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                WidgetTheme.countdown(to: roll.revealAt)
                    .layoutPriority(1)
            }
            .foregroundStyle(accent)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
        }
    }
}
