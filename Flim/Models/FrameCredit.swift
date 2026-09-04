import Foundation

/// The time half of a deck credit line ("N of M · 8:14 PM"), shared by `RollRevealView`'s paging
/// strip and `PhotoPagerView`'s roll footer.
///
/// A burst of frames a second or two apart all round to the same displayed minute, so with plain
/// `.shortened` time (no seconds) fifteen burst shots in a row all read "8:14 PM": indistinguishable,
/// and easy to mistake for the deck somehow duplicating one photo. The fix isn't a duration
/// threshold, it's relative to the deck itself: show seconds only for a frame whose *neighbor*
/// (the shot immediately before or after it in the deck) displays the same minute, so an isolated
/// shot, the ordinary case of one photo every few minutes, still reads as the plain "8:14 PM".
enum FrameCredit {
    /// The credit line's time label for the frame at `index`, given every frame's capture time in
    /// deck order (`takenAt`, same order/count as the deck itself). Out-of-range `index` falls
    /// back to plain minute-only formatting of `date` rather than trapping, since a caller that
    /// mis-tracks an index should still get a displayable (if imprecise) label.
    static func timeLabel(for date: Date, index: Int, in takenAt: [Date],
                           calendar: Calendar = .current,
                           locale: Locale = .autoupdatingCurrent) -> String {
        let showsSeconds = takenAt.indices.contains(index)
            && sharesDisplayedMinuteWithNeighbor(index: index, in: takenAt, calendar: calendar)
        return format(date, showsSeconds: showsSeconds, calendar: calendar, locale: locale)
    }

    /// Whether the frame at `index` shares its displayed (year/month/day/hour/minute) minute with
    /// the frame immediately before or after it in the deck. Only adjacent frames are checked,
    /// deliberately: two shots twelve minutes apart that happen to share a neighbor three frames
    /// away isn't the ambiguity this is solving.
    private static func sharesDisplayedMinuteWithNeighbor(index: Int, in takenAt: [Date],
                                                            calendar: Calendar) -> Bool {
        func minuteKey(_ date: Date) -> DateComponents {
            calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        }
        let mine = minuteKey(takenAt[index])
        if index > 0, minuteKey(takenAt[index - 1]) == mine { return true }
        if index + 1 < takenAt.count, minuteKey(takenAt[index + 1]) == mine { return true }
        return false
    }

    private static func format(_ date: Date, showsSeconds: Bool, calendar: Calendar,
                                locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(showsSeconds ? "hmmssa" : "hmma")
        return formatter.string(from: date)
    }
}
