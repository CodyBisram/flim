import SwiftUI

/// The Chapters shelf (3a): a horizontal strip of month covers on the profile, between the
/// actions row and the grid. Shown on both the owner's own page and a stranger's, unchanged
/// either way, the RPC behind `chapters` is what decides what a month contains for who is
/// looking.
///
/// Renders nothing at all when there are no months, per spec: this is not an empty state with a
/// prompt, it is the absence of a section.
struct ChapterShelfView: View {
    @Environment(\.flimAccent) private var accent
    let chapters: [ChapterSummary]
    /// Keyed by storage path, matching every cover across every card: `CachedImage` keys its
    /// caches on the path, not on which chapter or card position happened to reference it.
    let coverURLs: [String: URL]
    /// Whose shelf: "ON YOUR SHELF" on your own page, "ON THE SHELF" on someone else's (1.7).
    var isOwn: Bool = true
    let onSelect: (ChapterSummary) -> Void

    var body: some View {
        if AppInfo.is17, !chapters.isEmpty {
            deskShelf
        } else if !chapters.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text("Chapters")
                        .flimFont(11, weight: .semibold, relativeTo: .caption2)
                        .tracking(1.4)
                        .textCase(.uppercase)
                        .foregroundStyle(FlimTheme.textSecondary)
                    LinearGradient(colors: [FlimTheme.stroke, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(height: 1)
                }
                .padding(.horizontal, 16).padding(.bottom, 12)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(chapters) { chapter in
                            Button {
                                Haptics.tap()
                                onSelect(chapter)
                            } label: {
                                card(chapter)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    /// 1.7's shelf (Blend 1, 4a): "ON YOUR SHELF" stamped in mono with the count of months, and
    /// each finished month as a rounded cover with its month stamped on, not a lidded box.
    private var deskShelf: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(isOwn ? "ON YOUR SHELF" : "ON THE SHELF")
                    .font(DeskType.data(10.5))
                    .tracking(1.7)
                    .foregroundStyle(FlimTheme.textTertiary)
                Spacer()
                Text("\(chapters.count) month\(chapters.count == 1 ? "" : "s")")
                    .flimFont(13, relativeTo: .footnote)
                    .foregroundStyle(FlimTheme.textTertiary)
            }
            .padding(.horizontal, 24)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(chapters) { chapter in
                        Button {
                            Haptics.tap()
                            onSelect(chapter)
                        } label: {
                            deskCover(chapter)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(chapter.monthName()), \(chapter.statsLine). Plays the month.")
                    }
                }
                .padding(.horizontal, 24)
            }
        }
    }

    private func deskCover(_ chapter: ChapterSummary) -> some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let path = chapter.coverPaths.first {
                    CachedImage(url: coverURLs[path], maxPixel: 300, cacheKey: path) { image in
                        image.resizable().scaledToFill()
                    } placeholder: { FlimTheme.well }
                } else {
                    FlimTheme.well
                }
            }
            .frame(width: 80, height: 104)
            .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
            Text(Self.stamp(chapter))
                .font(DeskType.data(10))
                .tracking(1.4)
                .foregroundStyle(Color(white: 0.98))
                .padding(.leading, 8)
                .padding(.bottom, 7)
        }
        .frame(width: 80, height: 104)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// "NOV", or "NOV 25" for a month from another year, so two Novembers never look alike.
    static func stamp(_ chapter: ChapterSummary) -> String {
        let month = chapter.monthName().prefix(3).uppercased()
        let calendar = Calendar.current
        let year = calendar.component(.year, from: chapter.monthStart)
        guard year != calendar.component(.year, from: .now) else { return month }
        return "\(month) \(String(format: "%02d", year % 100))"
    }

    /// Fixed 118pt wide at the frame aspect, per the handoff. `Color.clear` sizes the box, the
    /// same technique `PostThumb` and the roll archive tiles use, so the box's own size is never
    /// at the mercy of whichever cover image happens to be widest.
    private func card(_ chapter: ChapterSummary) -> some View {
        ZStack(alignment: .bottom) {
            Color.clear
                .aspectRatio(FlimTheme.frameAspect, contentMode: .fit)
                .overlay {
                    if let path = chapter.coverPaths.first {
                        CachedImage(url: coverURLs[path], maxPixel: 340, cacheKey: path) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.white.opacity(0.06)
                        }
                    } else {
                        Color.white.opacity(0.06)
                    }
                }

            LinearGradient(stops: [
                .init(color: .clear, location: 0.4),
                .init(color: .black.opacity(0.75), location: 1),
            ], startPoint: .top, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 2) {
                Text(chapter.monthName())
                    .flimFont(12.5, weight: .semibold, relativeTo: .caption)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(chapter.statsLine)
                    .flimFont(10.5, relativeTo: .caption2)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 118)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .topTrailing) {
            // The newest finished month wears the tag: it is the recap most people have not
            // played yet. The month in progress is not on the shelf at all.
            if chapter.id == chapters.first?.id {
                Label("Recap", systemImage: "play.fill")
                    .labelStyle(.chapterRecapTag)
                    .flimFont(9.5, weight: .bold, relativeTo: .caption2)
                    .tracking(0.8)
                    .foregroundStyle(FlimTheme.ink(accent))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(6)
            }
        }
    }
}

/// A label style with the glyph before the text at a smaller, matched size, since the default
/// `Label` sizes its `systemImage` independently of the surrounding `.flimFont`, which read as an
/// oversized play glyph next to the compact "RECAP" caption.
private struct ChapterRecapTagLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 7, weight: .bold))
            configuration.title.textCase(.uppercase)
        }
    }
}

private extension LabelStyle where Self == ChapterRecapTagLabelStyle {
    static var chapterRecapTag: ChapterRecapTagLabelStyle { ChapterRecapTagLabelStyle() }
}
