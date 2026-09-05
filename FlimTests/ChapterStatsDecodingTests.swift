import Testing
import Foundation
@testable import Flim

/// Decoding `chapter_stats` rows straight from fixture JSON with a bare `JSONDecoder()`, same
/// discipline as `ChapterDecodingTests`: a key is ABSENT from the array entirely when there's
/// nothing to say, never a zero row, and an unrecognized `stat_key` (the server shipping a new
/// one before this client knows about it) must drop just that row, not fail the whole array.
struct ChapterStatsDecodingTests {
    @Test("decodes a photo-backed row (most_reacted)")
    func decodesPhotoBackedRow() throws {
        let photoId = UUID()
        let json = Data(#"""
        {"stat_key":"most_reacted","value_int":12,"value_text":null,
         "photo_id":"\#(photoId.uuidString)","photo_thumb_path":"thumb.jpg"}
        """#.utf8)
        let row = try JSONDecoder().decode(ChapterStatRow.self, from: json)
        #expect(row.resolvedKey == .mostReacted)
        #expect(row.valueInt == 12)
        #expect(row.valueText == nil)
        #expect(row.photoId == photoId)
        #expect(row.photoThumbPath == "thumb.jpg")
        #expect(row.postId == nil)
    }

    // MARK: - post_id (reaction/comment fix)

    @Test("a photo-backed row carrying post_id decodes it")
    func decodesPostId() throws {
        let photoId = UUID()
        let postId = UUID()
        let json = Data(#"""
        {"stat_key":"most_reacted","value_int":12,
         "photo_id":"\#(photoId.uuidString)","photo_thumb_path":"thumb.jpg",
         "post_id":"\#(postId.uuidString)"}
        """#.utf8)
        let row = try JSONDecoder().decode(ChapterStatRow.self, from: json)
        #expect(row.postId == postId)
    }

    @Test("a row from a server that doesn't send post_id yet decodes to nil, not a failure")
    func missingPostIdDecodesToNilNotFailure() throws {
        let json = Data(#"""
        {"stat_key":"most_reacted","value_int":12,"photo_id":"\#(UUID().uuidString)"}
        """#.utf8)
        let row = try JSONDecoder().decode(ChapterStatRow.self, from: json)
        #expect(row.postId == nil)
    }

    @Test("decodes a text-valued row (top_reaction) with no photo columns present at all")
    func decodesTextValuedRowWithoutPhotoColumns() throws {
        let json = Data(#"""
        {"stat_key":"top_reaction","value_int":12,"value_text":"❤️"}
        """#.utf8)
        let row = try JSONDecoder().decode(ChapterStatRow.self, from: json)
        #expect(row.resolvedKey == .topReaction)
        #expect(row.valueInt == 12)
        #expect(row.valueText == "❤️")
        #expect(row.photoId == nil)
        #expect(row.photoThumbPath == nil)
    }

    @Test("a count-only row (streak_days) decodes with value_text and photo columns nil")
    func decodesCountOnlyRow() throws {
        let json = Data(#"""
        {"stat_key":"streak_days","value_int":6}
        """#.utf8)
        let row = try JSONDecoder().decode(ChapterStatRow.self, from: json)
        #expect(row.resolvedKey == .streakDays)
        #expect(row.valueInt == 6)
        #expect(row.valueText == nil)
    }

    @Test("an array with an unrecognized stat_key still decodes every row; the unknown one is dropped when keyed")
    func unrecognizedKeyDoesNotFailTheArray() throws {
        let json = Data(#"""
        [{"stat_key":"streak_days","value_int":6},
         {"stat_key":"some_future_stat_this_client_does_not_know","value_int":1}]
        """#.utf8)
        let rows = try JSONDecoder().decode([ChapterStatRow].self, from: json)
        #expect(rows.count == 2)
        let keyed = rows.keyedByStat()
        #expect(keyed.count == 1)
        #expect(keyed[.streakDays]?.valueInt == 6)
    }

    @Test("keying drops absent keys entirely: a fixture with only three rows keys to exactly three")
    func keyingReflectsOnlyPresentRows() throws {
        let rows: [ChapterStatRow] = [
            ChapterStatRow(statKey: "most_reacted", valueInt: 4, photoId: UUID(), photoThumbPath: "a.jpg"),
            ChapterStatRow(statKey: "busiest_day", valueInt: 3, valueText: "2026-08-12"),
            ChapterStatRow(statKey: "rolls_count", valueInt: 2),
        ]
        let keyed = rows.keyedByStat()
        #expect(keyed.count == 3)
        #expect(keyed[.mostCommented] == nil)
        #expect(keyed[.nightShots] == nil)
    }

    // MARK: - user_id (the five newer stats)

    @Test("a person-backed row (biggest_fan) decodes user_id")
    func decodesUserId() throws {
        let userId = UUID()
        let json = Data(#"""
        {"stat_key":"biggest_fan","value_int":34,"value_text":"sabs","user_id":"\#(userId.uuidString)"}
        """#.utf8)
        let row = try JSONDecoder().decode(ChapterStatRow.self, from: json)
        #expect(row.resolvedKey == .biggestFan)
        #expect(row.valueInt == 34)
        #expect(row.valueText == "sabs")
        #expect(row.userId == userId)
    }

    @Test("a row from a server that doesn't send user_id yet decodes to nil, not a failure")
    func missingUserIdDecodesToNilNotFailure() throws {
        let json = Data(#"""
        {"stat_key":"top_given_reaction","value_int":219,"value_text":"❤️"}
        """#.utf8)
        let row = try JSONDecoder().decode(ChapterStatRow.self, from: json)
        #expect(row.userId == nil)
    }

    @Test("a fixture carrying all five newer stat_keys decodes and keys every one")
    func decodesFiveNewerStats() throws {
        let fanId = UUID()
        let mvpId = UUID()
        let gapPhotoId = UUID()
        let gapPostId = UUID()
        let json = Data(#"""
        [
         {"stat_key":"biggest_fan","value_int":34,"value_text":"sabs","user_id":"\#(fanId.uuidString)"},
         {"stat_key":"top_given_reaction","value_int":219,"value_text":"❤️"},
         {"stat_key":"golden_hour","value_int":20,"value_text":"9"},
         {"stat_key":"roll_mvp","value_int":10,"value_text":"tristan","user_id":"\#(mvpId.uuidString)"},
         {"stat_key":"longest_gap","value_int":5,"photo_id":"\#(gapPhotoId.uuidString)",
          "photo_thumb_path":"gap.jpg","post_id":"\#(gapPostId.uuidString)"}
        ]
        """#.utf8)
        let rows = try JSONDecoder().decode([ChapterStatRow].self, from: json)
        let keyed = rows.keyedByStat()
        #expect(keyed.count == 5)
        #expect(keyed[.biggestFan]?.userId == fanId)
        #expect(keyed[.biggestFan]?.valueText == "sabs")
        #expect(keyed[.topGivenReaction]?.valueInt == 219)
        #expect(keyed[.goldenHour]?.valueInt == 20)
        #expect(keyed[.goldenHour]?.valueText == "9")
        #expect(keyed[.rollMVP]?.userId == mvpId)
        #expect(keyed[.longestGap]?.valueInt == 5)
        #expect(keyed[.longestGap]?.photoId == gapPhotoId)
        #expect(keyed[.longestGap]?.postId == gapPostId)
    }
}
