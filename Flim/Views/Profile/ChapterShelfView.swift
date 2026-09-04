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
    let onSelect: (ChapterSummary) -> Void

    var body: some View {
        if !chapters.isEmpty {
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
            if chapter.isCurrentMonth() {
                Label("Recap", systemImage: "play.fill")
                    .labelStyle(.chapterRecapTag)
                    .flimFont(9.5, weight: .bold, relativeTo: .caption2)
                    .tracking(0.8)
                    .foregroundStyle(accent)
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
