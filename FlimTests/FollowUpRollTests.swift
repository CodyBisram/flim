import Testing
import Foundation
@testable import Flim

struct FollowUpRollTests {
    @Test func theSuggestedNameCountsDays() {
        #expect(Roll.followUpName(after: "Orlando") == "Orlando, day 2")
        #expect(Roll.followUpName(after: "Orlando, day 2") == "Orlando, day 3")
        #expect(Roll.followUpName(after: "Orlando, day 12") == "Orlando, day 13")
        #expect(Roll.followUpName(after: "  Islands  ") == "Islands, day 2")
        #expect(Roll.followUpName(after: "") == "Day 2")
        #expect(Roll.followUpName(after: "Day 2 vibes") == "Day 2 vibes, day 2")
    }

    @Test func theJoinPushRouteRoundTrips() {
        let parsed = PushDestination.parse(userInfo: ["flim": ["t": "join", "code": "ab12cd"]])
        #expect(parsed == .joinRoll(code: "AB12CD"))
        #expect(PushDestination.joinRoll(code: "AB12CD").wireValue["t"] as? String == "join")
        #expect(PushDestination.joinRoll(code: "AB12CD").wireValue["code"] as? String == "AB12CD")
        #expect(PushDestination.parse(userInfo: ["flim": ["t": "join", "code": "nope"]]) == nil)
        #expect(PushDestination.parse(userInfo: ["flim": ["t": "join"]]) == nil)
    }

    @Test func aRollDecodesWithOrWithoutAParent() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","name":"Orlando, day 2","invite_code":"ABC123",
         "created_by":"00000000-0000-0000-0000-000000000002","created_at":"2026-09-11T12:00:00Z",
         "reveal_at":"2026-09-12T00:00:00Z","parent_roll_id":"00000000-0000-0000-0000-000000000003"}
        """
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let roll = try decoder.decode(Roll.self, from: Data(json.utf8))
        #expect(roll.parentRollId == UUID(uuidString: "00000000-0000-0000-0000-000000000003"))
        let bare = try decoder.decode(Roll.self, from: Data(json.replacingOccurrences(of: ",\"parent_roll_id\":\"00000000-0000-0000-0000-000000000003\"", with: "").utf8))
        #expect(bare.parentRollId == nil)
    }
}

struct FollowUpRollNameEdgeTests {
    @Test func theSuggestionNeverOverflowsOrExceedsTheServerLimit() {
        #expect(Roll.followUpName(after: "x, day \(Int.max)").hasPrefix("x, day"))   // no trap
        let long = String(repeating: "a", count: 60)
        #expect(Roll.followUpName(after: long).count <= 60)
    }
}
