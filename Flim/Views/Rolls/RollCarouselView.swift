import SwiftUI

/// A full-screen, swipeable walk through a developed roll, every shot in chronological order,
/// with the current photo's date, who took it, and reactions.
struct RollCarouselView: View {
    @State private var profileRoute: ProfileRoute?
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
    @State private var showComments = false
    /// Which of this roll's photos have already been shared to someone's page, a quiet signal,
    /// not tied to who shared it or who took the shot. Loaded once for the whole roll rather than
    /// per-swipe, since `photos` is already the full array.
    @State private var sharedPhotoIds: Set<UUID> = []

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
                .gesture(pageOrDismissGesture)

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
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            Spacer()
            Button { showComments = true } label: {
                Image(systemName: "bubble.right").font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white).padding(12).glassCapsule(interactive: true)
            }
            .accessibilityLabel("Comments")
            Button {
                if let photo = current, let url = urls[photo.id],
                   let image = ImageCache.shared.object(forKey: "\(url.absoluteString)|1600" as NSString) {
                    shareItem = ShareImage(image: image)
                }
            } label: {
                Image(systemName: "square.and.arrow.up").font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white).padding(12).glassCapsule(interactive: true)
            }
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
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(Color(white: 0.68))
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
            .onEnded { value in
                let h = value.translation.width
                let v = value.translation.height
                if abs(v) > abs(h) {
                    if abs(v) > 120 { Haptics.tap(); dismiss() }
                } else if abs(h) > 60 {
                    step(h < 0 ? 1 : -1)
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
}
