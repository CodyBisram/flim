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
    /// This frame's burst, if `BurstDetector` (or a live capture on some other member's phone)
    /// matched it to a near-duplicate shot within a few seconds. Shared by every frame in the
    /// burst; `nil` for a lone shot, or for one whose analysis hasn't landed yet (the first frame
    /// of a pair only learns its group once the SECOND frame arrives and patches it in, see
    /// `BurstDetector`). Optional so a photo from before this column existed, or one this device's
    /// own Vision pass simply failed on, decodes as ungrouped rather than failing to decode.
    var burstGroup: UUID?
    /// A [0, 1] sharpness score from the SAME capture-time pass, used to pick a burst's cover
    /// frame (`BurstGrouping.sharpest`). `nil` alongside `burstGroup == nil` for a photo that
    /// predates this column, or whose on-device analysis failed; a lone (non-burst) photo may
    /// still carry a score even though nothing currently reads it.
    var sharpness: Double?

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
        case burstGroup = "burst_group"
        case sharpness
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
    /// Written at insert time, from the SAME capture-time analysis pass as the sidecar `photos`
    /// row's other fields; see `Photo.burstGroup`/`sharpness`. Both default nil so every other
    /// insert site (seeding, the personal fallback) compiles unchanged.
    var burstGroup: UUID?
    var sharpness: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case rollId = "roll_id"
        case storagePath = "storage_path"
        case thumbPath = "thumb_path"
        case feedPath = "feed_path"
        case developsAt = "develops_at"
        case isSorted = "is_sorted"
        case burstGroup = "burst_group"
        case sharpness
    }
}
