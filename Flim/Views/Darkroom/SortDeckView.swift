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
    /// True from an action's tap until its card has left the deck; see `performSwipe`.
    @State private var isTransitioning = false
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
    /// A post that landed, said once so the person knows where it went. Cleared by the next
    /// action or a few seconds, whichever first.
    @State private var postedNotice = false
    /// Which posted notice the running timer belongs to; see `commit`.
    @State private var postedNoticeId: UUID?
    /// The frame just swiped to post, while it can go up for Spotlight: the capsule that shares
    /// the compose pill's slot (see `DeckSpotlightOffer`). Offered at the swipe, not when the
    /// post lands: the deck holds each swipe for Undo and only posts it at the next swipe or the
    /// close, so an offer tied to the post came one card late. Eight seconds, or until the next
    /// swipe, Undo or the close; a put-up on the wire keeps it until the server answers.
    @State private var offer: DeckSpotlightOffer?
    /// The same offer on the last card, where no card is left to hold the capsule: the item of
    /// `SpotlightDeckLastSheet`. Holds the empty deck open until it is answered.
    @State private var lastCardOffer: DeckSpotlightOffer?
    /// The last card posted from the compose sheet: its Spotlight sheet waits for the compose
    /// sheet to finish going, since two presentations at once drop the second.
    @State private var queuedLastCardOffer: DeckSpotlightOffer?
    /// The last card's sheet is on screen, from its appearance until its onDismiss, including
    /// the dismissal itself: dismissing the deck in that window can wedge it mid-animation.
    @State private var lastCardSheetPresented = false
    /// A close asked for while the last card's sheet was up or going; its onDismiss closes.
    @State private var closeAfterLastCardSheet = false
    @Environment(\.dynamicTypeSize) private var typeSize
    /// "Developed after its week closed" is said once per deck open, not once per frame.
    @State private var closedWeekNoticeShown = false
    @State private var developedLateNotice = false
    /// The capsule's take-down says nothing on success, so the deck says it in its own line.
    @State private var takenDownNotice = false
    /// A put-up or take-down the server refused. It lands in `UndoCenter`'s slot too, but the tab
    /// host that renders that sits under this full-screen cover, so the deck says it here.
    @State private var refusalNotice: String?
    /// The Spotlight notice's own height, to tell when it needs the ground under it.
    @State private var spotlightNoticeHeight: CGFloat = 0
    /// The first-time Spotlight sheet, presented over the deck (see `SpotlightPutUpFlow`).
    @State private var spotlightFirstTimePost: Post?
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
                    // The last card's Spotlight sheet holds the deck open until it is answered,
                    // and its dismissal closes the deck.
                    // A put-up from the capsule still in flight (a swipe onto the last card
                    // while it posts, or the first-time sheet over it) holds the deck open too;
                    // it closes once that resolves.
                    Color.clear.onAppear { closeIfEmptyAndSettled() }
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
            // Gone by any route, the deck's own close or not: a put-up still sending must not
            // present the first-time sheet on a view that no longer exists (it says why instead).
            closing = true
            // Safety net if dismissed some other way, commit any still-held action.
            if let p = lastPhoto, let a = lastAction {
                let caption = lastCaption, tags = lastTags
                lastPhoto = nil; lastAction = nil; lastCaption = nil; lastTags = []
                Task { await commit(p, a, caption: caption, tags: tags) }
            }
        }
        // Hosted here, not left to the tab host under this cover: a first-timer's "Put it up"
        // shows the Spotlight explanation sheet, which has to present over the deck. The deck
        // sends the put-up itself, so the capsule can wait for the server's answer.
        .spotlightPutUpFlow(firstTimePost: $spotlightFirstTimePost, takeOutPost: .constant(nil),
                            onFirstTimeAnswer: { firstTimeAnswered($0) })
        .sheet(item: $composePhoto, onDismiss: {
            // The last card, posted from the compose sheet: its Spotlight sheet waited for this
            // one to finish going.
            guard let queued = queuedLastCardOffer else { return }
            queuedLastCardOffer = nil
            if lastPhoto?.id == queued.photo.id {
                lastCardOffer = queued
            } else if cards.isEmpty && loaded {
                closeDeck()
            }
        }) { composePhoto in
            SortDeckComposeSheet(photo: composePhoto, url: urls[composePhoto.id],
                                  caption: $composeCaption, tags: $composeTags,
                                  spotlightEligibleIfUntagged: spotlightEligibleIfUntagged(composePhoto)) {
                // Same publish path as swipe-right/the Post button, just carrying what was
                // typed into the sheet: `performSwipe` already commits the PREVIOUS held
                // action, flies this card off, and holds this one for undo exactly as it does
                // for the fast path.
                performSwipe(.publish, caption: composeCaption, tags: composeTags)
            }
        }
        .sheet(item: $lastCardOffer, onDismiss: {
            // "Not now", "Done", a take-down, a pull down and the header's close all end here
            // and close the deck, and the held frame posts as it would have. Undo put the card
            // back first, so the deck stays.
            lastCardSheetPresented = false
            let closeAsked = closeAfterLastCardSheet
            closeAfterLastCardSheet = false
            if closeAsked || (cards.isEmpty && loaded) { closeDeck() }
        }) { current in
            SpotlightDeckLastSheet(
                offer: current, url: urls[current.photo.id], cacheKey: current.photo.viewPath,
                upThumbURL: feed.ownSpotlightThumb.url, upThumbPath: feed.ownSpotlightThumb.path,
                firstTimeUnseen: auth.currentUser.map { !SpotlightFirstTime.hasSeen(userId: $0.id) } ?? false,
                busy: feed.spotlightWriteInFlight,
                onPutUp: { putUpLastCard() },
                onNotNow: { closeDeck() },
                onDone: { closeDeck() },
                onTakeDown: { takeDownLastCard($0) })
            .onAppear { lastCardSheetPresented = true }
        }
        // A capsule put-up that resolves on an emptied deck closes it (see the empty branch).
        .onChange(of: offer?.phase.isInFlight ?? false) { _, inFlight in
            if !inFlight { closeIfEmptyAndSettled() }
        }
        // The swap names the frame up now and ends on its thumbnail: read on open, and again
        // whenever the frame up changes (a put-up from here, or from another phone).
        .task(id: feed.ownSpotlightEntry?.photoId) {
            guard let uid = auth.currentUser?.id else { return }
            await feed.refreshOwnSpotlightThumb(userId: uid)
        }
        .task(id: offerTimerKey) { await runOfferTimer() }
        .task(id: refusalNotice) {
            guard refusalNotice != nil else { return }
            try? await Task.sleep(for: .seconds(Self.noticeSeconds))
            guard !Task.isCancelled else { return }
            withAnimation(Self.crossFade) { refusalNotice = nil }
        }
        .task(id: takenDownNotice) {
            guard takenDownNotice else { return }
            try? await Task.sleep(for: .seconds(Self.noticeSeconds))
            guard !Task.isCancelled else { return }
            withAnimation(Self.crossFade) { takenDownNotice = false }
        }
        .task(id: developedLateNotice) {
            guard developedLateNotice else { return }
            try? await Task.sleep(for: .seconds(Self.noticeSeconds))
            guard !Task.isCancelled else { return }
            withAnimation(Self.crossFade) { developedLateNotice = false }
        }
    }

    /// The pill under the top card: both the hint that a caption/tags are possible and, along
    /// with the card itself, a tap target into the compose sheet. This is not a hidden gesture,
    /// swipe-right/the green Post button still publish instantly with neither.
    ///
    /// While a Spotlight offer is up, the pair covers the pill: an overlay on the pill's own frame
    /// on the screen's ground, so the card, the slot and the circles keep their sizes at every
    /// text size. The pill underneath stays in the layout, hidden from VoiceOver, and the pair's
    /// compact pill is the same button.
    private func composeHint(for photo: Photo) -> some View {
        Button { openCompose(for: photo) } label: {
            Label("Add a caption or tag people", systemImage: "square.and.pencil")
                .flimFont(13, weight: .medium, relativeTo: .subheadline)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.1), in: Capsule())
        }
        .accessibilityLabel(Self.composeLabel)
        .accessibilityHidden(offer != nil)
        .frame(maxWidth: .infinity)
        .overlay {
            if let offer {
                spotlightPair(offer, top: photo)
                    .padding(.horizontal, Self.horizontalMargin)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(FlimTheme.bg)
                    .clipped()
                    .transition(.opacity)
            }
        }
        .padding(.bottom, 6)
    }

    private static let composeLabel = "Add a caption or tag people on this photo"

    /// The compact pill and the Spotlight capsule, centred, 9pt apart. When the pair does not
    /// fit on one line (a long weekday, an accessibility size), the pill becomes a pencil circle,
    /// the deck's own circle vocabulary, and the capsule may wrap to two lines.
    ///
    /// Compose is off while a put-up from the capsule is in flight: a compose sheet opened then
    /// would take the first-time sheet's place, and that sheet would never come.
    private func spotlightPair(_ offer: DeckSpotlightOffer, top: Photo) -> some View {
        let accessibilitySize = typeSize.isAccessibilitySize
        // Below the accessibility sizes the slot is the pill's height, so the circle is too, and
        // it never clips; at them the slot is tall enough for the deck's 52pt circle.
        let circle: CGFloat = accessibilitySize ? 52 : 32
        let circleInset = max(0, (44 - circle) / 2)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: FlimSpace.m) {
                Button { openCompose(for: top) } label: {
                    Label(SpotlightPostedAsk.composeShort, systemImage: "square.and.pencil")
                        .flimFont(13, weight: .medium, relativeTo: .subheadline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.1), in: Capsule())
                }
                .disabled(offer.phase.isInFlight)
                .expandTapTarget(top: 6, leading: 4, bottom: 6, trailing: 4)
                .accessibilityLabel(Self.composeLabel)
                spotlightCapsule(offer, lineLimit: 1)
            }
            HStack(spacing: FlimSpace.m) {
                Button { openCompose(for: top) } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: accessibilitySize ? 20 : 13, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: circle, height: circle)
                        .background(Color.white.opacity(0.1), in: Circle())
                }
                .disabled(offer.phase.isInFlight)
                .expandTapTarget(top: circleInset, leading: circleInset, bottom: circleInset, trailing: 4)
                .accessibilityLabel(Self.composeLabel)
                // Two lines only where the slot has the height for them.
                spotlightCapsule(offer, lineLimit: accessibilitySize ? 2 : 1)
            }
        }
    }

    /// The capsule, by phase. The accent means "put up" and nothing else: after a put-up the
    /// capsule turns neutral for "Take it down". Phases cross-fade; nothing slides or scales.
    @ViewBuilder
    private func spotlightCapsule(_ offer: DeckSpotlightOffer, lineLimit: Int) -> some View {
        switch offer.phase {
        case .offered, .pending:
            // Pending: the first-time sheet is up over it and nothing has been sent, so it keeps
            // the offer's look rather than a spinner.
            Button { putUpOffered() } label: {
                offerCapsule(offer.kind, lineLimit: lineLimit)
            }
            .disabled(feed.spotlightWriteInFlight || offer.phase == .pending)
            .expandTapTarget(top: 6, leading: 4, bottom: 6, trailing: 4)
            .accessibilityLabel(Self.capsuleLabel(offer.kind))
            .transition(.opacity)
        case .working:
            // Keeps the offer's width, the spinner and words centred in it, so the pill beside
            // it never shifts while the put-up is on the wire.
            offerCapsule(offer.kind, lineLimit: lineLimit, content: .hidden)
                .overlay {
                    HStack(spacing: 7) {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(accent)
                        Text(SpotlightPostedAsk.working)
                            .flimFont(13, weight: .medium, relativeTo: .subheadline)
                            .lineLimit(lineLimit)
                    }
                    .foregroundStyle(accent)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(SpotlightPostedAsk.working)
                .transition(.opacity)
        case .up(let post):
            Button { takeDownOffered(post) } label: {
                HStack(spacing: 7) {
                    Image(systemName: SpotlightGlyph.systemName)
                        .flimFont(12, weight: .medium, relativeTo: .subheadline)
                        .foregroundStyle(FlimTheme.textSecondary)
                    Text(SpotlightPostedAsk.takeDown)
                        .flimFont(13, weight: .medium, relativeTo: .subheadline)
                        .foregroundStyle(.white)
                        .lineLimit(lineLimit)
                        .multilineTextAlignment(.leading)
                }
                .padding(.leading, 12)
                .padding(.trailing, 15)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.1), in: Capsule())
            }
            .disabled(feed.spotlightWriteInFlight)
            .expandTapTarget(top: 6, leading: 4, bottom: 6, trailing: 4)
            .accessibilityLabel(SpotlightPostedAsk.takeDownLabel)
            .transition(.opacity)
        }
    }

    private enum CapsuleContent { case shown, hidden }

    /// The accent capsule for an offer: "Put it up for Spotlight", or "Swap in for Tuesday's"
    /// ending on Tuesday's frame so the word and the picture sit together.
    private func offerCapsule(_ kind: SpotlightPostedAsk.Kind, lineLimit: Int,
                              content: CapsuleContent = .shown) -> some View {
        HStack(spacing: 7) {
            Image(systemName: SpotlightGlyph.systemName)
                .flimFont(12, weight: .medium, relativeTo: .subheadline)
            Text(Self.capsuleTitle(kind))
                .flimFont(13, weight: .medium, relativeTo: .subheadline)
                .lineLimit(lineLimit)
                .multilineTextAlignment(.leading)
            if case .swap = kind {
                // Chrome, so it stays 15 by 20 at every text size.
                CachedImage(url: feed.ownSpotlightThumb.url, maxPixel: 112, cacheKey: feed.ownSpotlightThumb.path) {
                    $0.resizable().scaledToFill()
                } placeholder: {
                    FlimTheme.loading
                }
                .frame(width: 15, height: 20)
                // The photo radius, halved for a frame this small.
                .clipShape(RoundedRectangle(cornerRadius: FlimRadius.photo / 2))
                .overlay(RoundedRectangle(cornerRadius: FlimRadius.photo / 2).stroke(Color.white.opacity(0.16), lineWidth: 1))
            }
        }
        .opacity(content == .hidden ? 0 : 1)
        .foregroundStyle(accent)
        // The swap trims its vertical padding so the 20pt frame keeps the capsule at 32, and
        // ends 9pt from the curve so the curve never clips the frame's corners.
        .padding(.leading, 12)
        .padding(.trailing, kind == .putUp ? 15 : 9)
        .padding(.vertical, kind == .putUp ? 8 : 6)
        .background(flimAccentSoft(accent), in: Capsule())
    }

    private static func capsuleTitle(_ kind: SpotlightPostedAsk.Kind) -> String {
        switch kind {
        case .putUp: SpotlightPostedAsk.putUpCapsule
        case .swap(let day): SpotlightPostedAsk.swapCapsule(day: day)
        }
    }

    private static func capsuleLabel(_ kind: SpotlightPostedAsk.Kind) -> String {
        switch kind {
        case .putUp: SpotlightPostedAsk.putUpLabel
        case .swap(let day): SpotlightPostedAsk.swapLabel(day: day)
        }
    }

    /// Overlaid on `controls`, not inserted into the VStack: it used to sit between the compose
    /// pill and `controls`, so the whole control row jumped down when a publish/delete error
    /// appeared and back up when it cleared. Anchored to `controls`' own bottom edge rather than
    /// to the button row itself, so it lands inside `controls`' existing 30pt trailing padding
    /// (otherwise-blank space below the captions) regardless of whether the swipe hint line below
    /// the buttons is showing, and doesn't reach up far enough to compete with the compose pill
    /// above.
    @ViewBuilder private var publishErrorBanner: some View {
        if let line = spotlightLine, publishError == nil {
            spotlightNotice(line)
                .transition(.opacity)
        } else if postedNotice, publishError == nil {
            VStack(spacing: 2) {
                HStack(spacing: 10) {
                    Label("Posted to your page. Your followers can see it.", systemImage: "checkmark.circle.fill")
                        .flimType(.label)
                        .foregroundStyle(FlimTheme.success)
                    Button("View") {
                        guard let uid = auth.currentUser?.id else { return }
                        closeDeck(then: .profile(userId: uid))
                    }
                    .flimFont(13, weight: .semibold, relativeTo: .subheadline)
                    .foregroundStyle(accent)
                }
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

    /// What Spotlight says in the notice area, most urgent first. The put-up's confirmation is
    /// `UndoCenter`'s own line, read while the capsule shows the frame is up.
    private enum SpotlightLine: Equatable {
        case refusal(String)
        case confirmation(String)
        case takenDown
        case developedLate
    }

    private var spotlightLine: SpotlightLine? {
        if let refusalNotice { return .refusal(refusalNotice) }
        if case .up = offer?.phase, UndoCenter.shared.noticeIsConfirmation,
           let text = UndoCenter.shared.failureNotice {
            return .confirmation(text)
        }
        if takenDownNotice { return .takenDown }
        if developedLateNotice { return .developedLate }
        return nil
    }

    /// Where the captions start inside `controls`: its top padding, the circles' slot, and the
    /// gap to the caption.
    private static let captionTop: CGFloat = 10 + largestCircleSize + 7
    /// The blank space under the captions that a one-line notice fits in.
    private static let noticeRoom: CGFloat = 30

    /// A notice taller than the room under the captions (a swap's two lines, a closed week, any
    /// line at a large text size) sits over them for its few seconds on the screen's own
    /// ground, so it reads as the notice rather than as text printed over text. The layout
    /// never moves.
    private func spotlightNotice(_ line: SpotlightLine) -> some View {
        let coversCaptions = spotlightNoticeHeight > Self.noticeRoom
        return spotlightNoticeText(line)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, line == .developedLate ? 28 : 24)
            .padding(.bottom, 4)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { spotlightNoticeHeight = $0 }
            .frame(maxWidth: .infinity, maxHeight: coversCaptions ? .infinity : nil, alignment: .bottom)
            .background(coversCaptions ? FlimTheme.bg : Color.clear)
            .padding(.top, coversCaptions ? Self.captionTop : 0)
    }

    @ViewBuilder private func spotlightNoticeText(_ line: SpotlightLine) -> some View {
        switch line {
        case .refusal(let text):
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .flimType(.label)
                .foregroundStyle(FlimTheme.error)
                .multilineTextAlignment(.leading)
        case .confirmation(let text):
            Label(text, systemImage: "checkmark.circle.fill")
                .flimType(.label)
                .foregroundStyle(FlimTheme.success)
                .multilineTextAlignment(.leading)
        case .takenDown:
            Text(SpotlightPostedAsk.takenDown)
                .flimType(.label)
                .foregroundStyle(FlimTheme.textSecondary)
                .multilineTextAlignment(.center)
        case .developedLate:
            Text(SpotlightPostedAsk.developedLate)
                .flimType(.meta)
                .foregroundStyle(FlimTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Spotlight

    /// How long the capsule stays with nobody answering, and after a put-up for "Take it down".
    private static let offerSeconds: Double = 8
    /// How long the deck's own Spotlight lines stay, the posted notice's few seconds.
    private static let noticeSeconds: Double = 3
    /// The pair and its phases cross-fade in 0.2s. No slide and no scale, so Reduce Motion needs
    /// nothing different.
    private static let crossFade = Animation.easeInOut(duration: 0.2)

    /// Makes the offer for a frame just swiped to post, or breaks the silence once for a frame
    /// that developed after its week closed. Nothing is said for any other frame that cannot go
    /// up: the offer comes for every one that can, so its absence is the answer.
    private func offerSpotlight(for photo: Photo, userId: UUID, tags: [PendingTag], isLast: Bool) {
        // One at a time: a put-up on the wire keeps the slot, and its answer is about to change
        // the entry this frame's offer would be made against.
        guard !(offer?.phase.isInFlight ?? false), let entry = feed.ownSpotlightEntry else { return }
        if let kind = SpotlightPostedAsk.offer(userId: userId, photoOwnerId: photo.userId, isTagged: !tags.isEmpty,
                                               entry: entry, takenAt: photo.takenAt, postedAt: .now) {
            let next = DeckSpotlightOffer(photo: photo, kind: kind, weekKey: entry.weekKey)
            if isLast {
                closeAfterLastCardSheet = false
                if composePhoto != nil { queuedLastCardOffer = next } else { lastCardOffer = next }
            } else {
                withAnimation(Self.crossFade) { offer = next }
                AccessibilityNotification.Announcement(SpotlightPostedAsk.announcement).post()
            }
        } else if !isLast, !closedWeekNoticeShown, photo.userId == userId, tags.isEmpty,
                  entry.canPutUp, Date.now < entry.weekClosesAt,
                  SpotlightPostedAsk.developedAfterClose(takenAt: photo.takenAt, developsAt: photo.developsAt,
                                                         entry: entry) {
            closedWeekNoticeShown = true
            withAnimation(Self.crossFade) { developedLateNotice = true }
        }
    }

    /// Whether the compose sheet's frame could go up with nobody tagged, for its tagged line.
    private func spotlightEligibleIfUntagged(_ photo: Photo) -> Bool {
        guard let uid = auth.currentUser?.id else { return false }
        return SpotlightPostedAsk.offer(userId: uid, photoOwnerId: photo.userId, isTagged: false,
                                        entry: feed.ownSpotlightEntry, takenAt: photo.takenAt,
                                        postedAt: .now) != nil
    }

    /// The capsule's timer, keyed so it restarts on each phase and stops while the first-time
    /// sheet is up.
    private struct OfferTimerKey: Hashable {
        let photoId: UUID
        let phase: Int
        let paused: Bool
    }

    private var offerTimerKey: OfferTimerKey? {
        guard let offer else { return nil }
        let phase: Int
        switch offer.phase {
        case .offered: phase = 0
        case .pending: phase = 1
        case .working: phase = 2
        case .up: phase = 3
        }
        return OfferTimerKey(photoId: offer.photo.id, phase: phase, paused: spotlightFirstTimePost != nil)
    }

    /// Eight seconds for an offer. A put-up on the wire waits for the server instead, then
    /// "Take it down" gets its own eight seconds; later, it is the post's menu. Never past the
    /// week's close, where either answer would only be refused.
    private func runOfferTimer() async {
        guard let key = offerTimerKey, !key.paused, let offer, !offer.phase.isInFlight else { return }
        let untilClose = feed.ownSpotlightEntry?.weekClosesAt.timeIntervalSinceNow ?? Self.offerSeconds
        let seconds = max(0, min(Self.offerSeconds, untilClose))
        try? await Task.sleep(for: .seconds(seconds))
        guard !Task.isCancelled, self.offer?.photo.id == key.photoId else { return }
        withAnimation(Self.crossFade) { self.offer = nil }
    }

    /// The capsule's "Put it up" or "Swap in": posts the held frame now (it can no longer be
    /// undone, which is what answering means), then runs the menu's own flow, so a first-timer
    /// reads the explanation first and the confirmation waits for the server.
    ///
    /// Every path out of `.pending` and `.working` resolves the offer: a failed post clears it,
    /// a sent put-up ends in `finishPutUp`, the first-time sheet's dismissal always answers in
    /// `firstTimeAnswered`, and a put-up that could not be sent or shown says so.
    private func putUpOffered() {
        guard var current = offer, current.phase == .offered, !closing, !feed.spotlightWriteInFlight,
              lastPhoto?.id == current.photo.id, lastAction == .publish,
              let uid = auth.currentUser?.id else { return }
        // The entry may have moved since the offer was made (the week closed, a frame went up
        // from another phone): what is sent has to be what the capsule says.
        guard let kind = SpotlightPostedAsk.offer(userId: uid, photoOwnerId: current.photo.userId,
                                                  isTagged: !lastTags.isEmpty, entry: feed.ownSpotlightEntry,
                                                  takenAt: current.photo.takenAt, postedAt: .now) else {
            Haptics.error()
            withAnimation(Self.crossFade) {
                offer = nil
                refusalNotice = staleOfferRefusal()
            }
            return
        }
        guard kind == current.kind else {
            withAnimation(Self.crossFade) { offer?.kind = kind }
            return
        }
        let caption = lastCaption, tags = lastTags
        lastPhoto = nil; lastAction = nil; lastCaption = nil; lastTags = []
        // A first-timer's put-up waits on the explanation, and nothing is sent until its "Put it
        // up", so the capsule keeps the offer's look; otherwise it spins while the post and the
        // put-up go.
        current.phase = SpotlightFirstTime.hasSeen(userId: uid) ? .working : .pending
        withAnimation(Self.crossFade) { offer = current }
        let photoId = current.photo.id
        Task {
            guard let post = await commit(current.photo, .publish, caption: caption, tags: tags) else {
                // The post itself failed, and its error line says so; nothing can go up.
                if offer?.id == photoId { withAnimation(Self.crossFade) { offer = nil } }
                return
            }
            if offer?.id == photoId { offer?.post = post }
            var presented = false
            let sent = SpotlightFlow.requestPutUp(post, feed: feed, userId: uid) { post in
                // A deck closing under the post (its close button while the post was on the
                // wire) has nowhere to present the sheet.
                guard !closing, offer?.id == photoId else { return }
                presented = true
                spotlightFirstTimePost = post
            }
            if let sent {
                if offer?.id == photoId { offer?.phase = .working }
                finishPutUp(photoId: photoId, post: post, refusal: await sent.value)
            } else if !presented {
                // Nothing was sent: another Spotlight write is still on the wire, or the deck
                // closed before the explanation could show. The post's menu can still put it up.
                Haptics.error()
                if closing { UndoCenter.shared.showNotice(SpotlightRefusal.putUpNetwork) }
                finishPutUp(photoId: photoId, post: post, refusal: SpotlightRefusal.putUpNetwork)
            }
            // Otherwise the first-time sheet is up, and its answer arrives in `firstTimeAnswered`.
        }
    }

    /// The first-time sheet's answer for the capsule's put-up: "Put it up" sends it, Cancel
    /// returns to the deck with the pill whole again.
    private func firstTimeAnswered(_ confirmed: Post?) {
        guard let current = offer, current.phase == .pending, let post = current.post else { return }
        guard let confirmed, confirmed.id == post.id else {
            withAnimation(Self.crossFade) { offer = nil }
            return
        }
        let photoId = current.photo.id
        guard let sent = SpotlightFlow.putUp(post, feed: feed) else {
            Haptics.error()
            finishPutUp(photoId: photoId, post: post, refusal: SpotlightRefusal.putUpNetwork)
            return
        }
        withAnimation(Self.crossFade) { offer?.phase = .working }
        Task { finishPutUp(photoId: photoId, post: post, refusal: await sent.value) }
    }

    /// Why an offer that went stale before its tap cannot go up: the week closed, or the
    /// account can no longer put anything up (a covered window, an unknown entry).
    private func staleOfferRefusal() -> String {
        if let entry = feed.ownSpotlightEntry, Date.now >= entry.weekClosesAt {
            return SpotlightRefusal.weekClosedPutUp
        }
        return SpotlightRefusal.cantGoUp
    }

    /// Closes an emptied deck unless something still holds it open: the last card's sheet (or
    /// one waiting on the compose sheet), or a put-up from the capsule still in flight.
    private func closeIfEmptyAndSettled() {
        guard cards.isEmpty, loaded, lastCardOffer == nil, queuedLastCardOffer == nil,
              !lastCardSheetPresented, !(offer?.phase.isInFlight ?? false) else { return }
        closeDeck()
    }

    /// The server's answer: the capsule turns neutral for "Take it down" beside the existing
    /// confirmation, or goes, and the refusal says why. The frame stays posted either way.
    private func finishPutUp(photoId: UUID, post: Post, refusal: String?) {
        if let refusal {
            withAnimation(Self.crossFade) {
                if offer?.id == photoId { offer = nil }
                refusalNotice = refusal
            }
        } else if offer?.id == photoId {
            withAnimation(Self.crossFade) { offer?.phase = .up(post) }
        }
    }

    /// The neutral capsule's "Take it down". The take-down says nothing on success, so the deck
    /// says it once the server has; a refusal keeps the capsule for another try.
    private func takeDownOffered(_ post: Post) {
        guard case .up = offer?.phase, let sent = SpotlightFlow.takeDown(post, feed: feed) else { return }
        let photoId = offer?.id
        Task {
            let refusal = await sent.value
            withAnimation(Self.crossFade) {
                if let refusal {
                    refusalNotice = refusal
                } else {
                    if offer?.id == photoId { offer = nil }
                    refusalNotice = nil
                    takenDownNotice = true
                }
            }
        }
    }

    /// The last card's "Put it up": the sheet was the first-time explanation or it had been read
    /// before, so the account is marked as having seen it. Posts the held frame, then puts it up;
    /// the sheet turns into the answer once the server has one.
    private func putUpLastCard() {
        guard var current = lastCardOffer, current.phase == .offered, current.refusal == nil,
              lastPhoto?.id == current.photo.id, lastAction == .publish,
              let uid = auth.currentUser?.id else { return }
        // Another Spotlight write is still running: say so in the sheet rather than leave its
        // button pressed and silent.
        guard !feed.spotlightWriteInFlight else {
            Haptics.error()
            lastCardOffer?.refusal = SpotlightRefusal.putUpNetwork
            return
        }
        // Checked again at the tap, as the capsule is: a changed entry updates the sheet instead
        // of sending something it did not say.
        guard let kind = SpotlightPostedAsk.offer(userId: uid, photoOwnerId: current.photo.userId,
                                                  isTagged: !lastTags.isEmpty, entry: feed.ownSpotlightEntry,
                                                  takenAt: current.photo.takenAt, postedAt: .now) else {
            Haptics.error()
            lastCardOffer?.refusal = staleOfferRefusal()
            return
        }
        guard kind == current.kind else {
            lastCardOffer?.kind = kind
            return
        }
        SpotlightFirstTime.markSeen(userId: uid)
        let caption = lastCaption, tags = lastTags
        lastPhoto = nil; lastAction = nil; lastCaption = nil; lastTags = []
        current.phase = .working
        lastCardOffer = current
        let photoId = current.photo.id
        Task {
            guard let post = await commit(current.photo, .publish, caption: caption, tags: tags) else {
                if lastCardOffer?.id == photoId {
                    lastCardOffer?.refusal = publishError ?? SpotlightRefusal.putUpNetwork
                }
                return
            }
            if lastCardOffer?.id == photoId { lastCardOffer?.post = post }
            guard let sent = SpotlightFlow.putUp(post, feed: feed) else {
                Haptics.error()
                if lastCardOffer?.id == photoId { lastCardOffer?.refusal = SpotlightRefusal.putUpNetwork }
                return
            }
            let refusal = await sent.value
            guard lastCardOffer?.id == photoId else { return }
            if let refusal {
                lastCardOffer?.refusal = refusal
            } else {
                lastCardOffer?.phase = .up(post)
            }
        }
    }

    /// The last card's "Take it down": takes it down and closes, or says why not and stays.
    private func takeDownLastCard(_ post: Post) {
        guard case .up = lastCardOffer?.phase, let sent = SpotlightFlow.takeDown(post, feed: feed) else { return }
        lastCardOffer?.refusal = nil
        Task {
            if let refusal = await sent.value {
                lastCardOffer?.refusal = refusal
            } else {
                // Dismissing the sheet closes the deck (see its onDismiss).
                lastCardOffer = nil
            }
        }
    }

    private func openCompose(for photo: Photo) {
        // Not while a put-up from the capsule is in flight: the compose sheet would take the
        // first-time sheet's place, and that sheet would never come.
        guard composePhoto == nil, !(offer?.phase.isInFlight ?? false) else { return }
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
        takenDownNotice = false
        developedLateNotice = false
        // The next swipe is the "no" to an offer, and ends "Take it down"; later that is the
        // post's menu. A put-up still on the wire keeps its capsule until the server answers.
        if !(offer?.phase.isInFlight ?? false) { withAnimation(Self.crossFade) { offer = nil } }
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
        if action == .publish, let uid = auth.currentUser?.id {
            offerSpotlight(for: photo, userId: uid, tags: tags, isLast: cards.count == 1)
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
        // The last card's sheet goes first, and its onDismiss comes back here: dismissing the deck
        // while a sheet is still on screen, or still leaving it, can wedge it mid-animation. A
        // second close in that window (a double tap, "Not now" then the close button) only waits.
        if lastCardSheetPresented {
            closeAfterLastCardSheet = true
            lastCardOffer = nil
            return
        }
        // Set but not on screen yet: there is nothing to wait for.
        lastCardOffer = nil
        guard !closing else { return }   // auto-dismiss + button could both fire
        closing = true
        // Closing is a no: the held frame just posts. A last-card sheet still up goes with the
        // deck.
        offer = nil
        queuedLastCardOffer = nil
        let p = lastPhoto, a = lastAction, caption = lastCaption, tags = lastTags
        lastPhoto = nil; lastAction = nil; lastCaption = nil; lastTags = []
        Task {
            if let p, let a { await commit(p, a, caption: caption, tags: tags) }
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

    private func undo() {
        // Not while the swiped card is still flying off: the advance that follows would remove
        // the card Undo just put back, by id, and on the last card close the deck with the frame
        // unsorted. The card settles in 280 ms.
        guard !isTransitioning, let photo = lastPhoto else { return }
        Haptics.select()
        // The offer was for this frame: it goes with the swipe. On the last card that dismisses
        // the sheet, and the card coming back keeps the deck open.
        if offer?.id == photo.id, offer?.phase == .offered { withAnimation(Self.crossFade) { offer = nil } }
        if lastCardOffer?.id == photo.id { lastCardOffer = nil }
        if queuedLastCardOffer?.id == photo.id { queuedLastCardOffer = nil }
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
    @discardableResult
    private func commit(_ photo: Photo, _ action: SortAction, caption: String? = nil,
                         tags: [PendingTag] = []) async -> Post? {
        guard let uid = auth.currentUser?.id else { return nil }
        switch action {
        case .archive:
            await photoService.markSorted(photoId: photo.id)
        case .publish:
            await photoService.markSorted(photoId: photo.id)
            do {
                let created = try await feed.createPost(photo: photo, caption: caption, userId: uid, tags: tags)
                // The timer belongs to THIS notice: a second post while it shows starts its
                // own, and the first one's expiry no longer hides it (audit A8).
                let notice = UUID()
                postedNoticeId = notice
                withAnimation { postedNotice = true }
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    if postedNoticeId == notice { withAnimation { postedNotice = false } }
                }
                if shouldWarnThatTagsDidNotSave(created.tagsSaved) {
                    // The post itself is live, only the tags failed to attach; a genuine failure
                    // still has to speak up, same reasoning as the publish failure right below,
                    // it just isn't the same failure.
                    Haptics.error()
                    publishError = "Posted, but the tags didn't save. Try again from Edit tags."
                }
                return created.post
            } catch {
                // The photo is already marked sorted and the card is gone, so silence here means
                // someone believes they published something that never left the device. This is
                // the one action in the deck that makes a photo public; it has to speak up.
                Haptics.error()
                publishError = "Couldn't post that one. It's in your Darkroom, post it from there."
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
        return nil
    }

    private func load() async {
        guard let uid = auth.currentUser?.id else { loaded = true; return }
        // `?? []` preserves this view's original behavior: a fresh deck has no earlier list to
        // keep, so a failure here still just shows the (now correctly typed) empty case.
        cards = await photoService.fetchUnsorted(userId: uid) ?? []
        // The posted notice's Spotlight ask needs this week's bounds and whether anything is up
        // yet. A cold launch straight into the deck has not visited the Feed that reads them,
        // and one read before the week turned, or before a put-up from another phone, would
        // ask about the wrong week or swap a frame out unasked, so it is read on every open.
        Task { await feed.refreshOwnSpotlightEntry() }

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

/// The sort deck's Spotlight offer for the frame just swiped to post (see
/// `SpotlightPostedAsk.offer`): the capsule in the compose pill's slot, or the last card's
/// sheet.
struct DeckSpotlightOffer: Identifiable {
    enum Phase: Equatable {
        case offered
        /// A first-timer's put-up: the held frame is being posted, or the first-time sheet is up
        /// over it. Nothing has been sent to Spotlight.
        case pending
        /// The held frame is being posted, or its put-up is on the wire.
        case working
        /// The server has it up; the post is what the held frame became.
        case up(Post)

        /// Answered and not yet resolved: the slot is held and the deck stays open.
        var isInFlight: Bool { self == .pending || self == .working }
    }

    let photo: Photo
    /// Recomputed at the tap; a changed entry changes what is offered.
    var kind: SpotlightPostedAsk.Kind
    /// This week's key when the offer was made, for the last card's swap sentence.
    let weekKey: String
    var phase: Phase = .offered
    /// The post the held frame became, once it has landed.
    var post: Post?
    /// Why the put-up, the post itself, or a take-down did not happen, for the last card's
    /// sheet, which shows it in the error colour. The capsule says it in the notice area.
    var refusal: String?

    var id: UUID { photo.id }
}
