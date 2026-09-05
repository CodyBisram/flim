import Testing
import Foundation
@testable import Flim

/// Decoding both `profile_chapters` and `chapter_photos` row shapes straight from fixture JSON,
/// with a bare `JSONDecoder()`: this must agree with however the Supabase client's own decoder
/// parses the same bytes at runtime, which is why both `ChapterSummary` and `ChapterPhoto` parse
/// their timestamp columns by hand rather than trusting a configured `dateDecodingStrategy`
/// neither type controls.
struct ChapterDecodingTests {

    // MARK: - ChapterSummary / profile_chapters

    @Test("decodes a full profile_chapters row")
    func decodesChapterSummaryRow() throws {
        let json = Data(#"""
        {"month_start":"2026-08-01","shot_count":34,"roll_count":2,
         "cover_paths":["a.jpg","b.jpg","c.jpg"],
         "first_shot_at":"2026-08-02T10:00:00.000Z","last_shot_at":"2026-08-29T21:15:00.000Z"}
        """#.utf8)
        let row = try JSONDecoder().decode(ChapterSummary.self, from: json)
        #expect(row.shotCount == 34)
        #expect(row.rollCount == 2)
        #expect(row.coverPaths == ["a.jpg", "b.jpg", "c.jpg"])
        let comps = Calendar.current.dateComponents([.year, .month], from: row.monthStart)
        #expect(comps.year == 2026 && comps.month == 8)
        #expect(row.firstShotAt < row.lastShotAt)
    }

    @Test("a profile_chapters row with cover_paths missing entirely degrades to empty, not a decode failure")
    func missingCoverPathsDegradesToEmpty() throws {
        let json = Data(#"""
        {"month_start":"2026-08-01","shot_count":5,"roll_count":0,
         "first_shot_at":"2026-08-02T10:00:00.000Z","last_shot_at":"2026-08-02T10:00:00.000Z"}
        """#.utf8)
        let row = try JSONDecoder().decode(ChapterSummary.self, from: json)
        #expect(row.coverPaths == [])
    }

    @Test("a full timestamp is rejected where month_start must be a bare date")
    func monthStartRejectsFullTimestamp() {
        let json = Data(#"""
        {"month_start":"2026-08-01T00:00:00Z","shot_count":1,"roll_count":0,
         "first_shot_at":"2026-08-01T00:00:00.000Z","last_shot_at":"2026-08-01T00:00:00.000Z"}
        """#.utf8)
        do {
            _ = try JSONDecoder().decode(ChapterSummary.self, from: json)
            Issue.record("expected a decoding error for a full timestamp in month_start")
        } catch {
            // Expected: a full timestamp is not a bare yyyy-MM-dd date.
        }
    }

    // MARK: - ChapterPhoto / chapter_photos

    @Test("decodes a full chapter_photos row")
    func decodesChapterPhotoRow() throws {
        let id = UUID()
        let rollId = UUID()
        let json = Data(#"""
        {"id":"\#(id.uuidString)","taken_at":"2026-08-09T18:30:00.000Z",
         "thumb_path":"thumb.jpg","feed_path":"feed.jpg","storage_path":"full.jpg",
         "roll_id":"\#(rollId.uuidString)","roll_name":"Roommates"}
        """#.utf8)
        let row = try JSONDecoder().decode(ChapterPhoto.self, from: json)
        #expect(row.id == id)
        #expect(row.thumbPath == "thumb.jpg")
        #expect(row.feedPath == "feed.jpg")
        #expect(row.storagePath == "full.jpg")
        #expect(row.rollId == rollId)
        #expect(row.rollName == "Roommates")
        #expect(row.displayPath == "thumb.jpg")
        #expect(row.viewPath == "feed.jpg")
        #expect(row.postId == nil)
    }

    // MARK: - post_id (reaction/comment fix)

    @Test("a chapter_photos row carrying post_id decodes it")
    func decodesPostId() throws {
        let id = UUID()
        let postId = UUID()
        let json = Data(#"""
        {"id":"\#(id.uuidString)","taken_at":"2026-08-09T18:30:00.000Z","storage_path":"full.jpg",
         "post_id":"\#(postId.uuidString)"}
        """#.utf8)
        let row = try JSONDecoder().decode(ChapterPhoto.self, from: json)
        #expect(row.postId == postId)
    }

    @Test("a chapter_photos row from a server that doesn't send post_id yet decodes to nil, not a failure")
    func missingPostIdDecodesToNilNotFailure() throws {
        let id = UUID()
        let json = Data(#"""
        {"id":"\#(id.uuidString)","taken_at":"2026-08-09T18:30:00.000Z","storage_path":"full.jpg"}
        """#.utf8)
        let row = try JSONDecoder().decode(ChapterPhoto.self, from: json)
        #expect(row.postId == nil)
    }

    @Test("a null post_id (present, explicitly null) decodes the same as an absent key")
    func nullPostIdDecodesToNil() throws {
        let id = UUID()
        let json = Data(#"""
        {"id":"\#(id.uuidString)","taken_at":"2026-08-09T18:30:00.000Z","storage_path":"full.jpg",
         "post_id":null}
        """#.utf8)
        let row = try JSONDecoder().decode(ChapterPhoto.self, from: json)
        #expect(row.postId == nil)
    }

    @Test("a chapter_photos row with roll_id/roll_name missing (not on a roll) decodes to nil, not a failure")
    func missingRollFieldsDecodeToNil() throws {
        let id = UUID()
        let json = Data(#"""
        {"id":"\#(id.uuidString)","taken_at":"2026-08-09T18:30:00.000Z",
         "thumb_path":"thumb.jpg","feed_path":"feed.jpg","storage_path":"full.jpg"}
        """#.utf8)
        let row = try JSONDecoder().decode(ChapterPhoto.self, from: json)
        #expect(row.rollId == nil)
        #expect(row.rollName == nil)
    }

    @Test("a chapter_photos row missing both renditions falls back to storage_path for display and view")
    func missingRenditionsFallBackToStoragePath() throws {
        let id = UUID()
        let json = Data(#"""
        {"id":"\#(id.uuidString)","taken_at":"2026-08-09T18:30:00.000Z","storage_path":"full.jpg"}
        """#.utf8)
        let row = try JSONDecoder().decode(ChapterPhoto.self, from: json)
        #expect(row.thumbPath == nil)
        #expect(row.feedPath == nil)
        #expect(row.displayPath == "full.jpg")
        #expect(row.viewPath == "full.jpg")
    }

    @Test("a null roll_name (present, explicitly null) decodes the same as an absent key")
    func nullRollNameDecodesToNil() throws {
        let id = UUID()
        let json = Data(#"""
        {"id":"\#(id.uuidString)","taken_at":"2026-08-09T18:30:00.000Z","storage_path":"full.jpg",
         "roll_id":null,"roll_name":null}
        """#.utf8)
        let row = try JSONDecoder().decode(ChapterPhoto.self, from: json)
        #expect(row.rollId == nil)
        #expect(row.rollName == nil)
    }
}
