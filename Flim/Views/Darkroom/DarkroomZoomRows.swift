import SwiftUI

/// The Year and All-time zoom rungs' rows: one month (Year) or one year (All-time) per row.
/// PR 3 of the zoom redesign, revision 2.
///
/// Both rows take their counts as already-formatted, OPTIONAL strings rather than a
/// `DarkroomMonthSummary` directly: a `nil` count renders the same row, still fully navigable
/// (tap still lands `.month` on that row), just without a number on it. That's what lets
/// `DarkroomView` reuse these exact rows for its quiet "summary still in flight" treatment
/// (structure derived from whatever's already loaded, counts omitted rather than guessed) and
/// not only for the fully-resolved case.

// MARK: - Year rung: one row per month

struct DarkroomYearRow: View {
    let monthStart: Date
    /// Whether this is the rung's own anchor month: accent name, no other emphasis.
    let isAnchor: Bool
    /// "128 shots · 22 nights", `nil` while the server summary hasn't resolved yet.
    let meta: String?
    let hasDeveloping: Bool
    let accent: Color
    /// Up to `Self.slotCount` display paths, server order, `[]` while the summary (or this row's
    /// own month within it) hasn't resolved yet — the loading-state caller passes none, same as
    /// it passes `meta: nil`. Resolved to signed URLs by THIS row's own `.task`, one batched call
    /// per row as it scrolls into view (never per cell, never for the whole rung at once): see
    /// `sampleStrip`'s own doc.
    var coverPaths: [String] = []
    let onTap: () -> Void

    @Environment(PhotoService.self) private var photoService
    @State private var coverURLs: [String: URL] = [:]
    /// Cover paths whose `CachedImage` has permanently failed (the object no longer exists, most
    /// often a deleted photo). Without this, a 404 read as CachedImage's own built-in retry tile
    /// (a spinning-arrow, tap-to-retry affordance), which forever fails again since the photo is
    /// actually gone, not merely offline. Flipping the slot to the SAME unexposed look every
    /// other unresolved slot already uses reads as "nothing here", not as a broken control.
    @State private var failedPaths: Set<String> = []

    /// The strip's fixed slot count: real covers fill from the left, whatever's left over stays
    /// unexposed. Matches the RPC's own `p_covers` call site (`DarkroomView.reload`).
    static let slotCount = 8

    private var monthName: String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM"
        return formatter.string(from: monthStart)
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(monthName)
                        .flimFont(17, weight: .light)
                        .tracking(0.4)
                        .foregroundStyle(isAnchor ? accent : FlimTheme.textPrimary)
                    Spacer(minLength: 8)
                    if let meta {
                        Text(meta)
                            .flimFont(11.5)
                            .foregroundStyle(FlimTheme.textTertiary)
                    }
                    if hasDeveloping {
                        Capsule().fill(accent).frame(width: 16, height: 2)
                    }
                }
                sampleStrip
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 14)
            .overlay(alignment: .bottom) {
                Rectangle().fill(FlimTheme.stroke.opacity(0.7)).frame(height: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(meta.map { "\(monthName), \($0)" } ?? monthName)
        .accessibilityAddTraits(.isButton)
    }

    /// `Self.slotCount` slots, left-aligned: `coverPaths` fills from the left as either a real
    /// image (once its signed URL resolves) or the unexposed placeholder (while it's still
    /// resolving — no spinner, same look as a slot with no cover at all), and whatever's left
    /// over past `coverPaths.count` stays unexposed permanently, never a guessed image. Keyed by
    /// the cover PATH itself (a pad slot keyed by its own synthetic id), never by index: a path
    /// is stable identity, an index is not once `coverPaths` itself changes between renders.
    ///
    /// Resolution is THIS row's own job, not `DarkroomView`'s: the `.task(id:)` below fires once
    /// as this specific row scrolls into view (a `LazyVStack` row, mounted/unmounted like any
    /// other), batching every path this row needs into ONE `signedURLs` call — never one call per
    /// cell, and never the whole rung's rows resolved together just because a few of them are on
    /// screen at once. `CachedImage`'s own cache (`cacheKey: path`) means a month already browsed
    /// on either rung costs nothing to redraw here.
    private var sampleStrip: some View {
        HStack(spacing: 2) {
            ForEach(coverSlots) { slot in
                switch slot {
                case .cover(let path) where !failedPaths.contains(path):
                    CachedImage(url: coverURLs[path], maxPixel: 120, cacheKey: path, onFailure: {
                        failedPaths.insert(path)
                    }) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        unexposedCell
                    }
                    .frame(width: 26, height: 35)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(FlimTheme.stroke, lineWidth: 1))
                case .cover, .empty:
                    unexposedCell
                }
            }
        }
        .task(id: coverPaths) {
            guard !coverPaths.isEmpty else { return }
            coverURLs = await photoService.signedURLs(for: coverPaths)
        }
        .accessibilityHidden(true)
    }

    private var unexposedCell: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color(white: 0.078))
            .frame(width: 26, height: 35)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(FlimTheme.stroke, lineWidth: 1))
    }

    private enum CoverSlot: Identifiable {
        case cover(String)
        case empty(Int)
        var id: String {
            switch self {
            case .cover(let path): return path
            case .empty(let index): return "empty-\(index)"
            }
        }
    }

    private var coverSlots: [CoverSlot] {
        let real = coverPaths.prefix(Self.slotCount).map(CoverSlot.cover)
        let padCount = Self.slotCount - real.count
        guard padCount > 0 else { return Array(real) }
        return real + (0..<padCount).map(CoverSlot.empty)
    }
}

extension DarkroomYearRow {
    /// The fully-resolved case: every number (and cover) comes straight from the server summary
    /// row.
    init(summary: DarkroomMonthSummary, isAnchor: Bool, accent: Color, onTap: @escaping () -> Void) {
        self.init(
            monthStart: summary.monthStart,
            isAnchor: isAnchor,
            meta: "\(summary.shotCount) shot\(summary.shotCount == 1 ? "" : "s") · \(summary.nightCount) night\(summary.nightCount == 1 ? "" : "s")",
            hasDeveloping: summary.developingCount > 0,
            accent: accent,
            coverPaths: summary.coverPaths,
            onTap: onTap
        )
    }
}

// MARK: - All-time rung: one row per year

struct DarkroomAllTimeRow: View {
    let year: Int
    /// "1,042 shots · 88 nights", `nil` while the server summary hasn't resolved yet.
    let headerMeta: String?
    /// Whether a given 1...12 month number has at least one kept photo: drives the cell's
    /// tappability and border/label emphasis. Backed by the server summary once it resolves, or —
    /// while it hasn't — by whatever's already loaded (a real, counted fact about what's on
    /// screen, not a guess: see `DarkroomView.loadedYearMonths`'s own doc).
    let monthHasPhotos: (Int) -> Bool
    /// The month's exact shot count, ONLY for the accessibility label's detail. `nil` omits it
    /// (never a guessed number): the loading-state caller passes `nil` for every month even where
    /// `monthHasPhotos` reads `true`, since "present" and "how many" are two different facts and
    /// only the first is known before the summary resolves.
    let monthShotCount: (Int) -> Int?
    /// The FIRST 4 of the SAME `coverPaths` `DarkroomYearRow`'s own strip shows for that month,
    /// never a separately-chosen set: sharing paths (not just sharing the RPC row) is what makes
    /// a month already browsed on the Year rung a cache hit here, and vice versa. `[]` while the
    /// summary hasn't resolved yet (the loading-state caller passes an always-empty closure, same
    /// shape as `monthShotCount`'s `nil`).
    var monthCoverPaths: (Int) -> [String] = { _ in [] }
    let anchor: DarkroomYearMonth
    let accent: Color
    let onSelectMonth: (DarkroomYearMonth) -> Void

    @Environment(PhotoService.self) private var photoService
    @State private var coverURLs: [String: URL] = [:]
    /// Same reasoning as `DarkroomYearRow.failedPaths`: a permanently-failed cover (a deleted
    /// photo) must read as no cover at all, not as a forever-retrying tile.
    @State private var failedPaths: Set<String> = []

    private static let monthInitials = ["J", "F", "M", "A", "M", "J", "J", "A", "S", "O", "N", "D"]

    /// Every cover path this WHOLE row (one calendar year, up to 12 months × 4 covers) needs,
    /// deduplicated and sorted (a `Set`'s own iteration order isn't a contract worth leaning on
    /// for a value that feeds `.task(id:)`'s equality check). Resolved once per row, not once per
    /// month cell: a row scrolling into view bears one batched `signedURLs` call for its entire
    /// year, the same "per row, never per cell, never per rung" rule `DarkroomYearRow.sampleStrip`
    /// follows.
    private var allCoverPaths: [String] {
        Array(Set((1...12).flatMap(monthCoverPaths))).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(year))
                    .flimFont(26, weight: .ultraLight)
                    .tracking(1)
                    .foregroundStyle(FlimTheme.textPrimary)
                if let headerMeta {
                    Text(headerMeta)
                        .flimFont(12)
                        .foregroundStyle(FlimTheme.textTertiary)
                }
            }
            monthGrid
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 18)
        .overlay(alignment: .bottom) {
            Rectangle().fill(FlimTheme.stroke.opacity(0.7)).frame(height: 1)
        }
        .task(id: allCoverPaths) {
            guard !allCoverPaths.isEmpty else { return }
            coverURLs = await photoService.signedURLs(for: allCoverPaths)
        }
    }

    private var monthGrid: some View {
        HStack(spacing: 3) {
            ForEach(1...12, id: \.self) { month in
                monthCell(month)
            }
        }
    }

    @ViewBuilder
    private func monthCell(_ month: Int) -> some View {
        let hasPhotos = monthHasPhotos(month)
        let count = monthShotCount(month)
        let ym = DarkroomYearMonth(year: year, month: month)
        let isAnchor = ym == anchor

        VStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(white: 0.078))
                .frame(width: 26, height: 26)
                .overlay { monthMosaic(covers: monthCoverPaths(month)) }
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(isAnchor ? accent.opacity(0.65) : FlimTheme.stroke.opacity(0.9), lineWidth: 1)
                )
            Text(Self.monthInitials[month - 1])
                .flimFont(8)
                .tracking(0.3)
                .foregroundStyle(isAnchor ? accent : Color(white: 0.36))
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            guard hasPhotos else { return }
            onSelectMonth(ym)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(hasPhotos: hasPhotos, count: count, month: month))
        .accessibilityAddTraits(hasPhotos ? .isButton : [])
    }

    /// A 2x2 mosaic of up to the first 4 of `covers`, 0.5pt gutters, drawn OVER the cell's own
    /// fill+stroke (never replacing it): a slot with no cover yet — none exists, or its signed
    /// URL hasn't resolved — stays `Color.clear` and lets that same fill/border show through, so
    /// there is never a second "unexposed" look to keep in sync with `DarkroomYearRow`'s. Fixed
    /// 2x2 positions, not a `ForEach`: four hard-coded slots have no list-diffing identity concern
    /// to get wrong the way a dynamically-ordered collection would.
    private func monthMosaic(covers: [String]) -> some View {
        let tile: CGFloat = (26 - 0.5) / 2
        return VStack(spacing: 0.5) {
            HStack(spacing: 0.5) {
                mosaicTile(covers, index: 0, size: tile)
                mosaicTile(covers, index: 1, size: tile)
            }
            HStack(spacing: 0.5) {
                mosaicTile(covers, index: 2, size: tile)
                mosaicTile(covers, index: 3, size: tile)
            }
        }
        .frame(width: 26, height: 26)
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }

    @ViewBuilder
    private func mosaicTile(_ covers: [String], index: Int, size: CGFloat) -> some View {
        // A permanently-failed cover renders exactly like an absent one (`Color.clear` over the
        // cell's own fill+stroke, see `monthMosaic`'s own doc for why there is no second
        // "unexposed" look here to keep in sync with) rather than CachedImage's built-in
        // tap-to-retry tile, which would never succeed for a photo that's actually gone.
        if index < covers.count, !failedPaths.contains(covers[index]) {
            let path = covers[index]
            CachedImage(url: coverURLs[path], maxPixel: 120, cacheKey: path, onFailure: {
                failedPaths.insert(path)
            }) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.clear
            }
            .frame(width: size, height: size)
        } else {
            Color.clear.frame(width: size, height: size)
        }
    }

    private func accessibilityLabel(hasPhotos: Bool, count: Int?, month: Int) -> String {
        guard hasPhotos else { return "\(monthName(month)), no photos" }
        guard let count else { return monthName(month) }
        return "\(monthName(month)), \(count) shot\(count == 1 ? "" : "s")"
    }

    private func monthName(_ month: Int) -> String {
        let calendar = Calendar.current
        guard let date = calendar.date(from: DateComponents(year: 2000, month: month, day: 1)) else { return "" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM"
        return formatter.string(from: date)
    }
}

extension DarkroomAllTimeRow {
    /// The fully-resolved case: every number (and cover) comes straight from the server summary
    /// rows.
    init(totals: DarkroomYearTotals, monthSummaries: [DarkroomMonthSummary], anchor: DarkroomYearMonth, accent: Color, onSelectMonth: @escaping (DarkroomYearMonth) -> Void) {
        let calendar = Calendar.current
        let shotsByMonth = Dictionary(monthSummaries.map { (calendar.component(.month, from: $0.monthStart), $0.shotCount) },
                                       uniquingKeysWith: { first, _ in first })
        // The FIRST 4 of each month's own `coverPaths`, the same array (and the same order)
        // `DarkroomYearRow`'s strip draws from for that month — never re-picked here, so the two
        // rungs share cache hits rather than each minting their own signed URLs for what could
        // otherwise be a different-looking, separately-chosen set.
        let coversByMonth = Dictionary(monthSummaries.map { (calendar.component(.month, from: $0.monthStart), Array($0.coverPaths.prefix(4))) },
                                        uniquingKeysWith: { first, _ in first })
        self.init(
            year: totals.year,
            headerMeta: "\(DarkroomCountFormat.grouped(totals.shotCount)) shot\(totals.shotCount == 1 ? "" : "s") · \(totals.nightCount) night\(totals.nightCount == 1 ? "" : "s")",
            monthHasPhotos: { (shotsByMonth[$0] ?? 0) > 0 },
            monthShotCount: { shotsByMonth[$0] },
            monthCoverPaths: { coversByMonth[$0] ?? [] },
            anchor: anchor,
            accent: accent,
            onSelectMonth: onSelectMonth
        )
    }
}
