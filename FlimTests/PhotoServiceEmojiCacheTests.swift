import XCTest
@testable import Flim

/// `PhotoService.shouldRefetchSuggestion`, the pure rule behind `fetchSuggestedEmoji`'s
/// "already cached, skip it" filter.
///
/// Regression this guards: a `.negative` entry (the server confirmed no suggestion, at the
/// moment it was asked) used to be permanent, a bare `[]` with no timestamp. On-capture
/// classification and the opportunistic backfill both write their result strictly AFTER a photo
/// is already visible to a reader, so a screen that asked about a fresh photo a moment too early
/// would cache "nothing" and never ask again for the rest of the session, even once the real
/// classification landed on the server a second later. This suite pins that a `.negative` is
/// eventually retried, and that a `.found` suggestion never is.
final class PhotoServiceEmojiCacheTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testNeverFetchedIsAlwaysWorthFetching() {
        XCTAssertTrue(PhotoService.shouldRefetchSuggestion(nil, now: now))
    }

    func testAFoundSuggestionIsNeverRefetchedNoMatterHowOld() {
        let ancient = PhotoService.SuggestionCacheEntry.found(["🦎"])
        XCTAssertFalse(PhotoService.shouldRefetchSuggestion(ancient, now: now.addingTimeInterval(1_000_000)))
    }

    func testAFreshNegativeIsNotYetRetried() {
        // Fetched a moment ago, well inside the TTL: the common case of scrolling back and forth
        // over the same photo within a few seconds must not re-request it.
        let entry = PhotoService.SuggestionCacheEntry.negative(now)
        XCTAssertFalse(PhotoService.shouldRefetchSuggestion(entry, now: now.addingTimeInterval(1)))
    }

    func testANegativeExactlyAtTheTTLBoundaryIsStillTrusted() {
        let entry = PhotoService.SuggestionCacheEntry.negative(now)
        let atBoundary = now.addingTimeInterval(PhotoService.negativeCacheTTL)
        XCTAssertFalse(PhotoService.shouldRefetchSuggestion(entry, now: atBoundary))
    }

    func testANegativeOlderThanTheTTLIsRetried() {
        // This is the fix itself: a suggestion that arrived after the negative read now has a
        // bounded window in which it will surface again without an app restart.
        let entry = PhotoService.SuggestionCacheEntry.negative(now)
        let pastBoundary = now.addingTimeInterval(PhotoService.negativeCacheTTL + 1)
        XCTAssertTrue(PhotoService.shouldRefetchSuggestion(entry, now: pastBoundary))
    }
}
