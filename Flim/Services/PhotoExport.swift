import Foundation

/// Downloads photos to temp files for "Save all", so a big roll can't take the app down.
///
/// The original version collected every photo as a `UIImage` in an array and handed the array to
/// the share sheet. That holds the WHOLE roll in memory at once, and the rolls this feature exists
/// for are the big ones: there are 73- and 75-shot rolls in the field today. Once decoded, a
/// full-resolution frame is roughly 48MB. The likely outcome on a large roll is a jetsam kill,
/// which reads to the person as "saving my photos crashes the app".
///
/// Writing each one to disk as it arrives keeps memory flat at a single photo regardless of roll
/// size, and `UIActivityViewController` takes file URLs natively, so Photos imports them exactly
/// as before.
///
/// # Why every export gets its own directory
///
/// An export is started from a button as a detached `Task`, so it is NOT cancelled when the view
/// goes away. That is deliberate (backing out of a roll should not silently abandon a save you
/// asked for), but it means two exports can be in flight at once: start one on a 75-shot roll,
/// back out while it is still downloading, open another roll, start a second.
///
/// With a single shared directory and index-based filenames, that is a photo-mixing bug. The
/// second export's cleanup deletes the directory the first is still writing into, and both then
/// write `flim-01.jpg`, `flim-02.jpg`, … over each other. Whichever finishes last owns the files,
/// while the first export's share sheet still holds those exact URLs, so one friend group's roll
/// can be saved and shared as another's, with no error at any point because every individual
/// write succeeded.
///
/// Scoping each export to its own directory removes the shared mutable state entirely, which is
/// cheaper than trying to coordinate two independent tasks.
enum PhotoExport {

    /// Container for all exports. Injectable so tests never touch the real temp directory.
    static var root: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("FlimShareExport", isDirectory: true)

    /// How long an untouched export directory is kept before it is collected.
    ///
    /// Pruning is by MODIFICATION time, not creation time, so an export that is still actively
    /// writing is never collected out from under itself no matter how slow the network is.
    static let staleAfter: TimeInterval = 3600

    /// Starts an export and returns the directory it owns.
    ///
    /// Also collects previous exports that have gone quiet. Cleanup happens here rather than at
    /// the end of an export because the share sheet reads the files AFTER the export returns:
    /// deleting on the way out would hand the system paths to files that no longer exist.
    static func begin(now: Date = .now) -> URL {
        pruneStale(now: now)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Removes export directories that have not been written to for `staleAfter`.
    static func pruneStale(now: Date = .now) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root,
                                                        includingPropertiesForKeys: [.contentModificationDateKey],
                                                        options: [.skipsHiddenFiles])
        else { return }
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            // No date means we cannot prove it is idle, so leave it alone. An orphaned directory
            // costs disk; a wrongly deleted one costs someone their photos mid-save.
            guard let modified, now.timeIntervalSince(modified) > staleAfter else { continue }
            try? fm.removeItem(at: entry)
        }
    }

    /// A stable, ordered, Photos-friendly filename.
    ///
    /// Zero-padded so the share sheet and Photos keep capture order rather than sorting
    /// "flim-10" before "flim-2", and `.jpg` because an extensionless file is imported as an
    /// unknown document instead of a photograph.
    static func filename(index: Int, total: Int) -> String {
        let width = max(2, String(total).count)
        return "flim-\(String(format: "%0\(width)d", index + 1)).jpg"
    }

    /// Downloads one photo into a specific export's directory. Returns nil if it could not be
    /// fetched or written, so the caller can report a partial result rather than silently
    /// shipping a short roll.
    static func download(_ url: URL, into directory: URL, index: Int, total: Int) async -> URL? {
        guard let (data, _) = try? await URLSession.shared.data(from: url), !data.isEmpty
        else { return nil }
        let destination = directory.appendingPathComponent(filename(index: index, total: total))
        do {
            try data.write(to: destination, options: .atomic)
            return destination
        } catch {
            return nil
        }
    }
}
