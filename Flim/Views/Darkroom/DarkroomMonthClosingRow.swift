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
    /// "SEPTEMBER 2026" rather than "SEPTEMBER": the empty month's row stands as a heading
    /// directly under the zoom bar's own "OCTOBER 2026", so it is written the same way. The row
    /// at the end of a month's nights keeps the bare name.
    var includesYear = false

    private var monthName: String {
        if includesYear { return DarkroomZoomChrome.crumb(zoom: .month, anchor: month) }
        let calendar = Calendar.current
        guard let date = calendar.date(from: DateComponents(year: month.year, month: month.month, day: 1)) else { return "" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM"
        return formatter.string(from: date).uppercased()
    }

    private var nameText: some View {
        Text(monthName)
            .flimFont(12, weight: .semibold)
            .tracking(1.1)
            .foregroundStyle(FlimTheme.textSecondary)
    }

    /// The count, led by the separator dot only when it sits beside the name.
    @ViewBuilder
    private func countText(inline: Bool) -> some View {
        if let shotCount {
            Text((inline ? "· " : "") + "\(shotCount) shot\(shotCount == 1 ? "" : "s")")
                .flimFont(11.5)
                .foregroundStyle(FlimTheme.textTertiary)
        }
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 0) {
                // On one line like the zoom bar's crumb, and the count under the name when the
                // two no longer fit (the accessibility sizes), rather than the name breaking.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        nameText
                        countText(inline: true)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        nameText
                        countText(inline: false)
                    }
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
        .accessibilityLabel(shotCount.map { "\(monthName), \($0) shot\($0 == 1 ? "" : "s")" } ?? monthName)
        .accessibilityAddTraits(.isButton)
    }
}

/// The `.month` rung for an anchor month with nothing in it: "Nothing left in October." and, when
/// an older month is known, the closing row into it.
///
/// Laid out as the top of a list, not a centered message: the sentence is the month's one line,
/// directly under the zoom bar at its leading edge, and the next month follows as the next
/// section, a heading written and ruled exactly like the zoom bar's own. Whatever height is left
/// is simply the end of the page. Two earlier layouts were rejected on device: the closing row
/// 8pt under a centered sentence read as its caption (build 424), and the sentence centered in
/// the whole rung with the row 56pt below it floated mid-screen (build 425). Pinning the row
/// above the tab bar was tried too (2026-10-01): on iOS 26 it crowds the floating tab bar and
/// reads as part of it.
struct DarkroomEmptyMonthView: View {
    @Environment(\.flimAccent) private var accent
    /// The anchor month's full name, as prose ("October").
    let monthName: String
    /// The next-older month and its count, `nil` when none is known.
    let next: (month: DarkroomYearMonth, shotCount: Int?)?
    let onSelectNext: (DarkroomYearMonth) -> Void
    /// Pull to refresh, like every other state of the rung: after sorting on another device, the
    /// empty month is otherwise a dead end until the tab is left and reopened.
    var onRefresh: (() async -> Void)? = nil
    @ScaledMetric(relativeTo: .body) private var sectionGap: CGFloat = 8

    var body: some View {
        // Scrolls only when it has to (the largest accessibility sizes); the content always
        // starts at the top, whatever height the rung is given.
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                message
                    .padding(.top, 16)
                if let next {
                    // The row's own 44pt hit area centers its text, so this gap plus that
                    // inset puts about 28pt between the sentence and the next heading. Scaled,
                    // because at the accessibility sizes the text outgrows the 44pt and the
                    // inset is gone.
                    Color.clear.frame(height: sectionGap)
                    closingRow(next)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 24)
        }
        // Always bounces when it can refresh: a pull needs the drag even when nothing overflows.
        .scrollBounceBehavior(onRefresh == nil ? .basedOnSize : .always)
        .refreshableToCompletion { await onRefresh?() }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var message: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            // Scales with the sentence it leads, so the pair keeps its proportions at every
            // text size.
            Image(systemName: "camera.aperture")
                .flimFont(13, weight: .light)
                .foregroundStyle(accent.opacity(0.6))
                .accessibilityHidden(true)
            Text("Nothing left in \(monthName).")
                .flimFont(14, weight: .light)
                .foregroundStyle(FlimTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func closingRow(_ next: (month: DarkroomYearMonth, shotCount: Int?)) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            DarkroomMonthClosingRow(month: next.month, shotCount: next.shotCount,
                                    onTap: { onSelectNext(next.month) }, includesYear: true)
            DarkroomHeaderRule()
        }
    }
}
