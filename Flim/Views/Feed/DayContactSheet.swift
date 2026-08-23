import SwiftUI

/// A day past the film strip's cap, opened from the strip's `+N` tile: the whole day as a
/// contact-sheet grid. This is where the contact-sheet pattern that lost the feed-unit
/// bake-off lives on: best density, worst photographs, which is exactly right for an
/// overflow index and exactly wrong for the feed itself.
///
/// Tapping a shot hands its index back so the unit's pager jumps to it; nothing here is a
/// second surface for reactions or comments, those belong to the frame in the feed.
struct DayContactSheet: View {
    @Environment(\.flimAccent) private var accent
    @Environment(FeedService.self) private var feed
    @Environment(\.dismiss) private var dismiss

    let unit: FeedUnit
    let onSelect: (Int) -> Void

    @State private var urls: [Int: URL] = [:]

    private let columns = [GridItem(.flexible(), spacing: 2),
                           GridItem(.flexible(), spacing: 2),
                           GridItem(.flexible(), spacing: 2)]

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 2) {
                Text(unit.author.handle)
                    .flimFont(17, weight: .light, relativeTo: .body)
                    .tracking(0.4)
                    .foregroundStyle(FlimTheme.textPrimary)
                Text(unit.metaLine)
                    .flimFont(11.5, relativeTo: .caption)
                    .foregroundStyle(FlimTheme.textTertiary)
            }
            .padding(.top, 18)
            .padding(.bottom, 12)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(Array(unit.items.enumerated()), id: \.element.id) { index, item in
                        Button {
                            Haptics.tap()
                            onSelect(index)
                        } label: {
                            CachedImage(url: urls[index], maxPixel: 400, cacheKey: item.post.indexPath) {
                                $0.resizable().scaledToFill()
                            } placeholder: {
                                Rectangle().fill(Color.white.opacity(0.06))
                            }
                            .aspectRatio(3 / 4, contentMode: .fit)
                            .clipped()
                            .overlay(alignment: .bottomLeading) {
                                Text(String(format: "%02d", index + 1))
                                    .flimFont(9.5, relativeTo: .caption2)
                                    .foregroundStyle(Color(red: 0.96, green: 0.94, blue: 0.91).opacity(0.5))
                                    .padding(.leading, 6).padding(.bottom, 5)
                            }
                        }
                        .accessibilityLabel("Shot \(index + 1) of \(unit.items.count)")
                    }
                }
                .padding(.horizontal, 2)
                .padding(.bottom, 24)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(FlimTheme.bg)
        // One batched resolution for the whole day, not one round trip per cell; same
        // index-rendition preference as the strip, for the same reason.
        .task {
            let paths = unit.items.map(\.post.indexPath)
            let resolved = await feed.signedURLs(for: Array(Set(paths)))
            for (index, path) in paths.enumerated() where urls[index] == nil {
                urls[index] = resolved[path]
            }
        }
    }
}
