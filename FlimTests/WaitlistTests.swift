import XCTest
@testable import Flim

/// The rules behind the sign-in screen's waitlist: what Join accepts, how the server's one-word
/// answer is read, and the per-email "already joined" memory.
final class WaitlistTests: XCTestCase {
    /// An isolated suite per test, never `.standard`. See `PendingInviteRedeemedTests`.
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "WaitlistTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Name

    func testNameIsTrimmed() {
        XCTAssertEqual(Waitlist.normalizedName("  Sam \n"), "Sam")
    }

    func testEmptyOrBlankNameIsRejected() {
        XCTAssertNil(Waitlist.normalizedName(""))
        XCTAssertNil(Waitlist.normalizedName("   \n "))
    }

    func testNameLengthBoundsAreOneToSixty() {
        XCTAssertEqual(Waitlist.normalizedName("A"), "A")
        XCTAssertNotNil(Waitlist.normalizedName(String(repeating: "a", count: 60)))
        XCTAssertNil(Waitlist.normalizedName(String(repeating: "a", count: 61)))
        // Measured after trimming: padding never pushes a valid name over the limit.
        XCTAssertNotNil(Waitlist.normalizedName("  " + String(repeating: "a", count: 60) + "  "))
    }

    // MARK: - Email

    func testEmailIsTrimmedAndLowercased() {
        XCTAssertEqual(Waitlist.normalizedEmail("  Sam.Lee@Example.COM \n"), "sam.lee@example.com")
    }

    func testEmailShapesThatAreAccepted() {
        XCTAssertNotNil(Waitlist.normalizedEmail("a@b.co"))
        XCTAssertNotNil(Waitlist.normalizedEmail("first+tag@mail.example.org"))
    }

    func testEmailShapesThatAreRejected() {
        for bad in ["", "sam", "sam@", "@example.com", "sam@example", "sam@example.", "sam@.com",
                    "sam@@example.com", "sam@exa@mple.com", "sam lee@example.com", "sam@exa..com"] {
            XCTAssertNil(Waitlist.normalizedEmail(bad), "accepted \(bad)")
        }
    }

    func testCanSubmitNeedsBoth() {
        XCTAssertTrue(Waitlist.canSubmit(name: "Sam", email: "sam@example.com"))
        XCTAssertFalse(Waitlist.canSubmit(name: " ", email: "sam@example.com"))
        XCTAssertFalse(Waitlist.canSubmit(name: "Sam", email: "sam@example"))
    }

    // MARK: - The server's answer

    func testTheThreeServerWordsMap() {
        XCTAssertEqual(Waitlist.Outcome(serverValue: "joined"), .joined)
        XCTAssertEqual(Waitlist.Outcome(serverValue: "invalid"), .invalid)
        XCTAssertEqual(Waitlist.Outcome(serverValue: "rate_limited"), .rateLimited)
    }

    func testUnknownOrMissingWordIsUnreachable() {
        XCTAssertEqual(Waitlist.Outcome(serverValue: "maybe"), .unreachable)
        XCTAssertEqual(Waitlist.Outcome(serverValue: ""), .unreachable)
        XCTAssertEqual(Waitlist.Outcome(serverValue: nil), .unreachable)
    }

    func testParsesABareJSONString() {
        XCTAssertEqual(Waitlist.Outcome.parse(Data(#""joined""#.utf8)), .joined)
        XCTAssertEqual(Waitlist.Outcome.parse(Data(#""rate_limited""#.utf8)), .rateLimited)
    }

    func testParsesTheOtherShapesAScalarCanArriveIn() {
        XCTAssertEqual(Waitlist.Outcome.parse(Data(#"["invalid"]"#.utf8)), .invalid)
        XCTAssertEqual(Waitlist.Outcome.parse(Data(#"[{"join_waitlist":"joined"}]"#.utf8)), .joined)
        XCTAssertEqual(Waitlist.Outcome.parse(Data(#"{"join_waitlist":"joined"}"#.utf8)), .joined)
        XCTAssertEqual(Waitlist.Outcome.parse(Data("joined\n".utf8)), .joined)
    }

    func testUndecodableBodyIsUnreachable() {
        XCTAssertEqual(Waitlist.Outcome.parse(Data()), .unreachable)
        XCTAssertEqual(Waitlist.Outcome.parse(Data("null".utf8)), .unreachable)
        XCTAssertEqual(Waitlist.Outcome.parse(Data(#"{"message":"boom"}"#.utf8)), .unreachable)
        XCTAssertEqual(Waitlist.Outcome.parse(Data("<html>".utf8)), .unreachable)
    }

    func testOnlyInvalidIsAboutTheEmail() {
        XCTAssertTrue(Waitlist.Outcome.invalid.isAboutEmail)
        XCTAssertFalse(Waitlist.Outcome.rateLimited.isAboutEmail)
        XCTAssertFalse(Waitlist.Outcome.unreachable.isAboutEmail)
    }

    func testMessages() {
        XCTAssertNil(Waitlist.Outcome.joined.message)
        XCTAssertEqual(Waitlist.Outcome.invalid.message, "That email doesn't look right.")
        XCTAssertEqual(Waitlist.Outcome.rateLimited.message, "Too many tries. Give it a few minutes.")
        XCTAssertEqual(Waitlist.Outcome.unreachable.message, "Couldn't reach \(AppInfo.appName). Try again.")
    }

    // MARK: - Joined on this phone

    func testRememberedEmailIsJoinedCaseAndSpaceInsensitively() {
        XCTAssertFalse(Waitlist.hasJoined("sam@example.com", in: defaults))
        Waitlist.remember("sam@example.com", in: defaults)
        XCTAssertTrue(Waitlist.hasJoined("sam@example.com", in: defaults))
        XCTAssertTrue(Waitlist.hasJoined("  Sam@Example.com ", in: defaults))
    }

    func testOtherEmailsAreNotJoined() {
        Waitlist.remember("sam@example.com", in: defaults)
        XCTAssertFalse(Waitlist.hasJoined("lee@example.com", in: defaults))
        XCTAssertFalse(Waitlist.hasJoined("", in: defaults))
    }

    // MARK: - Copy

    func testCopyHasNoEmDashes() {
        let all = [Waitlist.Copy.noCode, Waitlist.Copy.askFriend, Waitlist.Copy.askFriendHint,
                   Waitlist.Copy.joinWaitlist, Waitlist.Copy.joinWaitlistHint, Waitlist.Copy.shareMessage,
                   Waitlist.Copy.title, Waitlist.Copy.body, Waitlist.Copy.nameField, Waitlist.Copy.emailField,
                   Waitlist.Copy.join, Waitlist.Copy.joinedTitle, Waitlist.Copy.joinedBody(email: "a@b.co"),
                   Waitlist.Copy.done, Waitlist.Copy.invalidEmail, Waitlist.Copy.rateLimited,
                   Waitlist.Copy.unreachable]
        for line in all {
            XCTAssertFalse(line.contains("\u{2014}"), "em dash in \(line)")
        }
    }

    func testShareMessageEndsWithTheSiteOnItsOwnLine() {
        XCTAssertEqual(Waitlist.Copy.shareMessage,
                       "Are you on \(AppInfo.appName)? Send me an invite code so I can join.\nhttps://flim-app.com")
    }
}
