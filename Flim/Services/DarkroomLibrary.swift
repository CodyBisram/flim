import Foundation
import Observation

/// 1.7's Darkroom, kept on the phone: every kept shot's row (not its pixels), so the Darkroom
/// opens on the whole library at once and scrolls back through every month without paging.
///
/// Rows only. Thumbnails already persist in `DiskImageCache` (keyed by path, read before any URL
/// is signed), so a shot seen once draws offline; this adds the list that says which shots exist.
/// About a kilobyte a row, so even five thousand shots is a few megabytes on disk.
///
/// Kept in step with the server three ways, cheapest first:
///  1. The head: the newest page is re-read on every sync and replaces what it covers, so new
///     shots, renditions that landed after upload, and shots deleted on another phone near the
///     top all settle.
///  2. The backfill: until the oldest shot has been reached once, older pages are read in the
///     background and appended; the timeline shows what has arrived and says it is still loading.
///  3. The month check: once complete, each month's count from `darkroom_month_summary_v2` is
///     compared with the local one, and only a month that differs is read again and replaced.
///
/// Deletes made here leave the library as soon as the server confirms them (`remove`). One file
/// per account in Application Support; another account never reads it, and `reset` (account
/// change, sign-out) drops what is in memory.
@MainActor
@Observable
final class DarkroomLibrary {
    static let shared = DarkroomLibrary()

    /// The whole library as known, newest first (`taken_at DESC, id DESC`, the server's order).
    private(set) var photos: [Photo] = [] {
        didSet { revision &+= 1 }
    }
    /// Bumped on every change to `photos`, so a screen can follow the library without comparing
    /// thousands of rows to notice.
    private(set) var revision = 0
    /// The backfill has reached the oldest shot at least once.
    private(set) var isComplete = false
    private(set) var isSyncing = false
    /// The last sync failed before it learned anything; nil once one succeeds.
    private(set) var syncError: String?
    /// Whose library this is. Nothing is shown for anyone else.
    private(set) var userId: UUID?
    /// The file had been read (or there was none) for `userId`.
    private(set) var isLoaded = false

    private var syncTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    /// Rows per request: big enough that a first backfill of a few thousand shots is a handful of
    /// round trips, well under PostgREST's 1000-row cap.
    static let pageSize = 500
    /// How many of the newest rows every sync re-reads.
    static let headSize = 200

    // MARK: - Opening

    /// Reads this account's saved library, if any. Cheap to call on every appear.
    func open(userId: UUID) {
        guard self.userId != userId || !isLoaded else { return }
        syncTask?.cancel()
        self.userId = userId
        photos = []
        isComplete = false
        syncError = nil
        if let saved = Self.read(userId: userId) {
            photos = saved.photos
            isComplete = saved.complete
        }
        isLoaded = true
    }

    /// Account change or sign-out: forget what is in memory. The file stays, and is read again
    /// only by the same account.
    func reset() {
        syncTask?.cancel()
        syncTask = nil
        userId = nil
        photos = []
        isComplete = false
        isSyncing = false
        syncError = nil
        isLoaded = false
    }

    // MARK: - Changes made on this phone

    /// Shots the server confirmed deleted.
    func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let before = photos.count
        photos.removeAll { ids.contains($0.id) }
        if photos.count != before { scheduleSave() }
    }

    // MARK: - Syncing

    /// Brings the library up to date. One sync at a time; a second call while one runs waits on it.
    func sync(photoService: PhotoService, timezone: String = TimeZone.current.identifier) async {
        guard let uid = userId else { return }
        if let running = syncTask { await running.value; return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runSync(userId: uid, photoService: photoService, timezone: timezone)
        }
        syncTask = task
        await task.value
        syncTask = nil
    }

    private func runSync(userId uid: UUID, photoService: PhotoService, timezone: String) async {
        isSyncing = true
        defer { isSyncing = false }
        let epoch = AccountEpoch.current
        func current() -> Bool { AccountEpoch.isCurrent(epoch) && userId == uid && !Task.isCancelled }

        // 1. The head.
        do {
            var head: [Photo] = []
            var cursor: PhotoService.PhotoCursor?
            var reachedEnd = false
            let known = Set(photos.map(\.id))
            // Read until a page overlaps what is already known, so a long absence with more than
            // one page of new shots still joins up with the saved rows. A short page is the end
            // of the whole library.
            while true {
                let page = try await photoService.fetchDarkroomPage(userId: uid, limit: Self.headSize, before: cursor)
                guard current() else { return }
                head += page.photos
                cursor = page.next
                if page.photos.count < Self.headSize || cursor == nil { reachedEnd = true; break }
                if known.isEmpty || page.photos.contains(where: { known.contains($0.id) }) { break }
            }
            photos = DarkroomLibraryMerge.replacingHead(photos, with: head, reachedEnd: reachedEnd)
            if reachedEnd { isComplete = true }
            syncError = nil
            scheduleSave()
        } catch {
            guard current() else { return }
            syncError = UserFacingError.messageIfNotCancelled(for: error)
            return
        }

        // 2. The backfill.
        while !isComplete, current() {
            guard let oldest = photos.last else { isComplete = true; break }
            let cursor = PhotoService.PhotoCursor(column: .takenAt, sortDate: oldest.takenAt, id: oldest.id)
            guard let page = try? await photoService.fetchDarkroomPage(userId: uid, limit: Self.pageSize, before: cursor),
                  current() else { break }
            photos = DarkroomLibraryMerge.appendingOlder(photos, page.photos)
            if page.photos.count < Self.pageSize { isComplete = true }
            scheduleSave()
        }

        // 3. The month check.
        guard isComplete, current(),
              let summaries = await photoService.darkroomMonthSummaryV2(timezone: timezone, covers: 1),
              current() else { return }
        let stale = DarkroomLibraryMerge.monthsToRefetch(local: photos, server: summaries)
        for month in stale {
            guard let rows = await fetchMonth(month, userId: uid, photoService: photoService), current() else { continue }
            photos = DarkroomLibraryMerge.replacingMonth(photos, month: month, with: rows)
            scheduleSave()
        }
    }

    /// Every kept shot in one calendar month, read from its upper edge down; nil on failure.
    func fetchMonth(_ month: DarkroomYearMonth, userId uid: UUID, photoService: PhotoService) async -> [Photo]? {
        var rows: [Photo] = []
        var cursor: PhotoService.PhotoCursor? = PhotoService.anchoredSeedCursor(before: month.upperEdge())
        while let at = cursor {
            guard let page = try? await photoService.fetchDarkroomPage(userId: uid, limit: Self.pageSize, before: at) else {
                return nil
            }
            let inMonth = page.photos.filter { DarkroomYearMonth(night: $0.takenAt) == month }
            rows += inMonth
            // Done once a page runs past the month's start, or the library ends.
            if inMonth.count < page.photos.count || page.photos.count < Self.pageSize { break }
            cursor = page.next
        }
        return rows
    }

    /// Makes sure a month is in the library (a jump from Year or All time during the backfill).
    func ensureMonth(_ month: DarkroomYearMonth, photoService: PhotoService) async {
        guard let uid = userId, !photos.contains(where: { DarkroomYearMonth(night: $0.takenAt) == month }) else { return }
        guard let rows = await fetchMonth(month, userId: uid, photoService: photoService), userId == uid else { return }
        photos = DarkroomLibraryMerge.replacingMonth(photos, month: month, with: rows)
        scheduleSave()
    }

    // MARK: - Thumbnails ahead of the scroll

    /// Fetches the thumbnails the phone doesn't have yet, newest first, a batch at a time, so
    /// scrolling far back draws without waiting and works offline afterwards. Bounded by
    /// `limit` and by `DiskImageCache`'s own size budget; stops when cancelled (the Darkroom
    /// leaving the screen) or the account changes.
    func warmThumbnails(photoService: PhotoService, scale: CGFloat, limit: Int = 1500) async {
        guard let uid = userId else { return }
        let candidates = photos.prefix(limit).filter { $0.isReady }
        var index = 0
        while index < candidates.count {
            guard !Task.isCancelled, userId == uid else { return }
            let batch = Array(candidates[index..<min(candidates.count, index + 60)])
            index += 60
            let missing = batch.filter { !DiskImageCache.hasRaw(path: $0.displayPath) }
            guard !missing.isEmpty else { continue }
            let urls = await photoService.signedURLs(for: missing.map(\.displayPath))
            guard !Task.isCancelled, userId == uid else { return }
            // Three at a time, leaving room for the frames on screen.
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                for photo in missing {
                    guard let url = urls[photo.displayPath] else { continue }
                    if next >= 3 { await group.next() }
                    group.addTask { _ = await ImageLoader.fetch(url: url, maxPixel: 400, scale: scale, cacheKey: photo.displayPath) }
                    next += 1
                }
            }
        }
    }

    // MARK: - Disk

    nonisolated private struct Saved: Codable, Sendable {
        var version = 1
        var photos: [Photo]
        var complete: Bool
    }

    nonisolated private static func fileURL(userId: UUID) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("DarkroomLibrary", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(userId.uuidString).json")
    }

    nonisolated private static func read(userId: UUID) -> Saved? {
        guard let url = fileURL(userId: userId), let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let saved = try? decoder.decode(Saved.self, from: data), saved.version == 1 else { return nil }
        return saved
    }

    /// Coalesced: a backfill writes once it settles, not once per page.
    private func scheduleSave() {
        guard let uid = userId else { return }
        saveTask?.cancel()
        let snapshot = Saved(photos: photos, complete: isComplete)
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let url = Self.fileURL(userId: uid) else { return }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    #if DEBUG
    /// Demo routes: a library filled from fixtures, never synced or saved.
    func installFixture(_ fixture: [Photo], userId: UUID) {
        syncTask?.cancel()
        self.userId = userId
        photos = fixture.sorted { $0.takenAt != $1.takenAt ? $0.takenAt > $1.takenAt : $0.id.uuidString > $1.id.uuidString }
        isComplete = true
        isLoaded = true
    }
    #endif
}

/// The library's merge rules, pure so they are pinned by tests.
enum DarkroomLibraryMerge {
    /// Server order: newest first, ties by id descending (uppercase uuid string order is the byte
    /// order Postgres compares `uuid` in).
    static func ordered(_ photos: [Photo]) -> [Photo] {
        photos.sorted { a, b in
            a.takenAt != b.takenAt ? a.takenAt > b.takenAt : a.id.uuidString > b.id.uuidString
        }
    }

    /// The fresh newest rows replace everything they span: a saved row as new as the head's
    /// oldest that the head no longer has was deleted (or un-kept) on the server. Older saved
    /// rows stay. `reachedEnd`: the head is the whole library, so nothing older survives either.
    static func replacingHead(_ saved: [Photo], with head: [Photo], reachedEnd: Bool) -> [Photo] {
        guard let floor = head.last else { return reachedEnd ? [] : saved }
        if reachedEnd { return ordered(head) }
        let headIds = Set(head.map(\.id))
        let older = saved.filter { !headIds.contains($0.id) && isOlder($0, than: floor) }
        return ordered(head + older)
    }

    /// An older page joins the end; anything it repeats keeps the newer copy.
    static func appendingOlder(_ saved: [Photo], _ page: [Photo]) -> [Photo] {
        let known = Set(saved.map(\.id))
        return ordered(saved + page.filter { !known.contains($0.id) })
    }

    /// One month's rows, replaced wholesale with what the server has for it now.
    static func replacingMonth(_ saved: [Photo], month: DarkroomYearMonth, with rows: [Photo]) -> [Photo] {
        let kept = saved.filter { DarkroomYearMonth(night: $0.takenAt) != month }
        let incoming = Set(rows.map(\.id))
        return ordered(kept.filter { !incoming.contains($0.id) } + rows)
    }

    /// Months whose kept-shot count differs between the server's summary and the library,
    /// including months only one side has.
    static func monthsToRefetch(local: [Photo], server: [DarkroomMonthSummaryV2]) -> [DarkroomYearMonth] {
        var localCounts: [DarkroomYearMonth: Int] = [:]
        for photo in local { localCounts[DarkroomYearMonth(night: photo.takenAt), default: 0] += 1 }
        var serverCounts: [DarkroomYearMonth: Int] = [:]
        for row in server { serverCounts[row.yearMonth] = row.shotCount }
        let months = Set(localCounts.keys).union(serverCounts.keys)
        return months.filter { localCounts[$0, default: 0] != serverCounts[$0, default: 0] }
            .sorted { ($0.year, $0.month) > ($1.year, $1.month) }
    }

    /// `a` comes after `b` in server order (older, or the same instant with a smaller id).
    static func isOlder(_ a: Photo, than b: Photo) -> Bool {
        a.takenAt != b.takenAt ? a.takenAt < b.takenAt : a.id.uuidString < b.id.uuidString
    }
}
