import XCTest
@testable import Flim

/// The share-to-feed sheet's pure logic: the destination line's verb and shape (loading vs.
/// resolved, adds-to vs. starts), the consequence line's pluralization, and the people picker's
/// recency ordering. All free functions, none of this touches the network or a view.
final class ShareToFeedSheetTests: XCTestCase {

    // MARK: - Destination line 1 (verb)

    func testLine1WhileLoadingIsNeutral() {
        // Before the count resolves, the sheet must not claim there IS something to add to.
        XCTAssertEqual(shareDestinationLine1(dayLabel: "Fri 22 Aug", count: .loading),
                        "Starts your Fri 22 Aug post")
    }

    func testLine1OnAFailedFetchMatchesLoadingNotResolvedZero() {
        // `FeedService.todayPostCount` returns `nil` on a genuine failure (offline, server
        // error), distinct from a resolved `0`. `ShareToFeedSheet` deliberately leaves
        // `todayCount` at `.loading` in that case rather than inventing a third case. Line 1's
        // wording happens to read identically either way ("Starts..." is the honest verb for
        // both "don't know yet" and "confirmed zero"), which is exactly why line 2, not line 1,
        // is where a failure could otherwise leak a false claim, see the test below.
        XCTAssertEqual(shareDestinationLine1(dayLabel: "Fri 22 Aug", count: .loading),
                        shareDestinationLine1(dayLabel: "Fri 22 Aug", count: .resolved(0)))
    }

    func testLine1WithExistingPostsAddsTo() {
        XCTAssertEqual(shareDestinationLine1(dayLabel: "Fri 22 Aug", count: .resolved(3)),
                        "Adds to your Fri 22 Aug post")
    }

    func testLine1WithZeroExistingPostsStarts() {
        XCTAssertEqual(shareDestinationLine1(dayLabel: "Fri 22 Aug", count: .resolved(0)),
                        "Starts your Fri 22 Aug post")
    }

    // MARK: - Destination line 2 (count claim)

    func testLine2WhileLoadingMakesNoCountClaim() {
        // Neither a guessed number nor "nothing from today is on the feed yet" (itself a claim
        // about the count) may appear before the server has actually answered.
        XCTAssertEqual(shareDestinationLine2(shotTime: "9:52 PM", count: .loading), "Shot 9:52 PM")
    }

    func testLine2WithOneExistingPostIsSingular() {
        XCTAssertEqual(shareDestinationLine2(shotTime: "9:52 PM", count: .resolved(1)),
                        "1 shot already there · this one shot 9:52 PM")
    }

    func testLine2WithSeveralExistingPostsIsPlural() {
        XCTAssertEqual(shareDestinationLine2(shotTime: "9:52 PM", count: .resolved(4)),
                        "4 shots already there · this one shot 9:52 PM")
    }

    func testLine2WithNoExistingPostsNamesTheEmptyState() {
        XCTAssertEqual(shareDestinationLine2(shotTime: "9:52 PM", count: .resolved(0)),
                        "Shot 9:52 PM · nothing from today is on the feed yet")
    }

    func testLine2OnAFailedFetchDoesNotClaimTheFeedIsEmpty() {
        // The exact regression this pins: a `nil` (failed) `todayPostCount` must NOT produce
        // "nothing from today is on the feed yet", a specific, false claim on a flaky network.
        // `ShareToFeedSheet` maps a failed fetch to `.loading`, never `.resolved(0)`, so line 2
        // stays the same bare "Shot {time}" a still-loading sheet shows, and must differ from
        // what a GENUINELY resolved zero produces.
        let onFailure = shareDestinationLine2(shotTime: "9:52 PM", count: .loading)
        let onResolvedZero = shareDestinationLine2(shotTime: "9:52 PM", count: .resolved(0))
        XCTAssertEqual(onFailure, "Shot 9:52 PM")
        XCTAssertNotEqual(onFailure, onResolvedZero)
    }

    // MARK: - Day label

    func testDayLabelFormat() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let day = calendar.date(from: DateComponents(year: 2026, month: 8, day: 22))!
        XCTAssertEqual(shareDestinationDayLabel(day, calendar: calendar), "Sat 22 Aug")
    }

    // MARK: - Consequence line

    func testConsequenceLineWithNobodyTagged() {
        XCTAssertEqual(shareConsequenceLine(taggedCount: 0), "Nobody is notified until you post.")
    }

    func testConsequenceLineIsSingularForOnePerson() {
        XCTAssertEqual(shareConsequenceLine(taggedCount: 1), "1 person will be notified when this posts.")
    }

    func testConsequenceLineIsPluralForSeveralPeople() {
        XCTAssertEqual(shareConsequenceLine(taggedCount: 2), "2 people will be notified when this posts.")
    }

    // MARK: - Picker ordering

    private func profile(_ id: UUID, name: String) -> UserProfile {
        UserProfile(id: id, username: name, avatarPath: nil, bio: nil, displayName: nil,
                    coverPath: nil, createdAt: .now, hiddenFromDiscovery: false, signupOrdinal: nil)
    }

    func testRecencyOrdersMostRecentTagFirst() {
        let a = profile(UUID(), name: "a")
        let b = profile(UUID(), name: "b")
        let c = profile(UUID(), name: "c")
        let recency: [UUID: Date] = [
            a.id: Date(timeIntervalSince1970: 100),
            b.id: Date(timeIntervalSince1970: 300),
            c.id: Date(timeIntervalSince1970: 200),
        ]
        let ordered = orderPeopleByRecency([a, b, c], recency: recency)
        XCTAssertEqual(ordered.map(\.username), ["b", "c", "a"])
    }

    func testNeverTaggedPeopleFallBackToTheFollowsListOrder() {
        // No timestamp on the server for these two, so the picker must not invent a proxy
        // ordering for them; they keep their relative position from `people`.
        let tagged = profile(UUID(), name: "tagged")
        let untagged1 = profile(UUID(), name: "untagged1")
        let untagged2 = profile(UUID(), name: "untagged2")
        let recency: [UUID: Date] = [tagged.id: .now]
        let ordered = orderPeopleByRecency([untagged1, untagged2, tagged], recency: recency)
        XCTAssertEqual(ordered.map(\.username), ["tagged", "untagged1", "untagged2"])
    }

    func testEmptyRecencyMapPreservesFollowsListOrderEntirely() {
        let a = profile(UUID(), name: "a")
        let b = profile(UUID(), name: "b")
        let ordered = orderPeopleByRecency([a, b], recency: [:])
        XCTAssertEqual(ordered.map(\.username), ["a", "b"])
    }
}

// MARK: - v2 audience sentence and capture states (2026-09-14)

final class V2FoundationsTests: XCTestCase {
    func testAudienceNamesFollowersAndCountsThem() {
        let a = ShareAudience(followerCount: 12, taggedNames: [])
        XCTAssertEqual(a.title, "Your followers can see this")
        XCTAssertEqual(a.detail, "That's 12 people right now, and anyone who follows you later.")
        XCTAssertEqual(ShareAudience(followerCount: 1, taggedNames: []).detail,
                       "That's 1 person right now, and anyone who follows you later.")
    }

    func testAudienceWithoutACountNeverClaimsOne() {
        XCTAssertEqual(ShareAudience(followerCount: nil, taggedNames: []).detail,
                       "And anyone who follows you later.")
    }

    func testAudienceNamesTheTaggedPerson() {
        let a = ShareAudience(followerCount: 3, taggedNames: ["Rae"])
        XCTAssertEqual(a.title, "Your followers, and Rae")
        XCTAssertTrue(a.detail.hasSuffix("You tagged Rae, so they can see this photo whether or not they follow you."))
        XCTAssertEqual(ShareAudience(followerCount: 3, taggedNames: ["Rae", "Sam", "Jo"]).title,
                       "Your followers, and 3 people you tagged")
    }

    func testCaptureStatusPrecedence() {
        XCTAssertEqual(CaptureStatus.derive(localSaveFailed: true, pendingCount: 1, isUploading: true, failedCount: 0, connected: true, justUploaded: false), .notSavedYet)
        XCTAssertEqual(CaptureStatus.derive(localSaveFailed: false, pendingCount: 2, isUploading: true, failedCount: 0, connected: true, justUploaded: false), .uploading(count: 2))
        XCTAssertEqual(CaptureStatus.derive(localSaveFailed: false, pendingCount: 1, isUploading: false, failedCount: 0, connected: true, justUploaded: false), .savedOnPhone)
        XCTAssertEqual(CaptureStatus.derive(localSaveFailed: false, pendingCount: 0, isUploading: false, failedCount: 1, connected: false, justUploaded: false), .queued(count: 1, offline: true))
        XCTAssertEqual(CaptureStatus.derive(localSaveFailed: false, pendingCount: 0, isUploading: false, failedCount: 0, connected: true, justUploaded: true), .uploaded)
        XCTAssertNil(CaptureStatus.derive(localSaveFailed: false, pendingCount: 0, isUploading: false, failedCount: 0, connected: true, justUploaded: false))
        XCTAssertEqual(CaptureStatus.uploading(count: 3).title, "Uploading 3")
        XCTAssertTrue(CaptureStatus.queued(count: 1, offline: true).attention)
        XCTAssertFalse(CaptureStatus.uploaded.attention)
    }
}
