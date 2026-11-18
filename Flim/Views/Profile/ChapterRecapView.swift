import SwiftUI

/// The monthly recap (3b): an opening card that answers "what am I about to watch", then
/// playback of the month's curated deck.
///
/// Playback is `PhotoPagerView` in its roll-rack mode, the app's canonical viewer (native paging,
/// fixed geometry, structurally stable children, film strip under a boxed photograph, credit
/// line, reactions, thread), fed the curated deck `ChapterRecapViewModel.pagerPhotos` already
/// reshapes for it. This used to be a bespoke `TabView(.page)` player reusing only `RevealPacing`'s
/// print-box geometry with no film strip at all; the owner's call was that a chapter's playback
/// should look like every other viewer in the app rather than being a third, unrelated one.
/// `RevealPacing` still sizes the opening card's fanned prints below, that usage is untouched.
struct ChapterRecapView: View {
    @Environment(\.flimAccent) private var accent
    @Environment(\.dismiss) private var dismiss
    @Environment(FeedService.self) private var feed
    @Environment(ChapterService.self) private var chapters
    @Environment(AuthService.self) private var auth
    @Environment(\.displayScale) private var displayScale
    /// How wide the screening has to play in, measured where it plays.
    @State private var screeningWidth: CGFloat = 0
    /// Bumped when a number on the open Duo's split opens a frame, so the pager rebuilds there.
    @State private var pagerJump = 0
    /// The month box cover's subject, found on device (`PhotoFocus`).
    @State private var coverFocus: PhotoFocus.Subject?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Accessibility text sizes stack the box's title row and its two buttons instead of
    /// squeezing them side by side.
    @Environment(\.dynamicTypeSize) private var typeSize

    let profileId: UUID
    let chapterCoverURLs: [String: URL]
    /// On the Duo's open display the box takes your page's right column instead of the screen
    /// (Blend 2, 6i: "Opening a box replaces the right column"); closing hands the column back
    /// through `onClose`. Playing the month still goes full screen, as a screening does.
    private let docked: Bool
    private let onClose: () -> Void

    /// The recap's two "rest" screens: `phase` is whichever one sits behind the pager. Closing
    /// the pager always lands on `.closing` when the month has anything to say
    /// (`ChapterRecapViewModel.hasClosingCard`) rather than ending the recap outright, whether
    /// that's the first close of the session or a replay reopened from the closing card's own
    /// "Play again"; there is no separate "already showed you this" state to track, every close
    /// of the pager behaves the same way. Playback itself is not a third case here: it is
    /// presented over whichever rest screen is current via `isPlayerPresented`, see `player`'s
    /// own doc for why.
    private enum Phase { case opening, closing }

    @State private var viewModel: ChapterRecapViewModel
    @State private var phase: Phase = .opening
    /// Whether the pager is up, as its own `.fullScreenCover` rather than a third `phase` case.
    @State private var isPlayerPresented = false
    /// The pager's `startIndex` the next time it's presented: 0 from "Play the month", or a
    /// specific frame from tapping a closing-card thumb (`ChapterRecapViewModel.deckIndex`).
    @State private var selection = 0
    /// Drives the opening card's swipe-to-dismiss (see `View.swipeToDismiss`). Not read by the
    /// player: a native `TabView(.page)` pager gets no competing drag gesture, the same as
    /// `RollRevealView`'s own playback and `PhotoPagerView`.
    @State private var cardOffset: CGSize = .zero
    /// Whether to show the one-time "what is a chapter" line under the opening card's fanned
    /// prints. Decided once, in `.task`, from `firstChapterSeenKey`: never on someone else's
    /// chapter (this account has never been TOLD anything about a page that isn't theirs), and
    /// never again after the first time on their own, same one-shot shape as
    /// `RollDetailView.revealSeenKey`.
    @State private var showFirstRunLine = false
    /// The closing card's "Biggest fan"/"Roll MVP" lines push a profile rather than opening the
    /// pager; this screen has no `NavigationStack` of its own reason to need one until now, so it
    /// gets one here, the same shape `RollRevealView` already uses for the same reason (a handle
    /// tapped mid-reveal pushes with a back button instead of presenting with no way out).
    @State private var profileRoute: ProfileRoute?
    /// 1.7's box edit (Blend 4, 12b): the sheet, the box's chosen cover by photo, and whether the
    /// box is previewing its posted shots with put-away shots left out.
    @State private var boxCoverPhotoId: UUID?
    /// Whether this box's put-away shots and chosen cover have been read. Edit waits for it: a
    /// sheet opened on a half-read box saved its empty guess and brought put-away shots back
    /// (nightly review, 2026-11-15).
    @State private var boxEditReady = false
    /// Edit, open: what it opened on, so Done saves only what changed from what the sheet showed.
    /// Presented by item, never a flag plus a separate value: a `sheet(isPresented:)` closure read
    /// the value from before the tap and opened with no cover.
    @State private var boxEdit: BoxEditSession?
    private struct BoxEditSession: Identifiable {
        let id = UUID()
        let putAway: Set<UUID>
        let cover: UUID?
    }
    @State private var asFriendsSee = false
    /// Freeze the preview's input when Play is tapped; an asynchronous read must not move a pager.
    @State private var previewPlayback: [ChapterPhoto]?

    private var visibleBoxPhotos: [ChapterPhoto] {
        ChapterRecapViewModel.excludingPutAway(viewModel.monthPhotos,
                                              postIds: asFriendsSee ? chapters.putAwayPostIds : [])
    }

    private var playableDeck: [ChapterPhoto] {
        ChapterRecapViewModel.excludingPutAway(viewModel.deck,
                                              postIds: asFriendsSee ? chapters.putAwayPostIds : [])
    }

    private var playbackDeck: [ChapterPhoto] { previewPlayback ?? viewModel.deck }

    init(profileId: UUID, chapter: ChapterSummary, chapterCoverURLs: [String: URL],
         docked: Bool = false, onClose: @escaping () -> Void = {}) {
        self.profileId = profileId
        self.chapterCoverURLs = chapterCoverURLs
        self.docked = docked
        self.onClose = onClose
        _viewModel = State(initialValue: ChapterRecapViewModel(profileId: profileId, chapter: chapter))
    }

    /// Namespaced per account, same shape as `RollDetailView.revealSeenKey`: a device that hosts
    /// more than one account must not let the first account's viewing burn the line for the
    /// second, and signing back in as the first must not show it again either.
    private func firstChapterSeenKey(userId: UUID) -> String { "firstChapterSeen.\(userId.uuidString)" }
    private var isOwnRecap: Bool { auth.currentUser?.id == profileId }
    private var boxKey: ChapterService.ChapterKey {
        .init(profileId: profileId, monthStart: viewModel.chapter.monthStart)
    }
    private var savingBox: Bool { chapters.isSavingBox(boxKey) }

    /// Ends the recap: the cover goes, or the docked box hands the column back.
    private func close() {
        if docked { onClose() } else { dismiss() }
    }

    var body: some View {
        if AppInfo.is17 {
            // 1.7: the box, the player and the closing card all sit on the chosen desk.
            recapBody.modifier(DeskEnvironment())
        } else {
            recapBody
        }
    }

    /// What a month plays on: the desk with its grain on 1.7; black on 1.6.
    @ViewBuilder private var screeningGround: some View {
        if AppInfo.is17 { DeskGround() } else { Color.black.ignoresSafeArea() }
    }

    /// 1.6 only: dark for the closing card.
    private struct Screening: ViewModifier {
        func body(content: Content) -> some View {
            content.environment(\.colorScheme, .dark)
        }
    }

    @ViewBuilder private var recapBody: some View {
        if docked {
            // Already inside your page's stack, so a handle pushes onto that one rather than a
            // second stack nested in the column.
            content
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .navigationDestination(item: $profileRoute) { UserPageView(userId: $0.id) }
                .fullScreenCover(isPresented: $isPlayerPresented) {
                    ZStack {
                        screeningGround
                        player
                    }
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { screeningWidth = $0 }
                    .statusBarHidden()
                }
        } else {
            NavigationStack {
                content
                    .toolbar(.hidden, for: .navigationBar)
                    .navigationDestination(item: $profileRoute) { UserPageView(userId: $0.id) }
            }
        }
    }

    private var content: some View {
        ZStack {
            if AppInfo.is17 {
                // The box and the month in numbers both sit on your desk, with its grain
                // (owner, 2026-11-15: the numbers were on plain black).
                DeskGround()
            } else {
                Color.black.ignoresSafeArea()
            }
            switch phase {
            case .opening: openingCard
            case .closing:
                if AppInfo.is17 { closingCard } else { closingCard.modifier(Screening()) }
            }
            // Inline, not a `.fullScreenCover` (changed 2026-09-10). The recap is already a cover
            // over the profile; the player was a second cover over that, and the viewer's export
            // sheet a third presentation on top. On iOS 26.6 that third layer was re-presented
            // by the system and then torn down along with the player, every time (breadcrumbs
            // in crash_diagnostics). Rolls, one cover deep, never had it. The pager's X now
            // calls `onClose` instead of the environment `dismiss()`, which is the only thing
            // the cover was buying (see `player`'s doc).
            if isPlayerPresented, !docked {
                ZStack {
                    screeningGround
                    player
                }
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { screeningWidth = $0 }
                .transition(.opacity)
                .zIndex(1)
            }
        }
        // The 1.7 box is a page on the desk and keeps the status bar; what plays hides it.
        .statusBarHidden(!docked && (!AppInfo.is17 || isPlayerPresented || phase == .closing))
        // `viewModel.deck` must never change while the pager is actually mounted (see
        // `ChapterRecapViewModel.isPlayerMounted`'s own doc); this is the one place that tells it
        // whether that's currently true, for both edges of the presentation.
        .onChange(of: isPlayerPresented) { _, presented in
            // Flip to the closing card the moment the pager starts to go, not after it has gone:
            // the cover's dismissal animation reveals whatever `phase` shows underneath, and a
            // flip made only in `onDismiss` left the opening card visible for that frame or two.
            // On the open Duo the numbers were beside the photographs all along: back to the box.
            if !presented, !asFriendsSee, viewModel.hasClosingCard, !splitsScreening { phase = .closing }
            viewModel.setPlayerMounted(presented)
            if !presented { handlePlayerDismissed() }
        }
        .task {
            viewModel.displayScale = displayScale
            // Decided once, up front, from the flag alone: never re-evaluated later in this same
            // presentation, so a first-run line already on screen can't blink off mid-view if
            // something else in this `.task` happens to touch `isOwnRecap`'s inputs.
            if isOwnRecap, let uid = auth.currentUser?.id {
                let key = firstChapterSeenKey(userId: uid)
                if !UserDefaults.standard.bool(forKey: key) {
                    showFirstRunLine = true
                    UserDefaults.standard.set(true, forKey: key)
                }
            }
            await viewModel.load(feed: feed, chapters: chapters)
            #if DEBUG
            // Screenshotting the player from the Simulator's own CLI has no way to deliver a
            // tap on "Play the month"; this jumps straight there alongside `-openChapterRecap`.
            if ProcessInfo.processInfo.arguments.contains("-autoPlayChapter") { isPlayerPresented = true }
            // `-chapterClosingDemo`, alongside `-openChapterRecap`: jumps straight to the closing
            // card itself, for screenshotting it without playing through the whole deck first.
            if ProcessInfo.processInfo.arguments.contains("-chapterClosingDemo") { phase = .closing }
            #endif
        }
    }

    // MARK: - Opening card

    @ViewBuilder private var openingCard: some View {
        if docked {
            // No swipe down in a column: it would drag the box over the rest of the page.
            openingCardBody.transition(.opacity)
        } else {
            openingCardBody
                .swipeToDismiss(offset: $cardOffset) { Haptics.tap(); close() }
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var openingCardBody: some View {
        if AppInfo.is17 { deskBox } else { v1OpeningCardBody }
    }

    // MARK: - 1.7 month box (Blend 4, 12a)

    /// The month, posted shots by day, newest day first, for the box's grid.
    private var boxDays: [(day: Date, photos: [ChapterPhoto])] {
        let live = visibleBoxPhotos
        let grouped = Dictionary(grouping: live) { FeedUnit.dayKey(for: $0.takenAt) }
        return grouped.keys.sorted(by: >).map { (day: $0, photos: grouped[$0] ?? []) }
    }

    /// This month's put-away posts, as last read.
    private var currentPutAway: Set<UUID> {
        Set(viewModel.monthPhotos.compactMap(\.postId).filter { chapters.putAwayPostIds.contains($0) })
    }

    private func isPutAway(_ photo: ChapterPhoto) -> Bool {
        photo.postId.map { chapters.putAwayPostIds.contains($0) } ?? false
    }

    private var putAwayCount: Int {
        viewModel.monthPhotos.filter { !$0.isDeadFrame && isPutAway($0) }.count
    }

    /// "Friends see 12 of 14. Put-away shots stay yours."
    /// The shot the month's own cover shows, so Edit can mark it before anything is chosen.
    private var defaultCoverPhotoId: UUID? {
        guard let path = viewModel.chapter.coverPaths.first else { return viewModel.monthPhotos.first?.id }
        return viewModel.monthPhotos.first { $0.displayPath == path || $0.thumbPath == path }?.id
            ?? viewModel.monthPhotos.first?.id
    }

    private var friendsSeeLine: String {
        let total = viewModel.monthPhotos.filter { !$0.isDeadFrame }.count
        return "Friends see \(total - putAwayCount) of \(total). Put-away shots stay yours."
    }

    /// The box's cover path: the shot chosen in Edit, else the box's stored cover, else the
    /// month's own first.
    private var boxCoverPath: String? {
        if asFriendsSee {
            let preferred = boxCoverPhotoId.flatMap { id in visibleBoxPhotos.first { $0.id == id } }
            let storedPath = chapters.coverPath(for: viewModel.chapter, profileId: profileId)
            let stored = visibleBoxPhotos.first { $0.displayPath == storedPath }
            return (preferred ?? stored ?? visibleBoxPhotos.first)?.displayPath
        }
        if let id = boxCoverPhotoId, let photo = viewModel.monthPhotos.first(where: { $0.id == id }) {
            return photo.displayPath
        }
        return chapters.coverPath(for: viewModel.chapter, profileId: profileId)
    }

    /// Saves what Edit changed: each shot put away or brought back, then the cover. Shown at once;
    /// anything that didn't land is put back and said.
    private func applyBoxEdit(cover: UUID?, putAway: Set<UUID>, from session: BoxEditSession) {
        guard let uid = auth.currentUser?.id, uid == profileId,
              let saveToken = chapters.beginBoxSave(boxKey) else { return }
        let key = boxKey
        let epoch = AccountEpoch.current
        // Against what the sheet opened on, never a set that changed under it.
        let before = session.putAway
        let toAway = putAway.subtracting(before)
        let toBack = before.subtracting(putAway)
        let previousCover = boxCoverPhotoId
        // Written only when it changed from what the sheet showed, chosen or default.
        let changedCover = cover.flatMap { $0 == session.cover ? nil : $0 }
        if let changedCover { boxCoverPhotoId = changedCover }
        let coverPhoto = changedCover.flatMap { id in viewModel.monthPhotos.first { $0.id == id } }
        let service = chapters
        let monthStart = viewModel.chapter.monthStart
        // Shown at once; the writes follow.
        service.putAwayPostIds.formUnion(toAway)
        service.putAwayPostIds.subtract(toBack)
        Task {
            defer { service.finishBoxSave(key, token: saveToken) }
            var failed = 0
            for id in toAway {
                guard AccountEpoch.isCurrent(epoch) else { return }
                let saved = await service.setPutAway(true, postId: id)
                guard AccountEpoch.isCurrent(epoch) else { return }
                if !saved { service.putAwayPostIds.remove(id); failed += 1 }
            }
            for id in toBack {
                guard AccountEpoch.isCurrent(epoch) else { return }
                let saved = await service.setPutAway(false, postId: id)
                guard AccountEpoch.isCurrent(epoch) else { return }
                if !saved { service.putAwayPostIds.insert(id); failed += 1 }
            }
            guard AccountEpoch.isCurrent(epoch) else { return }
            if let coverPhoto,
               !(await service.setMonthCover(photoId: coverPhoto.id, coverPath: coverPhoto.displayPath,
                                             userId: uid, monthStart: monthStart)) {
                guard AccountEpoch.isCurrent(epoch) else { return }
                boxCoverPhotoId = previousCover
                failed += 1
            }
            if failed > 0 {
                Haptics.error()
                UndoCenter.shared.showNotice("Some of that didn't save. Check your connection and try again.")
            }
        }
    }

    private static func dayStamp(_ day: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE d"
        return formatter.string(from: day).uppercased()
    }

    /// "OCT '26", the month's stamp on the box's cover.
    private var monthStamp: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM"
        let year = Calendar(identifier: .gregorian).component(.year, from: viewModel.chapter.monthStart) % 100
        return "\(formatter.string(from: viewModel.chapter.monthStart).uppercased()) '\(String(format: "%02d", year))"
    }

    private func play(from index: Int = 0) {
        previewPlayback = asFriendsSee ? playableDeck : nil
        Haptics.tap()
        selection = index
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { isPlayerPresented = true }
    }

    private var deskBox: some View {
        let month = viewModel.chapter.monthName()
        // Back (or Close in the Duo's column) stays put above the scroll, where a tap always
        // reaches it.
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { Haptics.tap(); close() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: docked ? "xmark" : "chevron.left")
                            .font(.system(size: 17, weight: .medium))
                        if !docked {
                            Text(isOwnRecap ? "You" : "Back")
                                .flimFont(17, relativeTo: .body)
                        }
                    }
                    .foregroundStyle(FlimTheme.textPrimary)
                    .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(docked ? "Close" : (isOwnRecap ? "Back to your page" : "Back"))
                Spacer()
                if isOwnRecap, !viewModel.monthPhotos.isEmpty {
                    Button {
                        guard boxEditReady, !savingBox else { return }
                        Haptics.tap()
                        asFriendsSee = false
                        boxEdit = BoxEditSession(putAway: currentPutAway, cover: boxCoverPhotoId ?? defaultCoverPhotoId)
                    } label: {
                        Text(savingBox ? "Saving…" : "Edit")
                            .flimFont(17, weight: .medium, relativeTo: .body)
                            .foregroundStyle(FlimTheme.textPrimary)
                            .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!boxEditReady || savingBox)
                    .opacity(boxEditReady && !savingBox ? 1 : 0.4)
                    .accessibilityHint("Choose the cover and put shots away")
                }
            }
            .padding(.horizontal, 24)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    boxTitleLayout {
                        Text(month)
                            .font(DeskType.serif(34, relativeTo: .largeTitle))
                            .foregroundStyle(FlimTheme.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
                        Text(asFriendsSee ? (visibleBoxPhotos.count == 1 ? "1 visible shot" : "\(visibleBoxPhotos.count) visible shots") : viewModel.chapter.statsLine)
                            .flimFont(14, relativeTo: .subheadline)
                            .foregroundStyle(FlimTheme.textSecondary)
                            .lineLimit(1)
                    }
                    .padding(.top, 4)

                    boxCover
                        .padding(.top, 14)

                    boxButtonLayout {
                        Button { play() } label: {
                            Label("Play \(month)", systemImage: "play.fill")
                                .flimFont(15, weight: .semibold, relativeTo: .body)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .labelStyle(.titleAndIcon)
                                .foregroundStyle(FlimTheme.bg)
                                .frame(maxWidth: .infinity, minHeight: 46)
                                .background(FlimTheme.textPrimary, in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        // A chapter is one person's month, so the sheet is theirs to share.
                        if isOwnRecap, !asFriendsSee {
                            Button {
                                guard !viewModel.isBuildingContactSheet, !viewModel.isLoadingDeck else { return }
                                Task { await viewModel.buildContactSheet() }
                            } label: {
                                HStack(spacing: 7) {
                                    if viewModel.isBuildingContactSheet || viewModel.isLoadingDeck {
                                        ProgressView().controlSize(.small).tint(FlimTheme.textPrimary)
                                    } else {
                                        Image(systemName: "square.and.arrow.up")
                                    }
                                    Text("Share")
                                        .lineLimit(1)
                                        .fixedSize()
                                }
                                .flimFont(15, weight: .semibold, relativeTo: .body)
                                .foregroundStyle(FlimTheme.textPrimary)
                                .padding(.horizontal, 22)
                                .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : nil, minHeight: 46)
                                .background(FlimTheme.chip, in: Capsule())
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(viewModel.isBuildingContactSheet || viewModel.isLoadingDeck)
                            .accessibilityLabel("Share as a contact sheet")
                        }
                    }
                    .padding(.top, 14)

                    if !asFriendsSee, let note = viewModel.contactSheetNote {
                        Text(note)
                            .flimFont(13, relativeTo: .footnote)
                            .foregroundStyle(FlimTheme.textSecondary)
                            .padding(.top, 8)
                    }
                    if !asFriendsSee, let error = viewModel.contactSheetError {
                        HStack(spacing: 10) {
                            Text(error)
                                .flimFont(13, relativeTo: .footnote)
                                .foregroundStyle(FlimTheme.textSecondary)
                            Button("Retry") { Task { await viewModel.buildContactSheet() } }
                                .flimFont(13, weight: .semibold, relativeTo: .footnote)
                                .foregroundStyle(FlimTheme.ink(accent))
                        }
                        .padding(.top, 8)
                    }

                    if isOwnRecap, putAwayCount > 0 {
                        Text(friendsSeeLine)
                            .font(DeskType.serif(15, italic: true, relativeTo: .body))
                            .tracking(0.2)
                            .foregroundStyle(FlimTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 12)
                    }
                    if asFriendsSee {
                        HStack {
                            Text("PUT-AWAY PREVIEW")
                                .font(DeskType.data(11))
                                .tracking(1.4)
                                .foregroundStyle(FlimTheme.textSecondary)
                            Spacer()
                            Button("Done") { withAnimation(.snappy) { asFriendsSee = false } }
                                .flimFont(15, weight: .semibold, relativeTo: .body)
                                .foregroundStyle(FlimTheme.ink(accent))
                                .frame(minHeight: 44)
                        }
                        .padding(.top, 8)
                        Text("Put-away shots are excluded. Other audience rules still apply.")
                            .flimFont(13, relativeTo: .footnote)
                            .foregroundStyle(FlimTheme.textSecondary)
                    }
                    if showFirstRunLine {
                        Text("Built from what you posted this month. Anyone who can see your page sees this too.")
                            .font(DeskType.serif(15, italic: true, relativeTo: .body))
                            .tracking(0.2)
                            .foregroundStyle(FlimTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 12)
                    }

                    ForEach(boxDays, id: \.day) { group in
                        Text(Self.dayStamp(group.day))
                            .font(DeskType.data(11))
                            .tracking(1.5)
                            .foregroundStyle(FlimTheme.textSecondary)
                            .padding(.top, 22)
                            .padding(.bottom, 8)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                            ForEach(group.photos) { photo in
                                boxThumb(photo)
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
        }
        // Keyed on the month's list: the load lands after the box first appears.
        .task(id: "\(viewModel.monthPhotos.count)-\(savingBox)") {
            guard !savingBox else { boxEditReady = false; return }
            await viewModel.signMonthThumbs(feed: feed)
            // Your own box: which shots are put away, and the cover you chose (12b).
            if isOwnRecap, !viewModel.monthPhotos.isEmpty, let uid = auth.currentUser?.id {
                let readPutAway = await chapters.loadPutAway(postIds: viewModel.monthPhotos.compactMap(\.postId))
                guard !Task.isCancelled, !savingBox else { return }
                var readCover = boxCoverPhotoId != nil
                if !readCover, let read = await chapters.monthCoverPhotoId(userId: uid, monthStart: viewModel.chapter.monthStart) {
                    guard !Task.isCancelled, !savingBox else { return }
                    boxCoverPhotoId = read
                    readCover = true
                }
                // Both read (a month with no chosen cover reads as `.some(nil)`): Edit can open.
                guard !Task.isCancelled, !savingBox else { return }
                boxEditReady = readPutAway && readCover
            }
        }
        .sheet(item: $boxEdit) { session in
            MonthBoxEditView(
                monthName: viewModel.chapter.monthName(),
                photos: viewModel.monthPhotos.filter { !$0.isDeadFrame },
                urls: viewModel.urls,
                cover: session.cover,
                putAway: session.putAway,
                onDone: { cover, putAway, preview in
                    applyBoxEdit(cover: cover, putAway: putAway, from: session)
                    withAnimation(.snappy) { asFriendsSee = preview }
                })
        }
        .onChange(of: asFriendsSee) { _, _ in viewModel.showContactSheetShare = false }
        .sheet(isPresented: Binding(get: { !asFriendsSee && viewModel.showContactSheetShare },
                                    set: { viewModel.showContactSheetShare = $0 })) {
            if let file = viewModel.contactSheetFile {
                ActivityView(items: [file])
            }
        }
    }

    /// The box's rows side by side, or stacked at accessibility sizes: the title row on its
    /// baseline, the buttons centred.
    private var boxTitleLayout: AnyLayout {
        typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                                     : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
    }

    private var boxButtonLayout: AnyLayout {
        typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
    }

    /// The box's cover: the month's first cover shot, its stamp, and a play mark; a tap plays.
    private var boxCover: some View {
        Button { play() } label: {
            Color.clear
                .aspectRatio(3.0 / 2.0, contentMode: .fit)
                .overlay {
                    if let path = boxCoverPath {
                        GeometryReader { geo in
                            CachedImage(url: chapterCoverURLs[path] ?? viewModel.urls[path], maxPixel: 900, cacheKey: path) {
                                focusedCover($0, in: geo.size)
                            } placeholder: { FlimTheme.well }
                        }
                    } else {
                        FlimTheme.well
                    }
                }
                .overlay {
                    LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .center, endPoint: .bottom)
                }
                .overlay {
                    // Dark on the cream disc whatever the desk: the desk's ink turns cream on
                    // Slate, which put a cream glyph on a cream disc (owner, 2026-11-14).
                    Image(systemName: "play.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(DeskColor.rgb(0x2A2420))
                        .offset(x: 2)
                        .frame(width: 60, height: 60)
                        .background(DeskColor.rgb(0xFBF6F0).opacity(0.96), in: Circle())
                        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
                }
                .overlay(alignment: .bottomLeading) {
                    Text(monthStamp)
                        .font(DeskType.data(13))
                        .tracking(1.5)
                        .foregroundStyle(.white)
                        .padding(14)
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play \(viewModel.chapter.monthName())")
        // Where the cover's subject is, so the crop keeps a face in rather than the middle.
        .task(id: boxCoverPath) {
            guard let path = boxCoverPath else { coverFocus = nil; return }
            if let hit = PhotoFocus.cached(path) { coverFocus = hit; return }
            coverFocus = nil
            guard let url = chapterCoverURLs[path] ?? viewModel.urls[path],
                  let image = await ImageLoader.fetch(url: url, maxPixel: 900, scale: displayScale, cacheKey: path)
            else { return }
            let found = await PhotoFocus.subject(of: image, key: path)
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { coverFocus = found }
        }
    }

    /// The cover filled into the box with its subject kept in view (`PhotoFocus`): a 3:4 frame in
    /// a 3:2 box shows half its height, and the middle half is where a standing person's face
    /// isn't. A frame wider than the box fills it centred, as before.
    private func focusedCover(_ image: Image, in size: CGSize) -> some View {
        let aspect = coverFocus?.aspect ?? FlimTheme.frameAspect
        let boxAspect = size.height > 0 ? size.width / size.height : 1.5
        return Group {
            if aspect < boxAspect, size.width > 0 {
                let height = size.width / aspect
                let top = PhotoFocus.windowTop(for: coverFocus, visible: size.height / height)
                image.resizable().scaledToFill()
                    .frame(width: size.width, height: height)
                    .clipped()
                    .offset(y: -top * height)
                    .frame(width: size.width, height: size.height, alignment: .top)
            } else {
                image.resizable().scaledToFill()
                    .frame(width: size.width, height: size.height)
            }
        }
        .clipped()
    }

    private func boxThumb(_ photo: ChapterPhoto) -> some View {
        Button {
            // A shot the screening plays opens there; one curation left out opens at the start.
            play(from: playableDeck.firstIndex { $0.id == photo.id } ?? 0)
        } label: {
            Color.clear
                .aspectRatio(FlimTheme.frameAspect, contentMode: .fit)
                .overlay {
                    CachedImage(url: viewModel.urls[photo.displayPath], maxPixel: 300, cacheKey: photo.displayPath) {
                        $0.resizable().scaledToFill()
                    } placeholder: { FlimTheme.well }
                }
                .overlay {
                    // Yours only: a shot you put away, still here for you, gone for friends.
                    if isOwnRecap, isPutAway(photo) {
                        ZStack {
                            FlimTheme.bg.opacity(0.55)
                            Image(systemName: "eye.slash")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(FlimTheme.textPrimary)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Shot from \(photo.takenAt.formatted(date: .abbreviated, time: .shortened))\(isOwnRecap && isPutAway(photo) ? ", put away" : "")")
    }

    private var v1OpeningCardBody: some View {
        ZStack {
            radialWash
            VStack(spacing: 0) {
                HStack {
                    Button { Haptics.tap(); close() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .accessibilityLabel("Close")
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                // Two flexible spacers, not one: the header/prints block sits roughly centred
                // in the space below the close button, and the controls stay pinned near the
                // bottom, rather than the content pinning to the top and leaving one enormous
                // gap above the buttons on a tall device.
                Spacer(minLength: 12)

                VStack(spacing: 0) {
                    Text("CHAPTER \(viewModel.chapter.chapterCode())")
                        .flimFont(12, weight: .semibold, design: .monospaced, relativeTo: .caption)
                        .tracking(3)
                        .foregroundStyle(accent)

                    Text(viewModel.chapter.monthName())
                        .flimFont(40, weight: .ultraLight, relativeTo: .largeTitle)
                        .foregroundStyle(.white)
                        .padding(.top, 4)

                    Text(viewModel.chapter.statsLine)
                        .flimFont(14, relativeTo: .subheadline)
                        .foregroundStyle(Color(white: 0.65))
                        .padding(.top, 6)

                    fannedPrints
                        .padding(.top, 28)

                    if showFirstRunLine {
                        Text("Built from what you posted this month. Anyone who can see your profile sees this too.")
                            .flimFont(13, relativeTo: .footnote)
                            .foregroundStyle(Color(white: 0.65))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 36)
                            .padding(.top, 16)
                    }
                }

                Spacer(minLength: 12)

                playControls
                    .padding(.horizontal, 32)
                    .padding(.bottom, 24)
            }
        }
    }

    private var radialWash: some View {
        GeometryReader { geo in
            // Filling the WHOLE screen and letting the gradient itself fade to `.clear` well
            // inside that area, rather than clipping a shorter box around it, is what keeps the
            // wash soft: a `.frame(height:)` short of where the gradient would naturally reach
            // `.clear` draws a visible ring at that box's own edge instead of a fade.
            RadialGradient(colors: [accent.opacity(0.28), .clear],
                           center: UnitPoint(x: 0.5, y: 0.22), startRadius: 0,
                           endRadius: geo.size.width * 0.85)
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    /// Three prints, fanned: the two behind at fixed angles, the hero (0°, front, carrying the
    /// date stamp) on top. Drawn from `chapterCoverURLs`/`coverPaths`, which are already resolved
    /// by the time the shelf tapped through to this screen, so the card never waits on the
    /// month's full photo fetch to have something to show.
    private var fannedPrints: some View {
        let paths = Array(viewModel.chapter.coverPaths.prefix(3))
        return ZStack {
            if paths.count > 1 {
                printCard(path: paths[1], rotation: 6, dateStamp: nil)
                    .zIndex(0)
            }
            if paths.count > 2 {
                printCard(path: paths[2], rotation: -7, dateStamp: nil)
                    .zIndex(1)
            }
            if let hero = paths.first {
                printCard(path: hero, rotation: 0, dateStamp: heroDateStamp)
                    .zIndex(2)
            } else {
                // No covers at all (a month whose photos never resolved a thumbnail) still gets
                // a frame-shaped placeholder rather than an empty gap where the card's centrepiece
                // should be.
                RoundedRectangle(cornerRadius: RevealPacing.frameCornerRadius)
                    .fill(Color.white.opacity(0.05))
                    .frame(width: 150, height: 150 / RevealPacing.frameAspectRatio)
            }
        }
        .frame(height: 220)
    }

    private func printCard(path: String, rotation: Double, dateStamp: String?) -> some View {
        CachedImage(url: chapterCoverURLs[path], maxPixel: 500, cacheKey: path) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Color.white.opacity(0.06)
        }
        .frame(width: 140, height: 140 / RevealPacing.frameAspectRatio)
        .clipShape(RoundedRectangle(cornerRadius: RevealPacing.frameCornerRadius))
        .overlay(RoundedRectangle(cornerRadius: RevealPacing.frameCornerRadius).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .overlay(alignment: .bottomTrailing) {
            if let dateStamp {
                Text(dateStamp)
                    .flimFont(11, weight: .medium, design: .monospaced, relativeTo: .caption2)
                    .tracking(1)
                    .foregroundStyle(accent)
                    .shadow(color: accent.opacity(0.9), radius: 6)
                    .padding(8)
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
        .rotationEffect(.degrees(rotation))
    }

    /// "26 08 09": year, month, day, matching the burned-in date-back's own digits (see
    /// `BrandedExport`), read off the month's most recent shot so a still-growing month's stamp
    /// keeps advancing as new shots land.
    private var heroDateStamp: String {
        // Gregorian explicitly, matching the burned-in date-back's own digits (`BrandedExport`):
        // `Calendar.current` on a Buddhist or Japanese device reads `.year` in that calendar's
        // era, printing a stamp that doesn't match the photograph it is burned into.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let comps = calendar.dateComponents([.year, .month, .day], from: viewModel.chapter.lastShotAt)
        let year = (comps.year ?? 0) % 100
        return String(format: "%02d %02d %02d", year, comps.month ?? 0, comps.day ?? 0)
    }

    private var playControls: some View {
        VStack(spacing: 14) {
            Button {
                Haptics.tap()
                selection = 0
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { isPlayerPresented = true }
            } label: {
                Text("Play the month")
                    .flimFont(15, weight: .semibold, relativeTo: .body)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(accent, in: Capsule())
            }

            // A chapter is one person's month, so the sheet is theirs to share and nobody
            // else's (see `PhotoExport.eligible`).
            if isOwnRecap {
            Button {
                guard !viewModel.isBuildingContactSheet, !viewModel.isLoadingDeck else { return }
                Task { await viewModel.buildContactSheet() }
            } label: {
                HStack(spacing: 7) {
                    // `isLoadingDeck` (curation still choosing the real pick) spins the button
                    // exactly the way `isBuildingContactSheet` already does; the opening card
                    // itself is never blocked on this, only the ONE action that wants curation's
                    // FINAL pick rather than the provisional one already on screen.
                    if viewModel.isBuildingContactSheet || viewModel.isLoadingDeck {
                        ProgressView().tint(Color(white: 0.7)).controlSize(.small)
                    } else {
                        Image(systemName: "square.grid.2x2").font(.system(size: 13))
                    }
                    Text(viewModel.isBuildingContactSheet ? "Building the sheet" : "Share as a contact sheet")
                        .flimFont(14, weight: .medium, relativeTo: .subheadline)
                }
                .foregroundStyle(Color(white: 0.7))
            }
            .disabled(viewModel.isBuildingContactSheet || viewModel.isLoadingDeck)
            }

            // Rule 4 (confirmations redesign), the same shape `RollRevealView.saveAll` uses: a
            // failure lands right under the button that caused it, with the retry in place.
            // Said under the button, before and after the share: an incomplete sheet is not an
            // error, it is a fact the person should have while deciding to send it.
            if let note = viewModel.contactSheetNote {
                Text(note)
                    .flimFont(12.5, relativeTo: .footnote)
                    .foregroundStyle(Color(white: 0.55))
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }

            if let error = viewModel.contactSheetError {
                HStack(spacing: 10) {
                    Text(error)
                        .flimFont(12.5, relativeTo: .footnote)
                        .foregroundStyle(Color(white: 0.55))
                    Button("Retry") { Task { await viewModel.buildContactSheet() } }
                        .flimFont(12.5, weight: .semibold, relativeTo: .footnote)
                        .foregroundStyle(accent)
                }
                .transition(.opacity)
            }
        }
        .sheet(isPresented: Binding(get: { viewModel.showContactSheetShare },
                                    set: { viewModel.showContactSheetShare = $0 })) {
            if let file = viewModel.contactSheetFile {
                ActivityView(items: [file])
            }
        }
    }

    // MARK: - Player

    /// No `swipeToDismiss` here, deliberately, matching `RollRevealView`'s own playback and
    /// `PhotoPagerView`: a vertical drag riding alongside a native `TabView(.page)` pager, even
    /// one gated to only act on vertical movement, visibly damps the pager's own physics on
    /// device. The pager's own X is the only way out while playing, the same as both of those.
    ///
    /// Loading and empty states keep the same small header (close + month name) the old player
    /// had, since `PhotoPagerView` only ever renders once there is a `current` photo to show.
    /// Presented as this screen's own `.fullScreenCover` (`isPlayerPresented`) rather than mounted
    /// directly in `body`'s `switch`, the same way `RollDetailView` presents its single-photo
    /// pager over its grid: `PhotoPagerView`'s own X calls the environment's `dismiss()`, and
    /// nesting a presentation boundary here is what makes that resolve to just this cover instead
    /// of the whole recap, so `handlePlayerDismissed()` gets a chance to route to the closing card
    /// rather than ending the recap outright.
    @ViewBuilder
    private var player: some View {
        // `!viewModel.loaded`, not `viewModel.isLoadingDeck`: `deck` is playable the instant
        // `chapter_photos` itself returns (the provisional pick), well before curation's Vision
        // pass finishes, so this only waits on that first, much shorter round trip. See
        // `ChapterRecapViewModel.load()`'s own doc.
        if !viewModel.loaded {
            VStack(spacing: 0) {
                playerHeader
                Spacer(minLength: 0)
                ProgressView().tint(FlimTheme.textSecondary)
                Spacer(minLength: 0)
            }
            .transition(.opacity)
        } else if playbackDeck.isEmpty {
            VStack(spacing: 0) {
                playerHeader
                Spacer(minLength: 0)
                emptyDeck
                Spacer(minLength: 0)
            }
            .transition(.opacity)
        } else if splitsScreening {
            // The open Duo (Blend 2): the photographs on the left of the fold, the month in
            // numbers on the right, so a wide screen isn't a narrow print in the middle.
            HStack(spacing: 0) {
                monthPager
                    .id(pagerJump)
                    .frame(maxWidth: .infinity)
                    .padding(.trailing, 14)
                splitNumbers
                    .frame(maxWidth: .infinity)
                    .padding(.leading, 14)
            }
            .transition(.opacity)
        } else {
            monthPager
        }
    }

    /// Plays the month beside its numbers: the open Duo, with numbers to show. Measured from the
    /// screening's own width rather than the desk layout, which a full-screen cover can disagree
    /// with; 700pt is past any phone and inside the open Duo (890pt).
    private var splitsScreening: Bool {
        AppInfo.is17 && !asFriendsSee && screeningWidth >= 700 && viewModel.hasClosingCard
    }

    /// The numbers beside the photographs on the open Duo: a frame opens in the pager, and its
    /// Back and X end the screening.
    private var splitNumbers: some View {
        ChapterClosingCardView(
            monthName: viewModel.chapter.monthName(),
            lines: viewModel.closingLines,
            thumbURLs: viewModel.urls,
            onSelectPhoto: { line in
                guard let photoId = line.photoId, let idx = viewModel.deckIndex(ofPhoto: photoId) else { return }
                selection = idx
                pagerJump += 1
            },
            onSelectProfile: { userId in
                isPlayerPresented = false
                profileRoute = ProfileRoute(id: userId)
            },
            onPlayAgain: { selection = 0; pagerJump += 1 },
            onClose: { withAnimation(.easeInOut(duration: 0.2)) { isPlayerPresented = false } },
            showsClose: false
        )
    }

    private var monthPager: some View {
            PhotoPagerView(
                photos: ChapterRecapViewModel.pagerPhotos(from: playbackDeck, profileId: profileId),
                startIndex: selection,
                signedURLs: ChapterRecapViewModel.pagerSignedURLs(from: playbackDeck, urls: viewModel.urls),
                // These are posts (chapters are posted-only), so the reactions/comments the
                // viewer already resolves by photo id apply exactly as they do anywhere else a
                // post's photo is shown full screen.
                showsReactions: true,
                showsComments: true,
                // A chapter is one profile's own month end to end, so crediting each frame with
                // the same @handle over and over is redundant, unlike a roll's several
                // photographers.
                showsAttribution: false,
                showsRollRack: true,
                // A recap is playback, not an editing surface: no roll name badge (see
                // `pagerPhotos`'s own doc on why `rollId` is dropped too) and no delete.
                rollName: { _ in nil },
                screeningTitle: viewModel.chapter.monthName(),
                showsDelete: false,
                // A chapter photo IS a post; its reactions/comments live on the post tables, not
                // the roll-photo ones. See `PhotoPagerView.posts`'s own doc.
                posts: ChapterRecapViewModel.pagerPosts(from: playbackDeck, profileId: profileId),
                onClose: { withAnimation(.easeInOut(duration: 0.2)) { isPlayerPresented = false } }
            )
            .transition(.opacity)
    }

    @ViewBuilder
    private var playerHeader: some View {
        if AppInfo.is17 {
            // The screening's header (3e) while the month loads: its name in Caslon, the close
            // on the right, where the pager's own header puts them.
            HStack(spacing: 14) {
                Text(viewModel.chapter.monthName())
                    .font(DeskType.serif(24, relativeTo: .title2))
                    .foregroundStyle(FlimTheme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button { Haptics.tap(); isPlayerPresented = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(FlimTheme.textPrimary)
                }
                .accessibilityLabel("Close")
                .expandTapTarget(by: 14)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
        } else {
            v1PlayerHeader
        }
    }

    private var v1PlayerHeader: some View {
        HStack(spacing: 12) {
            Button { Haptics.tap(); isPlayerPresented = false } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
            }
            .accessibilityLabel("Close")
            Text(viewModel.chapter.monthName())
                .flimFont(17, weight: .semibold, relativeTo: .body)
                .foregroundStyle(.white)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var emptyDeck: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 34, weight: .ultraLight))
                .foregroundStyle(accent.opacity(0.8))
            Text("Nothing to play in this chapter yet.")
                .flimFont(15, relativeTo: .subheadline)
                .foregroundStyle(FlimTheme.textPrimary)
        }
    }

    // MARK: - Closing card

    /// Runs once the pager's `.fullScreenCover` actually goes away, whichever way that happened:
    /// its own X (the environment `dismiss()` this cover scopes to, not the whole recap) or
    /// `playerHeader`'s close button setting `isPlayerPresented` directly for the loading/empty
    /// states. Lands on the closing card when this month has one, otherwise the recap is over,
    /// same as before the closing card existed.
    private func handlePlayerDismissed() {
        // `phase` was already flipped in `.onChange(of: isPlayerPresented)` the instant the
        // cover began to leave, so the screen under it is the closing card by the time the cover
        // is gone. Left here only for the no-card case, which ends the recap.
        if !viewModel.hasClosingCard && !AppInfo.is17 { close() }
    }

    private var closingCard: some View {
        ChapterClosingCardView(
            monthName: viewModel.chapter.monthName(),
            lines: viewModel.closingLines,
            thumbURLs: viewModel.urls,
            onSelectPhoto: { line in
                guard let photoId = line.photoId, let idx = viewModel.deckIndex(ofPhoto: photoId) else { return }
                selection = idx
                isPlayerPresented = true
            },
            onSelectProfile: { userId in
                profileRoute = ProfileRoute(id: userId)
            },
            onPlayAgain: {
                // From the start, not from whichever stat-line photo was opened last.
                selection = 0
                isPlayerPresented = true
            },
            // 1.7: the closing card hands back to the box it was played from.
            onClose: { if AppInfo.is17 { phase = .opening } else { close() } }
        )
    }
}

/// Choosing a box's cover and putting shots away (Blend 4, 12b). A tap makes a shot the cover;
/// a hold puts it away, and another hold brings it back. Putting the cover away moves the cover
/// to the next shot that is still out. Nothing is deleted. Nothing is saved until Done.
struct MonthBoxEditView: View {
    let monthName: String
    let photos: [ChapterPhoto]
    let urls: [String: URL]
    /// Done hands back the cover, the post ids put away, and whether to show the box as friends
    /// see it.
    let onDone: (UUID?, Set<UUID>, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.flimAccent) private var accent
    @State private var cover: UUID?
    @State private var putAway: Set<UUID>
    /// Set by a hold, so the tap that ends it doesn't also make the shot the cover.
    @State private var heldId: UUID?
    @State private var heldAt: Date?

    init(monthName: String, photos: [ChapterPhoto], urls: [String: URL], cover: UUID?, putAway: Set<UUID>,
         onDone: @escaping (UUID?, Set<UUID>, Bool) -> Void) {
        self.monthName = monthName
        self.photos = photos
        self.urls = urls
        self.onDone = onDone
        _cover = State(initialValue: cover)
        _putAway = State(initialValue: putAway)
    }

    private func isAway(_ photo: ChapterPhoto) -> Bool { photo.postId.map(putAway.contains) ?? false }

    private var friendsSee: Int { photos.filter { !isAway($0) }.count }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { dismiss() }
                    .flimFont(17, relativeTo: .body)
                    .foregroundStyle(FlimTheme.textPrimary)
                    .frame(minHeight: 44)
                Spacer()
                Text(monthName)
                    .font(DeskType.serif(22, relativeTo: .title3))
                    .foregroundStyle(FlimTheme.textPrimary)
                    .lineLimit(1)
                Spacer()
                Button("Done") { onDone(cover, putAway, false); dismiss() }
                    .flimFont(17, weight: .semibold, relativeTo: .body)
                    .foregroundStyle(FlimTheme.textPrimary)
                    .frame(minHeight: 44)
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Tap a shot to make it the cover. Hold one to put it away.")
                        .font(DeskType.serif(16, italic: true, relativeTo: .body))
                        .tracking(0.2)
                        .foregroundStyle(FlimTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                        ForEach(photos) { photo in
                            tile(photo)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }

            VStack(spacing: 10) {
                Text("Friends see \(friendsSee) of \(photos.count). Put-away shots stay yours.")
                    .flimFont(14, relativeTo: .footnote)
                    .foregroundStyle(FlimTheme.textSecondary)
                    .multilineTextAlignment(.center)
                Button { onDone(cover, putAway, true); dismiss() } label: {
                    Text("Preview without put-away shots")
                        .flimFont(15, weight: .semibold, relativeTo: .body)
                        .foregroundStyle(FlimTheme.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .overlay(Capsule().strokeBorder(FlimTheme.stroke, lineWidth: 1.5))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .background(DeskGround())
        .flimSheetSurface()
        .presentationDetents([.large])
    }

    private func tile(_ photo: ChapterPhoto) -> some View {
        let away = isAway(photo)
        let isCover = photo.id == cover
        return Color.clear
            .aspectRatio(FlimTheme.frameAspect, contentMode: .fit)
            .overlay {
                CachedImage(url: urls[photo.displayPath], maxPixel: 300, cacheKey: photo.displayPath) {
                    $0.resizable().scaledToFill()
                } placeholder: { FlimTheme.well }
                .opacity(away ? 0.3 : 1)
            }
            .overlay {
                if away {
                    VStack(spacing: 6) {
                        Image(systemName: "eye.slash").font(.system(size: 16, weight: .semibold))
                        Text("PUT AWAY").font(DeskType.data(9)).tracking(1.2)
                    }
                    .foregroundStyle(FlimTheme.textPrimary)
                }
            }
            .overlay(alignment: .topLeading) {
                if isCover {
                    Text("COVER")
                        .font(DeskType.data(9))
                        .tracking(1)
                        .foregroundStyle(Color(white: 0.1))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(accent, in: RoundedRectangle(cornerRadius: 3))
                        .padding(5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(isCover ? accent : .clear, lineWidth: 2.5)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                // The tap that ends a hold, not a later one: a hold that ended in a scroll left
                // `heldId` set and ate the next real tap (nightly review, 2026-11-15).
                if heldId == photo.id, let at = heldAt, Date.now.timeIntervalSince(at) < 1.5 { heldId = nil; return }
                heldId = nil
                // A put-away shot can't be the cover; bring it back first.
                guard !away else { Haptics.warning(); return }
                Haptics.tap()
                cover = photo.id
            }
            // Simultaneous, or the tap above claims the touch and the hold never fires (the same
            // trap as the camera's zoom chips).
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.35).onEnded { _ in
                heldId = photo.id
                heldAt = .now
                toggleAway(photo)
            })
            .accessibilityElement()
            .accessibilityLabel("Shot from \(photo.takenAt.formatted(date: .abbreviated, time: .shortened))\(isCover ? ", cover" : "")\(away ? ", put away" : "")")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "Make it the cover") { if !away { cover = photo.id } }
            .accessibilityAction(named: away ? "Bring it back" : "Put it away") { toggleAway(photo) }
    }

    private func toggleAway(_ photo: ChapterPhoto) {
        guard let postId = photo.postId else { return }
        Haptics.tap()
        if putAway.contains(postId) {
            putAway.remove(postId)
        } else {
            putAway.insert(postId)
            // The cover went away: the next shot still out takes it.
            if photo.id == cover {
                cover = photos.first { p in p.id != photo.id && !(p.postId.map(putAway.contains) ?? false) }?.id
            }
        }
    }
}
