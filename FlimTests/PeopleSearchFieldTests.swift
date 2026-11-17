import XCTest
@testable import Flim

final class PeopleSearchFieldTests: XCTestCase {
    func testPastedHandlesWhitespaceAndAccents() {
        let person = profile(username: "jose.photo", displayName: "José Rivera")
        XCTAssertTrue(personMatches(person, query: "  @JOSE.photo\n"))
        XCTAssertTrue(personMatches(person, query: "jose rivera"))
        XCTAssertTrue(personMatches(person, query: " \n "))
        XCTAssertTrue(personMatches(person, query: "@"))
        XCTAssertFalse(personMatches(person, query: "@someoneelse"))
    }

    func testFilteringDoesNotChangeMembershipOrOrder() {
        let first = profile(username: "ana", displayName: "Ana")
        let second = profile(username: "jose", displayName: "José")
        let third = profile(username: "ana.photo", displayName: "Anna")
        let friends = [first, second, third]
        XCTAssertEqual(friends.filter { personMatches($0, query: "ana") }.map(\.id), [first.id, third.id])
        XCTAssertEqual(friends.filter { personMatches($0, query: "  ") }.map(\.id), friends.map(\.id))
        XCTAssertTrue(friends.filter { personMatches($0, query: "missing") }.isEmpty)
    }
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
