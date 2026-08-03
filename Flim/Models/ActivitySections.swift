import Foundation

/// Where an activity row sits in the Activity screen's time grouping.
///
/// Ordered newest-bucket-first, which is the order they're shown in.
enum ActivitySection: Int, CaseIterable, Identifiable {
    case new, today, yesterday, thisWeek, thisMonth, earlier

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .new:       return "New"
        case .today:     return "Today"
        case .yesterday: return "Yesterday"
        case .thisWeek:  return "This Week"
        case .thisMonth: return "This Month"
        case .earlier:   return "Earlier"
        }
    }
}

/// Buckets one activity date.
///
/// Deliberately CALENDAR-DAY based, not rolling hours: something from 11pm last night belongs in
/// "Yesterday" at 1am, not in "Today" because it happened within 24 hours. That's what a date
/// header means to a reader.
///
/// `seenBefore` is when the user last opened Activity, BEFORE this visit stamped it. Anything
/// newer than that is "New" regardless of its date, so the things you haven't looked at sit at the
/// top even if they arrived yesterday. Pass nil to disable the New section.
func activitySection(
    for date: Date,
    seenBefore: Date?,
    now: Date = .now,
    calendar: Calendar = .current
) -> ActivitySection {
    if let seenBefore, date > seenBefore { return .new }

    let startOfDate = calendar.startOfDay(for: date)
    let startOfNow = calendar.startOfDay(for: now)
    let days = calendar.dateComponents([.day], from: startOfDate, to: startOfNow).day ?? 0

    switch days {
    case ..<1:   return .today        // includes a future date from clock skew
    case 1:      return .yesterday
    case 2...6:  return .thisWeek
    case 7...29: return .thisMonth
    default:     return .earlier
    }
}

/// Groups activity into ordered, non-empty sections, preserving the input order within each.
///
/// Generic over the element so the grouping rule can be tested with plain dates, without standing
/// up an ActivityItem (which needs profiles, posts and a kind).
func groupedActivity<T>(
    _ items: [T],
    date: (T) -> Date,
    seenBefore: Date?,
    now: Date = .now,
    calendar: Calendar = .current
) -> [(section: ActivitySection, items: [T])] {
    var buckets: [ActivitySection: [T]] = [:]
    for item in items {
        let section = activitySection(for: date(item), seenBefore: seenBefore, now: now, calendar: calendar)
        buckets[section, default: []].append(item)
    }
    return ActivitySection.allCases.compactMap { section in
        guard let group = buckets[section], !group.isEmpty else { return nil }
        return (section, group)
    }
}
