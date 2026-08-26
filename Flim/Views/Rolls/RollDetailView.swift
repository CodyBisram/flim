import SwiftUI
import UIKit

/// One iteration's outcome from `RollDetailView`'s roll-pagination drain loop, decided from
/// three server-observed facts rather than inline in the loop, so the "give up without claiming
/// the roll is fully paged" rule (and the retry budget behind it) is directly testable without a
/// live `PhotoService` or the `Task.sleep` backoff.
///
/// The loop this backs replaced an unconditional `break` on a starved (no-progress) iteration
/// that still fell through to `rollFullyPaged = true`: the shared `PhotoService.isLoading` guard
/// inside `loadMoreRoll` can return synchronously, doing nothing, whenever another screen (or
/// this same screen's own grid-scroll trigger) already has a fetch in flight, and a single
/// starved iteration used to be read as "the roll is done" rather than "something else is busy
/// right now" (both audits, 2026-08-25/26). See `rollDrainCompletedFully`.
enum RollDrainStep: Equatable {
    /// The loaded page grew: keep draining immediately, retry budget reset.
    case progressed
    /// No growth this iteration, but the retry budget isn't spent: yield, back off briefly, retry.
    case retry(starvedRetries: Int)
    /// The server says there's nothing left (`hasMore == false`): the drain is genuinely,
    /// honestly complete.
    case exhausted
    /// No growth, and the retry budget is spent: give up WITHOUT claiming the roll is fully
    /// paged. A later grid-scroll `loadMoreRoll` trigger, or simply reappearing on this roll, can
    /// still finish the job; this only stops THIS drain from lying about having finished it.
    case gaveUp
}

/// Pure decision function behind one iteration of the drain loop: given what that iteration
/// actually observed (the page count before/after `loadMoreRoll`, whether the server still has
/// more, and how many consecutive starved iterations have already happened), which of the four
/// `RollDrainStep` outcomes applies. `maxStarvedRetries` bounds the ~200ms-backoff retries the
/// loop performs before giving up (25 ≈ 5s worst case).
func rollDrainStep(loadedBefore: Int, loadedAfter: Int, hasMore: Bool,
                    starvedRetries: Int, maxStarvedRetries: Int = 25) -> RollDrainStep {
    guard hasMore else { return .exhausted }
    guard loadedAfter > loadedBefore else {
        let next = starvedRetries + 1
        return next >= maxStarvedRetries ? .gaveUp : .retry(starvedRetries: next)
    }
    return .progressed
}

/// Whether `RollDetailView.rollFullyPaged` may be set true: only when the drain loop exited
/// because the server genuinely reported nothing left (`hasMore == false`), never merely because
/// it returned. Setting `rollFullyPaged` on a starved give-up is the exact bug both audits found:
/// every count gated on it (the reveal banner's shot count, "Play through the roll · N", the
/// DEVELOPING header count) would silently undercount a roll that was still mid-drain.
func rollDrainCompletedFully(exitedBecauseExhausted: Bool) -> Bool {
    exitedBecauseExhausted
}

struct RollDetailView: View {
    @Environment(\.flimAccent) private var accent
    let roll: Roll
    @Environment(PhotoService.self) private var photoService
    @Environment(RollService.self) private var rollService
    @Environment(AuthService.self) private var auth
    @Environment(NotificationService.self) private var notifications
    @Environment(FeedService.self) private var feed
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dismiss) private var dismiss
    @AppStorage("developNotificationsEnabled") private var notificationsEnabled = true
    @State private var vm = DarkroomViewModel()
    @State private var showMembers = false
    @Namespace private var photoNS
    @State private var selectedPhoto: Photo?
    @State private var memberNames: [UUID: String] = [:]   // userId → username, for attribution
    @State private var showRename = false
    @State private var renameDraft = ""
    @State private var showDeleteRoll = false
    @State private var savingAll = false
    @State private var saveAllError: String?
    /// Set when the alert is a warning rather than a failure, so the share sheet opens after it
    /// is dismissed. Presenting both at once means SwiftUI shows one and drops the other.
    @State private var shareAfterAlert = false
    /// File URLs, not UIImages: see PhotoExport for why the roll is not held in memory.
    @State private var shareImages: [URL] = []
    @State private var showShareAll = false
    @State private var displayName = ""
    @State private var showInviteShare = false
    /// The file's one top-slot toast, reused for every transient status line (cover updated,
    /// rename/leave failures) so there is a single presentation and timing to reason about
    /// instead of one boolean per message.
    @State private var toastMessage: String?
    @State private var toastDismiss: Task<Void, Never>?
    @State private var toastIsError = false
    @State private var showLeaveRoll = false
    @State private var showCarousel = false
    @State private var shareItem: ShareImage?
    @State private var isMuted = false
    @State private var showReveal = false
    /// Flips true once a developed roll's pagination has been fully drained (see `onAppear`).
    /// Gates the "Play through the roll" button so it appears once, already showing the true
    /// count, without this, the button popped in after page 1 (30) and its own count label
    /// visibly ticked upward (30 → 60 → 75) as each further page streamed in behind it.
    @State private var rollFullyPaged = false

    private var revealSeenKey: String { "rollRevealSeen.\(roll.id.uuidString)" }

    private var isCreator: Bool { auth.currentUser?.id == roll.createdBy }
    /// Developed shots oldest → newest, for the flip-through carousel, cached on the view model
    /// (recomputed only when the roll's photos change) rather than sorted on every access.
    private var chronologicalDeveloped: [Photo] { vm.chronologicalDeveloped }

    /// The signed-in member's own shots in this roll, developed and developing alike, for the
    /// leave sheet's "your N shots stay" line. `nil` (rather than 0) when nothing is loaded
    /// yet, so the copy falls back to the countless wording instead of claiming "0 shots".
    private var myShotCount: Int? {
        guard let uid = auth.currentUser?.id else { return nil }
        let mine = (vm.developedPhotos + vm.developingPhotos).filter { $0.userId == uid }.count
        return mine > 0 ? mine : nil
    }
    private var isFullyDeveloped: Bool {
        roll.isDeveloped && rollFullyPaged && !vm.developedPhotos.isEmpty
    }

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    var body: some View {
        ZStack {
            FlimTheme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                FlimNavTitle(displayName.isEmpty ? roll.name : displayName)

                if let count = rollService.memberCounts[roll.id] {
                    Label("\(count) member\(count == 1 ? "" : "s")", systemImage: "person.2.fill")
                        .flimFont(13, weight: .medium)
                        .imageScale(.small)
                        .foregroundStyle(FlimTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                }

                // Countdown to the shared reveal, runs from the moment the roll was created,
                // so it shows even before anyone has taken a shot.
                if !roll.isDeveloped {
                    // nil (not 0) while pagination is still draining, 0 legitimately means "no
                    // shots yet", a different message from "still counting". See rollFullyPaged.
                    revealBanner(revealAt: roll.revealAt,
                                 shots: rollFullyPaged ? vm.developingPhotos.count : nil,
                                 people: Set(vm.developingPhotos.map(\.userId)).count)
                }

                // Flip through the whole developed roll, in order.
                if isFullyDeveloped {
                    Button {
                        showCarousel = true
                    } label: {
                        Label("Play through the roll · \(vm.developedPhotos.count)", systemImage: "play.circle.fill")
                            .flimFont(15, weight: .semibold)
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(accent, in: Capsule())
                    }
                    .padding(.horizontal, 16).padding(.bottom, 6)
                }

                Group {
                    if vm.isLoading && vm.photos.isEmpty {
                        ProgressView().tint(.white)
                    } else if let error = vm.error, vm.photos.isEmpty {
                        // The view model has always tracked this; the roll grid just never showed
                        // it, so a failed load looked like an empty roll.
                        ErrorState(message: error) {
                            await vm.loadRoll(photoService: photoService, rollId: roll.id, blockedIds: feed.blockedIds)
                        }
                    } else if vm.photos.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 36, weight: .ultraLight))
                                .foregroundStyle(accent.opacity(0.8))
                            Text("No photos in this roll yet.")
                                .flimFont(15, weight: .light, relativeTo: .body)
                                .foregroundStyle(FlimTheme.textSecondary)
                            Text("Take a photo and send it to \"\(roll.name)\".")
                                .flimFont(13, relativeTo: .subheadline)
                                .foregroundStyle(FlimTheme.textTertiary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)
                        }
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                if !vm.developingPhotos.isEmpty {
                                    // Same reasoning as the reveal banner: no count in the
                                    // header until it's the true total, not a page-1 fragment.
                                    sectionHeader(rollFullyPaged ? "\(vm.developingPhotos.count) DEVELOPING" : "DEVELOPING")
                                    photoGrid(vm.developingPhotos, triggersLoadMore: false)
                                }
                                if !vm.developedPhotos.isEmpty {
                                    sectionHeader("DEVELOPED")
                                    photoGrid(vm.developedPhotos, triggersLoadMore: true)
                                }
                            }
                        }
                        .refreshable {
                            await vm.loadRoll(photoService: photoService, rollId: roll.id, blockedIds: feed.blockedIds)
                            warmGridThumbnails()   // no-op for anything already cached
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .top) {
            if let toastMessage {
                Label(toastMessage, systemImage: toastIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .flimFont(13, weight: .medium)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showMembers = true } label: {
                    Image(systemName: "person.2")
                        .foregroundStyle(accent)
                }
                .accessibilityLabel("Members")
                Button {
                    Haptics.tap()
                    showInviteShare = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(accent)
                }
                .accessibilityLabel("Share invite")

                Menu {
                    // The reveal is the best thing this app does and it was strictly one-shot:
                    // seen once, gone forever, because the flag that stops it replaying on every
                    // visit never clears. So the moment a roll exists to be remembered by could
                    // never be watched again, which is backwards for something built to be
                    // rewatched with the people who were there.
                    if roll.isDeveloped, !vm.developedPhotos.isEmpty {
                        Button {
                            Haptics.tap()
                            replayReveal()
                        } label: { Label("Play reveal again", systemImage: "play.circle") }

                    }

                    // Disabled with no reason reads as a broken menu item. A menu can hold a
                    // plain Text, so it says which of the two reasons applies instead.
                    if vm.developedPhotos.isEmpty {
                        Text("Nothing to save until the roll develops")
                    } else {
                        Button {
                            saveAll()
                        } label: { Label(savingAll ? "Saving…" : "Save all to Camera Roll", systemImage: "square.and.arrow.down.on.square") }
                            .disabled(savingAll)
                    }

                    // Silence this roll's comment/reaction notifications without leaving it.
                    Button {
                        guard let uid = auth.currentUser?.id else { return }
                        let wanted = !isMuted
                        isMuted = wanted   // optimistic
                        Task {
                            if await !photoService.setRollMuted(wanted, rollId: roll.id, userId: uid) {
                                isMuted = !wanted   // the write never landed; don't claim it did
                                Haptics.error()
                            }
                        }
                    } label: {
                        Label(isMuted ? "Unmute notifications" : "Mute notifications",
                              systemImage: isMuted ? "bell.slash" : "bell")
                    }

                    if isCreator {
                        Button {
                            renameDraft = roll.name
                            showRename = true
                        } label: { Label("Rename roll", systemImage: "pencil") }
                        Button(role: .destructive) {
                            showDeleteRoll = true
                        } label: { Label("Delete roll", systemImage: "trash") }
                    } else {
                        Button(role: .destructive) {
                            showLeaveRoll = true
                        } label: { Label("Leave roll", systemImage: "rectangle.portrait.and.arrow.right") }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(accent)
                }
                .accessibilityLabel("More")
            }
        }
        // The whole-roll drain used to live in `.onAppear { Task { ... } }`, which is never
        // cancelled on disappear: leaving this screen didn't stop it, so a second roll's own
        // fetch could interleave with a dead roll's still-running drain, and `loadMoreRoll`
        // reads the SHARED `PhotoService.loadedPhotos` fresh on every call, so the stale roll's
        // rows could append straight into the new roll's list (cross-roll mixing, found by the
        // feed audit). `.task` is auto-cancelled the moment this view disappears; the drain loop
        // itself also checks `Task.isCancelled` on top of that, so a mid-drain cancellation stops
        // between iterations rather than waiting for one more full page.
        .task {
            if let uid = auth.currentUser?.id { await feed.loadBlocked(userId: uid) }
            guard !Task.isCancelled else { return }
            await vm.loadRoll(photoService: photoService, rollId: roll.id, blockedIds: feed.blockedIds)
            guard !Task.isCancelled else { return }
            // A roll's photo set is small (a friend group's shots), not the endless, ever-
            // growing personal Darkroom feed, where lazy, scroll-triggered pagination
            // genuinely protects performance, so it's safe to finish paging eagerly here
            // regardless of develop state. Without this, EVERY roll-count label read
            // PhotoService's first-30-photo page instead of the true total: the developing
            // banner's "N shots waiting" (the single most commonly seen roll screen, since a
            // roll spends most of its life developing), "Play through the roll · N", the
            // carousel, the reveal, and the develop-reminder notification's own shot count
            // below all draw from `vm.photos` / `vm.developingPhotos` / `vm.developedPhotos`.
            // If this roll is about to play its reveal, start pulling the first print NOW,
            // in parallel with the paging below rather than after it. The reveal waits for
            // that image before it starts (otherwise the develop animation plays over an
            // empty frame), so every second of the drain that isn't also spent downloading
            // is a second the user spends looking at a spinner.
            if roll.isDeveloped, !UserDefaults.standard.bool(forKey: revealSeenKey) {
                warmFirstRevealPrint()
            }

            let exitedBecauseExhausted = await drainRollPagination()
            guard !Task.isCancelled else { return }
            // Only ever flips true when the server genuinely said there was nothing left. A
            // starved give-up leaves it false, silently: a later grid-scroll `loadMoreRoll`
            // trigger (`photoGrid`'s own `.task`) or simply reopening this roll can still finish
            // the drain and set it then. See `rollDrainCompletedFully`'s own doc for the bug this
            // replaces: setting it on a starved break, not just an exhausted one, undercounted
            // every label gated on it.
            if rollDrainCompletedFully(exitedBecauseExhausted: exitedBecauseExhausted) {
                rollFullyPaged = true
            }
            // Only loadRoll batches signed URLs; loadMoreRoll doesn't, so every photo past
            // the first page used to mint its own URL round-trip as it scrolled into view.
            // One batched call for the whole (now fully paged, or as far as the drain got)
            // roll instead, then warm the thumbnails those URLs point at.
            await vm.prefetchURLs(photoService: photoService)
            guard !Task.isCancelled else { return }
            warmGridThumbnails()
            // The reveal, as an event: play everyone's shots once, the first time the
            // roll is opened after it has developed.
            if roll.isDeveloped, !vm.developedPhotos.isEmpty,
               !UserDefaults.standard.bool(forKey: revealSeenKey) {
                UserDefaults.standard.set(true, forKey: revealSeenKey)
                showReveal = true
            }
            // Ensure EVERY member gets a develop reminder, even those who didn't shoot.
            // The reveal is fixed at the roll's creation, so this works with zero photos too.
            if notificationsEnabled, !roll.isDeveloped {
                let myCount = vm.photos.filter { $0.userId == auth.currentUser?.id }.count
                await notifications.requestAuthorizationIfNeeded()
                notifications.scheduleRollDevelopNotification(
                    rollId: roll.id, rollName: displayName.isEmpty ? roll.name : displayName,
                    developsAt: roll.revealAt, photoCount: myCount
                )
            }
            // Keeps the countdown Live Activity going for anyone who opens the roll while it's
            // still developing, not just whoever created it, since sync() starts one fresh if
            // nothing's running yet. Ends it once developed; there's no push-driven lifecycle,
            // so this only fires the next time the roll is opened after reveal, not the instant
            // it happens.
            if roll.isDeveloped {
                RollLiveActivity.end(rollId: roll.id)
            } else {
                RollLiveActivity.sync(rollId: roll.id, rollName: displayName.isEmpty ? roll.name : displayName,
                                      revealAt: roll.revealAt, shotCount: vm.developingPhotos.count,
                                      developFrom: roll.createdAt)
            }
        }
        .task {
            if let members = try? await rollService.fetchMembers(for: roll.id) {
                memberNames = Dictionary(members.map { ($0.id, $0.username ?? "unknown") },
                                         uniquingKeysWith: { first, _ in first })
            }
        }
        .task {
            if let uid = auth.currentUser?.id {
                isMuted = await photoService.fetchMutedRolls(userId: uid).contains(roll.id)
            }
        }
        .fullScreenCover(item: $selectedPhoto) { photo in
            PhotoPagerView(
                photos: vm.developedPhotos,
                startIndex: vm.developedPhotos.firstIndex(where: { $0.id == photo.id }) ?? 0,
                signedURLs: vm.signedURLCache,
                showsReactions: true,
                showsComments: true,
                showsAttribution: true,
                memberNames: memberNames,
                // Every photo here belongs to this roll, so the delete-confirmation name is
                // always this roll's, regardless of the (all-identical) rollId.
                rollName: { _ in displayName.isEmpty ? roll.name : displayName },
                onDelete: { Task { await vm.loadRoll(photoService: photoService, rollId: roll.id, blockedIds: feed.blockedIds) } }
            )
            .navigationTransition(.zoom(sourceID: photo.id, in: photoNS))
        }
        .fullScreenCover(isPresented: $showCarousel) {
            RollCarouselView(photos: chronologicalDeveloped, memberNames: memberNames)
        }
        .fullScreenCover(isPresented: $showReveal) {
            RollRevealView(rollId: roll.id, rollName: displayName.isEmpty ? roll.name : displayName,
                           photos: chronologicalDeveloped, memberNames: memberNames)
        }
        .onChange(of: showReveal) { wasShowing, isShowing in
            // Finishing a reveal is one of the two moments a badge most plausibly just became
            // true (full_house, chipped_in, joined_in, roll_maker, darkroom all key off roll or
            // photo activity around exactly this roll). Fire-and-forget: worst case is the tab
            // dot catching up a moment later, never a blocking spinner on the roll screen.
            if wasShowing, !isShowing { Task { await feed.refreshOwnBadges() } }
        }
        .sheet(isPresented: $showMembers) {
            RollMembersView(roll: roll)
        }
        .sheet(item: $shareItem) { SharePreviewSheet(photo: $0.image) }
        .sheet(isPresented: $showShareAll) {
            ActivityView(items: shareImages)
        }
        .alert("Save all", isPresented: Binding(get: { saveAllError != nil },
                                                set: { if !$0 { saveAllError = nil } })) {
            Button("OK", role: .cancel) {
                if shareAfterAlert {
                    shareAfterAlert = false
                    showShareAll = true
                }
            }
        } message: {
            Text(saveAllError ?? "")
        }
        .sheet(isPresented: $showInviteShare) {
            ActivityView(items: [AppInfo.rollInviteMessage(rollName: displayName.isEmpty ? roll.name : displayName,
                                                           code: roll.inviteCode)],
                        onComplete: { Activation.log(.inviteSent) })
        }
        // Consequence sheets, not system dialogs (confirmations redesign rule 2): both of
        // these touch everyone in the roll, so they name it, count the people, and lead with
        // what survives. The copy lives in `RollConsequence`, shared with every other screen
        // that asks these questions, so the answers can never drift apart again.
        .sheet(isPresented: $showDeleteRoll) {
            ConsequenceSheet(consequence: .deleteRoll(
                name: displayName.isEmpty ? roll.name : displayName,
                people: memberNames.isEmpty ? nil : memberNames.count)) {
                notifications.cancelRollDevelopNotification(rollId: roll.id)
                Task {
                    try? await rollService.deleteRoll(rollId: roll.id)
                    dismiss()
                }
            }
        }
        .sheet(isPresented: $showLeaveRoll) {
            ConsequenceSheet(consequence: .leave(
                name: displayName.isEmpty ? roll.name : displayName,
                myShots: myShotCount)) {
                guard let uid = auth.currentUser?.id else { return }
                Task {
                    do {
                        try await rollService.leaveRoll(rollId: roll.id, userId: uid)
                        // Only cancel the develop notification and dismiss once the server
                        // confirms the leave; a failed leave must not act as though it happened.
                        notifications.cancelRollDevelopNotification(rollId: roll.id)
                        dismiss()
                    } catch {
                        Haptics.error()
                        showToast("Couldn't leave the roll. Check your connection and try again.", isError: true)
                    }
                }
            }
        }
        .alert("Rename roll", isPresented: $showRename) {
            TextField("Roll name", text: $renameDraft)
            Button("Save") {
                let name = renameDraft.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                displayName = name
                Task {
                    do {
                        try await rollService.renameRoll(rollId: roll.id, name: name)
                    } catch {
                        // The rename never landed; restore the input so it stays retryable
                        // instead of showing a name the server never accepted.
                        displayName = roll.name
                        Haptics.error()
                        showToast("Couldn't rename the roll. Check your connection and try again.", isError: true)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Replays the reveal for this roll.
    ///
    /// Clears the seen flag as well as presenting, so the roll is left in the same state a
    /// first-time viewer would leave it in: watched. Without the clear, a replay would present
    /// once and then the flag would still read "seen", which is the same thing, but leaving a
    /// stale flag around invites the next reader to wonder which one is authoritative.
    private func replayReveal() {
        UserDefaults.standard.set(true, forKey: revealSeenKey)
        showReveal = true
    }

    private func saveAll() {
        saveAllError = nil
        shareAfterAlert = false
        guard !savingAll else { return }
        savingAll = true
        Task {
            // Streamed to disk one at a time. Holding a 75-shot roll in memory as UIImages was a
            // jetsam kill waiting for someone with a big roll to tap this. See PhotoExport.
            // Its own directory: this Task outlives the view, so a second export started from
            // another roll must not be able to touch these files. See PhotoExport.
            let exportDir = PhotoExport.begin()
            let deck = vm.developedPhotos
            // The 1400px rendition, not the 2048px original.
            //
            // These two Save all buttons disagreed: the reveal's saved `viewPath` and this one
            // saved `storagePath`, so the same roll came out at three times the size and quality
            // depending on which screen you tapped, and nothing said so. Matching them on the
            // smaller rendition is the deliberate choice: a 75-shot roll costs about 28 MB of
            // egress instead of 94 MB, on the single most expensive action in the app, while the
            // free tier is the only tier. Saving the original becomes the Pro version of this.
            //
            // Single-photo share still sends the full image (see `share(_:)`), because one
            // photograph at 1.25 MB is not what makes this expensive.
            let signed = await photoService.signedURLs(for: deck.map(\.viewPath))
            var images: [URL] = []
            for (i, photo) in deck.enumerated() {
                guard let url = signed[photo.viewPath] else { continue }
                if let file = await PhotoExport.download(url, into: exportDir, index: i, total: deck.count) {
                    images.append(file)
                }
            }
            shareImages = images
            savingAll = false
            if images.isEmpty {
                // Every fetch failed, so no share sheet is coming. Silence here looks exactly
                // like the menu item doing nothing at all.
                Haptics.error()
                saveAllError = "Couldn't load the photos. Check your connection and try again."
            } else {
                if images.count < vm.developedPhotos.count {
                    // A partial result still reaches the sheet, because some photos IS better
                    // than none, but claiming "all" when it was 4 of 9 would be a lie the person
                    // only discovers later, in their camera roll, with no way to tell which four.
                    saveAllError = "Only \(images.count) of \(vm.developedPhotos.count) photos could be loaded. Saving those now."
                    shareAfterAlert = true
                } else {
                    showShareAll = true
                }
            }
        }
    }

    /// Long-press actions on a roll photo. Setting the cover used to be a bare long-press with
    /// nothing on screen announcing it existed, so only whoever wrote it knew it was there; it's
    /// a named menu item now, next to the actions that previously meant opening the shot first.
    @ViewBuilder
    private func photoMenu(_ photo: Photo) -> some View {
        if photo.isReady {
            if isCreator {
                Button { setCover(photo) } label: { Label("Use as roll cover", systemImage: "rectangle.on.rectangle") }
            }
            Button { share(photo) } label: { Label("Share", systemImage: "square.and.arrow.up") }
        } else {
            // Nothing to act on until the roll develops, but an empty menu would just flash a
            // blank card, so say why instead.
            Text("Develops with the roll")
        }
    }

    /// Drains this roll's remaining pages until the server reports nothing left (`hasMore ==
    /// false`), or until `rollDrainStep` gives up after too many consecutive iterations that made
    /// no progress while `hasMore` stayed true (most often the shared `PhotoService` mid-fetch
    /// for another screen, including this same screen's own grid-scroll trigger). Returns
    /// whether the loop exited because pagination genuinely finished; callers must gate
    /// `rollFullyPaged` on exactly that (`rollDrainCompletedFully`), never on the loop merely
    /// returning.
    ///
    /// Every iteration below either makes progress (the loaded count grew), genuinely suspends
    /// (`Task.sleep`), or exits: a starved iteration used to `break` immediately and still let
    /// the caller flag the roll complete, which is what silently undercounted every label gated
    /// on `rollFullyPaged` (both audits, 2026-08-25/26). Yielding and retrying with a short
    /// backoff instead gives the starving fetch room to finish while keeping every path through
    /// the loop a genuine suspension point, so it stays spin-proof the same way the Darkroom's
    /// own month-jump loop had to be fixed to be (see that incident's doc, referenced in the
    /// comment this replaced): no path here can return synchronously in a tight cycle.
    private func drainRollPagination() async -> Bool {
        var starvedRetries = 0
        while true {
            if Task.isCancelled { return false }
            let before = photoService.loadedPhotos.count
            await vm.loadMoreRoll(photoService: photoService, rollId: roll.id, blockedIds: feed.blockedIds)
            if Task.isCancelled { return false }
            let after = photoService.loadedPhotos.count
            switch rollDrainStep(loadedBefore: before, loadedAfter: after,
                                  hasMore: photoService.hasMore, starvedRetries: starvedRetries) {
            case .progressed:
                starvedRetries = 0
            case .retry(let next):
                starvedRetries = next
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(200))
            case .exhausted:
                return true
            case .gaveUp:
                return false
            }
        }
    }

    /// Pulls the roll's earliest developed print into cache, at the size and cache key the reveal
    /// will ask for, so the slideshow can start on an image that's already there.
    ///
    /// Fire-and-forget: if it doesn't finish in time the reveal waits for it itself, exactly as
    /// before. This only removes dead time, it isn't load-bearing.
    private func warmFirstRevealPrint() {
        guard let first = vm.chronologicalDeveloped.first else { return }
        Task {
            guard let url = try? await photoService.signedURL(for: first.viewPath) else { return }
            // cacheKey: first.viewPath and maxPixel 1400, matching exactly what RollRevealView's
            // full-size layer keys itself under; a different key or size would warm an entry the
            // reveal never looks for and it would download the bytes again itself.
            _ = await ImageLoader.fetch(url: url, maxPixel: 1400, scale: displayScale, cacheKey: first.viewPath)
        }
    }

    /// Warms the grid's thumbnails so cells don't pop in on a fast scroll, mirroring what the
    /// Darkroom grid already does at the same size.
    ///
    /// Deliberately the ~30KB `displayPath` thumbnail at 400pt, NOT the full 2048px image: a
    /// 75-shot roll costs roughly 2MB warmed this way, and most of it isn't even extra egress,
    /// since anything scrolled past would be downloaded anyway, just later and with a visible
    /// gap. The carousel is intentionally left alone for the same reason inverted, it shows full
    /// images, so warming a whole roll there would be tens of megabytes; its TabView already
    /// keeps the neighbouring pages loaded.
    ///
    /// Developed shots only. A developing one has no viewable image and no resolved URL.
    private func warmGridThumbnails() {
        let items = vm.developedPhotos.compactMap { photo -> (url: URL, cacheKey: String?)? in
            vm.signedURLCache[photo.id].map { ($0, photo.displayPath) }
        }
        guard !items.isEmpty else { return }
        ImageLoader.prefetch(items, maxPixel: 400, scale: displayScale)
    }

    private func setCover(_ photo: Photo) {
        Haptics.select()
        Task { await rollService.setRollCover(rollId: roll.id, path: photo.storagePath) }
        showToast("Roll cover updated")
    }

    /// The file's one top-slot toast. Errors sit slightly longer, they're longer sentences and
    /// the moment carries more consequence than a confirmation. A newer toast cancels the older
    /// one's pending dismiss, so a confirmation's 1.6s timer can never cut short an error that
    /// replaced it mid-flight.
    private func showToast(_ message: String, isError: Bool = false) {
        toastIsError = isError
        withAnimation { toastMessage = message }
        toastDismiss?.cancel()
        toastDismiss = Task {
            try? await Task.sleep(for: .seconds(isError ? 2.4 : 1.6))
            guard !Task.isCancelled else { return }
            withAnimation { toastMessage = nil }
        }
    }

    /// Pulls the full-res file down and hands it to the share composer.
    private func share(_ photo: Photo) {
        Haptics.tap()
        Task {
            guard let url = try? await photoService.signedURL(for: photo.storagePath),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else {
                Haptics.error()
                return
            }
            shareItem = ShareImage(image: image)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .flimFont(11, weight: .medium, relativeTo: .caption).tracking(2)
                .foregroundStyle(Color(white: 0.4))
            Spacer()
        }
        .padding(.horizontal, 6).padding(.top, 18).padding(.bottom, 8)
    }

    private func photoGrid(_ list: [Photo], triggersLoadMore: Bool) -> some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(list) { photo in
                // The reveal banner above already shows "Develops in Xh Xm" for the whole roll
                // (every shot in it develops together), so developing tiles here don't repeat it.
                PhotoGridCell(photo: photo, signedURL: vm.signedURLCache[photo.id], showsCountdown: false)
                    .matchedTransitionSource(id: photo.id, in: photoNS)
                    .onTapGesture {
                        // Can't peek before it develops, only open ready shots.
                        guard photo.isReady else { return }
                        selectedPhoto = photo
                    }
                    .contextMenu { photoMenu(photo) }
                    .task {
                        if photo.isReady, vm.signedURLCache[photo.id] == nil {
                            _ = await vm.signedURL(for: photo, photoService: photoService)
                        }
                        if triggersLoadMore, photo.id == list.last?.id {
                            await vm.loadMoreRoll(photoService: photoService, rollId: roll.id, blockedIds: feed.blockedIds)
                        }
                    }
            }
        }
        .padding(.horizontal, 2)
    }

    private func revealBanner(revealAt: Date, shots: Int?, people: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let remaining = max(0, Int(revealAt.timeIntervalSince(timeline.date)))
                Label("Develops in \(Self.countdown(remaining))", systemImage: "hourglass")
                    .flimFont(14, weight: .semibold)
                    .foregroundStyle(accent)
            }
            Group {
                if let shots {
                    Text(shots == 0
                         ? "No shots yet. Be the first to add one"
                         : "\(shots) shot\(shots == 1 ? "" : "s") waiting" + (people > 1 ? " from \(people) people" : ""))
                } else {
                    Text("Counting shots…")
                }
            }
            .flimFont(12, relativeTo: .caption)
            .foregroundStyle(FlimTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16).padding(.bottom, 4)
    }

    private static func countdown(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }
}
