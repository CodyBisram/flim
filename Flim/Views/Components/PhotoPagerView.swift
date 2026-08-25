import SwiftUI

/// How far the photo follows the finger during a paging swipe. At the first and last shot it
/// resists instead of sliding into blank space, so overswiping reads as a wall rather than dead
/// input. Free function so the feel is testable without a view.
///
/// `PhotoPagerView` itself no longer calls this (native `TabView` paging owns that feel now, see
/// its own header comment), but `RollCarouselView` still hand-rolls its pager the same way this
/// file used to, so the function and its tests stay.
func pagingDragOffset(width: CGFloat, index: Int, count: Int, resistance: CGFloat = 0.2) -> CGFloat {
    let atStart = index == 0 && width > 0
    let atEnd = index == count - 1 && width < 0
    return (atStart || atEnd) ? width * resistance : width
}

/// Which way a finished horizontal drag should page: -1 back, +1 forward, or nil when it didn't
/// travel far enough to count as a swipe. See `pagingDragOffset`'s own note on who still uses this.
func pagingStep(forDragWidth width: CGFloat, threshold: CGFloat = 60) -> Int? {
    guard abs(width) > threshold else { return nil }
    return width < 0 ? 1 : -1
}

/// A photo's resolved URL in `PhotoPagerView`, plus whether that URL is the real upgrade
/// (`viewPath`, the ~1400px feed rendition or, for the ~4% of photos with no feed rendition yet,
/// the full master) or just the grid's seeded thumbnail standing in for it.
struct PhotoResolutionState: Equatable {
    var url: URL?
    var isFull: Bool
}

/// Merges one `resolveAround` attempt into a photo's resolution state. Pure and free-standing so
/// the retry behaviour is testable without a network or a view: `PhotoPagerView.resolveAround`
/// used to key the whole upgrade attempt off `resolvedURLs[photo.id] == nil`, but the thumbnail
/// line right above it had already filled that slot, so once the upgrade's `signedURL` call
/// failed once (a network hiccup), the guard was permanently true and the upgrade could never be
/// attempted again for the rest of the session, leaving a thumbnail stretched to full screen.
///
/// `current.isFull` is the real guard now: a photo that already has its full URL is left alone
/// (settles, does not loop, matching photos with no feed rendition whose `viewPath` falls back to
/// the master and resolves on the first attempt), while anything short of that is retried on
/// every call, i.e. every time that photo re-enters the ±1 swipe window, rather than being
/// defeated forever by one failed attempt.
func resolvePhotoUpgrade(current: PhotoResolutionState, thumbnail: URL?, fullFetch: URL?) -> PhotoResolutionState {
    guard !current.isFull else { return current }
    var next = current
    if next.url == nil, let thumbnail {
        next.url = thumbnail
    }
    if let fullFetch {
        next.url = fullFetch
        next.isFull = true
    }
    return next
}

/// Which storage object's key a resolved URL must be filed under: `displayPath` (the grid
/// thumbnail's own object) while only the seed is in (`isFull == false`), `viewPath` (the real
/// upgrade's object) once it has landed. Pure and free-standing so the rule is pinned by a test
/// rather than only by eye.
///
/// THE INVARIANT this exists to protect: a `CachedImage`'s `url` and `cacheKey` must always name
/// the SAME storage object. `ImageLoader.fetch` downloads whatever `url` currently points to and
/// files those bytes under `cacheKey`, and a cache hit on `cacheKey` beats `url` on every later
/// load. Pairing a thumbnail URL (the seed phase, `isFull == false`) with the `viewPath` key
/// would file thumbnail-quality bytes under the full-res key, and once that entry exists in
/// memory, a later successful full-res fetch is never even attempted: `CachedImage.load()` hits
/// the poisoned cache entry first and returns the stretched thumbnail forever, across launches,
/// from one transient `viewPath` fetch failure. See `PhotoPagerTests` for the pin.
func resolvedCacheKey(isFull: Bool, displayPath: String, viewPath: String) -> String {
    isFull ? viewPath : displayPath
}

/// The single swipeable full-screen photo viewer, opened at whichever grid photo was tapped.
/// One component for both the Darkroom and a roll's grid (it replaced three near-duplicate views:
/// FullScreenPhotoView, DarkroomPhotoPagerView, RollPhotoPagerView, which had drifted apart and
/// carried three verbatim copies of the share composer). Feature flags cover the differences:
/// the Darkroom shows own photos only (no reactions/comments/attribution, just a date), a roll
/// grid shows everyone's shots (reactions, comments, photographer handle, and the
/// own-vs-report branch, all derived per photo).
///
/// Architecture: header and footer are declared ONCE, outside the pager, reading whichever photo
/// is current. Only the image (plus its own zoom state) is swapped as you swipe, so mid-swipe you
/// never see two competing captions/credits. Report-vs-manage is derived from
/// ownership, so a Darkroom (all-own) never shows report and a roll shows it per photo, with no
/// extra flag.
///
/// `showsNightRack` is the Darkroom redesign's mode flag (Phase C): the same engine, but with a
/// different header, a single-row film rack under the photograph, and a status+actions row
/// instead of the plain caption + share pill. Roll grids and the widget's single-photo case leave
/// it false and get today's chrome unchanged.
struct PhotoPagerView: View {
    @Environment(\.flimAccent) private var accent
    let photos: [Photo]                 // same order as the grid
    var startIndex: Int = 0
    /// Grid's already-resolved thumbnail URLs, keyed by photo id, seeds each page instantly.
    let signedURLs: [UUID: URL]
    var showsReactions: Bool = false
    var showsComments: Bool = false
    /// Show the photographer's @handle above the date (roll grid); off shows the date alone.
    var showsAttribution: Bool = false
    /// The Darkroom's own chrome: a night-scoped header, a single-row rack under the photograph,
    /// and a status+actions row. See the type's own doc.
    var showsNightRack: Bool = false
    @State private var profileRoute: ProfileRoute?
    /// A profile chosen inside the comment sheet, opened once that sheet has closed.
    @State private var pendingProfile: ProfileRoute?
    var memberNames: [UUID: String] = [:]
    /// The roll name for a given photo's rollId (nil for a personal, non-roll shot), used only in
    /// the delete-confirmation wording. A roll grid passes a closure returning its own name.
    var rollName: (UUID?) -> String? = { _ in nil }
    var onDelete: () -> Void = {}

    @Environment(PhotoService.self) private var photoService
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selection: Int
    /// Upgraded from the seeded thumbnail to full-res lazily, windowed to ±1 around `selection`
    /// (the neighbours you can reach with one swipe), so opening a big roll doesn't fire a fetch
    /// for every shot in it at once.
    @State private var resolvedURLs: [UUID: URL] = [:]
    /// Which photos in `resolvedURLs` hold the real upgrade rather than just the seeded
    /// thumbnail, see `resolvePhotoUpgrade`. A photo not in here is retried on its next visit to
    /// the ±1 window instead of being stuck on the thumbnail for the rest of the session.
    @State private var fullyResolvedIds: Set<UUID> = []
    /// Photos whose full-res fetch has FAILED (night-rack mode only). The page becomes a well
    /// with a Retry drawn in the photograph's place, and the same photo's rack frame becomes an
    /// empty outlined well, matching `FeedUnitCard`'s `failedFrames`.
    @State private var failedPhotoIds: Set<UUID> = []
    /// Bumped by `retryFailedImage`, matching `FeedUnitCard`'s own `retryTokens`: folded into the
    /// page's `.id` so a retry mounts a genuinely fresh `CachedImage` rather than reusing one that
    /// may still be holding its own failed internal state.
    @State private var retryTokens: [UUID: Int] = [:]
    @State private var reportedIds: Set<UUID> = []
    @State private var reactions: [PhotoReaction] = []
    /// Drives the heart that blooms over a double tap, matching the feed's.
    @State private var heartBurst = false
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    /// The scale the photo was resting at when the current pinch started, so releasing returns it
    /// there. Nil when no pinch is in flight.
    @State private var pinchStart: CGFloat?
    /// Where the current pinch went down, so the photo grows from there instead of its middle.
    @State private var zoomAnchor: UnitPoint = .center
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    @State private var pendingDeletePhoto: Photo?
    @State private var showReportConfirm = false
    @State private var shareItem: ShareImage?
    @State private var preparingShare = false
    @State private var showShareComposer = false
    @State private var shareCaptionDraft = ""
    @State private var pendingTags: [PendingTag] = []
    /// Night-rack mode's own share moment (Phase D): the promoted `Share` capsule opens
    /// `ShareToFeedSheet` for THIS photo, via `.sheet(item:)` rather than a bool, so the sheet's
    /// own `dismiss()` (on Share, or a plain swipe-down) automatically nils this out. Deliberately
    /// separate from `composerPhoto`, which is the legacy roll-pager composer's own target: the
    /// two flows must never share one variable, same reasoning as `taggingPhoto` vs.
    /// `composerPhoto` above.
    @State private var shareSheetPhoto: Photo?
    @State private var showTagSheet = false
    /// Night-rack mode's OTHER tag sheet: editing an ALREADY-shared photo's tags (the promoted
    /// "Tag" action), as distinct from `showTagSheet` above, which is the share composer's own
    /// "Tag people" step for a photo not shared yet. Never both true at once: "Tag" only exists
    /// once a shot is shared (see `PhotoPagerView`'s own doc, the absolute rule that unshared
    /// shots never get tagging in any form).
    @State private var showEditTags = false
    @State private var editingTags: [PendingTag] = []
    /// Captured when "Tag" is tapped, so the sheet's thumbnail and `setTags` both target the
    /// right shot even if `selection` moves while the sheet is up. Deliberately separate from
    /// `composerPhoto`: that one belongs to the share-composer flow, and the two can never be
    /// allowed to clobber each other's target.
    @State private var taggingPhoto: Photo?
    @State private var taggingPostId: UUID?
    /// In-flight guard for `beginTagging`'s post lookup, disabling the Tag capsule so the
    /// stale-write race needs an actual photo swap mid-flight, which the identity guard inside
    /// the task then catches.
    @State private var isLoadingTags = false
    @State private var showComments = false
    @State private var showSharedToast = false
    /// A failure that must not fail silently: a delete that didn't happen, a share that couldn't
    /// be prepared, a profile photo that didn't update. Shares the same top overlay slot as
    /// `showSharedToast`, they're never both true at once.
    @State private var errorToast: String?
    /// Captured when an action starts, rather than re-derived from `current` when it finishes,
    /// defensive against `selection` changing while a sheet/dialog is open.
    @State private var composerPhoto: Photo?
    @State private var commentsPhoto: Photo?
    @FocusState private var captionFocused: Bool
    /// The screen's own measured width, so the night-rack photograph can be a genuinely FIXED
    /// `width x width*4/3` box rather than guessing. 393 is a reasonable first-paint fallback,
    /// same convention `DarkroomView.scrollWidth` uses.
    @State private var screenWidth: CGFloat = 393
    /// The rack row's own measured width, for its edge-fade mask.
    @State private var rackWidth: CGFloat = 393
    /// A private namespace for the rack's OWN frame views. Never wired to a real navigation
    /// transition (that lives on the call site wrapping this whole view), it exists only because
    /// `DarkroomFrameView` requires one.
    @Namespace private var rackNS
    /// Thumbnail URLs for the rack's OWN frames, keyed by `displayPath` (`maxPixel: 120`,
    /// matching `DarkroomFrameView`'s own request), resolved lazily as a night's frames appear
    /// in the rack. Deliberately separate from `resolvedURLs`, which holds the FULL `viewPath`
    /// URL the main photograph downloads: passing that as a rack thumbnail's `signedURL` would
    /// hand `CachedImage` a URL for a different Storage object than the `cacheKey` it's keying
    /// by, which is exactly the cache-key/URL mismatch the image cache's own contract warns
    /// poisons the disk cache for good. `signedURLs` (seeded by the grid) is checked first; this
    /// only fills in whatever that didn't already have, e.g. a night's frame the grid never
    /// scrolled into view.
    @State private var rackThumbURLs: [UUID: URL] = [:]
    /// Bumped by `watchDeveloping` whenever a shot in the window crosses `developsAt` while this
    /// page is already on screen, purely so reading it inside `photoPage` forces that body to
    /// re-evaluate. See `watchDeveloping`'s own doc.
    @State private var developPulse = 0

    private var current: Photo? { photos.indices.contains(selection) ? photos[selection] : nil }

    init(photos: [Photo], startIndex: Int = 0, signedURLs: [UUID: URL],
         showsReactions: Bool = false, showsComments: Bool = false, showsAttribution: Bool = false,
         showsNightRack: Bool = false,
         memberNames: [UUID: String] = [:], rollName: @escaping (UUID?) -> String? = { _ in nil },
         onDelete: @escaping () -> Void = {}) {
        self.photos = photos
        self.startIndex = startIndex
        self.signedURLs = signedURLs
        self.showsReactions = showsReactions
        self.showsComments = showsComments
        self.showsAttribution = showsAttribution
        self.showsNightRack = showsNightRack
        self.memberNames = memberNames
        self.rollName = rollName
        self.onDelete = onDelete
        _selection = State(initialValue: min(max(startIndex, 0), max(0, photos.count - 1)))
    }

    var body: some View {
        // The viewer carries its own stack so a profile PUSHES, with the system back button,
        // exactly as it does from the feed. It used to be presented as a sheet instead, which put
        // UserPageView at the root of its own stack: no back button is generated for a root, so
        // the only way out was a swipe down nobody advertises, and the ••• menu was the sole
        // control on screen. UserPageView is built to be pushed, see its own comment about
        // letting the cover show under the back button.
        NavigationStack {
            pagerBody
                // The photo viewer is full bleed; only the pushed profile wants a bar.
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(item: $profileRoute) { UserPageView(userId: $0.id) }
        }
    }

    private var pagerBody: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                pager
                    .padding(.vertical, showsNightRack ? 8 : 12)

                if showsNightRack {
                    rackSection
                } else {
                    captionLabel
                    bottomBar
                        .padding(.horizontal, 20)
                        .padding(.bottom, 44)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { screenWidth = $0 }
        .ignoresSafeArea(.container)
        .statusBarHidden()
        // Sheet to sheet: the profile cannot be presented until the comment sheet has finished
        // dismissing, so the id waits in `pendingProfile` and onDismiss opens it.
        .sheet(isPresented: $showComments, onDismiss: {
            if let pending = pendingProfile { pendingProfile = nil; profileRoute = pending }
        }) {
            PhotoCommentsSheet(photoId: (commentsPhoto ?? current)?.id ?? UUID(),
                               memberNames: memberNames) { pendingProfile = ProfileRoute(id: $0) }
        }
        .sheet(isPresented: $showTagSheet) {
            // Same `resolvedCacheKey` phase rule as `photoPage`: `url` here is whatever
            // `resolvedURLs` currently holds for this photo, which is the thumbnail seed until
            // `fullyResolvedIds` says otherwise, so the key has to track that, not assume `viewPath`.
            TagPhotoSheet(url: composerPhoto.flatMap { resolvedURLs[$0.id] },
                          cacheKey: composerPhoto.map {
                              resolvedCacheKey(isFull: fullyResolvedIds.contains($0.id),
                                                displayPath: $0.displayPath, viewPath: $0.viewPath)
                          },
                          tags: $pendingTags, rollId: composerPhoto?.rollId)
        }
        .sheet(isPresented: $showEditTags) {
            TagPhotoSheet(url: taggingPhoto.flatMap { resolvedURLs[$0.id] },
                          cacheKey: taggingPhoto.map {
                              resolvedCacheKey(isFull: fullyResolvedIds.contains($0.id),
                                                displayPath: $0.displayPath, viewPath: $0.viewPath)
                          },
                          tags: $editingTags, rollId: taggingPhoto?.rollId) {
                if let postId = taggingPostId {
                    Task { await feed.setTags(editingTags, on: postId) }
                }
            }
        }
        .overlay(alignment: .top) {
            if showSharedToast {
                Label("Shared to your page", systemImage: "checkmark.circle.fill")
                    .flimFont(14, weight: .semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 64)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if let errorToast {
                Label(errorToast, systemImage: "exclamationmark.triangle.fill")
                    .flimFont(14, weight: .semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 64)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onChange(of: selection) { _, _ in
            // Fresh photo, fresh zoom state (otherwise the last photo's zoom carries over).
            // `pinchStart` belongs to that set: leaving it behind means a pinch still in flight
            // when the page turns springs the NEW photo back to the old one's resting scale.
            scale = 1; offset = .zero; lastOffset = .zero; pinchStart = nil
            Task { await resolveAround(selection) }
        }
        .task {
            // One batched query for the whole session rather than a `hasPosted` round trip per
            // photo in `resolveAround`'s window. The Darkroom's own reload already warms this,
            // but a roll's pager (RollDetailView, MainTabView) opens straight into this view
            // with nothing preloaded, so it still needs to ask once.
            if let uid = auth.currentUser?.id { await feed.loadMyPostedPhotoIds(userId: uid) }
        }
        .task {
            await resolveAround(selection)
        }
        // Keyed on `selection`, so it cancels naturally on the next swipe (`.task(id:)`'s own
        // contract) and on dismiss, and restarts fresh for the new window. See its own doc.
        .task(id: selection) {
            guard showsNightRack else { return }
            await watchDeveloping()
        }
        // Batched for every photo in the pager, not per swipe. Only where reactions actually
        // show (a roll grid); the Darkroom's own-photos pager never renders a reaction bar.
        .task {
            if showsReactions { await photoService.fetchSuggestedEmoji(photoIds: photos.map(\.id)) }
        }
        .confirmationDialog("Delete this photo?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                guard let photo = pendingDeletePhoto else { return }
                Haptics.warning()
                isDeleting = true
                Task {
                    // `deletePhoto` only reports success once the photo is actually gone (it
                    // deliberately leaves the row in place if the Storage removal failed). Only
                    // then is it safe to close the pager, otherwise this would tell the person
                    // their photo was deleted while it is still sitting in their account.
                    let deleted = await photoService.deletePhoto(photo)
                    isDeleting = false
                    guard deleted else {
                        flashError("Couldn't delete that. Check your connection and try again.")
                        return
                    }
                    // Confirmed gone server-side (posts.photo_id cascades), so drop any post of
                    // it from the already-loaded feed too, otherwise the Feed tab keeps showing
                    // this device's own now-imageless card until the next pull-to-refresh.
                    feed.dropPost(forDeletedPhotoId: photo.id)
                    onDelete()
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) { pendingDeletePhoto = nil }
        } message: {
            Text(deleteMessage(pendingDeletePhoto))
        }
        .confirmationDialog("Report this photo?", isPresented: $showReportConfirm, titleVisibility: .visible) {
            Button("Report", role: .destructive) {
                guard let photo = current else { return }
                Task {
                    // Only mark it reported (which disables the flag button below) once the
                    // write actually lands, a failed report used to look identical to a
                    // successful one and there was no way left to retry it.
                    if await photoService.reportPhoto(photo) {
                        reportedIds.insert(photo.id)
                        Haptics.success()
                    } else {
                        Haptics.error()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Flag this for review. Thanks for keeping \(AppInfo.appName) safe.")
        }
        .sheet(item: $shareItem) { item in
            SharePreviewSheet(photo: item.image)
        }
        .sheet(item: $shareSheetPhoto) { photo in
            // Falls back to the rack's own thumbnail resolution too, matching `rackSection`'s own
            // `signedURLs[photo.id] ?? rackThumbURLs[photo.id]`: a night reached via the jump
            // sheet (never scrolled past in the grid) has no entry in `signedURLs` at all, and
            // without the fallback the compose sheet's destination thumbnail sat on a permanent
            // placeholder.
            ShareToFeedSheet(
                photo: photo,
                thumbURL: signedURLs[photo.id] ?? rackThumbURLs[photo.id],
                onSuccess: { flashSharedToast() },
                onPartialFailure: { flashError($0) }
            )
        }
        .safeAreaInset(edge: .bottom) {
            if showShareComposer { shareComposer }
        }
    }

    // MARK: - Stable chrome

    @ViewBuilder
    private var header: some View {
        if showsNightRack {
            nightRackHeader
        } else {
            legacyHeader
        }
    }

    @ViewBuilder
    private var legacyHeader: some View {
        if let photo = current {
            let isOwnPhoto = photo.userId == auth.currentUser?.id
            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(12)
                        .glassCapsule(interactive: true)
                }
                .accessibilityLabel("Close")
                Spacer()
                if showsComments {
                    Button { commentsPhoto = photo; showComments = true } label: {
                        Image(systemName: "bubble.right")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(12)
                            .glassCapsule(interactive: true)
                    }
                    .accessibilityLabel("Comments")
                }
                Button {
                    share(photo)
                } label: {
                    Group {
                        if preparingShare {
                            ProgressView().tint(.white).controlSize(.small)
                        } else {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 15, weight: .medium))
                        }
                    }
                    .frame(width: 19, height: 19)
                    .foregroundStyle(.white)
                    .padding(12)
                    .glassCapsule(interactive: true)
                }
                .disabled(preparingShare)
                .accessibilityLabel(preparingShare ? "Preparing to share" : "Share photo")
                // Own photo, a manage menu (set avatar / delete). Someone else's (only possible on
                // a roll grid), report. Derived from ownership, so a Darkroom of all-own photos
                // never shows report without needing a flag.
                if isOwnPhoto {
                    Menu {
                        Button {
                            Haptics.tap()
                            // Reports the outcome. This returns Bool so a failure can be surfaced, and
                            // three of the four call sites were dropping it: you tapped 'Set as profile
                            // photo', nothing happened, and nothing said why.
                            Task {
                                if await auth.setAvatar(fromPhotoPath: photo.storagePath) {
                                    Haptics.success()
                                } else {
                                    Haptics.error()
                                    flashError("Couldn't update your profile photo. Check your connection and try again.")
                                }
                            }
                        } label: { Label("Set as profile photo", systemImage: "person.crop.circle") }
                        Button(role: .destructive) {
                            pendingDeletePhoto = photo
                            showDeleteConfirm = true
                        } label: { Label("Delete photo", systemImage: "trash") }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(12)
                            .glassCapsule(interactive: true)
                    }
                    .accessibilityLabel("More")
                    .disabled(isDeleting)
                } else {
                    let reported = reportedIds.contains(photo.id)
                    Button { showReportConfirm = true } label: {
                        Image(systemName: reported ? "flag.fill" : "flag")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(12)
                            .glassCapsule(interactive: true)
                    }
                    .accessibilityLabel("Report photo")
                    .disabled(reported)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 60)
        }
    }

    /// The Darkroom's own header: back, the current photo's night, its position WITHIN that
    /// night, then the export share button and the same manage menu the legacy header has.
    /// Every own photo here, developing included, so there is no report branch to derive.
    @ViewBuilder
    private var nightRackHeader: some View {
        if let photo = current {
            HStack(spacing: 10) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(12)
                        .glassCapsule(interactive: true)
                }
                .accessibilityLabel("Close")

                Text(currentNightTitle)
                    .flimFont(15, weight: .medium)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text("\(currentNightPosition) of \(currentNightPhotos.count)")
                    .flimFont(12)
                    .foregroundStyle(FlimTheme.textTertiary)
                    .lineLimit(1)
                    .fixedSize()

                Spacer(minLength: 8)

                Button { share(photo) } label: {
                    Group {
                        if preparingShare {
                            ProgressView().tint(.white).controlSize(.small)
                        } else {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 15, weight: .medium))
                        }
                    }
                    .frame(width: 19, height: 19)
                    .foregroundStyle(.white)
                    .padding(12)
                    .glassCapsule(interactive: true)
                }
                .disabled(preparingShare)
                .accessibilityLabel(preparingShare ? "Preparing to share" : "Share photo")

                Menu {
                    // Setting an unrevealed shot as your profile photo would be a spoiler of your
                    // own reveal, so the action simply isn't offered until it's ready, matching
                    // the grid's own developing menu (select + delete only).
                    if photo.isReady {
                        Button {
                            Haptics.tap()
                            Task {
                                if await auth.setAvatar(fromPhotoPath: photo.storagePath) {
                                    Haptics.success()
                                } else {
                                    Haptics.error()
                                    flashError("Couldn't update your profile photo. Check your connection and try again.")
                                }
                            }
                        } label: { Label("Set as profile photo", systemImage: "person.crop.circle") }
                    }
                    Button(role: .destructive) {
                        pendingDeletePhoto = photo
                        showDeleteConfirm = true
                    } label: { Label("Delete photo", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(12)
                        .glassCapsule(interactive: true)
                }
                .accessibilityLabel("More")
                .disabled(isDeleting)
            }
            .padding(.leading, 20)
            .padding(.trailing, 20)
            .padding(.top, 60)
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        if let photo = current {
            VStack(spacing: 14) {
                if showsReactions {
                    ReactionBar(
                        defaults: photoService.reactionDefaults(for: photo.id),
                        counts: Dictionary(grouping: reactions, by: \.emoji).mapValues(\.count),
                        mine: Set(reactions.filter { $0.userId == auth.currentUser?.id }.map(\.emoji))
                    ) { toggleReaction($0, on: photo) }
                    // Fresh reaction bar per photo, matching RollCarouselView. Without this the
                    // bar is ONE instance for the whole pager session, so it sorted itself once
                    // against the first photo's reactions and every photo you swiped to after
                    // that kept that order.
                    .id(photo.id)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Own photos, and any roll photo (you're a member if you can see it), can be
                // shared to your page.
                if (photo.userId == auth.currentUser?.id || photo.rollId != nil), !showShareComposer {
                    let shared = feed.myPostedPhotoIds.contains(photo.id)
                    Button { shareToPage(photo) } label: {
                        Label(shared ? "Shared to your page" : "Share to your page",
                              systemImage: shared ? "checkmark.circle.fill" : "square.and.arrow.up")
                            .flimFont(15, weight: .semibold)
                            .foregroundStyle(shared ? .white : .black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(shared ? Color.white.opacity(0.15) : accent, in: Capsule())
                    }
                    .disabled(shared)
                }
            }
        }
    }

    /// Inline caption composer, shown at the bottom when publishing a photo to your page.
    ///
    /// Phase D split this: night-rack mode's promoted `Share` (`shareCapsule`) now opens
    /// `ShareToFeedSheet` instead, so this composer, `shareToPage`, and `confirmShare` are dead
    /// for a Darkroom viewer. They stay exactly as they were for the ONE caller left, `bottomBar`
    /// above, which only renders when `!showsNightRack`: a roll grid's own photo, or the widget's
    /// single-photo pager, still publish through this inline bar.
    private var shareComposer: some View {
        VStack(spacing: 10) {
            Button { showTagSheet = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 14))
                    Text(pendingTags.isEmpty ? "Tag people" : "\(pendingTags.count) tagged")
                        .flimFont(14)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.white.opacity(0.1), in: Capsule())
            }

            HStack(spacing: 10) {
                TextField("Add a caption…", text: $shareCaptionDraft, axis: .vertical)
                    .lineLimit(1...3)
                    .focused($captionFocused)
                    .flimFont(15)
                    .foregroundStyle(.white)
                    .tint(accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.14), in: Capsule())
                Button {
                    showShareComposer = false
                    captionFocused = false
                } label: {
                    Text("Cancel").flimFont(13).foregroundStyle(.white.opacity(0.6))
                }
                Button { confirmShare() } label: {
                    Text("Share")
                        .flimFont(14, weight: .semibold)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(accent, in: Capsule())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    // MARK: - Pager

    /// The fixed 3:4 photograph, full width, edge to edge (night-rack mode) vs. the flexible
    /// fill between header and footer every other caller has always had. Two genuinely
    /// different frame APIs, so the split cannot collapse into one call: night-rack pins an
    /// EXACT `.frame(width:height:)` like the feed's pager (that fixed box is the swipe
    /// pattern's geometry precondition), while the roll/widget path needs
    /// `.frame(maxWidth: .infinity, maxHeight: .infinity)`. Passing `.infinity` as an exact
    /// width/height is not "fill what the parent offers", it reports an infinite size upward
    /// and breaks layout at runtime while compiling clean.
    // (Frame application lives in `PageFrameModifier` below.)

    private var pager: some View { pagerCore }

    /// Native page-style `TabView`, per the ratified swipe pattern (see `FeedUnitCard.pager`):
    /// FIXED geometry, and every page STRUCTURALLY STABLE at every index (the same view for
    /// `photo.id`, always present in the `ForEach`, never swapped for a placeholder as the
    /// selection window moves). The egress cap lives in the DATA instead (`resolveAround` only
    /// ever writes `resolvedURLs` for the ±1 window), not in which view type gets mounted.
    ///
    /// This used to be a hand-rolled `DragGesture` mover, deliberately NOT a `TabView(.page)`: the
    /// gesture kept only ONE photo mounted, because three separate root-cause fixes for an
    /// earlier `TabView` attempt (page-width sizing, footer-height stability, the reaction
    /// picker's own height) each closed a real way for it to desync mid-swipe, yet a swipe could
    /// still settle showing a sliver of the next photo.
    ///
    /// `FeedUnitCard`'s pager proved the actual cure: the desync was never `TabView` itself, it
    /// was pages that were NOT structurally stable (this file's old `photoPage` swapped a bare
    /// `ProgressView` in for whatever was outside the render window) inside geometry that was NOT
    /// fixed (this file's old footer changed height with the reaction bar and the share composer).
    /// Night-rack mode's photograph is a hard `width x width*4/3` box and its rack/status row have
    /// fixed heights; the roll/widget footer here keeps its existing flexible layout, which is why
    /// this conversion was done only once both preconditions held everywhere it's used.
    ///
    /// Construction now matches `FeedUnitCard.pager` exactly: a bare `TabView(.page)` with no
    /// gesture riding alongside it. It used to carry an extra `simultaneousGesture` (a vertical
    /// drag-to-dismiss) plus a matching `.offset(y:)`, which `FeedUnitCard`'s own pager has
    /// never had, and it was the prime suspect for the paging still not feeling native even
    /// after the `TabView(.page)` rewrite: a second gesture recognizer tracking every touch
    /// simultaneously with a native paging `UIScrollView`, even one that only ACTS on a vertical
    /// component, is enough for iOS to visibly damp the primary gesture's own physics. There is
    /// no equivalent in the feed to replicate instead: `FeedUnitCard`'s pager is inline in a
    /// scrolling card, nothing to dismiss; `PostDetailView`'s own swipe-to-go-back rides
    /// alongside a vertically-scrolling `ScrollView` showing ONE photo, not a horizontally
    /// paging `TabView`, so it is not the same situation either. The X button in both headers
    /// (`legacyHeader`/`nightRackHeader`) is the sole way to close this viewer now.
    private var pagerCore: some View {
        ZStack {
            TabView(selection: $selection) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                    photoPage(photo, index: index)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            // Explicit frame directly on the TabView, matching `FeedUnitCard.pager` (fixed
            // literal size for night-rack; flexible max-fill for the roll/widget path), rather
            // than relying on an ancestor to constrain it. See `pageFramed`.
            .modifier(PageFrameModifier(fixed: showsNightRack ? CGSize(width: photoWidth, height: photoHeight) : nil))
            // Mirrors the old `scale > 1 ? .none : .all` gesture mask exactly: paging is native
            // now, so the equivalent gate is disabling the TabView's own scroll while zoomed,
            // handing the touch fully to `panWhileZoomed` instead. Inert (false) at rest, so it
            // plays no part in ordinary swiping, only while a pinch is actually held open.
            .scrollDisabled(scale > 1)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(photos.count == 1 ? "Photo" : "Photo \(selection + 1) of \(photos.count)")

            // Over the photo rather than inside `photoPage`, so it is not scaled by a pinch in
            // flight and does not move with the paging offset. A plain overlay `Image` with
            // `allowsHitTesting(false)`, so unlike the dismiss drag this removed, it attaches no
            // gesture of its own and has no bearing on the TabView's swipe physics.
            Image(systemName: "heart.fill")
                .font(.system(size: 90))
                .foregroundStyle(.white)
                .shadow(radius: 8)
                .scaleEffect(heartBurst ? 1 : 0.4)
                .opacity(heartBurst ? 0.9 : 0)
                .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.55), value: heartBurst)
                .allowsHitTesting(false)
        }
    }

    /// STRUCTURALLY STABLE at every index, matching `FeedUnitCard.page(item:index:)` exactly (see
    /// its own comment block): a still-developing or in-window-but-unresolved photo used to
    /// render as a bare `ProgressView` swapped in for `CachedImage` once its URL resolved, and
    /// that placeholder-to-image subtree swap, landing while the TabView's own scroll was still
    /// settling, is the documented way to corrupt page-style scroll state (a swipe jumping two
    /// photos, or a page settling on a sliver of its neighbour). `CachedImage` is now ALWAYS
    /// mounted for every non-failed page, at every index, whether or not it currently has a URL;
    /// a still-developing shot and an out-of-window shot both simply show `CachedImage`'s own
    /// placeholder (the developing well, or a spinner) rather than a different view type
    /// entirely. Only the URL fed into it is windowed: `abs(index - selection) <= 1`, same egress
    /// gate the feed uses, so an off-window page may paint free from the disk cache but can never
    /// fetch.
    ///
    /// The one branch swap left is the failed state, mirroring `FeedUnitCard.brokenWell` exactly
    /// (down to the `failedPhotoIds` set and the `retryTokens`-keyed `.id`): a failed fetch must
    /// draw IN the photograph's place, never a stale or broken image underneath a Retry button,
    /// so that one case stays a genuine subtree replacement rather than an overlay.
    @ViewBuilder
    private func photoPage(_ photo: Photo, index: Int) -> some View {
        let isDeveloping = showsNightRack && !photo.isReady
        let isFailed = showsNightRack && failedPhotoIds.contains(photo.id)
        let failureHandler: (() -> Void)? = showsNightRack ? { failedPhotoIds.insert(photo.id) } : nil
        // Read for its own sake: bumped by `watchDeveloping` when a shot in the ±1 window
        // crosses `developsAt` while this page is already on screen, so this body evaluation
        // (and therefore `isDeveloping` above, which is otherwise only re-derived when SOME
        // other `@State` changes) is actually re-run. See `watchDeveloping`'s own doc.
        let _ = developPulse

        Group {
            if isFailed {
                brokenPage(photo)
            } else {
                // Downloads `viewPath` (the ~1400px feed card when one exists, the full original
                // only as a fallback for photos with no card yet) rather than always fetching the
                // 2048px original just to downsample it to `maxPixel` anyway.
                //
                // `cacheKey` MUST name the same storage object `url` actually points to, see
                // `resolvedCacheKey`'s own doc for the mechanism a mismatch breaks. While a photo
                // is only seeded with the grid's thumbnail (`fullyResolvedIds` doesn't have it
                // yet), `url` is the THUMBNAIL's URL, so the key has to be `displayPath`, that
                // thumbnail's own object, not `viewPath`. Only once `resolvePhotoUpgrade` reports
                // the real upgrade landed does `url` actually point at `viewPath`, and the key
                // switches to match. `repairRenditions` reads the raw bytes back by whichever key
                // was actually used here, so this also keeps that read honest: keying by
                // `storagePath`/`viewPath` while the bytes on disk are the thumbnail's would have
                // it rebuild the feed rendition FROM the thumbnail while believing it had the
                // full original.
                CachedImage(
                    url: (!isDeveloping && abs(index - selection) <= 1) ? resolvedURLs[photo.id] : nil,
                    maxPixel: 1600,
                    cacheKey: resolvedCacheKey(isFull: fullyResolvedIds.contains(photo.id),
                                                displayPath: photo.displayPath, viewPath: photo.viewPath),
                    onFailure: failureHandler
                ) { image in
                    image
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale, anchor: zoomAnchor)
                        .offset(offset)
                        .gesture(pinchToZoom)
                        // Pan is only active once zoomed in (GestureMask.none otherwise), so at 1x
                        // it never competes with the swipe above for a touch.
                        .gesture(panWhileZoomed, including: scale > 1 ? .all : .none)
                        // Double tap likes the photo, the same as it does in the feed, rather
                        // than holding a zoom. It used to do the latter, which meant the one
                        // gesture people already know from every other photo app did three
                        // different things depending on which screen they were on, and left the
                        // photo parked at 2.5x on a pan that never tracked the finger properly.
                        // Only where reactions exist: the Darkroom is your own photos and has
                        // no reaction bar for this to drive.
                        .onTapGesture(count: 2) { if showsReactions { doubleTapLike() } }
                } placeholder: {
                    if isDeveloping {
                        developingPlaceholder
                    } else {
                        ProgressView().tint(.white)
                    }
                }
                .id("page-\(photo.id)-\(retryTokens[photo.id, default: 0])")
            }
        }
        .modifier(PageFrameModifier(fixed: showsNightRack ? CGSize(width: photoWidth, height: photoHeight) : nil))
    }

    /// A still-developing shot in night-rack mode: there is no image to show yet, so the box
    /// stays a near-black well. The status row below names when it will be ready. Lives as
    /// `CachedImage`'s own placeholder now (see `photoPage`'s doc), not a separate mounted
    /// subtree, so a shot finishing development mid-session upgrades in place.
    private var developingPlaceholder: some View {
        Rectangle()
            .fill(Color(white: 0.035))
            .overlay {
                Circle()
                    .strokeBorder(accent.opacity(0.6), lineWidth: 1.5)
                    .frame(width: 28, height: 28)
            }
    }

    /// A failed fetch in night-rack mode, drawn IN the photograph's box, never over one. The
    /// rack, header, and status/actions row all stay live; only this one page is a well with a
    /// Retry, matching `FeedUnitCard.brokenWell`'s exact copy and shape.
    private func brokenPage(_ photo: Photo) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .overlay {
                VStack(spacing: 11) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 27, weight: .light))
                        .foregroundStyle(Color.white.opacity(0.37))
                    Text("This shot didn't load")
                        .flimFont(13, relativeTo: .subheadline)
                        .foregroundStyle(FlimTheme.textSecondary)
                    Button { retryFailedImage(photo) } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .flimFont(13, weight: .medium, relativeTo: .subheadline)
                            .foregroundStyle(accent)
                            .padding(.horizontal, 16).padding(.vertical, 7)
                            .overlay(Capsule().strokeBorder(accent, lineWidth: 1))
                    }
                }
            }
    }

    // MARK: - Night rack

    /// This photo's night, everything in it (developing included), in render order: the same
    /// contiguous block `DarkroomView` already built `photos` from, just filtered back out by
    /// day key rather than re-fetched.
    private var currentNightPhotos: [Photo] {
        guard let current else { return [] }
        let key = FeedUnit.dayKey(for: current.takenAt)
        return photos.filter { FeedUnit.dayKey(for: $0.takenAt) == key }
    }

    private var currentNightPosition: Int {
        guard let current else { return 0 }
        return (currentNightPhotos.firstIndex { $0.id == current.id } ?? 0) + 1
    }

    /// Tonight / Last night / a full `Sat 16 Aug` form, reusing `DarkroomDayUnit.title`'s exact
    /// rule. The pager never shows month bands, so it always asks for the full form.
    private var currentNightTitle: String {
        guard let current else { return "" }
        let key = FeedUnit.dayKey(for: current.takenAt)
        return DarkroomDayUnit(dayKey: key, photos: []).title(shortForm: false)
    }

    private var photoWidth: CGFloat { screenWidth }
    private var photoHeight: CGFloat { photoWidth * 4 / 3 }

    /// The night rack's own frame geometry, matching `FeedUnitCard.FilmStrip`'s exactly: 30pt
    /// frames, a 2pt gap, a 32pt pitch. Fixed at every count, same reasoning as the feed strip's
    /// own doc: sizing frames to fill the row would make a quiet night's frames bigger than a
    /// busy one's.
    private static let rackFrameGap: CGFloat = 2
    private static let rackPitch: CGFloat = 30 + rackFrameGap

    /// The rack + status/actions row that replaces the caption/share-pill footer in night-rack
    /// mode.
    private var rackSection: some View {
        VStack(spacing: 0) {
            DarkroomPerforationLine().frame(height: 3)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Self.rackFrameGap) {
                        ForEach(currentNightPhotos) { photo in
                            DarkroomFrameView(
                                photo: photo,
                                accent: accent,
                                signedURL: signedURLs[photo.id] ?? rackThumbURLs[photo.id],
                                isShared: feed.myPostedPhotoIds.contains(photo.id),
                                rollName: rollName(photo.rollId),
                                isSelecting: false,
                                isSelected: false,
                                photoNS: rackNS,
                                onTap: {},
                                onToggleSelect: {},
                                isCurrent: photo.id == current?.id,
                                allowsDevelopingTap: true,
                                isFailed: failedPhotoIds.contains(photo.id),
                                compact: true
                            )
                            .id(photo.id)
                        }
                    }
                    .padding(.vertical, Self.rackFrameGap)
                    // ONE recogniser on the row, resolving x to the frame whose band contains
                    // it, matching `FeedUnitCard.FilmStrip`'s own tap mechanism verbatim: every
                    // point in the row belongs to exactly one frame, no gap is dead, and a 30pt
                    // visual never has to be the 30pt target. `jump(to:)` already carries its own
                    // haptic and no-op guard for tapping the already-current frame.
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { value in
                        let frames = currentNightPhotos
                        guard !frames.isEmpty else { return }
                        let index = min(frames.count - 1, max(0, Int(value.location.x / Self.rackPitch)))
                        jump(to: frames[index])
                    })
                    // Flush with the photograph's own left edge, which in night-rack mode has
                    // no margin at all (a hard, full-bleed `width x width*4/3` box): the rack
                    // used to carry a 16pt leading inset the photo itself doesn't have, so the
                    // first frame floated in from the edge instead of starting exactly where
                    // the photo starts, unlike the feed's own strip (which matches ITS photo's
                    // margined edge, not a bare zero, because that photo has one). The trailing
                    // side keeps its inset; `rackFadeMask` and the centering `scrollTo` below
                    // are both already viewport-relative, not padding-relative, so neither needs
                    // to change alongside this.
                    .padding(.leading, 0)
                    .padding(.trailing, 16)
                }
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { rackWidth = $0 }
                .mask(rackFadeMask)
                .onChange(of: selection) { _, _ in
                    guard let id = current?.id else { return }
                    withAnimation(.snappy(duration: 0.22)) { proxy.scrollTo(id, anchor: .center) }
                }
                // First appear: land already centred, no animation.
                .task {
                    guard let id = current?.id else { return }
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            // Fills in whatever the grid never resolved (a night the grid didn't scroll past),
            // batched in one call rather than a round trip per frame. Keyed on the night's own
            // membership, so swiping into an adjacent night resolves that one too.
            .task(id: currentNightPhotos.map(\.id)) {
                let missing = currentNightPhotos.filter { signedURLs[$0.id] == nil && rackThumbURLs[$0.id] == nil }
                guard !missing.isEmpty else { return }
                let resolved = await photoService.signedURLs(for: missing.map(\.displayPath))
                for photo in missing {
                    if let url = resolved[photo.displayPath] { rackThumbURLs[photo.id] = url }
                }
            }
            DarkroomPerforationLine().frame(height: 3)
            statusActionsRow
        }
    }

    /// Fades both ends of the rack over 26pt, same convention as `DarkroomUnitSeparator`'s hairline.
    private var rackFadeMask: some View {
        let fade = rackWidth > 0 ? min(0.4, 26 / rackWidth) : 0
        return LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: fade),
                .init(color: .black, location: 1 - fade),
                .init(color: .clear, location: 1)
            ],
            startPoint: .leading, endPoint: .trailing)
    }

    private func jump(to photo: Photo) {
        guard let index = photos.firstIndex(where: { $0.id == photo.id }), index != selection else { return }
        Haptics.tap()
        withAnimation(.easeOut(duration: 0.2)) { selection = index }
    }

    /// Left: a single-line status, the shot's roll (if any) prefixed on. Right: the promoted
    /// Share/Tag capsules, dimmed and disabled while the shot is still developing (there is
    /// nothing to share or tag yet).
    ///
    /// No reaction count here. `FeedService.reactionsByPost` is keyed by POST id and is only
    /// populated for posts the feed has actually paged in; there is no cheap client-side map from
    /// a Darkroom photo id to its post id for a shot that predates whatever page happens to be
    /// loaded (the exact trap `PhotoService`'s own pagination note warns about, one layer over in
    /// `FeedService`). Showing a count here would mean either a new per-photo query on top of
    /// what this screen already fetches, or a number that's wrong for anything not in the
    /// currently-loaded feed window, so it's omitted rather than guessed.
    private var statusActionsRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(statusText)
                .flimFont(12)
                .foregroundStyle(FlimTheme.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                shareCapsule
                if showsTagCapsule { tagCapsule }
            }
            .opacity(current?.isReady == true ? 1 : 0.45)
            .disabled(current?.isReady != true)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .frame(minHeight: 32)
    }

    private var statusText: String {
        guard let photo = current else { return "" }
        guard photo.isReady else {
            return "Develops at \(FeedUnit.clockTime(photo.developsAt))"
        }
        let base = feed.myPostedPhotoIds.contains(photo.id) ? "Shared to Feed" : "Not shared"
        if let roll = rollName(photo.rollId) { return "\(roll) · \(base)" }
        return base
    }

    /// Tag only ever shows once a shot is already shared, and is ABSENT (not merely disabled) on
    /// an unshared one: tagging an unshared shot is not offered anywhere, in any form.
    private var showsTagCapsule: Bool {
        guard let photo = current else { return false }
        return feed.myPostedPhotoIds.contains(photo.id)
    }

    /// Night-rack's own share moment, Phase D: opens `ShareToFeedSheet` (see `shareSheetPhoto`),
    /// never the legacy inline composer that the roll pager's `bottomBar` still uses below.
    private var shareCapsule: some View {
        let shared = current.map { feed.myPostedPhotoIds.contains($0.id) } ?? false
        return Button {
            guard let photo = current else { return }
            Haptics.tap()
            shareSheetPhoto = photo
        } label: {
            // `shared` used to leave the label reading "Share" while the button quietly did
            // nothing: pixel-identical to the live state, so a second look never answered
            // whether a tap here would do anything. Both the text and the dim (matching
            // `tagCapsuleLabel`'s own disabled treatment) now say so at a glance.
            Text(shared ? "Shared" : "Share")
                .flimFont(13, weight: .medium)
                .foregroundStyle(accent)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .overlay(Capsule().strokeBorder(accent.opacity(0.55), lineWidth: 1))
                .opacity(shared ? 0.45 : 1)
        }
        .disabled(shared)
    }

    private var tagCapsule: some View {
        Button {
            guard let photo = current else { return }
            beginTagging(photo)
        } label: {
            tagCapsuleLabel
        }
        .disabled(isLoadingTags)
    }

    private var tagCapsuleLabel: some View {
        Group {
            Text("Tag")
                .flimFont(13, weight: .medium)
                .foregroundStyle(accent)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .overlay(Capsule().strokeBorder(accent.opacity(0.55), lineWidth: 1))
                .opacity(isLoadingTags ? 0.45 : 1)
        }
    }

    /// The current photo's caption, outside the swiping layer: the photographer @handle (roll
    /// grid, when `showsAttribution`) above the date; the date alone otherwise. Roll/widget mode
    /// only; night-rack mode's rack + status row replaces this.
    private var captionLabel: some View {
        VStack(spacing: 2) {
            if let photo = current {
                if showsAttribution, let name = memberNames[photo.userId] {
                    // Tappable, like every other handle in the app. It was a plain Text here, so
                    // the one place you are looking straight at someone's photograph was the one
                    // place their name did nothing.
                    Button { profileRoute = ProfileRoute(id: photo.userId) } label: {
                        Text("@\(name)")
                            .flimFont(14, weight: .semibold, relativeTo: .subheadline)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens @\(name)'s profile")
                }
                Text(photo.takenAt.formatted(date: .abbreviated, time: .shortened))
                    .flimFont(12, weight: .medium).foregroundStyle(Color(white: 0.68))
            }
        }
        .opacity(scale > 1 ? 0 : 1)
        .animation(.easeOut(duration: 0.2), value: scale > 1)
    }

    private func deleteMessage(_ photo: Photo?) -> String {
        if let name = rollName(photo?.rollId) {
            return "This shot is in the roll \"\(name)\". Deleting removes it for everyone."
        }
        return "This can't be undone."
    }

    // MARK: - Actions

    /// Hand the photo to the share sheet, fetching it if it isn't already decoded.
    ///
    /// The cache key has to be the one `CachedImage` actually stored under, which is
    /// `cacheKey|maxPixel` whenever a `cacheKey` is supplied, not the signed URL. This looked up
    /// the URL instead, and since `photoPage` always supplies a `cacheKey`, the lookup could never
    /// hit: the button silently did nothing, every time. A control that declines without saying so
    /// reads as a broken app, so a miss now costs a spinner rather than the feature.
    private func share(_ photo: Photo) {
        guard !preparingShare, let url = resolvedURLs[photo.id] else { return }
        // Same `resolvedCacheKey` phase rule as `photoPage`: `resolvedURLs[photo.id]` may still
        // be the thumbnail seed here, and keying this memory-cache entry `viewPath` regardless
        // would file thumbnail bytes under the key `photoPage`'s own `CachedImage` later reads
        // as "the full-res image is already decoded", the same poisoning `resolvedCacheKey`'s
        // own doc describes, just through the in-memory cache instead of disk.
        let shareCacheKey = resolvedCacheKey(isFull: fullyResolvedIds.contains(photo.id),
                                              displayPath: photo.displayPath, viewPath: photo.viewPath)
        let key = "\(shareCacheKey)|1600" as NSString
        if let image = ImageCache.shared.object(forKey: key) {
            shareItem = ShareImage(image: image)
            return
        }
        preparingShare = true
        Task {
            defer { preparingShare = false }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data)
            else {
                Haptics.error()
                flashError("Couldn't prepare that for sharing.")
                return
            }
            ImageCache.set(image, forKey: key)
            // A swipe mid-flight already moved `current` on; silently drop the stale export
            // rather than pop a share sheet for a photo no longer on screen. Retryable: the
            // share button is right there on whatever photo is current now.
            guard current?.id == photo.id else { return }
            shareItem = ShareImage(image: image)
        }
    }

    /// The shared top-slot toast for a failure that must not decline silently. Auto-hides, same
    /// timing as `showSharedToast`'s own success case right below.
    private func flashError(_ message: String) {
        withAnimation { errorToast = message }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { errorToast = nil }
        }
    }

    /// The shared top-slot success toast, timed exactly like `confirmShare`'s own inline
    /// version below, pulled out so `ShareToFeedSheet`'s `onSuccess` can reach it without
    /// duplicating the animation/sleep/animation dance a second time.
    private func flashSharedToast() {
        withAnimation { showSharedToast = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { showSharedToast = false }
        }
    }

    private func shareToPage(_ photo: Photo) {
        composerPhoto = photo
        shareCaptionDraft = ""
        pendingTags = []
        showShareComposer = true
        captionFocused = true
    }

    private func confirmShare() {
        guard let uid = auth.currentUser?.id, let photo = composerPhoto else { return }
        let caption = shareCaptionDraft
        let tags = pendingTags
        Haptics.tap()
        // Written to FeedService's shared set, not local state, so the Darkroom grid shows the
        // new badge the moment you go back without needing its own reload.
        feed.myPostedPhotoIds.insert(photo.id)
        showShareComposer = false
        captionFocused = false
        Task {
            do {
                let tagsSaved = try await feed.createPost(photo: photo, caption: caption, userId: uid, tags: tags)
                if shouldWarnThatTagsDidNotSave(tagsSaved) {
                    // The post itself is live, only the tags failed to attach, so this is not the
                    // "didn't reach the server" branch below: the share stands, un-marking it would
                    // claim the whole thing failed when it didn't.
                    Haptics.error()
                    flashError("Shared, but the tags didn't save. Try again from Edit tags.")
                } else {
                    Haptics.success()
                    withAnimation { showSharedToast = true }
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation { showSharedToast = false }
                }
            } catch {
                // Didn't reach the server, un-mark so the Share button comes back for a retry.
                feed.myPostedPhotoIds.remove(photo.id)
                Haptics.error()
            }
        }
    }

    /// The promoted "Tag" action on an already-shared shot: finds that shot's post, loads its
    /// current tags, and opens the same `TagPhotoSheet` the feed's own "Edit tags" uses. Never
    /// reachable on an unshared shot (see `showsTagCapsule`).
    private func beginTagging(_ photo: Photo) {
        guard let uid = auth.currentUser?.id, !isLoadingTags else { return }
        Haptics.tap()
        isLoadingTags = true
        taggingPhoto = photo
        Task {
            defer { isLoadingTags = false }
            guard let postId = await feed.postId(forPhotoId: photo.id, userId: uid) else {
                Haptics.error()
                flashError("Couldn't open tagging. Check your connection and try again.")
                return
            }
            await feed.loadTags(for: postId)
            // Identity guard after the LAST await: a second Tag tap on a different photo while
            // this lookup was in flight has already retargeted `taggingPhoto`, and writing this
            // photo's post id and tag list now would open the sheet showing one photograph while
            // editing another post's tags, with Done then moving a tag between two posts. The
            // stale task simply stands down; the newer one owns the sheet.
            guard taggingPhoto?.id == photo.id else { return }
            editingTags = (feed.tagsByPost[postId] ?? []).compactMap { tag in
                feed.tagProfiles[tag.taggedUserId].map { PendingTag(user: $0, x: tag.x, y: tag.y) }
            }
            taggingPostId = postId
            showEditTags = true
        }
    }

    /// Clears a failed page and re-requests both the signed URL and the image, matching
    /// `FeedUnitCard`'s Retry exactly: drop the photo from `resolvedURLs`/`fullyResolvedIds` so
    /// `resolveAround` treats it as unresolved again, and re-run it for the current window.
    private func retryFailedImage(_ photo: Photo) {
        failedPhotoIds.remove(photo.id)
        resolvedURLs.removeValue(forKey: photo.id)
        fullyResolvedIds.remove(photo.id)
        retryTokens[photo.id, default: 0] += 1
        Task { await resolveAround(selection) }
    }

    private func toggleReaction(_ emoji: String, on photo: Photo) {
        guard let uid = auth.currentUser?.id else { return }
        let mine = reactions.contains { $0.emoji == emoji && $0.userId == uid }
        Haptics.tap()
        Task {
            if mine {
                reactions.removeAll { $0.emoji == emoji && $0.userId == uid }
                await photoService.removeReaction(photoId: photo.id, emoji: emoji, userId: uid)
            } else {
                reactions.append(PhotoReaction(id: UUID(), photoId: photo.id, userId: uid, emoji: emoji))
                await photoService.addReaction(photoId: photo.id, emoji: emoji, userId: uid)
            }
            let fetched = await photoService.fetchReactions(photoId: photo.id)
            // Same fast-swipe guard as `resolveAround`'s own terminal write: a swipe mid-flight
            // has already moved `current` on, and writing this photo's counts into `reactions`
            // now would show them under whatever photo the person swiped to instead.
            guard current?.id == photo.id else { return }
            reactions = fetched
        }
    }

    /// Adds a heart on a double tap, the way the feed does. It never removes one: a double tap is
    /// an enthusiastic gesture, and having it silently undo the like you just gave reads as the
    /// tap not registering.
    private func doubleTapLike() {
        guard let uid = auth.currentUser?.id, let photo = current else { return }
        Haptics.tap()
        if !reduceMotion {
            heartBurst = true
            Task { try? await Task.sleep(for: .milliseconds(650)); heartBurst = false }
        }
        guard !reactions.contains(where: { $0.emoji == "❤️" && $0.userId == uid }) else { return }
        Task {
            reactions.append(PhotoReaction(id: UUID(), photoId: photo.id, userId: uid, emoji: "❤️"))
            await photoService.addReaction(photoId: photo.id, emoji: "❤️", userId: uid)
            let fetched = await photoService.fetchReactions(photoId: photo.id)
            // Same fast-swipe guard as `toggleReaction`/`resolveAround`.
            guard current?.id == photo.id else { return }
            reactions = fetched
        }
    }

    /// Resolves full-res URLs for the ±1 window around `index`, and (when the roll grid shows
    /// reactions) refetches the current photo's reactions. A photo's upgrade is retried on every
    /// visit to the window until it succeeds (see `resolvePhotoUpgrade`); reaction state is live
    /// so it's re-read as you swipe. Share state lives in `feed.myPostedPhotoIds` instead, loaded
    /// once for the whole session, not per swipe.
    ///
    /// A failed upgrade is deliberately silent in roll/widget mode (no `flashError`, unlike the
    /// actions below it): the photo is still fully visible, just softer than it will be once the
    /// retry lands. Night-rack mode is the one place a failure DOES surface, as the broken-page
    /// well `photoPage` renders once `CachedImage`'s `onFailure` marks the photo in
    /// `failedPhotoIds`; that failure is per-photo state, not something this function has to know
    /// about.
    private func resolveAround(_ index: Int) async {
        guard auth.currentUser?.id != nil else { return }
        // Same fix as RollCarouselView: the refetch at the end of this function is async, so
        // without clearing, the bar shows the PREVIOUS photo's counts under the new photo.
        if showsReactions { reactions = [] }
        for i in [index - 1, index, index + 1] where photos.indices.contains(i) {
            let photo = photos[i]
            guard !fullyResolvedIds.contains(photo.id) else { continue }
            // Nothing to resolve for a still-developing shot: there is no viewable image yet.
            guard photo.isReady else { continue }
            // `viewPath`, matching the `cacheKey` used below and in `photoPage`: the feed
            // card when this photo has one, the original only as its own fallback. `try?`
            // still swallows a failed fetch here (there is nothing more specific to do with
            // the error), but unlike before, failing no longer permanently blocks the retry:
            // see `resolvePhotoUpgrade`.
            let full = try? await photoService.signedURL(for: photo.viewPath)
            let next = resolvePhotoUpgrade(
                current: PhotoResolutionState(url: resolvedURLs[photo.id], isFull: false),
                thumbnail: signedURLs[photo.id],
                fullFetch: full
            )
            resolvedURLs[photo.id] = next.url
            if next.isFull { fullyResolvedIds.insert(photo.id) }
        }
        // Warm the neighbours' decoded images, not just their URLs. TabView(.page) used to keep
        // the adjacent pages mounted, so they were already decoded by the time you swiped; the
        // pager mounts only the current photo now, so without this a swipe could land on a
        // spinner. The cacheKey must match what `photoPage` requests exactly, or this warms an
        // entry the view never looks for. Same `resolvedCacheKey` phase rule as `photoPage`: a
        // neighbour still on the thumbnail seed must warm under `displayPath`, not `viewPath`,
        // or this prefetch is the exact same poisoning bug from a second call site.
        let neighbours: [(url: URL, cacheKey: String?)] = [index - 1, index + 1]
            .filter { photos.indices.contains($0) }
            .compactMap { i in
                let neighbour = photos[i]
                return resolvedURLs[neighbour.id].map {
                    (url: $0, cacheKey: resolvedCacheKey(isFull: fullyResolvedIds.contains(neighbour.id),
                                                          displayPath: neighbour.displayPath, viewPath: neighbour.viewPath))
                }
            }
        ImageLoader.prefetch(neighbours, maxPixel: 1600, scale: displayScale)

        // Rebuild any missing renditions from bytes now on the device. Free: it reads the disk
        // cache and gives up when the bytes aren't there, so nothing is ever downloaded for this.
        // Run for the window, not just the current photo, because prefetching the neighbours is
        // what put their bytes within reach.
        //
        // Deliberately NOT awaited. This is maintenance with no UI riding on it, and awaiting it
        // put two uploads in front of the reaction fetch below and, through the caller, in front
        // of the tag sheet opening. On the 9% of photos that need repair that meant the bar sat
        // empty and the sheet sat shut for as long as an upload takes on a bad connection.
        let window = [index - 1, index, index + 1]
            .filter { photos.indices.contains($0) }
            .map { photos[$0] }
        Task {
            for photo in window {
                await photoService.repairRenditions(for: photo)
                // Same "free, cached-bytes-only, never awaited by anything with UI riding on it"
                // shape as the repair above. Ownership and "already has one" are both checked
                // inside `backfillSuggestedEmoji` itself, so this is safe to fire for every photo
                // in the window regardless of whether it's this pager's own account's photo.
                await photoService.backfillSuggestedEmoji(for: photo)
            }
        }

        guard showsReactions, let photo = current else { return }
        let id = photo.id
        let fetched = await photoService.fetchReactions(photoId: id)
        guard current?.id == id else { return }   // fast-swipe guard
        reactions = fetched
    }

    /// Keeps re-checking the ±1 window while any photo in it is still developing, so sitting on
    /// (or beside) a shot as it crosses `developsAt` promotes it in place, without needing
    /// another swipe. `resolveAround` itself only ever runs on a selection change or the initial
    /// `.task`, so before this a shot that finished developing while already on screen (or one
    /// swipe away) stayed a "Develops at HH:MM" well until the person swiped away and back.
    ///
    /// Driven by `.task(id: selection)`, which is what gives this its cancellation for free: a
    /// new selection starts a fresh loop for the new window, and the old one is torn down by
    /// SwiftUI, same as it would be on dismiss. Capped at re-checking every 60s even when the
    /// nearest `developsAt` is much further out, so this can't sleep past the point where
    /// something else (a retry, a delete) has already changed the window.
    private func watchDeveloping() async {
        while !Task.isCancelled {
            let window = [selection - 1, selection, selection + 1]
                .filter { photos.indices.contains($0) }
                .map { photos[$0] }
            let stillDeveloping = window.filter { !$0.isReady }
            guard let earliest = stillDeveloping.map(\.developsAt).min() else { return }
            let wait = min(60, max(1, earliest.timeIntervalSinceNow + 1))
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            await resolveAround(selection)
            // `resolveAround` itself only writes observable state for a photo it actually
            // resolves a URL for; a shot that just crossed `developsAt` needs the page to
            // re-render regardless (to swap `developingPlaceholder` for the real image, and to
            // recompute `statusText`), so this is bumped unconditionally rather than trusting
            // that side effect.
            developPulse += 1
        }
    }

    // MARK: - Gestures

    /// Pinch is a look, not a mode: it magnifies while your fingers are down and springs back to
    /// wherever the photo was resting when you let go. Holding a zoom is what the double tap is
    /// for, and a pinch that started from a double-tapped zoom returns to that, not to 1x.
    ///
    /// It used to keep whatever scale the pinch ended on unless that was under 1.2x, which left
    /// the photo stuck at an arbitrary size with no visible way back except a double tap people
    /// had to guess at. It also read the gesture's magnification as an absolute scale, so a pinch
    /// begun on an already-zoomed photo jumped to near 1x before it moved at all.
    private var pinchToZoom: some Gesture {
        TransientPinch(scale: $scale, anchor: $zoomAnchor, restingScale: $pinchStart) { resting in
            if resting <= 1 { offset = .zero; lastOffset = .zero }
        }
    }

    private var panWhileZoomed: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height)
            }
            .onEnded { _ in lastOffset = offset }
    }
}

/// The pager's two genuinely different frame APIs, one decision: a fixed size pins an EXACT
/// `.frame(width:height:).clipped()` (night-rack's 3:4 box, the swipe pattern's geometry
/// precondition, matching `FeedUnitCard.pager`); `nil` means the roll/widget path's flexible
/// `.frame(maxWidth: .infinity, maxHeight: .infinity)`. Passing `.infinity` as an exact
/// width/height is NOT "fill what the parent offers": it reports an infinite size upward and
/// breaks layout at runtime while compiling clean, which is why this cannot be one call.
private struct PageFrameModifier: ViewModifier {
    let fixed: CGSize?

    func body(content: Content) -> some View {
        if let fixed {
            content.frame(width: fixed.width, height: fixed.height).clipped()
        } else {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
