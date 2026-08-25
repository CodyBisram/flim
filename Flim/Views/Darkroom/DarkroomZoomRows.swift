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
    let onTap: () -> Void

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

    /// Unexposed placeholder frames this PR: no images, no signed URLs. The covers client lands
    /// in PR 6, reading `DarkroomMonthSummary.coverPaths`.
    private var sampleStrip: some View {
        HStack(spacing: 2) {
            ForEach(0..<8, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(white: 0.078))
                    .frame(width: 26, height: 35)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(FlimTheme.stroke, lineWidth: 1))
            }
        }
        .accessibilityHidden(true)
    }
}

extension DarkroomYearRow {
    /// The fully-resolved case: every number comes straight from the server summary row.
    init(summary: DarkroomMonthSummary, isAnchor: Bool, accent: Color, onTap: @escaping () -> Void) {
        self.init(
            monthStart: summary.monthStart,
            isAnchor: isAnchor,
            meta: "\(summary.shotCount) shot\(summary.shotCount == 1 ? "" : "s") · \(summary.nightCount) night\(summary.nightCount == 1 ? "" : "s")",
            hasDeveloping: summary.developingCount > 0,
            accent: accent,
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
    let anchor: DarkroomYearMonth
    let accent: Color
    let onSelectMonth: (DarkroomYearMonth) -> Void

    private static let monthInitials = ["J", "F", "M", "A", "M", "J", "J", "A", "S", "O", "N", "D"]

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
    /// The fully-resolved case: every number comes straight from the server summary rows.
    init(totals: DarkroomYearTotals, monthSummaries: [DarkroomMonthSummary], anchor: DarkroomYearMonth, accent: Color, onSelectMonth: @escaping (DarkroomYearMonth) -> Void) {
        let calendar = Calendar.current
        let shotsByMonth = Dictionary(monthSummaries.map { (calendar.component(.month, from: $0.monthStart), $0.shotCount) },
                                       uniquingKeysWith: { first, _ in first })
        self.init(
            year: totals.year,
            headerMeta: "\(DarkroomCountFormat.grouped(totals.shotCount)) shot\(totals.shotCount == 1 ? "" : "s") · \(totals.nightCount) night\(totals.nightCount == 1 ? "" : "s")",
            monthHasPhotos: { (shotsByMonth[$0] ?? 0) > 0 },
            monthShotCount: { shotsByMonth[$0] },
            anchor: anchor,
            accent: accent,
            onSelectMonth: onSelectMonth
        )
    }
}
