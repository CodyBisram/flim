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
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(shotCount.map { "\(monthName), \($0) shots" } ?? monthName)
        .accessibilityAddTraits(.isButton)
    }
}

/// The `.month` rung for an anchor month with nothing in it: "Nothing left in October." and, when
/// an older month is known, the closing row into it.
///
/// The two have separate places. The closing row used to sit 8pt under the sentence, inside the
/// same centered stack, so the next month read as a caption of the empty message (owner report,
/// build 424). The sentence now owns the open space; the closing row is the way into the next
/// section, so it is laid out as a heading of one.
struct DarkroomEmptyMonthView: View {
    @Environment(\.flimAccent) private var accent
    /// The anchor month's full name, as prose ("October").
    let monthName: String
    /// The next-older month and its count, `nil` when none is known.
    let next: (month: DarkroomYearMonth, shotCount: Int?)?
    let onSelectNext: (DarkroomYearMonth) -> Void

    var body: some View {
        // Scrolls only when it has to (the largest accessibility sizes), and otherwise fills the
        // rung exactly, so the spacers below can place things against the real height.
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 24)
                    message
                    if let next {
                        // A clear gap, then the next month as a heading of the same kind as
                        // the month crumb above: its name, its count, the same hairline under
                        // it. Pinning it above the tab bar instead was tried (2026-10-01): on
                        // iOS 26 it crowds the floating tab bar and reads as part of it.
                        Color.clear.frame(height: 56)
                        closingRow(next)
                    }
                    Spacer(minLength: 24)
                }
                .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var message: some View {
        VStack(spacing: 10) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 28, weight: .ultraLight))
                .foregroundStyle(accent.opacity(0.5))
                .accessibilityHidden(true)
            Text("Nothing left in \(monthName).")
                .flimFont(14, weight: .light)
                .foregroundStyle(FlimTheme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
    }

    @ViewBuilder
    private func closingRow(_ next: (month: DarkroomYearMonth, shotCount: Int?)) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            DarkroomMonthClosingRow(month: next.month, shotCount: next.shotCount) {
                onSelectNext(next.month)
            }
            DarkroomHeaderRule()
        }
    }
}
