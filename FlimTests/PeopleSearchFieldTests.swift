import XCTest
@testable import Flim

final class PeopleSearchFieldTests: XCTestCase {
    private func profile(username: String?, displayName: String?) -> UserProfile {
        UserProfile(id: UUID(), username: username, avatarPath: nil, bio: nil,
                    displayName: displayName, coverPath: nil, createdAt: .now)
    }

    func testMatchesOnHandle() {
        let p = profile(username: "codyb", displayName: "Cody")
        XCTAssertTrue(personMatches(p, query: "codyb"))
        XCTAssertTrue(personMatches(p, query: "cod"))
    }

    func testMatchesOnDisplayName() {
        let p = profile(username: "codyb", displayName: "Cody Bisram")
        XCTAssertTrue(personMatches(p, query: "Bisram"))
        XCTAssertTrue(personMatches(p, query: "Cody"))
    }

    func testCaseInsensitive() {
        let p = profile(username: "CodyB", displayName: "Cody Bisram")
        XCTAssertTrue(personMatches(p, query: "codyb"))
        XCTAssertTrue(personMatches(p, query: "BISRAM"))
    }

    func testEmptyQueryMatchesEverything() {
        let p = profile(username: "codyb", displayName: "Cody Bisram")
        let empty = profile(username: nil, displayName: nil)
        XCTAssertTrue(personMatches(p, query: ""))
        XCTAssertTrue(personMatches(empty, query: ""))
    }

    func testNilUsernameDoesNotCrashOrWronglyMatch() {
        let p = profile(username: nil, displayName: "Cody Bisram")
        XCTAssertTrue(personMatches(p, query: "Cody"))
        XCTAssertFalse(personMatches(p, query: "someone"))
    }

    func testNilDisplayNameDoesNotCrashOrWronglyMatch() {
        let p = profile(username: "codyb", displayName: nil)
        XCTAssertTrue(personMatches(p, query: "codyb"))
        XCTAssertFalse(personMatches(p, query: "someone"))
    }

    func testBothNilNeverMatchesNonEmptyQuery() {
        let p = profile(username: nil, displayName: nil)
        XCTAssertFalse(personMatches(p, query: "anything"))
    }

    func testNoMatchReturnsFalse() {
        let p = profile(username: "codyb", displayName: "Cody Bisram")
        XCTAssertFalse(personMatches(p, query: "zzz"))
    }
}
