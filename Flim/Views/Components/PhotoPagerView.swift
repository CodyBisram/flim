import SwiftUI

/// How far the photo follows the finger during a paging swipe. At the first and last shot it
/// resists instead of sliding into blank space, so overswiping reads as a wall rather than as
/// dead input. Free function so the feel is testable without a view.
func pagingDragOffset(width: CGFloat, index: Int, count: Int, resistance: CGFloat = 0.2) -> CGFloat {
    let atStart = index == 0 && width > 0
    let atEnd = index == count - 1 && width < 0
    return (atStart || atEnd) ? width * resistance : width
}

/// Which way a finished horizontal drag should page: -1 back, +1 forward, or nil when it didn't
/// travel far enough to count as a swipe.
func pagingStep(forDragWidth width: CGFloat, threshold: CGFloat = 60) -> Int? {
    guard abs(width) > threshold else { return nil }
    return width < 0 ? 1 : -1
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
    @State private var profileRoute: ProfileRoute?
    @State private var dragY: CGFloat = 0
    var memberNames: [UUID: String] = [:]
    /// The roll name for a given photo's rollId (nil for a personal, non-roll shot), used only in
    /// the delete-confirmation wording. A roll grid passes a closure returning its own name.
    var rollName: (UUID?) -> String? = { _ in nil }
    var onDelete: () -> Void = {}
    /// Opens straight into the share-to-page composer with the tag sheet already up. Lets the
    /// Darkroom's "Tag people" action land on tagging directly: tags belong to a POST, so there's
    /// nothing to attach them to until the photo is being shared, and this makes that one step
    /// instead of "open the photo, find Share, then find Tag people".
    var startTagging: Bool = false

    @Environment(PhotoService.self) private var photoService
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dismiss) private var dismiss

    @State private var selection: Int
    /// Upgraded from the seeded thumbnail to full-res lazily, windowed to ±1 around `selection`
    /// (the neighbours you can reach with one swipe), so opening a big roll doesn't fire a fetch
    /// for every shot in it at once.
    @State private var resolvedURLs: [UUID: URL] = [:]
    @State private var sharedIds: Set<UUID> = []
    @State private var reportedIds: Set<UUID> = []
    @State private var reactions: [PhotoReaction] = []
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    /// The scale the photo was resting at when the current pinch started, so releasing returns it
    /// there. Nil when no pinch is in flight.
    @State private var pinchStart: CGFloat?
    /// Where the current pinch went down, so the photo grows from there instead of its middle.
    @State private var zoomAnchor: UnitPoint = .center
    /// Live horizontal offset while a paging swipe is in progress; always settles back to 0.
    @State private var dragX: CGFloat = 0
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    @State private var pendingDeletePhoto: Photo?
    @State private var showReportConfirm = false
    @State private var shareItem: ShareImage?
    @State private var showShareComposer = false
    @State private var shareCaptionDraft = ""
    @State private var pendingTags: [PendingTag] = []
    @State private var showTagSheet = false
    /// `startTagging` must fire once, not on every re-resolve as you swipe away and back.
    @State private var didAutoOpenTagging = false
    @State private var showComments = false
    @State private var showSharedToast = false
    /// Captured when an action starts, rather than re-derived from `current` when it finishes,
    /// defensive against `selection` changing while a sheet/dialog is open.
    @State private var composerPhoto: Photo?
    @State private var commentsPhoto: Photo?
    @FocusState private var captionFocused: Bool

    private var current: Photo? { photos.indices.contains(selection) ? photos[selection] : nil }

    init(photos: [Photo], startIndex: Int = 0, signedURLs: [UUID: URL],
         showsReactions: Bool = false, showsComments: Bool = false, showsAttribution: Bool = false,
         memberNames: [UUID: String] = [:], rollName: @escaping (UUID?) -> String? = { _ in nil },
         onDelete: @escaping () -> Void = {}, startTagging: Bool = false) {
        self.startTagging = startTagging
        self.photos = photos
        self.startIndex = startIndex
        self.signedURLs = signedURLs
        self.showsReactions = showsReactions
        self.showsComments = showsComments
        self.showsAttribution = showsAttribution
        self.memberNames = memberNames
        self.rollName = rollName
        self.onDelete = onDelete
        _selection = State(initialValue: min(max(startIndex, 0), max(0, photos.count - 1)))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack {
                header

                pager
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, 12)

                captionLabel

                bottomBar
                    .padding(.horizontal, 20)
                    .padding(.bottom, 44)
            }
        }
        .ignoresSafeArea(.container)
        .statusBarHidden()
        .sheet(isPresented: $showComments) {
            PhotoCommentsSheet(photoId: (commentsPhoto ?? current)?.id ?? UUID(), memberNames: memberNames)
        }
        .sheet(isPresented: $showTagSheet) {
            TagPhotoSheet(url: composerPhoto.flatMap { resolvedURLs[$0.id] }, tags: $pendingTags)
        }
        .overlay(alignment: .top) {
            if showSharedToast {
                Label("Shared to your page", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
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
            scale = 1; offset = .zero; lastOffset = .zero; dragX = 0; pinchStart = nil
            Task { await resolveAround(selection) }
        }
        .task {
            await resolveAround(selection)
            // After resolveAround, not before: the tag sheet renders the photo from
            // `resolvedURLs`, so opening it any earlier would show an empty frame to tag onto.
            if startTagging, !didAutoOpenTagging, let photo = current {
                didAutoOpenTagging = true
                shareToPage(photo)
                showTagSheet = true
            }
        }
        .confirmationDialog("Delete this photo?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                guard let photo = pendingDeletePhoto else { return }
                Haptics.warning()
                isDeleting = true
                Task {
                    await photoService.deletePhoto(photo)
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
                    await photoService.reportPhoto(photo)
                    reportedIds.insert(photo.id)
                    Haptics.success()   // the report went through, matching the toast
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Flag this for review. Thanks for keeping \(AppInfo.appName) safe.")
        }
        // Presented rather than pushed: this view is a full-screen cover with no navigation
        // stack of its own, so it carries the stack the profile needs.
        .sheet(item: $profileRoute) { route in
            NavigationStack { UserPageView(userId: route.id) }
        }
        .sheet(item: $shareItem) { item in
            SharePreviewSheet(photo: item.image)
        }
        .safeAreaInset(edge: .bottom) {
            if showShareComposer { shareComposer }
        }
    }

    // MARK: - Stable chrome

    @ViewBuilder
    private var header: some View {
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
                    if let url = resolvedURLs[photo.id],
                       let image = ImageCache.shared.object(forKey: "\(url.absoluteString)|1600" as NSString) {
                        shareItem = ShareImage(image: image)
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(12)
                        .glassCapsule(interactive: true)
                }
                .accessibilityLabel("Share photo")
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

    @ViewBuilder
    private var bottomBar: some View {
        if let photo = current {
            VStack(spacing: 14) {
                if showsReactions {
                    ReactionBar(
                        defaults: PostEmoji.all,
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
                    let shared = sharedIds.contains(photo.id)
                    Button { shareToPage(photo) } label: {
                        Label(shared ? "Shared to your page" : "Share to your page",
                              systemImage: shared ? "checkmark.circle.fill" : "square.and.arrow.up")
                            .font(.system(size: 15, weight: .semibold))
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
    private var shareComposer: some View {
        VStack(spacing: 10) {
            Button { showTagSheet = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 14))
                    Text(pendingTags.isEmpty ? "Tag people" : "\(pendingTags.count) tagged")
                        .font(.system(size: 14))
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
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .tint(accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.14), in: Capsule())
                Button {
                    showShareComposer = false
                    captionFocused = false
                } label: {
                    Text("Cancel").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                }
                Button { confirmShare() } label: {
                    Text("Share")
                        .font(.system(size: 14, weight: .semibold))
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

    /// One photo at a time, swapped by a horizontal swipe.
    ///
    /// Deliberately NOT `TabView(.page)`. That keeps neighbouring pages mounted, and three
    /// separate root-cause fixes for it (page-width sizing, footer-height stability, the reaction
    /// picker's own height) each closed a real way for it to desync mid-swipe, yet a swipe could
    /// still settle showing a sliver of the next photo. RollCarouselView abandoned TabView for
    /// plain state and has never had the complaint. This is the same approach and keeps the
    /// swipe: only the current photo is ever mounted, so there is no neighbour that CAN leak
    /// into frame, rather than a neighbour that is supposed to stay hidden.
    private var pager: some View {
        ZStack {
            if let photo = current {
                photoPage(photo)
                    .id(photo.id)
                    .transition(.opacity)
                    .offset(x: dragX, y: dragY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        // At 1x the swipe pages; once zoomed in, `panWhileZoomed` owns the drag instead.
        .gesture(swipeToPage, including: scale > 1 ? .none : .all)
    }

    /// Follows the finger, damped at both ends so the first and last shot feel like walls rather
    /// than dead input, and commits past a threshold.
    private var swipeToPage: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                // Vertical drags move the whole view toward dismissal instead of paging, so the
                // two gestures never fight: whichever axis dominates wins, and only that axis
                // moves. This viewer had no swipe-to-dismiss at all, while the carousel had
                // nothing else; each had exactly the half the other was missing.
                if abs(value.translation.height) > abs(value.translation.width), scale <= 1 {
                    dragY = max(0, value.translation.height) * 0.6
                    dragX = 0
                } else {
                    dragX = pagingDragOffset(width: value.translation.width,
                                             index: selection, count: photos.count)
                    dragY = 0
                }
            }
            .onEnded { value in
                let dismissing = scale <= 1
                    && abs(value.translation.height) > abs(value.translation.width)
                    && value.translation.height > 120
                withAnimation(.easeOut(duration: 0.18)) { dragX = 0; dragY = 0 }
                if dismissing {
                    Haptics.tap()
                    dismiss()
                } else if abs(value.translation.width) > abs(value.translation.height),
                          let delta = pagingStep(forDragWidth: value.translation.width) {
                    step(delta)
                }
            }
    }

    private func step(_ delta: Int) {
        let next = selection + delta
        guard photos.indices.contains(next) else { return }
        Haptics.tap()
        withAnimation(.easeOut(duration: 0.22)) { selection = next }
    }

    @ViewBuilder
    private func photoPage(_ photo: Photo) -> some View {
        Group {
            if let url = resolvedURLs[photo.id] {
                // `cacheKey` is the storage path so the DOWNLOADED BYTES are kept, not just the
                // decoded image. That is what makes rendition repair free: a photo whose thumbnail
                // and card never uploaded can be rebuilt from these bytes instead of fetching the
                // original again. It also stops a re-view going back to the network.
                CachedImage(url: url, maxPixel: 1600, cacheKey: photo.storagePath) { image in
                    image
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale, anchor: zoomAnchor)
                        .offset(offset)
                        .gesture(pinchToZoom)
                        // Pan is only active once zoomed in (GestureMask.none otherwise), so at 1x
                        // it never competes with the swipe above for a touch.
                        .gesture(panWhileZoomed, including: scale > 1 ? .all : .none)
                        .onTapGesture(count: 2) { toggleZoom() }
                } placeholder: {
                    ProgressView().tint(.white)
                }
            } else {
                ProgressView().tint(.white)
            }
        }
    }

    /// The current photo's caption, outside the swiping layer: the photographer @handle (roll
    /// grid, when `showsAttribution`) above the date; the date alone otherwise.
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
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Color(white: 0.68))
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
        sharedIds.insert(photo.id)
        showShareComposer = false
        captionFocused = false
        Task {
            do {
                try await feed.createPost(photo: photo, caption: caption, userId: uid, tags: tags)
                Haptics.success()
                withAnimation { showSharedToast = true }
                try? await Task.sleep(for: .seconds(2))
                withAnimation { showSharedToast = false }
            } catch {
                // Didn't reach the server, un-mark so the Share button comes back for a retry.
                sharedIds.remove(photo.id)
                Haptics.error()
            }
        }
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
            reactions = await photoService.fetchReactions(photoId: photo.id)
        }
    }

    private func toggleZoom() {
        // A double tap has no two fingers to grow from, so it goes back to the middle. Leaving
        // the last pinch's anchor in place would send a centred zoom lurching off to wherever the
        // previous pinch happened to land.
        zoomAnchor = .center
        withAnimation(.spring(duration: 0.3)) {
            if scale > 1 {
                scale = 1; offset = .zero; lastOffset = .zero
            } else {
                scale = 2.5
            }
        }
    }

    /// Resolves full-res URLs and share state for the ±1 window around `index`, and (when the roll
    /// grid shows reactions) refetches the current photo's reactions. URLs don't change so they're
    /// resolved once; share/reaction state is live so it's re-read as you swipe.
    private func resolveAround(_ index: Int) async {
        guard let uid = auth.currentUser?.id else { return }
        // Same fix as RollCarouselView: the refetch at the end of this function is async, so
        // without clearing, the bar shows the PREVIOUS photo's counts under the new photo.
        if showsReactions { reactions = [] }
        for i in [index - 1, index, index + 1] where photos.indices.contains(i) {
            let photo = photos[i]
            if resolvedURLs[photo.id] == nil {
                if let thumb = signedURLs[photo.id] { resolvedURLs[photo.id] = thumb }
                if let full = try? await photoService.signedURL(for: photo.storagePath) {
                    resolvedURLs[photo.id] = full
                }
            }
            if !sharedIds.contains(photo.id), await feed.hasPosted(photoId: photo.id, userId: uid) {
                sharedIds.insert(photo.id)
            }
        }
        // Warm the neighbours' decoded images, not just their URLs. TabView(.page) used to keep
        // the adjacent pages mounted, so they were already decoded by the time you swiped; the
        // pager mounts only the current photo now, so without this a swipe could land on a
        // spinner. The cacheKey must match what `photoPage` requests exactly, or this warms an
        // entry the view never looks for.
        let neighbours: [(url: URL, cacheKey: String?)] = [index - 1, index + 1]
            .filter { photos.indices.contains($0) }
            .compactMap { i in
                resolvedURLs[photos[i].id].map { (url: $0, cacheKey: photos[i].storagePath) }
            }
        ImageLoader.prefetch(neighbours, maxPixel: 1600, scale: displayScale)

        // Rebuild any missing renditions from bytes now on the device. Free: it reads the disk
        // cache and gives up when the bytes aren't there, so nothing is ever downloaded for this.
        // Run for the window, not just the current photo, because prefetching the neighbours is
        // what put their bytes within reach.
        for i in [index - 1, index, index + 1] where photos.indices.contains(i) {
            await photoService.repairRenditions(for: photos[i])
        }

        guard showsReactions, let photo = current else { return }
        let id = photo.id
        let fetched = await photoService.fetchReactions(photoId: id)
        guard current?.id == id else { return }   // fast-swipe guard
        reactions = fetched
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
