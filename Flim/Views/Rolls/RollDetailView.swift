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

/// Merges a roll's authoritative, unpaginated snapshot (`PhotoService.fetchRollPhotosSnapshot`,
/// one uncapped query against every current row) into whatever `fetchRollPhotos`'s own
/// page-at-a-time drain has loaded so far (`paged`), so the photo VIEWER a grid tap opens is never
/// capped at a single page while the drain is still running, or gave up (`RollDrainStep.gaveUp`)
/// and has nothing left to re-trigger it: a roll bigger than one page (100) used to hand
/// `PhotoPagerView` whatever `vm.developedPhotos` held at the exact moment of the tap, which for
/// the very first grid interaction is reliably just page one.
///
/// `paged`'s own order is kept for every id both sides still agree exists, so a grid or an
/// already-open pager never re-sorts under a scroll or a swipe; anything the snapshot confirms
/// that paging hasn't reached yet is appended, newest-`developsAt`-first to match `fetchRollPhotos`'s
/// own page ordering (a snapshot query carries no `ORDER BY`, so its raw order is whatever Postgres
/// happened to return); anything `paged` has that the snapshot no longer confirms (deleted or
/// hidden since the snapshot's own last fetch) is dropped, so a stale top-up can never resurrect a
/// deleted photo through the pager, only ever narrow toward what the snapshot currently confirms.
func mergePhotoSnapshot(paged: [Photo], snapshot: [Photo]) -> [Photo] {
    guard !snapshot.isEmpty else { return paged }
    let snapshotById = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, $0) })
    let kept = paged.compactMap { snapshotById[$0.id] }
    let keptIds = Set(kept.map(\.id))
    let extra = snapshot
        .filter { !keptIds.contains($0.id) }
        .sorted { $0.developsAt > $1.developsAt }
    return kept + extra
}

/// A roll-photo push's intent, carried alongside `MainTabView.route(to:)`'s own `rollsPath.append`
/// so `RollDetailView` can open a specific photo (and its comment thread) once it's safe to.
/// Id-keyed rather than positional: `RollDetailView` matches by `rollId` before consuming it, so a
/// second push landing while the same roll is already open still finds this instance, matching
/// the `openPhotoId` pattern the Darkroom uses for a widget's frame tap.
struct RollPhotoIntent: Equatable {
    let rollId: UUID
    let photoId: UUID
    let comments: Bool
}

/// Whether `photoId` has arrived in the roll's merged photo list yet. Pure so the "keep polling or
/// give up" boundary a pending push-photo intent waits on is pinned without a live `PhotoService`,
/// roll, or timer: the photo can land on the eager, unpaginated snapshot (`rollSnapshot`) rather
/// than the grid's own first page, and that snapshot is a fire-and-forget fetch, so the photo is
/// not guaranteed to be present the instant the roll's `.task` pipeline finishes loading.
func photoArrived(_ photoId: UUID, in photos: [Photo]) -> Bool {
    photos.contains { $0.id == photoId }
}

struct RollDetailView: View {
    @Environment(\.flimAccent) private var accent
    let roll: Roll
    /// A pending roll-photo push intent, owned by `MainTabView` and shared down through
    /// `RollsView`. `nil` for every ordinary open (a grid tap, `-openRollId`); this view only ever
    /// consumes an entry whose `rollId` matches its own `roll.id`, and nils it the instant it does,
    /// so a later push for some OTHER roll finds it still there for that roll's own instance.
    var pendingPhotoIntent: Binding<RollPhotoIntent?> = .constant(nil)
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
    /// The grid long-press delete flow: the photo held, and the consequence sheet for it.
    @State private var gridDeletePhoto: Photo?
    @State private var gridDeleteConsequence: RollConsequence?
    @State private var showDeleteRoll = false
    @State private var savingAll = false
    @State private var saveAllError: String?
    /// File URLs, not UIImages: see PhotoExport for why the roll is not held in memory.
    @State private var shareImages: [URL] = []
    @State private var showShareAll = false
    @State private var showInviteShare = false
    /// The file's one top-slot toast, reused for every transient status line (cover updated,
    /// rename/leave failures) so there is a single presentation and timing to reason about
    /// instead of one boolean per message.
    @State private var toastMessage: String?
    @State private var toastDismiss: Task<Void, Never>?
    @State private var toastIsError = false
    @State private var showLeaveRoll = false
    @State private var shareItem: ShareImage?
    @State private var isMuted = false
    @State private var showReveal = false
    /// Flips true once a developed roll's pagination has been fully drained (see `onAppear`).
    /// Gates the "Play through the roll" button so it appears once, already showing the true
    /// count, without this, the button popped in after page 1 (30) and its own count label
    /// visibly ticked upward (30 → 60 → 75) as each further page streamed in behind it.
    @State private var rollFullyPaged = false
    /// Set from `pendingPhotoIntent` once it matches this roll; consumed (nil'd) only after the
    /// pager actually opens (or gives up). Separate from the binding itself so this survives the
    /// binding being nil'd by the moment `adoptPendingPhotoIntent` reads it.
    @State private var awaitingPhotoId: UUID?
    @State private var awaitingPhotoComments = false
    /// Whether the NEXT `selectedPhoto` presentation should open the comment sheet on arrival.
    /// Reset right after `PhotoPagerView` reads it, so an ordinary grid tap opened after a pending
    /// photo push never inherits a stale "open comments" flag.
    @State private var pagerOpenComments = false

    private var revealSeenKey: String { "rollRevealSeen.\(roll.id.uuidString)" }
    /// One-shot, unpaginated top-up for the roll viewer: everything `fetchRollPhotosSnapshot`
    /// currently confirms for this roll, refreshed alongside every full reload (`reloadRoll`).
    /// `nil` until the first fetch lands, in which case `pagerPhotos` just falls back to whatever
    /// the grid itself has paged in.
    @State private var rollSnapshot: [Photo]?

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

    /// What the full-screen viewer is actually fed: `vm.developedPhotos` (the grid's own paged
    /// list, unchanged, still oldest-page-first-loaded and whatever order the grid itself shows)
    /// topped up with anything `rollSnapshot` confirms exists beyond that page. See
    /// `mergePhotoSnapshot`'s own doc for why the grid stays exactly as it was rather than being
    /// switched onto the snapshot too: this only fixes what the VIEWER opens with.
    private var pagerPhotos: [Photo] {
        guard let rollSnapshot else { return vm.developedPhotos }
        return mergePhotoSnapshot(paged: vm.developedPhotos, snapshot: rollSnapshot)
    }

    /// `pagerPhotos` in the order the grid shows them, oldest shot first, so the viewer's roll
    /// rack and the grid are the same strip of film. Ties on `takenAt` break on id so the order
    /// is total and stable across re-evaluations.
    private var pagerPhotosChronological: [Photo] {
        pagerPhotos.sorted { a, b in
            a.takenAt != b.takenAt ? a.takenAt < b.takenAt : a.id.uuidString < b.id.uuidString
        }
    }


    var body: some View {
        ZStack {
            FlimTheme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                FlimNavTitle(roll.name)

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

                // The reveal, again. This used to open the carousel, a third near-identical
                // walk through the same roll, while the actual reveal hid in the overflow menu:
                // the ceremony the roll is built around was the harder of the two to reach.
                // One primary control, and it plays the thing people came back for.
                if isFullyDeveloped {
                    Button {
                        Haptics.tap()
                        replayReveal()
                    } label: {
                        Label("Play reveal again", systemImage: "play.circle.fill")
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
                            await reloadRoll()
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
                                    // Oldest to newest: a roll reads like a strip of film, not the
                                    // server's `id DESC` append order (every shot in a roll shares
                                    // one `develops_at`, so that order is random ids). The load-more
                                    // sentinel still anchors to the SERVER's tail, which is the one
                                    // cell guaranteed to be freshly mounted on every new page; the
                                    // chronological tail can be a cell that mounted pages ago and
                                    // would never re-arm.
                                    photoGrid(chronologicalDeveloped, triggersLoadMore: true,
                                              loadMoreAnchorId: vm.developedPhotos.last?.id)
                                }
                            }
                        }
                        .refreshable {
                            await reloadRoll()
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
                // Invites end when the roll develops (owner decision, 2026-08-26): a
                // developed roll is a finished thing to rewatch, not a group still forming,
                // so the share-invite affordance disappears with the develop. The members
                // sheet's code banner follows the same rule.
                if !roll.isDeveloped {
                    Button {
                        Haptics.tap()
                        showInviteShare = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(accent)
                    }
                    .accessibilityLabel("Share invite")
                }

                Menu {
                    // The reveal is the best thing this app does and it was strictly one-shot:
                    // seen once, gone forever, because the flag that stops it replaying on every
                    // visit never clears. So the moment a roll exists to be remembered by could
                    // never be watched again, which is backwards for something built to be
                    // rewatched with the people who were there.

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
        .onAppear { adoptPendingPhotoIntent() }
        // A second push for THIS SAME roll while it's already open (no reappear to catch it):
        // `MainTabView` still appends a fresh path entry, but the intent itself lands here via
        // the shared binding, and by now the main `.task` pipeline below has long since finished,
        // so this has to trigger the open attempt itself rather than waiting for that task to.
        .onChange(of: pendingPhotoIntent.wrappedValue) { _, _ in
            adoptPendingPhotoIntent()
            if awaitingPhotoId != nil {
                Task { await openAwaitingPhotoIfReady() }
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
            #if DEBUG
            // `-tapFirstDevelopedPhoto`: opens the pager on the first developed photo the moment
            // page one lands, before `refreshRollSnapshot` below (let alone the drain further
            // down) has landed. Simulates the real report exactly, a tap before pagination
            // finishes, for screenshotting and reproduction without simulator tap automation.
            if ProcessInfo.processInfo.arguments.contains("-tapFirstDevelopedPhoto"),
               let first = vm.developedPhotos.first {
                selectedPhoto = first
            }
            #endif
            // Fire-and-forget: the pager (`pagerPhotos`) picks this up the moment it lands,
            // whether that's before or after the tap above, via the same growing-array remap
            // `PhotoPagerView.onChange(of: photos.map(\.id))` already does. Independent of the
            // drain below, so a roll big enough to need a second page is never capped at page one
            // in the viewer even if that drain starves out (`RollDrainStep.gaveUp`).
            refreshRollSnapshot()
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
            //
            // Presenting no longer writes the seen flag. Under the old timed slideshow the
            // deck always finished on its own, so open and watched were the same event; the
            // self-paced reveal (Rolls redesign) lets someone swipe away at frame 2 of 47,
            // and writing on open would burn their only ceremony AND fire the camera-roll
            // auto-save gate for a reveal nobody watched. `RollRevealView` reports genuine
            // completion instead; see its `onCompleted`.
            if roll.isDeveloped, !vm.developedPhotos.isEmpty,
               !UserDefaults.standard.bool(forKey: revealSeenKey) {
                showReveal = true
            }
            // A pending push-photo intent waits for exactly this point: the reveal decision just
            // above has already been made, so if `showReveal` just became true, this call is a
            // no-op and `onChange(of: showReveal)` picks it back up once the reveal finishes
            // instead. If the reveal was already seen, this opens the photo right here, polling
            // briefly for `rollSnapshot` if it hasn't landed yet.
            if awaitingPhotoId != nil {
                await openAwaitingPhotoIfReady()
            }
            // Ensure EVERY member gets a develop reminder, even those who didn't shoot, as a
            // fallback for a phone push can't reach (see `scheduleRollDevelopNotification`). The
            // reveal is fixed at roll creation, so this works with zero photos too.
            if notificationsEnabled, !roll.isDeveloped, let myId = auth.currentUser?.id {
                let myCount = vm.photos.filter { $0.userId == myId }.count
                await notifications.requestAuthorizationIfNeeded()
                notifications.scheduleRollDevelopNotification(
                    rollId: roll.id, rollName: roll.name,
                    developsAt: roll.revealAt, photoCount: myCount, userId: myId
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
                RollLiveActivity.sync(rollId: roll.id, rollName: roll.name,
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
            // Read once and reset immediately: this closure runs again on every presentation, and
            // without the reset a photo push's "open comments" would leak into the very next
            // ordinary grid tap on this same roll.
            let openComments = pagerOpenComments
            PhotoPagerView(
                photos: pagerPhotosChronological,
                startIndex: pagerPhotosChronological.firstIndex(where: { $0.id == photo.id }) ?? 0,
                signedURLs: vm.signedURLCache,
                showsReactions: true,
                showsComments: true,
                showsAttribution: true,
                // The reveal's shape: film strip, credit, reactions, thread. The two screens
                // show the same roll a few taps apart and had no reason to look unrelated.
                showsRollRack: true,
                memberNames: memberNames,
                // Every photo here belongs to this roll, so the delete-confirmation name is
                // always this roll's, regardless of the (all-identical) rollId.
                rollName: { _ in roll.name },
                onDelete: { Task { await reloadRoll() } },
                openCommentsOnAppear: openComments
            )
            .navigationTransition(.zoom(sourceID: photo.id, in: photoNS))
            .onAppear { pagerOpenComments = false }
        }
        .fullScreenCover(isPresented: $showReveal) {
            RollRevealView(rollId: roll.id, rollName: roll.name,
                           photos: chronologicalDeveloped, memberNames: memberNames,
                           onCompleted: { UserDefaults.standard.set(true, forKey: revealSeenKey) })
        }
        .onChange(of: showReveal) { wasShowing, isShowing in
            // Finishing a reveal is one of the two moments a badge most plausibly just became
            // true (full_house, chipped_in, joined_in, roll_maker, darkroom all key off roll or
            // photo activity around exactly this roll). Fire-and-forget: worst case is the tab
            // dot catching up a moment later, never a blocking spinner on the roll screen.
            if wasShowing, !isShowing {
                Task { await feed.refreshOwnBadges() }
                // The reveal just finished (watched or swiped away, either way it played, never
                // skipped): a photo a push was waiting on can open now.
                if awaitingPhotoId != nil { Task { await openAwaitingPhotoIfReady() } }
            }
        }
        .sheet(isPresented: $showMembers) {
            RollMembersView(roll: roll)
        }
        .sheet(item: $shareItem) { SharePreviewSheet(photo: $0.image, caption: $0.caption) }
        .sheet(isPresented: $showShareAll) {
            ActivityView(items: shareImages)
        }
        // Rule 4 (confirmations redesign): a failed Save all lands where the action was, with
        // retry in place, never as a modal whose only button admits it. Partial results skip
        // this entirely: they proceed straight to the share sheet with a toast saying how
        // many made it, see `saveAll()`.
        .overlay(alignment: .bottom) {
            if let saveAllError {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.red.opacity(0.9))
                    Text(saveAllError)
                        .flimFont(13, weight: .medium)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Spacer(minLength: 6)
                    Button("Retry") { saveAll() }
                        .flimFont(13, weight: .semibold)
                        .foregroundStyle(accent)
                    Button {
                        withAnimation { self.saveAllError = nil }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(FlimTheme.textTertiary)
                    }
                    .accessibilityLabel("Dismiss")
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.red.opacity(0.3), lineWidth: 1))
                .padding(.horizontal, 16).padding(.bottom, 10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $showInviteShare) {
            ActivityView(items: [AppInfo.rollInviteMessage(rollName: roll.name,
                                                           code: roll.inviteCode)],
                        onComplete: { Activation.log(.inviteSent) })
        }
        // Consequence sheets, not system dialogs (confirmations redesign rule 2): both of
        // these touch everyone in the roll, so they name it, count the people, and lead with
        // what survives. The copy lives in `RollConsequence`, shared with every other screen
        // that asks these questions, so the answers can never drift apart again.
        .sheet(isPresented: $showDeleteRoll) {
            ConsequenceSheet(consequence: .deleteRoll(
                name: roll.name,
                people: rollService.memberCounts[roll.id]
                    ?? (memberNames.isEmpty ? nil : memberNames.count))) {
                notifications.cancelRollDevelopNotification(rollId: roll.id)
                Task {
                    try? await rollService.deleteRoll(rollId: roll.id)
                    dismiss()
                }
            }
        }
        .sheet(item: $gridDeleteConsequence) { consequence in
            ConsequenceSheet(consequence: consequence) { performGridDelete() }
        }
        .sheet(isPresented: $showLeaveRoll) {
            ConsequenceSheet(consequence: .leave(
                name: roll.name,
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
    }

    /// Replays the reveal for this roll. The flag is already set (a replay is only offered on
    /// a roll whose reveal has been watched), and `RollRevealView` re-sets it on completion,
    /// so this only has to present.
    private func replayReveal() {
        showReveal = true
    }

    /// Pulls a matching pending push-photo intent out of the shared binding and into local state,
    /// exactly once. Called on appear, and again on `onChange` for a second push landing while
    /// this roll is already open (no reappear to catch that one). A mismatched or absent intent is
    /// left untouched, for whichever OTHER roll's `RollDetailView` it actually belongs to.
    private func adoptPendingPhotoIntent() {
        guard let intent = pendingPhotoIntent.wrappedValue, intent.rollId == roll.id else { return }
        pendingPhotoIntent.wrappedValue = nil
        awaitingPhotoId = intent.photoId
        awaitingPhotoComments = intent.comments
    }

    /// Opens `awaitingPhotoId` in the pager once it's safe to, or gives up silently.
    ///
    /// Never while the reveal is up: the reveal is the roll's one-shot ceremony, and a push must
    /// not skip it. `onChange(of: showReveal)` calls this again once it finishes, so the photo
    /// still opens right after, not never.
    ///
    /// The photo may land on `rollSnapshot`'s fire-and-forget fetch rather than the grid's own
    /// first page, so this polls briefly for it rather than checking once. Bounded the same way
    /// `drainRollPagination`'s own starved-retry budget is (25 x 200ms, ~5s): past that, a
    /// deleted/hidden/blocked photo and a slow network are indistinguishable from here, and both
    /// get the same answer every other push destination gives when it can't find its target, land
    /// on a real, populated screen (the roll) rather than an error.
    private func openAwaitingPhotoIfReady() async {
        guard let photoId = awaitingPhotoId, !showReveal else { return }
        var found = photoArrived(photoId, in: pagerPhotos)
        var attempts = 0
        while !found, attempts < 25 {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            found = photoArrived(photoId, in: pagerPhotos)
            attempts += 1
        }
        let comments = awaitingPhotoComments
        awaitingPhotoId = nil
        awaitingPhotoComments = false
        guard found, let photo = pagerPhotos.first(where: { $0.id == photoId }) else { return }
        pagerOpenComments = comments
        selectedPhoto = photo
    }

    /// The one place that reloads this roll's photos: resets the grid's own pagination (page one)
    /// and then refreshes `rollSnapshot`. Every caller that used to call `vm.loadRoll` directly
    /// (pull to refresh, the error-state retry, and a pager delete) goes through this instead.
    ///
    /// The two have to move in this order, never the reverse: `vm.loadRoll` resets pagination to
    /// page one, and a `rollSnapshot` refreshed BEFORE that reset lands would be immediately
    /// stale, able to resurrect a since-deleted photo through `pagerPhotos`'s merge
    /// (`mergePhotoSnapshot` can only drop what it knows is gone; a stale snapshot doesn't know a
    /// photo missing from the fresh page one was deleted rather than simply not paged in yet).
    private func reloadRoll() async {
        await vm.loadRoll(photoService: photoService, rollId: roll.id, blockedIds: feed.blockedIds)
        refreshRollSnapshot()
    }

    /// Fire-and-forget top-up for `rollSnapshot` (mirrors `warmFirstRevealPrint`'s own shape):
    /// the pager only needs this to land EVENTUALLY, never has to block whatever triggered the
    /// reload, and must not depend on `drainRollPagination`'s own paginated cursor succeeding,
    /// since the whole point is a fetch that can complete on its own even when that one gives up.
    private func refreshRollSnapshot() {
        Task {
            guard let fetched = try? await photoService.fetchRollPhotosSnapshot(rollId: roll.id) else { return }
            rollSnapshot = feed.blockedIds.isEmpty ? fetched : fetched.filter { !feed.blockedIds.contains($0.userId) }
        }
    }

    private func saveAll() {
        saveAllError = nil
        guard !savingAll else { return }
        savingAll = true
        Task {
            // Streamed to disk one at a time. Holding a 75-shot roll in memory as UIImages was a
            // jetsam kill waiting for someone with a big roll to tap this. See PhotoExport.
            // Its own directory: this Task outlives the view, so a second export started from
            // another roll must not be able to touch these files. See PhotoExport.
            let exportDir = PhotoExport.begin()
            // Same order the reveal's own Save all exports in, oldest shot first, so the two
            // Save all buttons on one roll number their files the same way.
            let deck = chronologicalDeveloped
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
                // like the menu item doing nothing at all. Inline with Retry, never a modal.
                Haptics.error()
                withAnimation { saveAllError = "Couldn't load the photos. Check your connection." }
            } else {
                if images.count < vm.developedPhotos.count {
                    // A partial result still reaches the sheet, because some photos IS better
                    // than none, but claiming "all" when it was 4 of 9 would be a lie the person
                    // only discovers later, in their camera roll, with no way to tell which four.
                    // Said in a toast alongside the sheet now, not a modal in front of it.
                    showToast("Only \(images.count) of \(vm.developedPhotos.count) photos could be loaded. Saving those now.", isError: true)
                }
                showShareAll = true
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
            // Own shots only: the item simply doesn't exist on a friend's cell (a disabled
            // Delete on their photo would read as broken, not as theirs). Routes through the
            // same consequence sheet the pager uses; the grid must not be a quieter door to
            // the same shared delete.
            if photo.userId == auth.currentUser?.id {
                Button(role: .destructive) { requestGridDelete(photo) } label: {
                    Label("Delete photo", systemImage: "trash")
                }
            }
        } else {
            // Nothing to act on until the roll develops, but an empty menu would just flash a
            // blank card, so say why instead.
            Text("Develops with the roll")
        }
    }

    private func requestGridDelete(_ photo: Photo) {
        gridDeletePhoto = photo
        let mine = (auth.currentUser?.id).map { uid in
            (vm.developedPhotos + vm.developingPhotos)
                .filter { $0.userId == uid && $0.id != photo.id }.count
        }
        gridDeleteConsequence = .deleteShot(
            rollName: roll.name,
            people: rollService.memberCounts[roll.id],
            myOtherShots: mine)
    }

    private func performGridDelete() {
        guard let photo = gridDeletePhoto else { return }
        gridDeletePhoto = nil
        Task {
            // Same contract as the pager's delete: `deletePhoto` only reports success once
            // the photo is actually gone, and only then does the grid drop the cell.
            guard await photoService.deletePhoto(photo) else {
                Haptics.error()
                showToast("Couldn't delete that. Check your connection and try again.", isError: true)
                return
            }
            feed.dropPost(forDeletedPhotoId: photo.id)
            vm.photos.removeAll { $0.id == photo.id }
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
            shareItem = ShareImage(
                image: image,
                caption: BrandedExport.Caption(date: photo.takenAt))
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

    private func photoGrid(_ list: [Photo], triggersLoadMore: Bool, loadMoreAnchorId: UUID? = nil) -> some View {
        // A roll IS a strip of film, so its grid is laid out as one: rows of frames on a
        // perforated road, ending where the roll's own last frame does rather than ruling a line
        // out to the margin. Same atom the Darkroom's day racks draw.
        FilmStripGrid(items: list, gap: 2) { photo in
            Group {
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
                        if triggersLoadMore, photo.id == (loadMoreAnchorId ?? list.last?.id) {
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
