import SwiftUI

/// Lapse-style triage deck for un-sorted instants: swipe left to archive (Darkroom),
/// right to publish (Feed), or tap the red button to trash.
struct SortDeckView: View {
    @Environment(\.flimAccent) private var accent
    @Environment(AuthService.self) private var auth
    @Environment(PhotoService.self) private var photoService
    @Environment(FeedService.self) private var feed
    @Environment(\.dismiss) private var dismiss
    /// Called when the deck is emptied so the Darkroom can refresh.
    var onFinish: () -> Void = {}

    @State private var cards: [Photo] = []
    @State private var urls: [UUID: URL] = [:]
    @State private var drag: CGSize = .zero
    @State private var loaded = false
    @State private var closing = false
    // The last swipe, held un-committed so it can be undone (even a delete).
    @State private var lastPhoto: Photo?
    @State private var lastAction: SortAction?
    /// Caption/tags that ride along with `lastPhoto`/`lastAction` when the held action is a
    /// compose-sheet publish rather than the plain swipe-right/Post fast path (which leaves both
    /// empty). Held separately, not as part of `SortAction`, because enum cases can't carry
    /// default-valued associated data, and every other call site constructing a `.publish` would
    /// otherwise have to spell out empty values.
    @State private var lastCaption: String?
    @State private var lastTags: [PendingTag] = []
    @State private var publishError: String?
    /// The compose sheet, opened from the pill under the top card or a tap on the card itself.
    @State private var showCompose = false
    @State private var composePhoto: Photo?
    @State private var composeCaption = ""
    @State private var composeTags: [PendingTag] = []
    /// Retired after a few sorts. A permanent hint is furniture, and stops being read.
    @AppStorage("flim.sortDeck.sortsCompleted") private var sortsCompleted = 0

    private enum SortAction { case archive, publish, trash }

    /// How many sorts someone does before the hint stops appearing.
    static let swipeHintSortLimit = 6
    private var showSwipeHint: Bool { sortsCompleted < Self.swipeHintSortLimit }
    private let threshold: CGFloat = 110

    /// Captures are a fixed 3:4 (see `CapturedPhotoCropper`), so the card is too. Anything else
    /// means the triage screen shows a different picture than the one that gets developed.
    static let cardAspect: CGFloat = 3.0 / 4.0

    /// Shared by the header and the card so the X/Undo row and the card below it line up. 20pt
    /// reads slightly tighter than the card's 22pt corner radius, close enough that the corner
    /// still visually "sits inside" the margin instead of a wider gap making the two look
    /// unrelated.
    private static let horizontalMargin: CGFloat = 20

    /// The largest control circle (Delete). Every `circleButton` reserves this much vertical
    /// space for its circle, so Keep/Delete/Post captions land on one baseline even though the
    /// circles themselves stay different sizes.
    private static let largestCircleSize: CGFloat = 64

    /// The largest 3:4 card that fits the available area.
    ///
    /// A complete 3:4 photo still fills ~82% of the height the old full-bleed card used, so
    /// honesty costs about a sixth of the card and buys back the ~18% of every frame that was
    /// being hidden.
    static func cardSize(in area: CGSize) -> CGSize {
        guard area.width > 0, area.height > 0 else { return area }
        let heightIfFullWidth = area.width / cardAspect
        if heightIfFullWidth <= area.height {
            return CGSize(width: area.width, height: heightIfFullWidth)
        }
        // A short, wide area (landscape, or a small phone): fit to height instead so the card
        // never overflows the space it was given.
        return CGSize(width: area.height * cardAspect, height: area.height)
    }

    var body: some View {
        ZStack {
            FlimTheme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                if cards.isEmpty && loaded {
                    // Nothing left to sort, return to the previous screen (no "all sorted" wall).
                    Color.clear.onAppear { closeDeck() }
                } else {
                    GeometryReader { geo in
                        ZStack {
                            ForEach(Array(cards.prefix(3).enumerated()).reversed(), id: \.element.id) { index, photo in
                                card(photo, index: index, area: geo.size)
                            }
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                    }
                    .padding(.horizontal, Self.horizontalMargin)
                    .padding(.vertical, 10)
                    if let top = cards.first {
                        composeHint(for: top)
                    }
                    controls.overlay(alignment: .bottom) { publishErrorBanner }
                }
            }
        }
        .task { await load() }
        .onDisappear {
            // Safety net if dismissed some other way, commit any still-held action.
            if let p = lastPhoto, let a = lastAction {
                let caption = lastCaption, tags = lastTags
                lastPhoto = nil; lastAction = nil; lastCaption = nil; lastTags = []
                Task { await commit(p, a, caption: caption, tags: tags) }
            }
        }
        .sheet(isPresented: $showCompose) {
            if let composePhoto {
                SortDeckComposeSheet(photo: composePhoto, url: urls[composePhoto.id],
                                      caption: $composeCaption, tags: $composeTags) {
                    // Same publish path as swipe-right/the Post button, just carrying what was
                    // typed into the sheet: `performSwipe` already commits the PREVIOUS held
                    // action, flies this card off, and holds this one for undo exactly as it does
                    // for the fast path.
                    performSwipe(.publish, caption: composeCaption, tags: composeTags)
                }
            }
        }
    }

    /// The pill under the top card: both the hint that a caption/tags are possible and, along
    /// with the card itself, a tap target into the compose sheet. This is not a hidden gesture,
    /// swipe-right/the green Post button still publish instantly with neither.
    private func composeHint(for photo: Photo) -> some View {
        Button { openCompose(for: photo) } label: {
            Label("Add a caption or tag people", systemImage: "square.and.pencil")
                .flimFont(13, weight: .medium, relativeTo: .subheadline)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.1), in: Capsule())
        }
        .accessibilityLabel("Add a caption or tag people on this photo")
        .padding(.bottom, 6)
    }

    /// Overlaid on `controls`, not inserted into the VStack: it used to sit between the compose
    /// pill and `controls`, so the whole control row jumped down when a publish/delete error
    /// appeared and back up when it cleared. Anchored to `controls`' own bottom edge rather than
    /// to the button row itself, so it lands inside `controls`' existing 30pt trailing padding
    /// (otherwise-blank space below the captions) regardless of whether the swipe hint line below
    /// the buttons is showing, and doesn't reach up far enough to compete with the compose pill
    /// above.
    @ViewBuilder private var publishErrorBanner: some View {
        if let publishError {
            Text(publishError)
                .flimFont(13, relativeTo: .subheadline)
                .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.42))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 4)
                .transition(.opacity)
        }
    }

    private func openCompose(for photo: Photo) {
        guard !showCompose else { return }
        Haptics.tap()
        composePhoto = photo
        composeCaption = ""
        composeTags = []
        showCompose = true
    }

    // MARK: - Header

    /// Centred with a ZStack/overlay, not balanced between two Spacers: "Undo" (icon + text) is
    /// far wider than the leading X, so a Spacer-balanced title sits left of centre, and it would
    /// shift sideways the moment Undo appears/disappears. Centring the title on the whole header
    /// instead means it's fixed to the screen and never moves regardless of what's in the
    /// leading/trailing row.
    private var header: some View {
        ZStack {
            if !cards.isEmpty {
                Text("\(cards.count) to sort")
                    .flimFont(13, weight: .medium, relativeTo: .footnote).foregroundStyle(FlimTheme.textSecondary)
            }
            HStack {
                Button { closeDeck() } label: {
                    Image(systemName: "xmark").font(.system(size: 16, weight: .medium)).foregroundStyle(.white)
                }
                Spacer()
                if lastPhoto != nil {
                    Button { undo() } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                            .flimFont(13, weight: .semibold)
                            .foregroundStyle(accent)
                    }
                }
            }
        }
        .padding(.horizontal, Self.horizontalMargin).padding(.top, 16).padding(.bottom, 8)
    }

    // MARK: - Card

    private func card(_ photo: Photo, index: Int, area: CGSize) -> some View {
        let isTop = index == 0
        let size = Self.cardSize(in: area)
        return RoundedRectangle(cornerRadius: 22)
            .fill(FlimTheme.bgElevated)
            .overlay {
                // scaledToFit inside a 3:4 card, so what you judge is the whole photograph.
                //
                // This used to be scaledToFill into a card that filled the available area, which
                // is much taller than 3:4, so it scaled the photo to the card's HEIGHT and let the
                // sides run off: roughly 18% of the frame's width, ~9% off each edge. This is the
                // screen where you decide what to keep and what to share, so the call was being
                // made on less than the file contains, and you would never find out what you
                // missed, because the thing you could not see is the thing you did not know to
                // look for. Someone standing at the edge of the frame was invisible here and
                // present in the developed shot.
                //
                // 1600 rather than the old 2048: that budget existed to cover the extra
                // magnification scaledToFill applied. Fitting a 3:4 photo into a 3:4 card is 1:1,
                // so it now matches the full-screen viewer's budget.
                CachedImage(url: urls[photo.id], maxPixel: 1400, cacheKey: photo.viewPath) { $0.resizable().scaledToFit() }
                    placeholder: { ShimmerPlaceholder(cornerRadius: 22) }
            }
            // No decorative GrainOverlay here, unlike the feed and the grid. Those screens are
            // presentational; this one is evaluative, and adding texture the file does not have to
            // the screen whose job is judging image quality works against itself. The Darkroom's
            // own full-screen viewer doesn't add it either, so the deck now agrees with the view
            // you would check the photo in.
            .overlay { if isTop { dragLabels } }
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.white.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 14, y: 8)
            .frame(width: size.width, height: size.height)
            .scaleEffect(isTop ? 1 : 1 - CGFloat(index) * 0.04)
            .offset(y: isTop ? 0 : CGFloat(index) * 14)
            .offset(isTop ? drag : .zero)
            .rotationEffect(.degrees(isTop ? Double(drag.width / 22) : 0))
            .gesture(isTop ? dragGesture : nil)
            // Simultaneous, not exclusive, with the drag gesture above: a genuine tap never
            // travels far enough for `dragGesture`'s onChanged/onEnded to fire, so the two don't
            // compete, and the card becomes the larger target the compose pill's affordance
            // promises. Lower cards in the stack keep the gesture attached (harmless, `isTop`
            // guards the action) rather than branching the modifier itself, matching how
            // `dragLabels` above is gated.
            .simultaneousGesture(TapGesture().onEnded { if isTop { openCompose(for: photo) } })
    }

    private var dragLabels: some View {
        ZStack {
            label("PUBLISH", color: .green, angle: -14)
                .opacity(Double(max(0, drag.width) / 90))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            label("ARCHIVE", color: accent, angle: 14)
                .opacity(Double(max(0, -drag.width) / 90))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .padding(18)
    }

    private func label(_ text: String, color: Color, angle: Double) -> some View {
        Text(text)
            .flimFont(22, weight: .heavy, relativeTo: .title3)
            .foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(color, lineWidth: 3))
            .rotationEffect(.degrees(angle))
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 14) {
            HStack(spacing: 26) {
                circleButton("tray.and.arrow.down", tint: accent, size: 54,
                             caption: "Keep", label: "Keep in your Darkroom") { performSwipe(.archive) }
                circleButton("trash", tint: .red, size: 64,
                             caption: "Delete", label: "Delete photo") { performSwipe(.trash) }
                circleButton("paperplane.fill", tint: .green, size: 54,
                             caption: "Post", label: "Post to your page") { performSwipe(.publish) }
            }

            // One line, once, and only while it can still change what you do. Three tinted
            // icons do not say which one is public, and the drag labels only appear once the
            // card is already moving, so the first time through the only way to find out that
            // right means POST is to post something.
            if showSwipeHint {
                Text("Swipe right to post, left to keep it private.")
                    .flimFont(12, relativeTo: .caption)
                    .foregroundStyle(FlimTheme.textSecondary)
                    .transition(.opacity)
            }
        }
        .padding(.bottom, 30).padding(.top, 10)
    }

    /// `caption` names the action under the icon; `label` is the fuller VoiceOver phrasing.
    ///
    /// These were icon-only. A paper plane is "send", but send WHERE, and to whom, is exactly
    /// the thing you want to know before you tap it, since this is the one control in the app
    /// that makes a photograph public.
    private func circleButton(_ icon: String, tint: Color, size: CGFloat,
                              caption: String, label: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 7) {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: size * 0.36, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: size, height: size)
                    .background(Color.white.opacity(0.08), in: Circle())
                    .overlay(Circle().stroke(tint.opacity(0.4), lineWidth: 1))
            }
            // Every circle gets the same vertical slot (the largest, Delete's), centred within
            // it, so the three captions below land on one baseline even though Delete's circle is
            // deliberately bigger than Keep/Post's.
            .frame(height: Self.largestCircleSize)
            Text(caption)
                .flimFont(11, relativeTo: .caption2)
                .foregroundStyle(FlimTheme.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Gestures & actions

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { drag = $0.translation }
            .onEnded { value in
                if value.translation.width > threshold { performSwipe(.publish) }
                else if value.translation.width < -threshold { performSwipe(.archive) }
                else { withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { drag = .zero } }
            }
    }

    /// `caption`/`tags` are only ever non-empty when this came from the compose sheet; the plain
    /// swipe-right and the green Post button both call this with neither, so they stay exactly
    /// the instant, caption-less, tag-less publish they always were.
    private func performSwipe(_ action: SortAction, caption: String? = nil, tags: [PendingTag] = []) {
        guard let photo = cards.first else { return }
        Haptics.tap()

        switch action {
        case .archive: withAnimation(.easeOut(duration: 0.28)) { drag = CGSize(width: -700, height: 0) }
        case .publish: withAnimation(.easeOut(duration: 0.28)) { drag = CGSize(width: 700, height: 0) }
        case .trash:   withAnimation(.easeIn(duration: 0.25)) { drag = CGSize(width: 0, height: 900) }
        }

        // The previous swipe can no longer be undone, commit it now, and hold this one.
        if let p = lastPhoto, let a = lastAction {
            let prevCaption = lastCaption, prevTags = lastTags
            lastPhoto = nil; lastAction = nil; lastCaption = nil; lastTags = []
            Task { await commit(p, a, caption: prevCaption, tags: prevTags) }
        }
        lastPhoto = photo
        lastAction = action
        lastCaption = caption
        lastTags = tags
        sortsCompleted += 1

        // Advance the deck after the card flies off.
        Task {
            try? await Task.sleep(for: .milliseconds(280))
            if !cards.isEmpty { cards.removeFirst() }
            drag = .zero
            if cards.isEmpty { onFinish() }
        }
    }

    /// Closes the deck, finishing any held action FIRST so the caller's refresh sees the
    /// committed state (otherwise the "N to sort" count lingers).
    private func closeDeck() {
        guard !closing else { return }   // auto-dismiss + button could both fire
        closing = true
        let p = lastPhoto, a = lastAction, caption = lastCaption, tags = lastTags
        lastPhoto = nil; lastAction = nil; lastCaption = nil; lastTags = []
        Task {
            if let p, let a { await commit(p, a, caption: caption, tags: tags) }
            dismiss()
        }
    }

    private func undo() {
        guard let photo = lastPhoto else { return }
        Haptics.select()
        lastPhoto = nil
        lastAction = nil
        lastCaption = nil
        lastTags = []
        drag = .zero
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            cards.insert(photo, at: 0)
        }
    }

    /// Applies a sort action to the backend. `caption`/`tags` only apply to `.publish`; the plain
    /// swipe-right/Post fast path calls this with neither, exactly as before.
    private func commit(_ photo: Photo, _ action: SortAction, caption: String? = nil,
                         tags: [PendingTag] = []) async {
        guard let uid = auth.currentUser?.id else { return }
        switch action {
        case .archive:
            await photoService.markSorted(photoId: photo.id)
        case .publish:
            await photoService.markSorted(photoId: photo.id)
            do {
                let tagsSaved = try await feed.createPost(photo: photo, caption: caption, userId: uid, tags: tags)
                if shouldWarnThatTagsDidNotSave(tagsSaved) {
                    // The post itself is live, only the tags failed to attach; a genuine failure
                    // still has to speak up, same reasoning as the publish failure right below,
                    // it just isn't the same failure.
                    Haptics.error()
                    publishError = "Posted, but the tags didn't save. Try again from Edit tags."
                }
            } catch {
                // The photo is already marked sorted and the card is gone, so silence here means
                // someone believes they published something that never left the device. This is
                // the one action in the deck that makes a photo public; it has to speak up.
                Haptics.error()
                publishError = "Couldn't share that one. It's in your Darkroom, share it from there."
            }
        case .trash:
            // No `feed.dropPost` needed here: `cards` only ever holds unsorted photos
            // (`fetchUnsorted`, `is_sorted = false`), and the only path that creates a post
            // (`.publish` above) marks the photo sorted BEFORE calling `createPost`, so a photo
            // still in this deck can never have a post to drop.
            let ok = await photoService.deletePhoto(photo)
            if !ok {
                // `deletePhoto` deliberately leaves the row in place when the server refuses
                // (network dropped, the Storage removal itself failed), so the photo is still
                // really there. The swipe animation already carried it off the deck and
                // `performSwipe` already dropped it from `cards`; without putting it back it
                // would just look gone for the rest of this session even though it survived.
                Haptics.error()
                publishError = "Couldn't delete that one. Check your connection and try again."
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    cards.insert(photo, at: 0)
                }
            }
        }
    }

    private func load() async {
        guard let uid = auth.currentUser?.id else { loaded = true; return }
        cards = await photoService.fetchUnsorted(userId: uid)

        // Batched, not one at a time. `signedURLs` reuses persisted URLs and mints the misses in
        // parallel; signing them in a loop cost one sequential round trip PER PHOTO before the
        // deck could be shown. Sorting is what you do right after shooting a batch, so this was
        // slowest exactly when there was most to sort. Same fix RollsView already carries for
        // roll covers.
        // `viewPath`, not `storagePath`: the 1400px card rather than the 2048px master. This deck
        // shows one photo full-screen and does not pinch-zoom, which is precisely the case
        // `Photo.viewPath` exists for -- "pixel-identical to the full 2048px image here for
        // roughly a third of the bytes". Measured, those bytes are 383 kB against 1008 kB, and
        // sorting is what you do immediately after shooting a batch, so this was the app's hottest
        // path fetching its largest object. Falls back to the master on its own for a photo whose
        // rendition has not landed yet (1 of 10 unsorted in production today).
        let head = Array(cards.prefix(5))
        let headURLs = await photoService.signedURLs(for: head.map(\.viewPath))
        for photo in head { urls[photo.id] = headURLs[photo.viewPath] }
        loaded = true

        // The rest can arrive after the deck is interactive.
        let tail = Array(cards.dropFirst(5))
        guard !tail.isEmpty else { return }
        let tailURLs = await photoService.signedURLs(for: tail.map(\.viewPath))
        for photo in tail { urls[photo.id] = tailURLs[photo.viewPath] }
    }
}
