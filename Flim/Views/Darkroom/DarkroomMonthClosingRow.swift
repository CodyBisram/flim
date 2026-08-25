import SwiftUI

/// The row at the end of an anchor month's own night list (PR 5 of the zoom redesign, revision
/// 2): only ever shown once within-month pagination has genuinely STOPPED (see
/// `DarkroomView.monthPagingActive`'s own doc — never while a page may still arrive, or this
/// would flash under the real next night and disappear). Tapping it is the same anchored jump a
/// Year-row or All-time-cell tap makes: the anchor updates, the crumb changes, and the scroll
/// restarts at the new month's own top.
///
/// Copy is structural only (a month name and a count), never a new sentence: this is chrome, not
/// a message.
struct DarkroomMonthClosingRow: View {
    /// The next-older month this row jumps to.
    let month: DarkroomYearMonth
    /// The month's exact shot count, `nil` when it isn't known yet (the fallback derived this
    /// row from loaded spillover alone, before the server summary resolved) — omitted entirely
    /// rather than guessed, see `DarkroomMonthPaging.nextOlderMonth`'s own doc.
    let shotCount: Int?
    let onTap: () -> Void

    private var monthName: String {
        let calendar = Calendar.current
        guard let date = calendar.date(from: DateComponents(year: month.year, month: month.month, day: 1)) else { return "" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM"
        return formatter.string(from: date).uppercased()
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Text(monthName)
                    .flimFont(12, weight: .semibold)
                    .tracking(1.1)
                    .foregroundStyle(FlimTheme.textSecondary)
                if let shotCount {
                    Text("· \(shotCount) shot\(shotCount == 1 ? "" : "s")")
                        .flimFont(11.5)
                        .foregroundStyle(FlimTheme.textTertiary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FlimTheme.textTertiary)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(shotCount.map { "\(monthName), \($0) shots" } ?? monthName)
        .accessibilityAddTraits(.isButton)
    }
}
