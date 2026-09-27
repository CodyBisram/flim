import SwiftUI

/// Lapse-style triage deck for un-sorted instants: swipe left to archive (Darkroom),
/// right to publish (Feed), or tap the red button to trash.
struct SortDeckView: View {
    @Environment(\.flimAccent) private var accent
    @Environment(AuthService.self) private var auth
    @Environment(PhotoService.self) private var photoService
    @Environment(FeedService.self) private var feed
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Called when the deck is emptied so the Darkroom can refresh.
    var onFinish: () -> Void = {}

    @State private var cards: [Photo] = []
    /// The session's live state: the cards' signed URLs and the frames this sort posted. An
    /// observable model rather than `@State` values, so the session sheet reads it in its own
    /// body; see `SortDeckSession`.
    @State private var session = SortDeckSession()
    /// True from an action's tap until its card has left the deck; see `performSwipe`.
    @State private var isTransitioning = false
    @State private var drag: CGSize = .zero
    @State private var loaded = false
    @State private var closing = false
    /// The last card left on its own and the session is being finished; see `finishSession`.
    @State private var finishing = false
    /// The held swipe `finishSession` took, on the wire. `closeDeck` waits for it before it
    /// dismisses, as it waits for a held swipe of its own, so the Darkroom refresh behind the
    /// deck still sees the committed state.
    @State private var finishCommit: Task<Void, Never>?
    /// This week's Spotlight entry, read when the deck opens if it was unknown or past its
    /// close. The session's end waits for this one read rather than guessing.
    @State private var entryRead: Task<Void, Never>?
    /// The Spotlight session sheet; nil is no sheet. Presented by ITEM, for the same reason as
    /// `composePhoto` below.
    @State private var sessionOffer: SpotlightSessionOffer?
    /// An offer made while the compose sheet was still going (the last card posted from it):
    /// presenting a second sheet during the first one's exit can be dropped by SwiftUI, leaving
    /// an offer set and no sheet, so it waits for the compose sheet's onDismiss.
    @State private var deferredOffer: SpotlightSessionOffer?
    /// Set as the compose sheet posts, cleared in its onDismiss: it is on its way out.
    @State private var composeClosing = false
    /// The offer the sheet actually appeared with, kept past its dismissal (which clears
    /// `sessionOffer`) so the close can record what it showed. nil until it has appeared.
    @State private var shownOffer: SpotlightSessionOffer?
    /// A put-up from the session sheet landed; read as the sheet closes, for the ledger.
    @State private var sessionPutUp = false
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
    /// A post that landed, said once so the person knows where it went. Cleared by the next
    /// action or a few seconds, whichever first.
    @State private var postedNotice = false
    /// Which posted notice the running three-second timer belongs to; see `commit`.
    @State private var postedNoticeId: UUID?
    /// The compose sheet, opened from the pill under the top card or a tap on the card itself.
    /// The photo the compose sheet is open for; nil is no sheet. Presented by ITEM, not by a
    /// Bool beside an optional: `.sheet(isPresented:) { if let composePhoto { ... } }` built
    /// the sheet's content from the optional as it was when presentation began, which SwiftUI
    /// can evaluate before the same transaction's write to it is visible, so the sheet came
    /// up empty (no title, no fields, a dark rectangle) and stayed that way until something
    /// else re-rendered it, seconds later. `.sheet(item:)` hands the photo to the content
    /// directly, so there is nothing to be nil.
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

    /// The notice row's resting height under `controls`: the blank space the deck always kept
    /// there, which a one-line notice fits inside. See `publishErrorBanner`.
    private static let noticeRowHeight: CGFloat = 30

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
                    // Nothing left to sort, return to the previous screen (no "all sorted" wall),
                    // by way of the Spotlight session sheet when this sort posted a frame that
                    // can go up. See `finishSession`.
                    Color.clear.onAppear { finishSession() }
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
                    controls
                    ZStack(alignment: .top) {
                        Color.clear.frame(height: Self.noticeRowHeight)
                        publishErrorBanner
                            // A few points under the captions, where the notice always sat.
                            .padding(.top, 4)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity)
                    }
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
        .sheet(item: $composePhoto, onDismiss: {
            composeClosing = false
            // The last card, posted from here: its session sheet waited for this one to go.
            guard let offer = deferredOffer else { return }
            deferredOffer = nil
            guard !closing else { return }
            if session.offered(offer).isEmpty { closeDeck() } else { sessionOffer = offer }
        }) { composePhoto in
            SortDeckComposeSheet(photo: composePhoto, url: session.urls[composePhoto.id],
                                  caption: $composeCaption, tags: $composeTags) {
                composeClosing = true
                // Same publish path as swipe-right/the Post button, just carrying what was
                // typed into the sheet: `performSwipe` already commits the PREVIOUS held
                // action, flies this card off, and holds this one for undo exactly as it does
                // for the fast path.
                performSwipe(.publish, caption: composeCaption, tags: composeTags)
            }
        }
        .sheet(item: $sessionOffer, onDismiss: { sessionSheetClosed() }) { offer in
            SpotlightSessionSheet(
                offer: offer,
                session: session,
                accessibilitySize: typeSize.isAccessibilitySize,
                onPutUp: { await putUpFromSession($0, offer: offer) })
            .onAppear { sessionSheetAppeared(offer) }
        }
        // The session sheet's "Up now" row shows the frame up this week: read on open, and
        // again whenever the frame up changes (a put-up from here, or from another phone).
        // Nothing up clears it without a request.
        .task(id: feed.ownSpotlightEntry?.photoId) {
            guard let uid = auth.currentUser?.id else { return }
            await feed.refreshOwnSpotlightThumb(userId: uid)
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

    /// A real row under `controls`, top-aligned in a `noticeRowHeight` slot: the slot is the
    /// blank space the deck always kept below the captions, so a one-line notice (the posted
    /// line and View fit one line on every phone at the default size) appears without moving
    /// anything. A notice that needs more (an error, a large text size) grows the row, and the
    /// card, the flexible child above, gives up the height: nothing overlaps the captions or
    /// runs off the bottom of a phone without a home indicator.
    @ViewBuilder private var publishErrorBanner: some View {
        if postedNotice, publishError == nil {
            HStack(spacing: 10) {
                Label("Posted. Your followers can see it.", systemImage: "checkmark.circle.fill")
                    .flimType(.label)
                    .foregroundStyle(FlimTheme.success)
                Button("View") {
                    guard let uid = auth.currentUser?.id else { return }
                    closeDeck(then: .profile(userId: uid))
                }
                .flimFont(13, weight: .semibold, relativeTo: .subheadline)
                .foregroundStyle(accent)
                .expandTapTarget(top: 14, bottom: 14)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 4)
            .transition(.opacity)
        }
        if let publishError {
            Text(publishError)
                .flimFont(13, relativeTo: .subheadline)
                .foregroundStyle(FlimTheme.error)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 4)
                .transition(.opacity)
        }
    }

    private func openCompose(for photo: Photo) {
        guard composePhoto == nil else { return }
        Haptics.tap()
        composeCaption = ""
        composeTags = []
        composePhoto = photo
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
                .accessibilityLabel("Close")
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
                // 1400 rather than the old 2048: that larger budget existed to cover the extra
                // magnification scaledToFill applied. Fitting a 3:4 photo into a 3:4 card is 1:1,
                // so it matches the full-screen viewer's own budget (`PhotoPagerView`).
                CachedImage(url: session.urls[photo.id], maxPixel: 1400, cacheKey: photo.viewPath) { $0.resizable().scaledToFit() }
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
            label("POST", color: FlimTheme.success, angle: -14)
                .opacity(Double(max(0, drag.width) / 90))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            label("KEEP", color: accent, angle: 14)
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
            // One sorting vocabulary (v2): the word under each circle says what happens, and
            // the three consequential actions always pair their glyph with a word.
            HStack(alignment: .top, spacing: 22) {
                circleButton("lock", tint: accent, size: 54,
                             caption: "Keep private", label: "Keep private. Only you see it, in your Darkroom") { performSwipe(.archive) }
                circleButton("trash", tint: FlimTheme.destructive, size: 54,
                             caption: "Delete", label: "Delete photo") { performSwipe(.trash) }
                circleButton("paperplane", tint: FlimTheme.success, size: 54,
                             caption: "Post to page", label: "Post to your page, for the people who follow you") { performSwipe(.publish) }
            }

            // One line, once, and only while it can still change what you do. Three tinted
            // icons do not say which one is public, and the drag labels only appear once the
            // card is already moving, so the first time through the only way to find out that
            // right means POST is to post something.
            if showSwipeHint {
                Text("Keeping a photo puts it in your Darkroom, where only you can see it. Posting shows it to the people who follow you.")
                    .flimType(.meta)
                    .foregroundStyle(FlimTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, FlimSpace.xxl)
                    .transition(.opacity)
            }
        }
        .padding(.top, 10)
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
                .flimType(.label)
                .foregroundStyle(FlimTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(width: 92)
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
        // One action per card. A second tap (or a swipe plus a tap) inside the 280 ms transition
        // used to act on the SAME top card and then remove a second one, so the next photograph
        // left the deck unreviewed. The card is claimed here and released when it is gone.
        guard !isTransitioning, let photo = cards.first else { return }
        isTransitioning = true
        postedNotice = false
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
        if action == .publish {
            // Pending until its commit answers; Undo takes it back out (it never committed).
            session.published(photo, isTagged: !tags.isEmpty)
        }

        // Advance the deck after the card flies off.
        Task {
            try? await Task.sleep(for: .milliseconds(280))
            // Remove the card that was acted on, by id, never "whatever is on top now".
            if let i = cards.firstIndex(where: { $0.id == photo.id }) { cards.remove(at: i) }
            drag = .zero
            isTransitioning = false
            if cards.isEmpty { onFinish() }
        }
    }

    /// Closes the deck, finishing any held action FIRST so the caller's refresh sees the
    /// committed state (otherwise the "N to sort" count lingers). The deck lands in exactly one
    /// place afterwards, decided here and nowhere else: `destination` when the person asked for
    /// one (the posted notice's View), else a new account's first-sort Darkroom, else wherever
    /// the dismiss leaves them. Posting the destination from the button and letting the default
    /// fire later let the default win over an explicit tap (audit A6).
    private func closeDeck(then destination: PushDestination? = nil) {
        guard !closing else { return }   // auto-dismiss + button could both fire
        closing = true
        let p = lastPhoto, a = lastAction, caption = lastCaption, tags = lastTags
        lastPhoto = nil; lastAction = nil; lastCaption = nil; lastTags = []
        Task {
            if let p, let a { await commit(p, a, caption: caption, tags: tags) }
            await finishCommit?.value
            dismiss()
            // A new account's first sort ends in the Darkroom, once (owner's call 2026-09-09):
            // the frame they just kept is the reason the Darkroom exists, and landing back on
            // the camera hid it. `.openDarkroom` is the same switch a push uses. Only after a
            // sort actually happened, never on a deck closed untouched. An explicit destination
            // consumes the one-shot too: the person has seen where their frame went.
            let firstSortPending: Bool = {
                guard sortsCompleted > 0, let uid = auth.currentUser?.id,
                      NewAccountIntro.isNewAccount(createdAt: auth.currentUser?.createdAt),
                      !NewAccountIntro.firstSortLanded(userId: uid) else { return false }
                NewAccountIntro.markFirstSortLanded(userId: uid)
                return true
            }()
            if let destination {
                NotificationCenter.default.post(name: .openPushDestination, object: destination)
            } else if firstSortPending {
                NotificationCenter.default.post(name: .openDarkroom, object: nil)
            }
        }
    }

    // MARK: - The Spotlight session sheet

    /// This week's entry, when it belongs to this account and its week has not closed; nil
    /// means unknown, and nothing is offered on an unknown week.
    private var currentSpotlightEntry: OwnSpotlightEntry? {
        guard feed.ownSpotlightEntryIsCurrent, let entry = feed.ownSpotlightEntry,
              Date.now < entry.weekClosesAt else { return nil }
        return entry
    }

    /// How long the end of a sort waits for an unknown week before closing with no sheet.
    private static let entryWait: Duration = .milliseconds(1500)

    /// The last card left on its own. With nothing from this sort that could go up, this is
    /// `closeDeck()`, exactly as before. Otherwise the held swipe is committed now (Undo ends
    /// here, which is where the deck used to close) and the session sheet is offered over the
    /// emptied deck, without waiting for that commit: its frame shows as still posting. The
    /// header's X and the posted notice's View never come through here, so they never show it.
    private func finishSession() {
        guard !finishing, !closing else { return }
        finishing = true
        // Nothing untagged of your own posted: no entry could make an offer, so nothing waits.
        guard let uid = auth.currentUser?.id, session.hasCandidate(viewerId: uid) else {
            closeDeck()
            return
        }
        if let entry = currentSpotlightEntry {
            guard let offer = makeSessionOffer(entry: entry, userId: uid) else {
                closeDeck()
                return
            }
            commitHeldForFinish()
            present(offer, userId: uid)
            return
        }
        // The week is not known yet: wait for the one read the deck started (or start it), but
        // not past `entryWait`, since the emptied deck is blank meanwhile; then offer, or close
        // with no sheet if it is still unknown. A read that lands later still updates the menus.
        commitHeldForFinish()
        let read = entryRead ?? Task { await feed.refreshOwnSpotlightEntry() }
        Task {
            _ = await SortDeckSession.finished(read, within: Self.entryWait)
            guard !closing else { return }
            guard let entry = currentSpotlightEntry, let offer = makeSessionOffer(entry: entry, userId: uid) else {
                closeDeck()
                return
            }
            present(offer, userId: uid)
        }
    }

    private func makeSessionOffer(entry: OwnSpotlightEntry, userId: UUID) -> SpotlightSessionOffer? {
        session.offer(entry: entry, viewerId: userId, ledger: SpotlightSessionLedger.load(userId: userId))
    }

    /// Takes the held swipe and starts its commit, for `closeDeck` to wait on later.
    private func commitHeldForFinish() {
        guard let p = lastPhoto, let a = lastAction else { return }
        let caption = lastCaption, tags = lastTags
        lastPhoto = nil; lastAction = nil; lastCaption = nil; lastTags = []
        finishCommit = Task { await commit(p, a, caption: caption, tags: tags) }
    }

    /// Presents the sheet, or holds it for the compose sheet's onDismiss while that sheet is
    /// still up or on its way out. Nothing is written to the ledger until it appears.
    private func present(_ offer: SpotlightSessionOffer, userId: UUID) {
        var offer = offer
        offer.firstTime = !SpotlightFirstTime.hasSeen(userId: userId)
        sessionPutUp = false
        session.kindOverride = nil
        session.emptiedByFailures = false
        if composePhoto != nil || composeClosing {
            deferredOffer = offer
        } else {
            sessionOffer = offer
        }
    }

    /// The sheet is on screen: only now is a swap ask spent for the week.
    private func sessionSheetAppeared(_ offer: SpotlightSessionOffer) {
        guard shownOffer?.id != offer.id else { return }
        shownOffer = offer
        guard offer.isSwap, let uid = auth.currentUser?.id else { return }
        var ledger = SpotlightSessionLedger.load(userId: uid)
        ledger.recordSwapShown(weekKey: offer.weekKey)
        SpotlightSessionLedger.save(ledger, userId: uid)
    }

    /// The sheet's put-up. The first time for this account, the sheet's own copy was the
    /// explanation, so the tap marks it seen before sending.
    ///
    /// The button said put up or swap against the entry as it was when the sheet opened. If
    /// the frame up has changed since (another phone), the tap would do something else than
    /// it said, so nothing is sent: the entry is read again and the sheet's title, Up now row
    /// and button move to what a tap does now, for a fresh tap.
    private func putUpFromSession(_ post: Post, offer: SpotlightSessionOffer) async -> SpotlightPutUpOutcome {
        let shownSwap = { if case .swap = session.kind(offer) { return true } else { return false } }()
        if currentSpotlightEntry.map({ ($0.postId != nil) != shownSwap }) ?? true {
            await feed.refreshOwnSpotlightEntry()
            guard let fresh = currentSpotlightEntry else {
                Haptics.error()
                return .refused(message: SpotlightRefusal.putUpNetwork, refusal: nil)
            }
            // An account that can no longer put up (a covered window began) is not a connection
            // problem: end the sheet the way the server's own "covered" refusal would.
            guard fresh.canPutUp else {
                Haptics.error()
                return .refused(message: SpotlightRefusal.message(refusal: "covered", action: .putUp)
                                    ?? SpotlightRefusal.cantGoUp, refusal: "covered")
            }
            guard let kind = SpotlightSessionOffer.kind(for: fresh) else {
                Haptics.error()
                return .refused(message: SpotlightRefusal.putUpNetwork, refusal: nil)
            }
            let freshSwap = { if case .swap = kind { return true } else { return false } }()
            if freshSwap != shownSwap {
                Haptics.warning()
                session.kindOverride = kind
                return .frameUpChanged
            }
        }
        if offer.firstTime, let uid = auth.currentUser?.id { SpotlightFirstTime.markSeen(userId: uid) }
        let outcome = await feed.putUpForSpotlightOutcome(post)
        if case .up = outcome { sessionPutUp = true }
        return outcome
    }

    /// Done, Not now, a pull down, and a sheet emptied by failed posts all end here: the
    /// ledger records what was shown (a decline only when the person said no), and the deck
    /// closes exactly as it would have when the last card left.
    private func sessionSheetClosed() {
        if let uid = auth.currentUser?.id, let offer = shownOffer {
            var ledger = SpotlightSessionLedger.load(userId: uid)
            // A frame still posting when the sheet closed has no post to name; it is new, so no
            // later sheet can meet it again anyway.
            let shown = session.offered(offer).compactMap { $0.post?.id }
            ledger.recordClosed(weekKey: offer.weekKey, shownPostIds: shown,
                                declined: !sessionPutUp && !session.emptiedByFailures)
            SpotlightSessionLedger.save(ledger, userId: uid)
        }
        shownOffer = nil
        closeDeck()
    }

    private func undo() {
        // Not while the swiped card is still flying off: the advance that follows would remove
        // the card Undo just put back, by id, and on the last card close the deck with the frame
        // unsorted. The card settles in 280 ms.
        guard !isTransitioning, let photo = lastPhoto else { return }
        Haptics.select()
        if lastAction == .publish { session.undone(photoId: photo.id) }
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
                let created = try await feed.createPost(photo: photo, caption: caption, userId: uid, tags: tags)
                let tagsSaved = created.tagsSaved
                session.landed(photoId: photo.id, post: created.post)
                // The timer belongs to THIS notice: a second post inside the three seconds
                // starts its own, and the first one's expiry no longer hides it (audit A8).
                let notice = UUID()
                postedNoticeId = notice
                withAnimation { postedNotice = true }
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    if postedNoticeId == notice { withAnimation { postedNotice = false } }
                }
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
                publishError = "Couldn't post that one. It's in your Darkroom, post it from there."
                session.failed(photoId: photo.id)
                // The session sheet never shows a frame that did not post; with nothing left to
                // offer, it goes (not a decline), and its dismissal closes the deck. A sheet
                // still deferred behind the compose sheet is checked in that sheet's onDismiss.
                if let offer = sessionOffer, session.offered(offer).isEmpty {
                    session.emptiedByFailures = true
                    sessionOffer = nil
                }
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
        // The session sheet needs this week's bounds and whether a frame is up. A cold launch
        // straight into the deck has not visited the Feed that reads them, and one read before
        // the week turned would ask about the wrong week, so it is read beside the cards when
        // unknown or past its close, the same condition `loadSpotlightMenuInputs` uses.
        if currentSpotlightEntry == nil {
            entryRead = Task { await feed.refreshOwnSpotlightEntry() }
        }
        // `?? []` preserves this view's original behavior: a fresh deck has no earlier list to
        // keep, so a failure here still just shows the (now correctly typed) empty case.
        cards = await photoService.fetchUnsorted(userId: uid) ?? []

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
        for photo in head { session.urls[photo.id] = headURLs[photo.viewPath] }
        loaded = true

        // The rest can arrive after the deck is interactive.
        let tail = Array(cards.dropFirst(5))
        guard !tail.isEmpty else { return }
        let tailURLs = await photoService.signedURLs(for: tail.map(\.viewPath))
        for photo in tail { session.urls[photo.id] = tailURLs[photo.viewPath] }
    }
}
