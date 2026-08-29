import SwiftUI

/// The Year and All-time zoom rungs' rows: one month (Year) or one year (All-time) per row.
/// PR 3 of the zoom redesign, revision 2.
///
/// Both rows take their counts as already-formatted, OPTIONAL strings rather than a
/// `DarkroomMonthSummaryV2` directly: a `nil` count renders the same row, still fully navigable
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
    /// Up to `p_covers` display paths, server order (chronological, see `DarkroomMonthSummaryV2
    /// .coverPaths`'s own doc), `[]` while the summary (or this row's own month within it) hasn't
    /// resolved yet — the loading-state caller passes none, same as it passes `meta: nil`.
    /// Resolved to signed URLs by THIS row's own `.task`, one batched call per row as it scrolls
    /// into view (never per cell, never for the whole rung at once): see `sampleStrip`'s own doc.
    var coverPaths: [String] = []
    /// This row's own frame slot count, derived by `DarkroomView.yearRowCapacity` from the real
    /// available width at the rack's shared 44x59/46pt pitch, never hard-coded here: real covers
    /// fill from the left, whatever's left over past `coverPaths.count` (or past the RPC's own
    /// `p_covers` cap, whichever is smaller) stays unexposed. Defaults to the RPC's own
    /// `p_covers` call site (`DarkroomView.reload`) for previews/tests that don't thread a real
    /// measured width through.
    var capacity: Int = 7
    let onTap: () -> Void

    @Environment(PhotoService.self) private var photoService
    @State private var coverURLs: [String: URL] = [:]
    /// Cover paths whose `CachedImage` has permanently failed (the object no longer exists, most
    /// often a deleted photo). Without this, a 404 read as CachedImage's own built-in retry tile
    /// (a spinning-arrow, tap-to-retry affordance), which forever fails again since the photo is
    /// actually gone, not merely offline. Flipping the slot to the SAME unexposed look every
    /// other unresolved slot already uses reads as "nothing here", not as a broken control.
    @State private var failedPaths: Set<String> = []

    private var monthName: String {
        DarkroomDayUnit.monthNameFormatter.string(from: monthStart)
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

    /// Up to `capacity` covers, left-aligned, and ONLY covers: each renders as a real image once
    /// its signed URL resolves, with the unexposed placeholder while resolving or after a failed
    /// load (no spinner, never a guessed image). See `visibleCoverPaths` for why the strip never
    /// pads empty frames past the covers it actually has. Keyed by the cover PATH itself, never
    /// by index: a path is stable identity, an index is not once `coverPaths` itself changes
    /// between renders.
    ///
    /// Frame size and pitch match the default rack's own (`DarkroomDayUnit.framePitch`/
    /// `frameGap`, 44x59 frames on a 46pt pitch, owner call 2026-08-27: take the reading trade,
    /// a row shows what it fits): this strip is the Year rung's own contact sheet, not a
    /// miniature of it.
    ///
    /// Resolution is THIS row's own job, not `DarkroomView`'s: the `.task(id:)` below fires once
    /// as this specific row scrolls into view (a `LazyVStack` row, mounted/unmounted like any
    /// other), batching every path this row needs into ONE `signedURLs` call — never one call per
    /// cell, and never the whole rung's rows resolved together just because a few of them are on
    /// screen at once. `CachedImage`'s own cache (`cacheKey: path`) means a month already browsed
    /// on either rung costs nothing to redraw here.
    private var sampleStrip: some View {
        HStack(spacing: DarkroomDayUnit.frameGap) {
            ForEach(visibleCoverPaths, id: \.self) { path in
                if !failedPaths.contains(path) {
                    CachedImage(url: coverURLs[path], maxPixel: 120, cacheKey: path, onFailure: {
                        failedPaths.insert(path)
                    }) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        unexposedCell
                    }
                    .frame(width: DarkroomDayUnit.photoFramePitch - DarkroomDayUnit.frameGap,
                            height: DarkroomDayUnit.photoFrameHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(FlimTheme.stroke, lineWidth: 1))
                } else {
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
            .frame(width: DarkroomDayUnit.photoFramePitch - DarkroomDayUnit.frameGap,
                            height: DarkroomDayUnit.photoFrameHeight)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(FlimTheme.stroke, lineWidth: 1))
    }

    /// NO pad slots, unlike the night rack: there an unexposed frame is film that was never
    /// shot, part of the object; here it read as a photo that failed to load (owner report
    /// 2026-08-27, the "empty block"). A month with fewer covers than the row fits just ends,
    /// and a device narrower than the server's 8-cover ask renders the first `capacity` of the
    /// chronological array and never shows the extras.
    private var visibleCoverPaths: [String] {
        Array(coverPaths.prefix(capacity))
    }
}

extension DarkroomYearRow {
    /// The fully-resolved case: every number (and cover) comes straight from the server summary
    /// row.
    init(summary: DarkroomMonthSummaryV2, isAnchor: Bool, accent: Color, capacity: Int = 7, onTap: @escaping () -> Void) {
        self.init(
            monthStart: summary.monthStart,
            isAnchor: isAnchor,
            meta: "\(summary.shotCount) shot\(summary.shotCount == 1 ? "" : "s") · \(summary.nightCount) night\(summary.nightCount == 1 ? "" : "s")",
            hasDeveloping: summary.developingCount > 0,
            accent: accent,
            coverPaths: summary.coverPaths,
            capacity: capacity,
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
    /// The month's `topCoverPath` (the true rank-1 most-reacted photo, see `DarkroomMonthSummaryV2
    /// .topCoverPath`'s own doc), `nil` while the summary hasn't resolved yet (the loading-state
    /// caller passes an always-nil closure, same shape as `monthShotCount`'s `nil`) or when the
    /// server genuinely returned none. Often one of `DarkroomYearRow`'s own strip covers for the
    /// same month (rank-1 is always among the top-N), so browsing one rung frequently warms the
    /// other's cache too, just never guaranteed the way sharing one literal array used to be.
    var monthTopCoverPath: (Int) -> String? = { _ in nil }
    let anchor: DarkroomYearMonth
    let accent: Color
    let onSelectMonth: (DarkroomYearMonth) -> Void

    @Environment(PhotoService.self) private var photoService
    @State private var coverURLs: [String: URL] = [:]
    /// Same reasoning as `DarkroomYearRow.failedPaths`: a permanently-failed cover (a deleted
    /// photo) must read as no cover at all, not as a forever-retrying tile.
    @State private var failedPaths: Set<String> = []

    private static let monthInitials = ["J", "F", "M", "A", "M", "J", "J", "A", "S", "O", "N", "D"]

    /// Every cover path this WHOLE row (one calendar year, up to 12 months, one cover each) needs,
    /// deduplicated and sorted (a `Set`'s own iteration order isn't a contract worth leaning on
    /// for a value that feeds `.task(id:)`'s equality check). Resolved once per row, not once per
    /// month cell: a row scrolling into view bears one batched `signedURLs` call for its entire
    /// year, the same "per row, never per cell, never per rung" rule `DarkroomYearRow.sampleStrip`
    /// follows.
    private var allCoverPaths: [String] {
        Array(Set((1...12).compactMap(monthTopCoverPath))).sorted()
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
                .overlay { monthCover(monthTopCoverPath(month)) }
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

    /// ONE cover image, the full 26x26 cell, drawn OVER the cell's own fill+stroke (never
    /// replacing it): no cover yet — `path` is `nil`, or its signed URL hasn't resolved, or it
    /// permanently failed — stays `Color.clear` and lets that same fill/border show through, the
    /// exact same "no second unexposed look" rule the old 2x2 mosaic this replaced followed
    /// (owner call 2026-08-27: one true rank-1 cover per month reads better than four small,
    /// often-repeated ones). `maxPixel: 120` matches every other cover slot on both rungs, this
    /// cell being no bigger than the strip's own.
    @ViewBuilder
    private func monthCover(_ path: String?) -> some View {
        if let path, !failedPaths.contains(path) {
            CachedImage(url: coverURLs[path], maxPixel: 120, cacheKey: path, onFailure: {
                failedPaths.insert(path)
            }) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.clear
            }
            .frame(width: 26, height: 26)
            .clipShape(RoundedRectangle(cornerRadius: 2))
        } else {
            Color.clear.frame(width: 26, height: 26)
        }
    }

    private func accessibilityLabel(hasPhotos: Bool, count: Int?, month: Int) -> String {
        guard hasPhotos else { return "\(monthName(month)), no photos" }
        guard let count else { return monthName(month) }
        return "\(monthName(month)), \(count) shot\(count == 1 ? "" : "s")"
    }

    private func monthName(_ month: Int) -> String {
        guard let date = Calendar.current.date(from: DateComponents(year: 2000, month: month, day: 1)) else { return "" }
        return DarkroomDayUnit.monthNameFormatter.string(from: date)
    }
}

extension DarkroomAllTimeRow {
    /// The fully-resolved case: every number (and cover) comes straight from the server summary
    /// rows.
    init(totals: DarkroomYearTotals, monthSummaries: [DarkroomMonthSummaryV2], anchor: DarkroomYearMonth, accent: Color, onSelectMonth: @escaping (DarkroomYearMonth) -> Void) {
        let calendar = Calendar.current
        let shotsByMonth = Dictionary(monthSummaries.map { (calendar.component(.month, from: $0.monthStart), $0.shotCount) },
                                       uniquingKeysWith: { first, _ in first })
        // Each month's own `topCoverPath`, the same field (never re-picked here) `DarkroomAllTimeRow
        // .monthTopCoverPath`'s own doc explains: the true rank-1 photo, not a re-derived guess.
        let topCoverByMonth = Dictionary(monthSummaries.map { (calendar.component(.month, from: $0.monthStart), $0.topCoverPath) },
                                          uniquingKeysWith: { first, _ in first })
        self.init(
            year: totals.year,
            headerMeta: "\(DarkroomCountFormat.grouped(totals.shotCount)) shot\(totals.shotCount == 1 ? "" : "s") · \(totals.nightCount) night\(totals.nightCount == 1 ? "" : "s")",
            monthHasPhotos: { (shotsByMonth[$0] ?? 0) > 0 },
            monthShotCount: { shotsByMonth[$0] },
            monthTopCoverPath: { topCoverByMonth[$0] ?? nil },
            anchor: anchor,
            accent: accent,
            onSelectMonth: onSelectMonth
        )
    }
}
