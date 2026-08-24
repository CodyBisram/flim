import SwiftUI

/// The Darkroom month band's tap target: a bottom sheet that jumps the scroller to any month,
/// grouped by year. Split out of `DarkroomView.swift` for the same reason `DarkroomRackView.swift`
/// was: this owns its own layout and its own pure cell-derivation logic, not the screen's state.

// MARK: - Cell state (pure)

/// What one month cell in the grid shows and whether it's tappable.
enum DarkroomMonthCellState: Equatable {
    /// Has at least one photo. `count` is the server's number, or `nil` when the RPC hasn't
    /// answered yet (pre-migration): the month is still reachable, just without a number on it.
    case enabled(count: Int?)
    /// Confirmed zero photos (past or current month). Dimmed, inert.
    case empty
    /// A future month of the current year. Dimmed, inert, reads as a plain hyphen.
    case future
}

/// One cell of the jump sheet's 4x12 grid.
struct DarkroomMonthCell: Identifiable, Equatable {
    /// 1...12.
    let month: Int
    let state: DarkroomMonthCellState
    /// Whether this cell is the current calendar month, which draws an accent ring regardless of
    /// `state` (a current month with nothing shot yet is still `.empty`, but still gets the ring).
    let isCurrentMonth: Bool

    var id: Int { month }

    var isEnabled: Bool {
        if case .enabled = state { return true }
        return false
    }

    /// The small second line under the month abbreviation: the count when known, a plain hyphen
    /// for a future month, or nothing at all (never a derived or zero count).
    var secondaryLabel: String {
        switch state {
        case .enabled(let count): return count.map(String.init) ?? ""
        case .empty: return ""
        case .future: return "-"
        }
    }
}

/// Pure derivation behind the jump sheet, kept free of any view code so both can be pinned by
/// tests without a live RPC or a rendered sheet.
enum DarkroomJumpSheetLogic {
    /// Every year the header's tab row should offer, newest first: from the oldest month with
    /// data through the current year.
    ///
    /// When the RPC hasn't answered (`rpcRows == nil`, the pre-migration state), the oldest year
    /// falls back to whatever's already loaded in the list rather than to the current year alone
    /// — a screen that has already scrolled back a year would otherwise offer a tab row that
    /// can't reach the very months on screen behind it.
    static func availableYears(
        rpcRows: [DarkroomMonthCount]?,
        loadedMonths: Set<DarkroomYearMonth>,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [Int] {
        let currentYear = calendar.component(.year, from: now)
        let years: [Int]
        if let rpcRows, !rpcRows.isEmpty {
            years = rpcRows.map { $0.yearMonth.year }
        } else {
            years = loadedMonths.map(\.year)
        }
        let oldest = years.min() ?? currentYear
        guard oldest <= currentYear else { return [currentYear] }
        return Array(stride(from: currentYear, through: oldest, by: -1))
    }

    /// The selected year's 12 grid cells.
    ///
    /// `rpcRows == nil` (pre-migration) degrades to: a month is `.enabled` (no count shown) only
    /// if it's already loaded in the list, everything else `.empty`. This is the rule that must
    /// never regress to "everything empty when the RPC hasn't answered": that would make a
    /// freshly-scrolled screen's own visible months look unreachable in the very sheet meant to
    /// navigate them. A live-looking cell always lands somewhere.
    static func monthCells(
        year: Int,
        rpcRows: [DarkroomMonthCount]?,
        loadedMonths: Set<DarkroomYearMonth>,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [DarkroomMonthCell] {
        let current = DarkroomYearMonth(date: now, calendar: calendar)
        return (1...12).map { month in
            let ym = DarkroomYearMonth(year: year, month: month)
            let isFuture = year > current.year || (year == current.year && month > current.month)

            let state: DarkroomMonthCellState
            if isFuture {
                state = .future
            } else if let rpcRows {
                let count = rpcRows.photoCount(for: ym) ?? 0
                state = count > 0 ? .enabled(count: count) : .empty
            } else {
                state = loadedMonths.contains(ym) ? .enabled(count: nil) : .empty
            }
            return DarkroomMonthCell(month: month, state: state, isCurrentMonth: ym == current)
        }
    }

    /// Fixed `en_US_POSIX` `MMM` abbreviation for a 1...12 month number, independent of the
    /// device locale, matching every other date format this screen already hand-fixes
    /// (`DarkroomDayUnit.dayFormatter`, `DarkroomMonthGroup.title`).
    static func monthAbbreviation(_ month: Int, calendar: Calendar = .current) -> String {
        guard let date = calendar.date(from: DateComponents(year: 2000, month: month, day: 1)) else { return "" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM"
        return formatter.string(from: date)
    }

    /// Full month name, for the cell's accessibility label.
    static func monthName(_ month: Int, calendar: Calendar = .current) -> String {
        guard let date = calendar.date(from: DateComponents(year: 2000, month: month, day: 1)) else { return "" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM"
        return formatter.string(from: date)
    }
}

// MARK: - View

struct DarkroomJumpSheet: View {
    @Environment(\.flimAccent) private var accent
    let monthCounts: [DarkroomMonthCount]?
    let loadedMonths: Set<DarkroomYearMonth>
    /// (year, month) of the tapped, enabled cell. The caller dismisses and scrolls; this view
    /// never touches the list itself.
    let onSelect: (Int, Int) -> Void

    @State private var selectedYear: Int

    init(monthCounts: [DarkroomMonthCount]?, loadedMonths: Set<DarkroomYearMonth>, onSelect: @escaping (Int, Int) -> Void) {
        self.monthCounts = monthCounts
        self.loadedMonths = loadedMonths
        self.onSelect = onSelect
        _selectedYear = State(initialValue: Calendar.current.component(.year, from: .now))
    }

    private var years: [Int] {
        DarkroomJumpSheetLogic.availableYears(rpcRows: monthCounts, loadedMonths: loadedMonths)
    }

    private var cells: [DarkroomMonthCell] {
        DarkroomJumpSheetLogic.monthCells(year: selectedYear, rpcRows: monthCounts, loadedMonths: loadedMonths)
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(cells) { cell in cellView(cell) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 24)
        .presentationDetents([.height(340)])
        .presentationDragIndicator(.visible)
        .flimSheetSurface()
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Jump to")
                .flimFont(13)
                .foregroundStyle(FlimTheme.textTertiary)
            Spacer(minLength: 8)
            // A horizontal scroller, not a bare HStack: FLIM's own history is short today, but a
            // year row that keeps growing every January must not silently clip against the
            // sheet's fixed width.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(years, id: \.self) { year in
                        Button {
                            Haptics.tap()
                            withAnimation(.snappy(duration: 0.2)) { selectedYear = year }
                        } label: {
                            Text(String(year))
                                .flimFont(13, weight: year == selectedYear ? .semibold : .regular)
                                .foregroundStyle(year == selectedYear ? accent : FlimTheme.textTertiary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(year == selectedYear ? accent.opacity(0.14) : .clear))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cellView(_ cell: DarkroomMonthCell) -> some View {
        Button {
            guard cell.isEnabled else { return }
            Haptics.tap()
            onSelect(selectedYear, cell.month)
        } label: {
            VStack(spacing: 3) {
                Text(DarkroomJumpSheetLogic.monthAbbreviation(cell.month))
                    .flimFont(13.5, weight: .medium)
                    .foregroundStyle(FlimTheme.textPrimary)
                Text(cell.secondaryLabel)
                    .flimFont(10.5)
                    .foregroundStyle(FlimTheme.textTertiary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                if cell.isCurrentMonth {
                    RoundedRectangle(cornerRadius: 9).inset(by: 1).stroke(accent, lineWidth: 1.5)
                }
            }
            .opacity(cell.isEnabled ? 1 : 0.3)
        }
        .buttonStyle(.plain)
        .disabled(!cell.isEnabled)
        .accessibilityLabel(accessibilityLabel(for: cell))
    }

    private func accessibilityLabel(for cell: DarkroomMonthCell) -> String {
        let name = DarkroomJumpSheetLogic.monthName(cell.month)
        switch cell.state {
        case .enabled(let count):
            guard let count else { return name }
            return "\(name), \(count) shot\(count == 1 ? "" : "s")"
        case .empty: return "\(name), no photos"
        case .future: return "\(name), not yet"
        }
    }
}
