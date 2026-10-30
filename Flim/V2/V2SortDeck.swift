import SwiftUI

/// What sorting a print does: keep it in your Darkroom, post it to your friends, or delete it.
enum V2SortPile: CaseIterable {
    case keep, delete, post
}

/// The sort deck (board 2a, 12d, 15b; prototype): one print at a time, dragged to a pile or swiped,
/// left to keep, right to post, down to delete. The piles show what went where; Undo takes the
/// last one back. At accessibility sizes the three piles are buttons as well (board 12d).
///
/// Each action is held until the next one, so Undo can take it back without a server round
/// trip, then written exactly as the App Store deck writes it (`SortDeckView.commit`), with the
/// same failure words. Writing on the back before posting makes the post's caption, and Tag people
/// tags it. When the last print is sorted, this week's Spotlight is offered for what was posted.
struct V2SortDeck: View {
    var close: () -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.v2Palette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AuthService.self) private var auth
    @Environment(PhotoService.self) private var photos
    @Environment(FeedService.self) private var feed

    @State private var cards: [Photo] = []
    @State private var total = 0
    @State private var loaded = false
    @State private var loadFailed = false
    @State private var drag: CGSize = .zero
    @State private var flying = false
    /// The last action, not yet written, so Undo can take it back.
    @State private var held: (photo: Photo, pile: V2SortPile, caption: String?, tags: [PendingTag])?
    /// People tagged on the top print, posted with it.
    @State private var tags: [PendingTag] = []
    @State private var tagging: Photo?
    @State private var tagURL: URL?
    /// The sort's posts, for the Spotlight sheet at its end (`SortDeckSession`, as the App Store
    /// deck).
    @State private var session = SortDeckSession()
    @State private var sessionOffer: SpotlightSessionOffer?
    @State private var shownOffer: SpotlightSessionOffer?
    @State private var sessionPutUp = false
    @State private var offeredThisSort = false
    /// Every sort this session, newest last, for the piles and the closing line.
    @State private var history: [(photo: Photo, pile: V2SortPile)] = []
    @State private var caption = ""
    @State private var problem: String?
    @State private var closing = false
    @FocusState private var writing: Bool

    /// How far a print travels before letting go sorts it (prototype: 90).
    static let threshold: CGFloat = 90

    var body: some View {
        GeometryReader { proxy in
            let mode = V2LayoutMode.resolve(horizontalSizeClass: sizeClass, proxy: proxy)
            Group {
                if mode == .outer { column(proxy.size) } else { stacked(proxy.size) }
            }
            .environment(\.v2LayoutMode, mode)
        }
        .background { V2Desktop(palette: palette) }
        .foregroundStyle(palette.ink)
        .task { await load() }
        .sheet(item: $tagging) { photo in
            TagPhotoSheet(url: tagURL, cacheKey: photo.viewPath, tags: $tags, rollId: photo.rollId)
        }
        .sheet(item: $sessionOffer, onDismiss: { sessionSheetClosed() }) { offer in
            SpotlightSessionSheet(offer: offer, session: session, accessibilitySize: typeSize.isAccessibilitySize,
                                  onPutUp: { await putUp($0, offer: offer) })
                .onAppear { if shownOffer?.id != offer.id { shownOffer = offer } }
        }
        // The last print sorted on its own: offer this week's Spotlight, as the App Store deck
        // does. Done never does.
        .onChange(of: cards.isEmpty) { _, empty in
            if empty, loaded, !history.isEmpty { offerSpotlight() }
        }
        // Open, the deck sits in the Darkroom's half and leaves with it when you swipe to
        // Friends: what was held is written then, as Done would.
        .onDisappear {
            guard !closing, let last = held else { return }
            held = nil
            Task { await commit(last.photo, last.pile, caption: last.caption, tags: last.tags) }
        }
    }

    // MARK: Arrangements

    /// Phone, and the open display's right half: header, the three piles, the print, the hint.
    private func stacked(_ size: CGSize) -> some View {
        // Header, piles and hint take about 230 points; the print gets the rest.
        let width = cardWidth(in: CGSize(width: size.width - V2CameraMetrics.printInset * 2, height: size.height - 230))
        return VStack(spacing: 0) {
            HStack {
                doneButton
                Spacer(minLength: 8)
                title
                Spacer(minLength: 8)
                undoButton
            }
            .padding(.horizontal, V2Metrics.margin)
            HStack(alignment: .top) {
                pile(.keep)
                Spacer(minLength: 8)
                pile(.delete)
                Spacer(minLength: 8)
                pile(.post)
            }
            .padding(.horizontal, V2Metrics.margin)
            .padding(.top, 8)
            Spacer(minLength: 12)
            deck(width: width)
            tagRow
                .padding(.top, 10)
            Spacer(minLength: 12)
            footer
                .padding(.horizontal, V2Metrics.margin)
                .padding(.bottom, 12)
        }
    }

    /// Closed (board 15b): Keep peeks in from the leading edge so it stays clear of the column,
    /// Post is in the column, Delete sits under the print, and the count is last in the column.
    private func column(_ size: CGSize) -> some View {
        let columnWidth = V2RootMetrics.columnWidth
        let width = cardWidth(in: CGSize(width: size.width - columnWidth - 64, height: size.height - 170))
        return HStack(spacing: 0) {
            VStack(spacing: 14) {
                HStack(alignment: .center, spacing: 10) {
                    pile(.keep)
                        .frame(width: 60)
                    deck(width: width)
                        .frame(maxWidth: .infinity)
                }
                HStack {
                    pile(.delete)
                    Spacer()
                    tagRow
                }
                .padding(.horizontal, 12)
                Spacer(minLength: 0)
                footer
                    .padding(.horizontal, 12)
            }
            .padding(.top, 12)
            .padding(.leading, 8)
            VStack(alignment: .trailing, spacing: 6) {
                doneButton
                undoButton
                Spacer(minLength: 12)
                pile(.post)
                Spacer(minLength: 12)
                if !cards.isEmpty {
                    Text("\(position) OF \(total)")
                        .font(V2Type.data(10))
                        .tracking(1.6)
                        .foregroundStyle(palette.ink2)
                }
            }
            .padding(.vertical, 12)
            .padding(.trailing, 14)
            .frame(width: columnWidth, alignment: .trailing)
        }
    }

    private func cardWidth(in box: CGSize) -> CGFloat {
        min(V2DarkroomMetrics.maxStackWidth, V2PrintGeometry.width(fitting: box))
    }

    private var position: Int { min(total - cards.count + 1, total) }

    // MARK: Header

    private var doneButton: some View {
        Button { finish() } label: {
            Text("Done")
                .font(V2Type.control())
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var undoButton: some View {
        Button { undo() } label: {
            Text("Undo")
                .font(V2Type.control())
                .foregroundStyle(held == nil ? palette.ink3 : palette.ink)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(held == nil || flying)
    }

    @ViewBuilder
    private var title: some View {
        if !cards.isEmpty {
            (Text("Sorting ") + Text("\(position)").italic() + Text(" of \(total)"))
                .font(V2Type.serif(15, relativeTo: .subheadline))
        }
    }

    // MARK: Piles

    private func pile(_ pile: V2SortPile) -> some View {
        let sorted = history.filter { $0.pile == pile }
        let toward = leaning == pile
        let label: String = switch pile {
        case .keep: "Keep · \(sorted.count)"
        case .post: "Post · \(sorted.count)"
        case .delete: "Delete"
        }
        let control = VStack(spacing: 6) {
            ZStack {
                if pile == .delete || sorted.isEmpty {
                    Rectangle()
                        .strokeBorder(toward ? palette.ink : palette.ink3, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    if pile == .delete, !sorted.isEmpty {
                        Text("\(sorted.count)")
                            .font(.system(.caption))
                            .foregroundStyle(palette.ink3)
                    }
                } else {
                    // The last few sorted there, loose, the newest on top.
                    ForEach(Array(sorted.suffix(3).enumerated()), id: \.element.photo.id) { offset, entry in
                        V2PrintCard(width: 46, borderFraction: 3.0 / 46, footFraction: 9.0 / 46) {
                            V2Image(path: entry.photo.thumbPath ?? entry.photo.viewPath, maxPixel: 100)
                        } foot: { Color.clear }
                        .rotationEffect(.degrees(Double(offset - 1) * (pile == .keep ? -4 : 4)))
                    }
                }
            }
            .frame(width: 60, height: 78)
            Text(label)
                .font(V2Type.control(.caption))
                .foregroundStyle(toward ? palette.ink : palette.ink2)
        }
        .frame(minWidth: 72)
        .animation(V2Motion.setDown, value: sorted.count)
        // At accessibility sizes dragging is hard to aim; the piles become buttons (board 12d).
        return Group {
            if typeSize.isAccessibilitySize {
                Button { sort(pile) } label: { control }
                    .buttonStyle(.plain)
                    .disabled(cards.isEmpty || flying)
            } else {
                control
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The pile the print is being dragged toward, past half the threshold.
    private var leaning: V2SortPile? {
        let half = Self.threshold / 2
        if drag.width < -half, abs(drag.width) > drag.height { return .keep }
        if drag.width > half, drag.width > drag.height { return .post }
        if drag.height > half { return .delete }
        return nil
    }

    // MARK: The deck

    @ViewBuilder
    private func deck(width: CGFloat) -> some View {
        let height = V2PrintGeometry.height(width: width)
        if loadFailed {
            dashed(width: width, height: height) {
                VStack(spacing: 14) {
                    Text("Couldn't load your prints.")
                        .font(V2Type.serif(20, relativeTo: .title3))
                    Button {
                        Task { await load() }
                    } label: {
                        Text("Try again").font(V2Type.control()).underline().frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                }
            }
        } else if let top = cards.first {
            ZStack {
                if cards.count > 1 {
                    Rectangle().fill(V2Color.print)
                        .frame(width: width * 0.97, height: height * 0.97)
                        .shadow(color: .black.opacity(0.14), radius: 4, y: 2)
                        .rotationEffect(.degrees(2))
                        .offset(x: 4, y: 10)
                }
                card(top, width: width)
                    .id(top.id)
                    .offset(drag)
                    .rotationEffect(.degrees(reduceMotion ? 0 : Double(drag.width / 20)))
                    .gesture(dragGesture)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Print \(position) of \(total)")
                    .accessibilityActions {
                        Button("Keep") { sort(.keep) }
                        Button("Post") { sort(.post) }
                        Button("Delete") { sort(.delete) }
                    }
            }
            .frame(width: width, height: height)
        } else if loaded {
            dashed(width: width, height: height) {
                VStack(spacing: 18) {
                    Text("All sorted.")
                        .font(V2Type.serif(24, relativeTo: .title2))
                    Text(summary)
                        .font(V2Type.serif(15, italic: true, relativeTo: .callout))
                        .foregroundStyle(palette.ink2)
                    Button { finish() } label: {
                        Text("Back to the desk")
                            .font(V2Type.control(.subheadline))
                            .foregroundStyle(palette.background)
                            .padding(.horizontal, 22)
                            .frame(minHeight: 44)
                            .background(palette.ink, in: RoundedRectangle(cornerRadius: V2Metrics.radius))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 10)
                }
                .multilineTextAlignment(.center)
                .padding(40)
            }
        } else {
            Color.clear.frame(width: width, height: height)
        }
    }

    private func card(_ photo: Photo, width: CGFloat) -> some View {
        V2PrintCard(width: width) {
            V2Image(path: photo.viewPath, maxPixel: width * 1.4)
                .overlay(alignment: .bottomTrailing) {
                    V2DateStamp(text: BrandedExport.dateText(.init(date: photo.takenAt)),
                                cellHeight: width * 0.04, stamp: .amber)
                        .padding(.trailing, width * 0.04)
                        .padding(.bottom, width * 0.03)
                }
        } foot: {
            // What you write here goes with the print if you post it.
            TextField("", text: $caption,
                      prompt: Text("write something on the back")
                        .font(V2Type.serif(16, italic: true, relativeTo: .body))
                        .foregroundStyle(V2Color.printInk3),
                      axis: .vertical)
                .font(V2Type.serif(16, italic: true, relativeTo: .body))
                .foregroundStyle(V2Color.printInk)
                .lineLimit(1...2)
                .focused($writing)
                .submitLabel(.done)
                .onSubmit { writing = false }
                .padding(.horizontal, 4)
                .accessibilityLabel("Caption, posted with the print")
        }
    }

    private func dashed(width: CGFloat, height: CGFloat, @ViewBuilder content: () -> some View) -> some View {
        content()
            .frame(width: width, height: height)
            .overlay {
                Rectangle().strokeBorder(palette.ink3, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard !flying else { return }
                writing = false
                drag = value.translation
            }
            .onEnded { value in
                guard !flying else { return }
                let t = value.translation
                if t.width < -Self.threshold, abs(t.width) > t.height { sort(.keep) }
                else if t.width > Self.threshold, t.width > t.height { sort(.post) }
                else if t.height > Self.threshold { sort(.delete) }
                else { withAnimation(V2Motion.slide) { drag = .zero } }
            }
    }

    /// Tag people on the top print; they go out with it if it is posted.
    @ViewBuilder
    private var tagRow: some View {
        if let top = cards.first, !flying {
            Button { openTagging(top) } label: {
                Text(tags.isEmpty ? "Tag people" : (tags.count == 1 ? "1 tagged" : "\(tags.count) tagged"))
                    .font(V2Type.control())
                    .foregroundStyle(tags.isEmpty ? palette.ink2 : palette.ink)
                    .underline(!tags.isEmpty)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Tags people on this print, posted with it")
        }
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        Text(problem ?? (cards.isEmpty ? "" : "Drag it to a pile, or swipe. Keep goes to your Darkroom. Post goes to your friends."))
            .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
            .foregroundStyle(problem == nil ? palette.ink2 : Color.red)
            .multilineTextAlignment(.center)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
    }

    private var summary: String {
        let kept = history.filter { $0.pile == .keep }.count
        let posted = history.filter { $0.pile == .post }.count
        let gone = history.filter { $0.pile == .delete }.count
        return "\(kept) kept, \(posted) posted, \(gone) gone."
    }

    // MARK: Actions

    private func sort(_ pile: V2SortPile) {
        guard !flying, let photo = cards.first else { return }
        flying = true
        writing = false
        problem = nil
        Haptics.tap()
        let text = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        let away: CGSize = switch pile {
        case .keep: CGSize(width: -700, height: 0)
        case .post: CGSize(width: 700, height: 0)
        case .delete: CGSize(width: 0, height: 900)
        }
        withAnimation(.easeOut(duration: 0.28)) { drag = away }
        // The one before can no longer be undone: write it now, and hold this one.
        if let previous = held {
            Task { await commit(previous.photo, previous.pile, caption: previous.caption, tags: previous.tags) }
        }
        let postTags = pile == .post ? tags : []
        held = (photo, pile, pile == .post && !text.isEmpty ? text : nil, postTags)
        if pile == .post { session.published(photo, isTagged: !postTags.isEmpty) }
        Task {
            try? await Task.sleep(for: .milliseconds(280))
            if let i = cards.firstIndex(where: { $0.id == photo.id }) { cards.remove(at: i) }
            history.append((photo, pile))
            caption = ""
            tags = []
            drag = .zero
            flying = false
        }
    }

    private func undo() {
        guard !flying, let last = held else { return }
        Haptics.select()
        held = nil
        if let i = history.lastIndex(where: { $0.photo.id == last.photo.id }) { history.remove(at: i) }
        caption = last.caption ?? ""
        tags = last.tags
        if last.pile == .post { session.undone(photoId: last.photo.id) }
        withAnimation(V2Motion.slide) { cards.insert(last.photo, at: 0) }
    }

    /// Writes whatever is held, then closes.
    private func finish() {
        guard !closing else { return }
        closing = true
        let last = held
        held = nil
        Task {
            if let last { await commit(last.photo, last.pile, caption: last.caption, tags: last.tags) }
            close()
        }
    }

    /// As `SortDeckView.commit`, with its words.
    private func commit(_ photo: Photo, _ pile: V2SortPile, caption: String?, tags: [PendingTag] = []) async {
        guard let uid = auth.currentUser?.id else { return }
        switch pile {
        case .keep:
            await photos.markSorted(photoId: photo.id)
        case .post:
            await photos.markSorted(photoId: photo.id)
            do {
                let created = try await feed.createPost(photo: photo, caption: caption, userId: uid, tags: tags)
                session.landed(photoId: photo.id, post: created.post)
                if shouldWarnThatTagsDidNotSave(created.tagsSaved) {
                    Haptics.error()
                    problem = "Posted, but the tags didn't save. Try again from Edit tags."
                }
            } catch {
                Haptics.error()
                ReviewPrompt.noteVisibleFailure()
                problem = "Couldn't post that one. It's in your Darkroom, post it from there."
                session.failed(photoId: photo.id)
                if let offer = sessionOffer, session.offered(offer).isEmpty {
                    session.emptiedByFailures = true
                    sessionOffer = nil
                }
            }
        case .delete:
            if await photos.deletePhoto(photo) == false {
                Haptics.error()
                ReviewPrompt.noteVisibleFailure()
                problem = "Couldn't delete that one. Check your connection and try again."
                if let i = history.lastIndex(where: { $0.photo.id == photo.id }) { history.remove(at: i) }
                withAnimation(V2Motion.slide) {
                    cards.insert(photo, at: min(drag == .zero && !flying ? 0 : 1, cards.count))
                }
            }
        }
    }

    private func openTagging(_ photo: Photo) {
        Haptics.tap()
        writing = false
        Task {
            tagURL = await feed.signedURL(for: photo.viewPath)
            tagging = photo
        }
    }

    // MARK: Spotlight at the end of a sort (as `SortDeckView.finishSession`)

    /// Writes what is held, then offers this week's Spotlight for what the sort posted, once.
    private func offerSpotlight() {
        guard !offeredThisSort, let uid = auth.currentUser?.id else { return }
        offeredThisSort = true
        let last = held
        held = nil
        let commitHeld = Task {
            if let last { await commit(last.photo, last.pile, caption: last.caption, tags: last.tags) }
        }
        // A new account's first sort goes straight on, with no sheet (the App Store deck's rule).
        guard !NewAccountIntro.skipsSessionSheet(userId: uid, createdAt: auth.currentUser?.createdAt),
              session.hasCandidate(viewerId: uid) else { return }
        Task {
            if feed.currentSpotlightEntry == nil { await feed.refreshOwnSpotlightEntry() }
            _ = await commitHeld.value
            guard let entry = feed.currentSpotlightEntry,
                  var offer = session.offer(entry: entry, viewerId: uid, ledger: SpotlightSessionLedger.load(userId: uid))
            else { return }
            offer.firstTime = !SpotlightFirstTime.hasSeen(userId: uid)
            for frame in session.offered(offer) where session.urls[frame.photo.id] == nil {
                session.urls[frame.photo.id] = await feed.signedURL(for: frame.photo.viewPath)
            }
            sessionPutUp = false
            session.kindOverride = nil
            session.emptiedByFailures = false
            sessionOffer = offer
        }
    }

    private func putUp(_ post: Post, offer: SpotlightSessionOffer) async -> SpotlightPutUpOutcome {
        let outcome = await feed.putUpFromSessionSheet(post, offer: offer, session: session, userId: auth.currentUser?.id)
        if case .up = outcome { sessionPutUp = true }
        return outcome
    }

    /// Records what the sheet showed (a decline only when the person said no), as the App Store
    /// deck's ledger does, so the same frames are not offered again.
    private func sessionSheetClosed() {
        if let uid = auth.currentUser?.id, let offer = shownOffer {
            var ledger = SpotlightSessionLedger.load(userId: uid)
            ledger.recordClosed(weekKey: offer.weekKey, shownPostIds: session.offered(offer).compactMap { $0.post?.id },
                                declined: !sessionPutUp && !session.emptiedByFailures)
            SpotlightSessionLedger.save(ledger, userId: uid)
        }
        shownOffer = nil
    }

    private func load() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-v2DemoDarkroom") {
            cards = V2DarkroomFixture.make().unsorted
            total = cards.count
            loaded = true
            return
        }
        #endif
        guard let uid = auth.currentUser?.id else { loaded = true; return }
        // A failed read is not an empty deck (`SortDeckView.opening`): it says so and offers a retry.
        guard let fetched = await photos.fetchUnsorted(userId: uid) else {
            Haptics.error()
            loadFailed = true
            return
        }
        loadFailed = false
        cards = fetched
        total = fetched.count
        loaded = true
    }
}
