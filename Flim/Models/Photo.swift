import Foundation

struct Photo: Codable, Identifiable {
    let id: UUID
    let userId: UUID
    let rollId: UUID?
    let storagePath: String
    /// Small thumbnail for grids/feeds; nil for photos taken before thumbnails existed.
    var thumbPath: String?
    /// Mid-size (~1400px) rendition for feed cards; nil for photos taken before it existed.
    var feedPath: String?
    let takenAt: Date
    let developsAt: Date
    var isDeveloped: Bool
    var caption: String?
    var isSorted: Bool = true

    var isReady: Bool { Date.now >= developsAt }
    /// Path to use in grids/feeds, the thumbnail if present, else the full image.
    var displayPath: String { thumbPath ?? storagePath }

    /// The ~1400px rendition, already wider than any phone screen at 3x, so it reads as
    /// pixel-identical to the full 2048px image for roughly a third of the bytes.
    ///
    /// This is the full-screen path for the reveal, the roll carousel, AND `PhotoPagerView`,
    /// which pinch-zooms the rendered frame itself rather than swapping to a higher-resolution
    /// source, so the extra bytes of the full image would buy it nothing either. `storagePath`
    /// stays reserved for export and save-to-camera-roll paths, which genuinely need the master.
    /// Falls back to the full image for photos taken before renditions existed, or whose
    /// rendition upload hasn't landed yet.
    var viewPath: String { feedPath ?? storagePath }

    var timeUntilDeveloped: TimeInterval { developsAt.timeIntervalSinceNow }

    /// Whether either downsized rendition never made it to Storage.
    ///
    /// 9% of the library is in this state: renditions are uploaded after the row exists, with two
    /// attempts three seconds apart, so a kill, a background, or a dropout longer than that loses
    /// them for good. A photo in this state falls back to `storagePath` everywhere, which means a
    /// grid cell downloads 1250 kB instead of 123 kB, on every view, forever.
    var needsRenditionRepair: Bool { thumbPath == nil || feedPath == nil }

    /// Every object this photo owns in Storage.
    ///
    /// Deleting a photo has to remove ALL of these, and forgetting one is invisible: the row
    /// disappears, the grid updates, the photo is gone as far as anyone can see, and the file is
    /// billed every month forever. `feedPath` was missing from both delete paths from the day it
    /// was added, which is how 286 objects and 160 MB accumulated before anyone counted.
    ///
    /// The list lives here, on the model, so adding a fourth rendition means adding it in ONE
    /// place rather than remembering two call sites.
    var allStoragePaths: [String] { [storagePath, thumbPath, feedPath].compactMap { $0 } }

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case rollId = "roll_id"
        case storagePath = "storage_path"
        case thumbPath = "thumb_path"
        case feedPath = "feed_path"
        case takenAt = "taken_at"
        case developsAt = "develops_at"
        case isDeveloped = "is_developed"
        case caption
        case isSorted = "is_sorted"
    }
}

struct PhotoReaction: Codable, Identifiable {
    let id: UUID
    let photoId: UUID
    let userId: UUID
    let emoji: String

    enum CodingKeys: String, CodingKey {
        case id
        case photoId = "photo_id"
        case userId = "user_id"
        case emoji
    }
}

// Insert-only payload, omits auto-generated fields
struct InsertPhoto: Encodable {
    let id: UUID
    let userId: UUID
    let rollId: UUID?
    let storagePath: String
    var thumbPath: String?
    var feedPath: String?
    let developsAt: Date
    var isSorted: Bool = true

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case rollId = "roll_id"
        case storagePath = "storage_path"
        case thumbPath = "thumb_path"
        case feedPath = "feed_path"
        case developsAt = "develops_at"
        case isSorted = "is_sorted"
    }
}
