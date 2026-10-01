import Foundation

/// PR 5 of the zoom redesign, revision 2: the pure rules behind month-scoped pagination stopping
/// and the closing row's next-older-month derivation. Kept free of SwiftUI, the same reasoning as
/// `DarkroomZoom.swift`, so both are directly testable without a live screen.
enum DarkroomMonthPaging {
    /// Whether within-month pagination should still be trying for another page while anchored on
    /// `anchor`: true only while the SERVER still has more (`hasMore`) AND the oldest photo
    /// loaded so far is still within `anchor`'s own month. `oldestLoadedMonth` is `nil` before
    /// anything has loaded at all, which is never itself a stop condition on its own — only
    /// `hasMore` decides that case.
    ///
    /// Once a fetched page's oldest photo crosses the month edge, it becomes SPILLOVER (see
    /// `DarkroomView.monthContent`'s own doc): further within-month pagination has nothing left
    /// to gain from continuing, and `DarkroomView`'s `loadMoreSentinel` and its geometry backstop
    /// both read this SAME property so neither can keep firing after the other has already
    /// stopped — two independent stop checks that could disagree would let one of them keep
    /// paging forever past the month it's supposed to stop at.
    static func shouldContinuePaging(oldestLoadedMonth: DarkroomYearMonth?, anchor: DarkroomYearMonth, hasMore: Bool) -> Bool {
        guard hasMore else { return false }
        guard let oldestLoadedMonth else { return true }
        return oldestLoadedMonth == anchor
    }

    /// The closing row's next-older-month target and its shot count, or `nil` when NEITHER
    /// source knows of anything older than `anchor` — the row is then omitted entirely, never a
    /// guessed one.
    ///
    /// Prefers the server summary once it has resolved: the NEWEST month strictly older than
    /// `anchor` with at least one kept photo, its exact `shotCount` alongside it. Falls back to
    /// the closest older month among whatever's already loaded (`spilloverMonths`, the older-
    /// month rows a page boundary already dragged in, see `DarkroomView.monthContent`'s own doc)
    /// only while the summary hasn't resolved yet or is unreachable — with `shotCount` always
    /// `nil` in that case: spillover only proves a month EXISTS, never how many shots are in it,
    /// and a count must never be guessed (see the closing row's own doc for the exact copy).
    static func nextOlderMonth(
        anchor: DarkroomYearMonth,
        summaries: [DarkroomMonthSummaryV2]?,
        spilloverMonths: [DarkroomYearMonth]
    ) -> (month: DarkroomYearMonth, shotCount: Int?)? {
        if let summaries {
            let older = summaries
                .filter { $0.yearMonth < anchor && $0.shotCount > 0 }
                .max { $0.monthStart < $1.monthStart }
            return older.map { (month: $0.yearMonth, shotCount: $0.shotCount) }
        }
        guard let closest = spilloverMonths.filter({ $0 < anchor }).max() else { return nil }
        return (month: closest, shotCount: nil)
    }
}

/// How the latest fetch FOR the anchor month, in the current load generation, ended. Recorded by
/// `DarkroomView` against the anchor the fetch was for, and only read back while that anchor and
/// generation are still current.
enum DarkroomAnchorFetchOutcome: Equatable {
    /// Applied, and at least one night in the result belongs to the anchor month.
    case landedWithRows
    /// Applied, and nothing in the result belongs to the anchor month: the server's own rows say
    /// the month has nothing visible in it right now (every shot deleted since the summary was
    /// read, or still hidden by a pending delete).
    case landedEmpty
    /// The request failed (offline, a server error).
    case failed
    /// Cancelled, superseded by a newer fetch, or refused as a stale jump: it never applied.
    case interrupted
}

/// What the `.month` rung's body shows for its anchor. See `DarkroomMonthBodyRule.decide`.
enum DarkroomMonthBody: Equatable {
    /// The anchor month's own nights.
    case content
    /// The loading skeleton: a fetch that can still bring the month's rows is running.
    case skeleton
    /// "Nothing left in <month>.", the scoped empty state (or, for a library with nothing in it
    /// at all, the first-run empty state).
    case scopedEmpty
    /// `ErrorState`, with retry.
    case error
    /// The skeleton, AND start the one automatic anchored fetch for this anchor and generation.
    case startFetch
}

/// The rule behind the `.month` rung's body, pure so it is testable without a view (see
/// `DarkroomMonthBodyRuleTests`).
///
/// The bug it exists for (build 424): "SEPTEMBER 2026 · 121 shots · 18 nights" in the header and
/// "Nothing left in September." under it. The body used to decide "empty" from the loaded page
/// alone, and the loaded page is not the month: it is whatever the last fetch, or anything that
/// emptied the shared list since, left behind. The scoped empty state is a claim about the
/// server, so it now needs the server's word for it: a summary that says the month has no shots,
/// or a fetch for this very month that landed with nothing in it. Short of that, a month the
/// summary says has shots gets ONE automatic anchored fetch per anchor per load generation
/// (`automaticAttempts` is the loop guard), shows the skeleton while any fetch is running, and
/// ends on `ErrorState` with retry if it still cannot show anything. Never "Nothing left".
enum DarkroomMonthBodyRule {
    /// - Parameters:
    ///   - hasRowsForAnchor: at least one loaded night belongs to the anchor month.
    ///   - fetchInFlight: a fetch that can still bring the anchor's rows is running (an anchored
    ///     jump, a landing not yet consumed, a reload's page fetch or its summary fetch).
    ///   - summaryShotCount: the server summary's shot count for the anchor month. `0` when the
    ///     summary resolved with no row for it, `nil` when there is no summary at all (still
    ///     loading, or the RPC failed or is unreachable).
    ///   - outcome: how the latest fetch for this anchor in this generation ended, `nil` if none.
    ///   - automaticAttempts: automatic fetches already started for this anchor in this
    ///     generation.
    static func decide(
        hasRowsForAnchor: Bool,
        fetchInFlight: Bool,
        summaryShotCount: Int?,
        outcome: DarkroomAnchorFetchOutcome?,
        automaticAttempts: Int
    ) -> DarkroomMonthBody {
        if hasRowsForAnchor { return .content }
        // The server summary says there is nothing to wait for. Ahead of `fetchInFlight` so a
        // known-empty month (the current month before its first shot, most often) does not
        // flash the skeleton on every reload.
        if summaryShotCount == 0 { return .scopedEmpty }
        if fetchInFlight { return .skeleton }
        switch outcome {
        case .landedEmpty: return .scopedEmpty
        // Never retried automatically: offline, the same request fails the same way, and the
        // error state's own retry is right there.
        case .failed: return .error
        case .landedWithRows, .interrupted, nil:
            // Rows that landed and are gone again, a fetch that never applied, or no fetch at
            // all: one automatic fetch, then the error state rather than another attempt.
            return automaticAttempts == 0 ? .startFetch : .error
        }
    }

    /// A finished page fetch's outcome, as evidence about one anchor month. `anchorHasRows` is
    /// read from the list right after the fetch returned, never from a cache that may still be
    /// catching up with it.
    static func outcome(for load: DarkroomViewModel.LoadOutcome, anchorHasRows: Bool) -> DarkroomAnchorFetchOutcome {
        switch load {
        case .applied: return anchorHasRows ? .landedWithRows : .landedEmpty
        case .failed: return .failed
        case .superseded, .cancelled: return .interrupted
        }
    }

    /// Two fetches for the same month can finish in either order (a reload's page fetch and the
    /// anchored fetch that superseded it). The one that never applied says nothing about the
    /// month, so it never overwrites one that landed; anything else, the later word wins.
    static func merged(existing: DarkroomAnchorFetchOutcome?, new: DarkroomAnchorFetchOutcome) -> DarkroomAnchorFetchOutcome {
        if new == .interrupted, existing == .landedWithRows || existing == .landedEmpty, let existing {
            return existing
        }
        return new
    }
}
