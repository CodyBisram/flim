import Testing
import Foundation
@testable import Flim

/// Exporting a roll to the share sheet without holding the roll in memory.
///
/// The failure this replaces is not a wrong pixel, it is the app being killed. "Save all" built an
/// array of every photo in the roll as a decoded image; the rolls people actually use it on are
/// the big ones, and there are 73- and 75-shot rolls in the field.
struct PhotoExportTests {

    private func isolate() -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PhotoExportTests-\(UUID().uuidString)", isDirectory: true)
        PhotoExport.root = root
        return root
    }

    @Test("names sort in capture order, not lexically")
    func zeroPadded() {
        // "flim-10" before "flim-2" would reorder the roll in Photos, which for a roll shot
        // across an evening is the one property that matters.
        _ = isolate()
        let names = (0..<12).map { PhotoExport.filename(index: $0, total: 12) }
        #expect(names == names.sorted(), "names must sort into capture order")
        #expect(names.first == "flim-01.jpg")
        #expect(names.last == "flim-12.jpg")
    }

    @Test("padding widens for a big roll")
    func widerPadding() {
        _ = isolate()
        let names = (0..<105).map { PhotoExport.filename(index: $0, total: 105) }
        #expect(names.first == "flim-001.jpg")
        #expect(names == names.sorted())
    }

    @Test("a small roll still gets at least two digits")
    func minimumPadding() {
        _ = isolate()
        #expect(PhotoExport.filename(index: 0, total: 3) == "flim-01.jpg")
    }

    @Test("every file is a .jpg, so Photos imports it as a photograph")
    func jpegExtension() {
        _ = isolate()
        // Without the extension the share sheet hands Photos an unknown document.
        #expect(PhotoExport.filename(index: 0, total: 1).hasSuffix(".jpg"))
    }



    @Test("a photo that fails to download reports nil rather than an empty file")
    func failedDownloadIsReported() async {
        // The caller counts what came back to decide between "saved everything", "saved some" and
        // "saved nothing". A zero-byte file masquerading as a photo would make it claim success
        // and hand Photos an unopenable image.
        let root = isolate()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = PhotoExport.begin()

        let unreachable = URL(string: "https://localhost:1/definitely-not-there.jpg")!
        let result = await PhotoExport.download(unreachable, into: dir, index: 0, total: 1)
        #expect(result == nil)

        let left = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        #expect(left.isEmpty, "a failed download must not leave a partial file behind")
    }

    // MARK: - Two exports at once

    @Test("two exports never share a directory")
    func exportsAreIsolated() {
        // "Save all" runs in a detached Task that outlives the view, so starting one on a big
        // roll, backing out, and starting another is an ordinary sequence. When both wrote into
        // one directory with index-based names, the second export's cleanup deleted the first's
        // files mid-write and both wrote flim-01.jpg over each other, so one roll could be shared
        // as another. No error at any point, because each individual write succeeded.
        let root = isolate()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = PhotoExport.begin()
        let second = PhotoExport.begin()
        #expect(first != second)
    }

    @Test("starting a second export does not disturb the first's files")
    func secondExportLeavesTheFirstAlone() throws {
        let root = isolate()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = PhotoExport.begin()
        let inFlight = first.appendingPathComponent(PhotoExport.filename(index: 0, total: 9))
        try Data("roll A photo".utf8).write(to: inFlight)

        _ = PhotoExport.begin()   // a second roll's export starts while the first is mid-download

        #expect(FileManager.default.fileExists(atPath: inFlight.path),
                "the first export's photos must survive a second export starting")
        #expect(try Data(contentsOf: inFlight) == Data("roll A photo".utf8),
                "and must not be overwritten by the second export's identical filenames")
    }

    @Test("an export still being written is never pruned, however slow the network")
    func activeExportSurvivesPruning() throws {
        // Pruning is by modification time precisely so a slow download cannot have its own
        // directory collected out from under it.
        let root = isolate()
        defer { try? FileManager.default.removeItem(at: root) }

        let active = PhotoExport.begin()
        try Data("just written".utf8).write(to: active.appendingPathComponent("flim-01.jpg"))

        PhotoExport.pruneStale()
        #expect(FileManager.default.fileExists(atPath: active.path))
    }

    @Test("an export that has gone quiet is collected")
    func staleExportIsPruned() throws {
        let root = isolate()
        defer { try? FileManager.default.removeItem(at: root) }

        let old = PhotoExport.begin()
        try Data("finished long ago".utf8).write(to: old.appendingPathComponent("flim-01.jpg"))
        // Backdate it past the staleness window.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-PhotoExport.staleAfter - 60)],
            ofItemAtPath: old.path)

        PhotoExport.pruneStale()
        #expect(!FileManager.default.fileExists(atPath: old.path))
    }
}
