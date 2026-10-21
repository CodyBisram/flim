import Testing
import Foundation
@testable import Flim

/// The notification service extension downloads only what `PushImage.url(from:)` lets through: a
/// signed URL for the photos bucket on the project's own storage host. Anything else is shown
/// without a picture.
struct PushImageTests {
    private let signed = "https://wxvwamwrjlrvqmuaafjv.supabase.co/storage/v1/object/sign/photos/u/p_feed.jpg?token=abc"

    private func info(_ img: Any?) -> [AnyHashable: Any] {
        var flim: [String: Any] = ["t": "feed"]
        if let img { flim["img"] = img }
        return ["flim": flim]
    }

    @Test("a signed photos URL on the project's host is fetched")
    func acceptsSignedPhoto() {
        #expect(PushImage.url(from: info(signed))?.absoluteString == signed)
    }

    @Test("another host is not fetched")
    func rejectsOtherHost() {
        #expect(PushImage.url(from: info("https://example.com/storage/v1/object/sign/photos/x.jpg")) == nil)
    }

    @Test("plain http is not fetched")
    func rejectsHTTP() {
        #expect(PushImage.url(from: info(signed.replacingOccurrences(of: "https:", with: "http:"))) == nil)
    }

    @Test("another bucket or an unsigned path is not fetched")
    func rejectsOtherPaths() {
        #expect(PushImage.url(from: info("https://wxvwamwrjlrvqmuaafjv.supabase.co/storage/v1/object/sign/avatars/a.jpg")) == nil)
        #expect(PushImage.url(from: info("https://wxvwamwrjlrvqmuaafjv.supabase.co/storage/v1/object/public/photos/a.jpg")) == nil)
    }

    @Test("no image, or not a string, is no image")
    func missingImage() {
        #expect(PushImage.url(from: info(nil)) == nil)
        #expect(PushImage.url(from: info(42)) == nil)
        #expect(PushImage.url(from: [:]) == nil)
    }

    @Test("an empty download is not attached")
    func sizeBounds() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let empty = dir.appendingPathComponent("empty")
        try Data().write(to: empty)
        #expect(PushImage.attachment(movingFrom: empty) == nil)
    }
}
