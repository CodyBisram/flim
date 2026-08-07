import SwiftUI

/// A full-screen, swipeable walk through a developed roll, every shot in chronological order,
/// with the current photo's date, who took it, and reactions.
struct RollCarouselView: View {
    @State private var profileRoute: ProfileRoute?
    @State private var dragX: CGFloat = 0
    let photos: [Photo]                    // developed, sorted oldest → newest
    let memberNames: [UUID: String]
    var startIndex: Int = 0

    @Environment(AuthService.self) private var auth
    @Environment(PhotoService.self) private var photoService
    @Environment(FeedService.self) private var feed
    @Environment(\.dismiss) private var dismiss

    @State private var selection = 0
    @State private var urls: [UUID: URL] = [:]
    @State private var reactions: [PhotoReaction] = []
    @State private var shareItem: ShareImage?
    @State private var preparingShare = false
    @State private var showComments = false
    /// Which of this roll's photos have already been shared to someone's page, a quiet signal,
    /// not tied to who shared it or who took the shot. Loaded once for the whole roll rather than
    /// per-swipe, since `photos` is already the full array.
    @State private var sharedPhotoIds: Set<UUID> = []
    /// Pinch to look closer at the shot you're on. Transient: it springs back when you let go, so
    /// there is no zoomed state to get stuck in halfway through a roll.
    @State private var scale: CGFloat = 1
    @State private var zoomAnchor: UnitPoint = .center
    @State private var pinchStart: CGFloat?

    private var current: Photo? { photos.indices.contains(selection) ? photos[selection] : nil }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // One vertical layout, header / flexible photo / footer, so the photo SHRINKS
            // when the reaction bar expands (or the emoji keyboard rises) instead of the bar
            // overlapping the metadata or the image.
            VStack {
                header

                // Deliberately not TabView(.page): three separate root-cause fixes this cycle
                // (page-width sizing, footer-height stability, the reaction picker's own height)
                // each closed a real way to corrupt it mid-swipe, and it was STILL reported
                // showing two half-visible photos after all three. Rather than keep patching
                // triggers one at a time, this is plain state (`selection`) advanced by a tap
                // zone or a drag gesture below, the same approach RollRevealView already uses,
                // which has never had this complaint, because there's no paging scroll view
                // underneath to desync from its content in the first place.
                ZStack {
                    Group {
                        if let photo = current, let url = urls[photo.id] {
                            CachedImage(url: url, maxPixel: 1600) { $0.resizable().scaledToFit() }
                                placeholder: { ProgressView().tint(.white) }
                        } else {
                            ProgressView().tint(.white)
                        }
                    }
                    .id(current?.id)
                    .transition(.opacity)
                    .scaleEffect(scale, anchor: zoomAnchor)
                    // Follows the finger. Without this the drag offset above is computed and
                    // thrown away, which is the same as not having it.
                    .offset(x: dragX)

                    // Tap zones: left half steps back, right half steps forward.
                    HStack(spacing: 0) {
                        Color.clear.contentShape(Rectangle())
                            .frame(maxWidth: .infinity)
                            .onTapGesture { step(-1) }
                        Color.clear.contentShape(Rectangle())
                            .frame(maxWidth: .infinity)
                            .onTapGesture { step(1) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 8)
                // The pinch belongs HERE, on the stack, not on the photo inside it.
                //
                // The tap zones above are full-bleed `Color.clear` with a `contentShape`, and in a
                // ZStack they are declared after the photo, which means they sit ON TOP of it. A
                // gesture attached to the photo is underneath them and never sees a finger, so the
                // zoom was dead on arrival. Same trap `PhotoTags` documents for its label layer.
                //
                // `simultaneousGesture` rather than `gesture` so it coexists with those tap zones
                // instead of replacing them: a pinch needs two fingers, a step needs one, and
                // neither should have to wait for the other to fail.
                .simultaneousGesture(TransientPinch(scale: $scale, anchor: $zoomAnchor,
                                                    restingScale: $pinchStart))
                // Paging stands down while the photo is zoomed, so a pinch that lands slightly
                // off-centre isn't read as a swipe to the next shot or a swipe to dismiss.
                .gesture(pageOrDismissGesture, including: scale > 1 ? .none : .all)

                footer
            }
        }
        .statusBarHidden()
        // Presented rather than pushed: this view is a full-screen cover with no navigation
        // stack of its own, so it carries the stack the profile needs.
        .sheet(item: $profileRoute) { route in
            NavigationStack { UserPageView(userId: route.id) }
        }
        .sheet(item: $shareItem) { SharePreviewSheet(photo: $0.image) }
        .sheet(isPresented: $showComments) {
            if let photo = current {
                PhotoCommentsSheet(photoId: photo.id, memberNames: memberNames)
            }
        }
        .onAppear { selection = min(max(startIndex, 0), max(0, photos.count - 1)) }
        .task(id: selection) { await loadAround(selection) }
        .task { sharedPhotoIds = await feed.postedPhotoIds(photos.map(\.id)) }
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white).padding(12).glassCapsule(interactive: true)
            }
            .accessibilityLabel("Close")
            Spacer()
            Text("\(selection + 1) / \(photos.count)")
                .flimFont(13, weight: .semibold).foregroundStyle(.white)
            Spacer()
            Button { showComments = true } label: {
                Image(systemName: "bubble.right").font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white).padding(12).glassCapsule(interactive: true)
            }
            .accessibilityLabel("Comments")
            Button {
                shareCurrent()
            } label: {
                Group {
                    if preparingShare {
                        ProgressView().tint(.white).controlSize(.small)
                    } else {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 15, weight: .medium))
                    }
                }
                .frame(width: 19, height: 19)
                .foregroundStyle(.white).padding(12).glassCapsule(interactive: true)
            }
            .disabled(preparingShare)
            .accessibilityLabel("Share this photo")
        }
        .padding(.horizontal, 20).padding(.top, 20)
    }

    @ViewBuilder
    private var footer: some View {
        if let photo = current {
            VStack(spacing: 10) {
                VStack(spacing: 2) {
                    // Always renders (opacity 0 when the name doesn't resolve) rather than
                    // being omitted, omitting it made the footer a different height on
                    // photos with vs. without a resolvable member name, and since the
                    // TabView above gets "whatever height is left" in this VStack, swiping
                    // between such photos resized the pager mid-transition: exactly the kind
                    // of thing that corrupts a paging TabView's internal scroll state and
                    // shows two photos at once.
                    // Wrapped in a Button so the handle opens that person's profile. The
                    // always-render-then-fade shape above is preserved exactly: a Button sizes to
                    // its label, so the footer's height still cannot vary per photo, which is what
                    // the comment above is protecting. Disabled when the name hasn't resolved, so
                    // an invisible label is never tappable.
                    Button { profileRoute = ProfileRoute(id: photo.userId) } label: {
                        Text(memberNames[photo.userId].map { "@\($0)" } ?? "@")
                            .flimFont(14, weight: .semibold, relativeTo: .subheadline)
                            .foregroundStyle(.white)
                            .opacity(memberNames[photo.userId] == nil ? 0 : 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(memberNames[photo.userId] == nil)
                    // Same always-render-then-fade approach as the handle above, and for the same
                    // reason: this row's height must never depend on per-photo state while a
                    // paging TabView sits above it.
                    HStack(spacing: 4) {
                        Text(photo.takenAt.formatted(date: .abbreviated, time: .shortened))
                            .flimFont(12, weight: .medium).foregroundStyle(Color(white: 0.68))
                        Image(systemName: "square.and.arrow.up.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Color(white: 0.68))
                            .opacity(sharedPhotoIds.contains(photo.id) ? 1 : 0)
                            .accessibilityLabel(sharedPhotoIds.contains(photo.id) ? "Shared to a page" : "")
                    }
                }
                ReactionBar(
                    defaults: PostEmoji.all,
                    counts: Dictionary(grouping: reactions, by: \.emoji).mapValues(\.count),
                    mine: Set(reactions.filter { $0.userId == auth.currentUser?.id }.map(\.emoji))
                ) { toggleReaction($0, on: photo) }
                .id(photo.id)   // fresh reaction bar per photo as you swipe
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 20).padding(.bottom, 40)
        }
    }

    /// Whichever axis moved further wins: a mostly-vertical drag past the threshold dismisses
    /// (either direction), a mostly-horizontal drag past a smaller threshold steps, a swipe, on
    /// top of the tap zones above, not instead of them.
    private var pageOrDismissGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            // The photo follows the finger now. This gesture had no `onChanged` at all, so a
            // swipe moved nothing until it was released and then snapped: a gesture recogniser
            // rather than a gesture. No threshold tuning fixes that, because what was missing is
            // feedback DURING the drag, not the decision at the end. Uses the same pure helpers
            // as the full-screen viewer, so both surfaces resist at the ends identically.
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                dragX = pagingDragOffset(width: value.translation.width,
                                         index: selection, count: photos.count)
            }
            .onEnded { value in
                withAnimation(.easeOut(duration: 0.18)) { dragX = 0 }
                let h = value.translation.width
                let v = value.translation.height
                if abs(v) > abs(h) {
                    if abs(v) > 120 { Haptics.tap(); dismiss() }
                } else if let delta = pagingStep(forDragWidth: h) {
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

    private func loadAround(_ index: Int) async {
        // Drop the previous photo's reactions the moment the photo changes. The fetch below is
        // async, so until it lands this state still holds the LAST photo's reactions, and the
        // bar was rendering those counts and highlights underneath the NEW photo, then seeding
        // its emoji order from them.
        reactions = []
        for i in [index - 1, index, index + 1] where photos.indices.contains(i) {
            let photo = photos[i]
            if urls[photo.id] == nil { urls[photo.id] = try? await photoService.signedURL(for: photo.viewPath) }
        }
        if let photo = current {
            // Guard against fast swipes: only apply the fetch if this is still the visible photo.
            let id = photo.id
            let fetched = await photoService.fetchReactions(photoId: id)
            if current?.id == id { reactions = fetched }
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

    /// Shares the photo on screen, fetching it if it is not already in cache.
    ///
    /// This used to be a single `if let` over `ImageCache`, so on a miss the button did nothing:
    /// no sheet, no spinner, no error. Nothing is worse than a control that silently declines,
    /// because the only available reading is that the app is broken. The cache hit is still
    /// instant; the miss now costs a spinner instead of the feature.
    private func shareCurrent() {
        guard !preparingShare, let photo = current, let url = urls[photo.id] else { return }
        let key = "\(url.absoluteString)|1600" as NSString
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
                return
            }
            ImageCache.shared.setObject(image, forKey: key)
            shareItem = ShareImage(image: image)
        }
    }

}
