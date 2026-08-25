import SwiftUI
import UIKit

/// Builds the roll-delete confirmation message from each photo's already-resolved roll name
/// (`nil` for a personal, non-roll photo). A batch that resolves to exactly one shared roll
/// names it; anything else (multiple rolls, a roll mixed with personal shots, or no rolls at
/// all) falls back to generic wording.
func rollDeleteConfirmationMessage(forRollNames names: [String?]) -> String {
    let uniqueNames = Set(names.compactMap { $0 })
    if uniqueNames.count == 1, let name = uniqueNames.first {
        return "This shot is in the roll \"\(name)\". Deleting removes it for everyone."
    }
    return "This shot is in a shared roll. Deleting removes it for everyone."
}

struct DarkroomView: View {
    @Environment(\.flimAccent) private var accent
    var scrollToTop: Int = 0
    /// A counter the tab bumps to open the sort deck from outside — a widget tap, today. A signal
    /// rather than a Bool for the same reason `scrollToTop` is one: the deck can be asked for
    /// twice in a row, and an already-true Bool is not a second request.
    var openSortDeckSignal: Int = 0
    /// A frame a widget tap asked to open. A binding so it can be cleared once consumed, which is
    /// what stops the same frame reopening every time the Darkroom reappears.
    var openPhotoId: Binding<UUID?> = .constant(nil)
    @Environment(AuthService.self) private var auth
    @Environment(PhotoService.self) private var photoService
    @Environment(RollService.self) private var rolls
    @Environment(FeedService.self) private var feed
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Namespace private var photoNS
    @State private var vm = DarkroomViewModel()
    @State private var selectedPhoto: Photo?
    @State private var selectedURL: URL?
    @State private var isSelecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var pendingDelete: [Photo] = []
    @State private var showUndoToast = false
    @State private var undoTask: Task<Void, Never>?
    /// A failure that must not fail silently, e.g. "Set as profile photo" not sticking.
    @State private var errorToast: String?
    @AppStorage("lastRevealCheck") private var lastRevealCheck: Double = 0
    @State private var showReveal = false
    @State private var revealAnim = false
    @State private var revealCount = 0
    /// The unsorted photos themselves, not just a count: the sort row needs three of them for
    /// its preview thumbnails.
    @State private var unsortedPhotos: [Photo] = []
    /// Signed URLs for `unsortedPhotos`' preview thumbnails, resolved in one batched call
    /// alongside `reload()`, never per cell.
    @State private var unsortedURLCache: [UUID: URL] = [:]
    @State private var showSortDeck = false
    /// The month jump sheet's own flag, deliberately not shared with any other sheet on this
    /// screen (`showSortDeck`, the roll-delete confirm): two surfaces sharing one flag once broke
    /// each other when one dismissed and the other's `onDismiss` fired for it.
    @State private var showJumpSheet = false
    /// The band that was tapped to open `showJumpSheet`, so the sheet can mark that one cell and
    /// open on that year's tab. `nil` for any future entry point that isn't a band tap.
    @State private var jumpSheetOrigin: DarkroomYearMonth?
    /// `darkroom_month_counts`' rows, `nil` until `reload()`'s dedicated fetch resolves or the
    /// RPC isn't reachable yet (see `PhotoService.darkroomMonthCounts`'s own doc). Every reader
    /// treats `nil` as "no server counts yet", never as zero.
    @State private var monthCounts: [DarkroomMonthCount]?
    /// Set once the scroll view exists, so a month-jump can call `scrollTo` from outside the
    /// `ScrollViewReader` closure that owns it.
    @State private var scrollProxy: ScrollViewProxy?
    /// Guards `jumpToMonth`'s page-until-anchor loop so a second tap on an unloaded month can't
    /// start a second one racing the first.
    @State private var jumpPagingInFlight = false
    @State private var jumpPagingTask: Task<Void, Never>?
    @State private var showRollDeleteConfirm = false
    @State private var pendingRollDeleteBatch: [Photo] = []
    @State private var shareItem: ShareImage?
    /// The scroll content's measured width, so the contact sheet's strip capacity is derived
    /// from the real available width rather than a hard-coded frame count. 393 is the design's
    /// own reference width, a reasonable first-paint guess before the geometry read lands.
    @State private var scrollWidth: CGFloat = 393

    private var stripCapacity: Int {
        max(1, DarkroomDayUnit.stripCapacity(availableWidth: scrollWidth - 32))
    }

    /// One unit per night, newest first, this render's single source of truth for both the
    /// contact sheet and the pager's flattened order. Cheap to recompute per body evaluation:
    /// grouping a few hundred loaded photos is well under the cost of the images beside it.
    private var dayUnits: [DarkroomDayUnit] {
        DarkroomDayUnit.units(from: vm.photos)
    }

    private var monthGroups: [DarkroomMonthGroup] {
        DarkroomDayUnit.monthGroups(units: dayUnits)
    }

    private var lastUnitId: Date? { monthGroups.last?.units.last?.id }

    /// The flattened archive in render order, developing shots included in their true
    /// chronological place: what `PhotoPagerView`'s night-rack pages through, so swiping (or a
    /// rack tap) can land on a still-developing shot's develops-at state instead of skipping it.
    private var renderOrderPhotos: [Photo] {
        dayUnits.flatMap(\.photos)
    }

    private var sortPreviewPhotos: [Photo] {
        DarkroomDayUnit.pickPreview(from: unsortedPhotos)
    }

    /// Distinct nights among `unsortedPhotos`, for the sort banner's second line. See
    /// `DarkroomDayUnit.distinctNightCount`'s own doc.
    private var unsortedNightCount: Int {
        DarkroomDayUnit.distinctNightCount(in: unsortedPhotos)
    }

    /// Every month currently rendered on screen, for the jump sheet's pre-migration fallback
    /// (see `DarkroomJumpSheetLogic`'s own doc) and for `jumpToMonth`'s "already loaded" check.
    private var loadedMonthKeys: Set<DarkroomYearMonth> {
        Set(monthGroups.map { DarkroomYearMonth(date: $0.monthKey) })
    }

    /// This month band's server-counted total, `nil` while `darkroom_month_counts` hasn't
    /// answered (or the month isn't in its rows, which the RPC's own contract makes equivalent
    /// to "unknown" here, since a month with zero photos wouldn't be rendering a band at all).
    private func shotCount(for group: DarkroomMonthGroup) -> Int? {
        monthCounts?.photoCount(for: DarkroomYearMonth(date: group.monthKey))
    }

    // MARK: - Header

    /// The one-row 44pt header the approved Darkroom design replaces the old big-title +
    /// toolbar arrangement with. Two mutually exclusive rows, not one row with conditional
    /// pieces bolted on: normal mode and select mode read as different intents (browse vs.
    /// batch action) and the approved design lays them out differently enough (title-left vs.
    /// centered count) that sharing one HStack would mean fighting its own alignment rules for
    /// both cases at once.
    @ViewBuilder
    private var darkroomHeader: some View {
        if isSelecting {
            selectionHeaderRow
        } else {
            normalHeaderRow
        }
    }

    private var normalHeaderRow: some View {
        HStack(spacing: 6) {
            Text("Darkroom")
                .flimFont(17, weight: .light)
                .tracking(0.5)
                .foregroundStyle(FlimTheme.textPrimary)

            // The ledger: server-counted, never the loaded page count (see PhotoService's own
            // pagination trap doc). Omitted with its dot at zero, same as the old toolbar total.
            if let total = vm.totalCount, total > 0 {
                Text("·")
                    .flimFont(12)
                    .foregroundStyle(FlimTheme.textTertiary)
                Text("\(total) shot\(total == 1 ? "" : "s")")
                    .flimFont(12)
                    .foregroundStyle(FlimTheme.textTertiary)
            }

            Spacer()

            #if DEBUG
            Button {
                Task {
                    if let uid = auth.currentUser?.id {
                        await photoService.seedUnsortedPhotos(userId: uid)
                        await reload()
                    }
                }
            } label: {
                Image(systemName: "ladybug").foregroundStyle(FlimTheme.textTertiary)
            }
            .accessibilityLabel("Seed unsorted (DEBUG)")
            #endif

            if !vm.photos.isEmpty {
                Button("Select") {
                    isSelecting = true
                    selectedIDs = []
                }
                .flimFont(15)
                .foregroundStyle(accent)
            }
        }
        .frame(height: 44)
        .padding(.horizontal, 20)
    }

    /// Cancel leading, the running count centered, laid out with a `ZStack` rather than a
    /// three-way `HStack` split so the count is exactly centered regardless of how wide "Cancel"
    /// renders at a given Dynamic Type size.
    private var selectionHeaderRow: some View {
        ZStack {
            Text("\(selectedIDs.count) selected")
                .flimFont(15)
                .foregroundStyle(FlimTheme.textPrimary)

            HStack {
                Button("Cancel") {
                    isSelecting = false
                    selectedIDs = []
                }
                .flimFont(15)
                .foregroundStyle(accent)

                Spacer()
            }
        }
        .frame(height: 44)
        .padding(.horizontal, 20)
    }

    var body: some View {
        ZStack {
            FlimTheme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                darkroomHeader

                // Pinned under the header, outside the scroll (PR 2 of the zoom redesign,
                // 2026-08-25): visible at every scroll offset instead of scrolling out of view
                // the moment a scan reaches night two. Same hide rules as before the move.
                if !isSelecting, !unsortedPhotos.isEmpty {
                    DarkroomSortBanner(
                        accent: accent,
                        count: unsortedPhotos.count,
                        nightCount: unsortedNightCount,
                        previewPhotos: sortPreviewPhotos,
                        previewURLs: unsortedURLCache,
                        onTap: { showSortDeck = true }
                    )
                }

                Group {
                    if vm.isLoading && vm.photos.isEmpty {
                        ScrollView { DarkroomLoadingSkeleton().padding(.top, 8) }
                            .scrollDisabled(true)
                    } else if let error = vm.error, vm.photos.isEmpty {
                        ErrorState(message: error) { await reload() }
                    } else if vm.photos.isEmpty {
                        emptyState
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                Color.clear.frame(height: 0).id("top")
                                nightList
                            }
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { scrollWidth = $0 }
                            .refreshable { await reload() }
                            .onChange(of: scrollToTop) {
                                withAnimation(.snappy) { proxy.scrollTo("top", anchor: .top) }
                            }
                            .onAppear { scrollProxy = proxy }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay {
            if showReveal { revealOverlay }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                Button(role: .destructive) { deleteSelected() } label: {
                    Text(selectedIDs.isEmpty ? "Select photos to delete" : "Delete \(selectedIDs.count)")
                        .flimFont(15, weight: .semibold)
                        .foregroundStyle(selectedIDs.isEmpty ? FlimTheme.textTertiary : .white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(selectedIDs.isEmpty ? Color.white.opacity(0.08) : Color.red.opacity(0.85), in: Capsule())
                }
                .disabled(selectedIDs.isEmpty)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
            }
        }
        // Undo toast, deletes are deferred a few seconds so an accidental tap is recoverable.
        .overlay(alignment: .bottom) {
            if showUndoToast {
                HStack(spacing: 14) {
                    Text("Deleted \(pendingDelete.count) photo\(pendingDelete.count == 1 ? "" : "s")")
                        .flimFont(14).foregroundStyle(.white)
                    Button("Undo") { undoDelete() }
                        .flimFont(14, weight: .semibold)
                        .foregroundStyle(accent)
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 90)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: showUndoToast)
        .overlay(alignment: .top) {
            if let errorToast {
                Label(errorToast, systemImage: "exclamationmark.triangle.fill")
                    .flimFont(13, weight: .medium).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onAppear {
            Task {
                await reload()
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-seedDemo"), vm.photos.isEmpty,
                   let uid = auth.currentUser?.id {
                    await photoService.seedDemoPhotos(userId: uid)
                    await reload()
                }
                #endif
            }
        }
        // The 60s develop poll only needs to run while this screen is on it, and a page-until-
        // anchor jump has no reason to keep paging once nobody's watching for it to land. A
        // still-pending delete is flushed rather than left to its own 4s timer, see
        // `commitPendingDelete`'s own doc.
        .onDisappear { vm.stopRefreshing(); jumpPagingTask?.cancel(); commitPendingDelete() }
        .fullScreenCover(item: $selectedPhoto) { photo in
            pager(for: photo)
        }
        .fullScreenCover(isPresented: $showSortDeck, onDismiss: { Task { await reload() } }) {
            SortDeckView(onFinish: {})
        }
        .sheet(isPresented: $showJumpSheet) {
            DarkroomJumpSheet(monthCounts: monthCounts, loadedMonths: loadedMonthKeys, origin: jumpSheetOrigin) { year, month in
                jumpToMonth(year: year, month: month)
            }
        }
        // On the outer chain, not on the grid's ScrollView: the grid does not exist in the empty
        // and loading states, and a widget tap that lands then would be silently dropped.
        .onChange(of: openSortDeckSignal) { _, _ in
            // Guarded on there being something to sort: a tap can land a moment after the deck
            // was emptied on another device, and an empty full-screen deck is a dead end.
            if !unsortedPhotos.isEmpty { showSortDeck = true }
        }
        .onChange(of: openPhotoId.wrappedValue) { _, _ in openRequestedPhoto() }
        .sheet(item: $shareItem) { SharePreviewSheet(photo: $0.image) }
        .confirmationDialog("Delete this photo?", isPresented: $showRollDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Haptics.warning()
                let batch = pendingRollDeleteBatch
                pendingRollDeleteBatch = []
                commitDeleteBatch(batch)
            }
            Button("Cancel", role: .cancel) { pendingRollDeleteBatch = [] }
        } message: {
            Text(rollDeleteMessage(for: pendingRollDeleteBatch))
        }
    }

    // MARK: - Night list

    /// One unit per night, a sticky month band on every month (always, not just when the
    /// library spans two or more — a single-month library still gets its band, which is also
    /// the only way into the jump sheet). The sort banner is no longer in here: it's pinned
    /// under the header instead, see `body`. `Section` per month keeps the header pin working
    /// uniformly.
    private var nightList: some View {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
            ForEach(monthGroups) { group in
                Section {
                    ForEach(group.units) { unit in
                        DarkroomDayUnitView(
                            unit: unit,
                            capacity: stripCapacity,
                            accent: accent,
                            signedURLCache: vm.signedURLCache,
                            sharedIds: feed.myPostedPhotoIds,
                            isSelecting: isSelecting,
                            selectedIDs: selectedIDs,
                            rollName: { rollName(for: $0) },
                            photoNS: photoNS,
                            onTapDeveloped: { photo in
                                selectedURL = vm.signedURLCache[photo.id]
                                selectedPhoto = photo
                            },
                            onToggleSelect: { toggleSelect($0) },
                            developedMenu: { AnyView(developedMenu($0)) },
                            developingMenu: { AnyView(developingMenu($0)) },
                            onFrameAppear: { photo in await onFrameAppear(photo) }
                        )
                        if unit.id != lastUnitId {
                            DarkroomUnitSeparator()
                        }
                    }
                } header: {
                    DarkroomMonthBandView(group: group, shotCount: shotCount(for: group)) {
                        Haptics.tap()
                        jumpSheetOrigin = DarkroomYearMonth(date: group.monthKey)
                        showJumpSheet = true
                    }
                }
            }
            loadMoreSentinel
        }
        .padding(.bottom, 12)
    }

    /// The pagination trigger, moved OUT of `onFrameAppear`/per-frame `.task` (see below) and
    /// into its own view, last in the `LazyVStack`. `.task` on a frame only ever fires once per
    /// that frame's OWN identity: `reload()` (fired from `.onAppear` every time this tab is
    /// revisited) resets `vm.photos` back to page one, but the frames for those same photo ids
    /// stay mounted with the same identity across that reassignment, so a frame whose `.task`
    /// already ran in an earlier session never re-fires, and the "last ready frame" trigger it
    /// used to carry could then never fire again: the library stuck at 30 photos, permanently,
    /// the moment you'd once scrolled far enough to load a second page and then left the tab.
    ///
    /// This sentinel has no such per-photo identity to get stuck on. `LazyVStack` mounts/
    /// unmounts it as it scrolls in and out of the viewport (unlike a rack's own frames, which
    /// sit inside a plain, non-lazy `HStack` and all mount together the moment their night is
    /// realized), so scrolling away and back always gives it a fresh `onAppear`. While it stays
    /// visible, `.task(id: vm.photos.count)` re-arms itself every time a page actually lands
    /// (the id changes), chaining pages automatically until either `photoService.hasMore` goes
    /// false (the `if` below then removes the sentinel outright) or the guard inside
    /// `DarkroomViewModel.loadMore` no-ops because a fetch is already in flight.
    @ViewBuilder
    private var loadMoreSentinel: some View {
        if photoService.hasMore {
            Color.clear
                .frame(height: 44)
                .onAppear { Task { await loadMoreIfNeeded() } }
                .task(id: vm.photos.count) { await loadMoreIfNeeded() }
        }
    }

    private func loadMoreIfNeeded() async {
        guard let uid = auth.currentUser?.id else { return }
        await vm.loadMore(photoService: photoService, userId: uid)
    }

    /// Resolves a frame's signed URL if it isn't cached yet (freshly-loaded pages aren't covered
    /// by `reload()`'s batched prefetch). Pagination itself is `loadMoreSentinel`'s job now, see
    /// its own doc for why this used to also carry that trigger and why that broke.
    private func onFrameAppear(_ photo: Photo) async {
        if photo.isReady, vm.signedURLCache[photo.id] == nil {
            _ = await vm.signedURL(for: photo, photoService: photoService)
        }
    }

    // MARK: - Grid long-press menu

    /// Long-press actions on a developed shot. This replaces the old bare long-press-to-select
    /// gesture: selecting is still one item in here, alongside the actions that until now
    /// required opening the photo full-screen first. A context menu and an `onLongPressGesture`
    /// on the same cell would compete for the gesture, so the menu subsumes it rather than
    /// stacking on top.
    @ViewBuilder
    private func developedMenu(_ photo: Photo) -> some View {
        Button { beginSelecting(photo.id) } label: { Label("Select", systemImage: "checkmark.circle") }
        // "Tag people" used to live here, routing into the share composer with the tag sheet up
        // (tags belong to a post, so there was nothing to attach one to until the photo was being
        // shared). Removed 2026-08-24: tagging an unshared archive shot from the grid contradicts
        // the rule that tagging only ever happens AT share time or on an already-shared shot,
        // even though this route technically went through the composer first. The viewer's own
        // promoted "Tag" action (only shown once a shot is already shared) is the one remaining
        // way to tag a Darkroom photo.
        Button { share(photo) } label: { Label("Share", systemImage: "square.and.arrow.up") }
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
                    flashError("Couldn't update your profile photo. Check your connection and try again.")
                }
            }
        } label: { Label("Set as profile photo", systemImage: "person.crop.circle") }
        Divider()
        Button(role: .destructive) { requestDelete([photo]) } label: { Label("Delete", systemImage: "trash") }
    }

    /// A still-developing shot has no viewable image yet, so its menu is select + delete only.
    @ViewBuilder
    private func developingMenu(_ photo: Photo) -> some View {
        Button { beginSelecting(photo.id) } label: { Label("Select", systemImage: "checkmark.circle") }
        Divider()
        Button(role: .destructive) { requestDelete([photo]) } label: { Label("Delete", systemImage: "trash") }
    }

    /// Pulls the full-res file down and hands it to the share composer, the same path the feed
    /// card's "Save to Camera Roll" uses.
    ///
    /// Checks the disk cache's raw bytes for this exact object first (see `DiskImageCache.
    /// loadRaw`): a long-press Share used to go through a bare `URLSession` every single time,
    /// re-downloading the ~1MB+ master even when it was already sitting on the device from an
    /// earlier repair pass or a previous share this session. A miss still falls all the way
    /// through to the same download this always did, and now saves those bytes for next time.
    private func share(_ photo: Photo) {
        Haptics.tap()
        Task {
            if let raw = await DiskImageCache.loadRaw(path: photo.storagePath), let image = UIImage(data: raw) {
                shareItem = ShareImage(image: image)
                return
            }
            guard let url = try? await photoService.signedURL(for: photo.storagePath),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else {
                Haptics.error()
                return
            }
            DiskImageCache.saveRaw(data, path: photo.storagePath)
            shareItem = ShareImage(image: image)
        }
    }

    /// Top-slot toast for a failure that must not decline silently. Auto-hides.
    private func flashError(_ message: String) {
        withAnimation { errorToast = message }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { errorToast = nil }
        }
    }

    private func toggleSelect(_ id: UUID) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
        Haptics.tap()
    }

    private func deleteSelected() {
        requestDelete((vm.developedPhotos + vm.developingPhotos).filter { selectedIDs.contains($0.id) })
    }

    /// Optimistically hides the photos and shows an Undo toast; the real (irreversible) server
    /// delete only commits after a few seconds if the user doesn't undo. Roll shots are shared,
    /// so if the batch includes any, confirm first (naming the roll), personal photos keep the
    /// instant-hide-then-undo behavior. The single delete entry point for both the selection
    /// toolbar and a cell's long-press menu, so a one-photo delete gets the same confirmation
    /// a batch does.
    private func requestDelete(_ toDelete: [Photo]) {
        guard !toDelete.isEmpty else { return }

        if toDelete.contains(where: { $0.rollId != nil }) {
            // No haptic yet, nothing destructive has happened until the dialog is confirmed.
            pendingRollDeleteBatch = toDelete
            showRollDeleteConfirm = true
        } else {
            Haptics.warning()
            commitDeleteBatch(toDelete)
        }
    }

    /// The roll-name message for a batch that includes shared shots, names the roll if every
    /// roll shot in the batch belongs to the same one, else falls back to generic wording.
    private func rollDeleteMessage(for batch: [Photo]) -> String {
        rollDeleteConfirmationMessage(forRollNames: batch.map { rollName(for: $0.rollId) })
    }

    private func commitDeleteBatch(_ toDelete: [Photo]) {
        // If a previous pending delete is still waiting, commit it now before starting a new one.
        commitPendingDelete()

        let ids = Set(toDelete.map(\.id))
        vm.photos.removeAll { ids.contains($0.id) }   // optimistic hide
        // Held for the whole undo window (and past it, until the server delete actually
        // resolves), so a reload or the 60s develop poll landing in between can't reassign
        // `vm.photos` from the server and resurrect this batch with the Undo toast still up.
        // See `DarkroomViewModel.assign`.
        vm.pendingHiddenIds.formUnion(ids)
        pendingDelete = toDelete
        selectedIDs = []
        isSelecting = false
        showUndoToast = true

        undoTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            let batch = pendingDelete
            let ok = await photoService.deletePhotos(batch)
            showUndoToast = false
            pendingDelete = []
            vm.pendingHiddenIds.subtract(ids)
            if ok {
                // Confirmed gone server-side, so any post among these photos has to go too, or
                // this device's already-loaded feed keeps showing an imageless card for it.
                // Removed directly rather than trusting the (now-lifted) `pendingHiddenIds`
                // filter alone: a reload could have landed inside the window and, filtered or
                // not, this batch belongs gone from `vm.photos` regardless of what it currently
                // holds.
                vm.photos.removeAll { ids.contains($0.id) }
                feed.dropPosts(forDeletedPhotoIds: batch.map(\.id))
            } else {
                restoreAfterFailedDelete(batch)
            }
        }
    }

    private func undoDelete() {
        undoTask?.cancel()
        showUndoToast = false
        // Lifted before the restoring reload below, or that reload's own reassignment would
        // filter this batch right back out.
        vm.pendingHiddenIds.subtract(pendingDelete.map(\.id))
        pendingDelete = []
        Task { await reload() }   // restore from the server, nothing was actually deleted
    }

    /// Flush a still-pending delete immediately: a new delete starting while one is still in its
    /// undo window, or the screen disappearing (wired from `.onDisappear`) while one is still
    /// waiting out its 4 seconds. Timing a delete's commit to a view that may already be torn
    /// down is what the undo window risks otherwise; flushing on disappear is strictly safer than
    /// leaving the timer to fire into whatever is left of this screen.
    private func commitPendingDelete() {
        guard !pendingDelete.isEmpty else { return }
        undoTask?.cancel()
        let batch = pendingDelete
        let ids = Set(batch.map(\.id))
        pendingDelete = []
        showUndoToast = false
        Task {
            let ok = await photoService.deletePhotos(batch)
            vm.pendingHiddenIds.subtract(ids)
            if ok {
                vm.photos.removeAll { ids.contains($0.id) }
                feed.dropPosts(forDeletedPhotoIds: batch.map(\.id))
            } else {
                restoreAfterFailedDelete(batch)
            }
        }
    }

    /// Puts photos back into the grid after the server refused a delete (network dropped, the
    /// Storage removal itself failed). `commitDeleteBatch` already hid these optimistically the
    /// moment Undo's window opened; `deletePhotos` returning `false` means the row was
    /// deliberately left in place rather than deleted out from under a failed Storage removal
    /// (see its own doc), so without this the photo stays correctly present server-side but
    /// invisible here until the next full reload.
    private func restoreAfterFailedDelete(_ batch: [Photo]) {
        guard !batch.isEmpty else { return }
        let existingIds = Set(vm.photos.map(\.id))
        let restored = batch.filter { !existingIds.contains($0.id) }
        guard !restored.isEmpty else { return }
        vm.photos.append(contentsOf: restored)
        // The personal Darkroom now pages (and renders) in `taken_at` order, not `develops_at`,
        // see `PhotoService.PhotoOrderColumn`'s own doc; restoring here has to land these frames
        // back where that order would have put them, or a restored photo can appear under the
        // wrong night.
        vm.photos.sort { $0.takenAt > $1.takenAt }
        Haptics.error()
        flashError(restored.count == 1
            ? "Couldn't delete that photo. Check your connection and try again."
            : "Couldn't delete those photos. Check your connection and try again.")
    }

    /// Long-press a photo to jump into selection mode with it selected.
    private func beginSelecting(_ id: UUID) {
        if !isSelecting { isSelecting = true }
        if !selectedIDs.contains(id) { selectedIDs.insert(id) }
        Haptics.select()
    }

    /// The name of the roll a photo belongs to (for labeling roll shots in the Darkroom).
    private func rollName(for rollId: UUID?) -> String? {
        guard let rollId else { return nil }
        return rolls.rolls.first { $0.id == rollId }?.name
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(accent.opacity(0.8))
            Text("Your darkroom's empty.")
                .flimFont(17, weight: .light)
                .foregroundStyle(FlimTheme.textSecondary)
            Text("Head to the camera and take your first shot. Sort it here, then keep it or share it.")
                .flimFont(13)
                .foregroundStyle(FlimTheme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                NotificationCenter.default.post(name: .openCamera, object: nil)
            } label: {
                Label("Take a shot", systemImage: "camera.aperture")
                    .flimFont(14, weight: .semibold)
                    .foregroundStyle(accent)
                    .padding(.horizontal, 20).padding(.vertical, 11)
                    .overlay(Capsule().stroke(accent, lineWidth: 1))
            }
            .padding(.top, 4)
        }
    }

    /// The full-screen pager for a tapped frame.
    ///
    /// Its own function because the body could no longer be type-checked with it inline, and
    /// because there are two genuinely different cases. A frame opened from the grid pages
    /// through the whole grid and zooms out of its own cell. A frame opened from a widget need
    /// not be in the loaded page at all (see `openRequestedPhoto`) — `firstIndex ?? 0` would then
    /// silently open whatever happens to be newest instead, which is the wrong photograph with
    /// nothing to indicate it. That one is paged alone and gets no zoom, because there is no cell
    /// on screen for it to zoom out of.
    @ViewBuilder
    private func pager(for photo: Photo) -> some View {
        // The flattened render order: units newest first, each night's own frames oldest first,
        // developing shots included in their true chronological place, so swiping plays a night
        // forward (develops-at wells and all) and then continues into the adjacent one.
        let orderedPhotos = renderOrderPhotos
        let index = orderedPhotos.firstIndex(where: { $0.id == photo.id })
        if let index {
            PhotoPagerView(photos: orderedPhotos,
                           startIndex: index,
                           signedURLs: vm.signedURLCache,
                           showsNightRack: true,
                           rollName: { rollName(for: $0) },
                           onDelete: { Task { await reload() } })
                .navigationTransition(.zoom(sourceID: photo.id, in: photoNS))
        } else {
            PhotoPagerView(photos: [photo],
                           startIndex: 0,
                           signedURLs: vm.signedURLCache,
                           showsNightRack: true,
                           rollName: { rollName(for: $0) },
                           onDelete: { Task { await reload() } })
        }
    }

    /// Opens a frame a widget asked for.
    ///
    /// Fetches it BY ID rather than looking in `vm.developedPhotos`, and that is the fix rather
    /// than a refinement. That array is one page of `is_sorted = true` photos, thirty at a time,
    /// newest first — so a frame from a month ago is essentially never in it, which is exactly
    /// the horizon the look-back tile is built to surface. Every tap on an older memory searched
    /// a list that could not contain it and quietly did nothing.
    ///
    /// The pager takes a single photo here, the same way the widget-less deep links in `FlimApp`
    /// present one. A frame that is gone (deleted, moderated, or belonging to an account no
    /// longer signed in) comes back nil and leaves a real, populated Darkroom on screen, which is
    /// the graceful no-op every other deep link here takes.
    private func openRequestedPhoto() {
        guard let id = openPhotoId.wrappedValue else { return }
        openPhotoId.wrappedValue = nil
        if let loaded = vm.developedPhotos.first(where: { $0.id == id }) {
            selectedPhoto = loaded          // already on screen: no round trip, keeps the zoom transition
            return
        }
        Task {
            guard let photo = await photoService.fetchPhoto(id: id) else { return }
            await MainActor.run { selectedPhoto = photo }
        }
    }

    /// Dismisses the jump sheet, then lands `year`/`month`'s band at the top of the scroller.
    ///
    /// A month already loaded scrolls immediately. A month the sheet promised has photos but
    /// isn't loaded yet is reached by paging forward (anchored paging proper is deferred, see
    /// the design brief) until a unit of it appears or `photoService.hasMore` runs out, guarded
    /// by `jumpPagingInFlight` so a second tap on an unloaded month can't race the first, and
    /// cancelled from `.onDisappear` if the screen goes away mid-loop. If pagination exhausts
    /// without ever finding the month (the RPC and the page boundary disagreeing, e.g. a
    /// timezone edge), this no-ops silently rather than crash or show a real photo as a bogus one.
    private func jumpToMonth(year: Int, month: Int) {
        showJumpSheet = false
        guard let targetId = Calendar.current.date(from: DateComponents(year: year, month: month, day: 1))
        else { return }

        if monthGroups.contains(where: { $0.id == targetId }) {
            withAnimation(.snappy) { scrollProxy?.scrollTo(targetId, anchor: .top) }
            return
        }

        guard !jumpPagingInFlight, let uid = auth.currentUser?.id else { return }
        jumpPagingInFlight = true
        jumpPagingTask = Task {
            defer { jumpPagingInFlight = false }
            while !Task.isCancelled, !monthGroups.contains(where: { $0.id == targetId }), photoService.hasMore {
                await vm.loadMore(photoService: photoService, userId: uid)
            }
            guard !Task.isCancelled, monthGroups.contains(where: { $0.id == targetId }) else { return }
            withAnimation(.snappy) { scrollProxy?.scrollTo(targetId, anchor: .top) }
        }
    }

    private func reload() async {
        guard let userId = auth.currentUser?.id else { return }
        async let counts = photoService.darkroomMonthCounts(timezone: TimeZone.current.identifier)
        await vm.load(photoService: photoService, userId: userId)
        monthCounts = await counts
        // Warm the grid's thumbnails so cells appear instantly as you scroll.
        let prefetch = vm.photos.compactMap { photo -> (url: URL, cacheKey: String?)? in
            vm.signedURLCache[photo.id].map { ($0, photo.displayPath) }
        }
        ImageLoader.prefetch(prefetch, maxPixel: 400, scale: displayScale)
        if rolls.rolls.isEmpty { try? await rolls.fetchRolls(for: userId) }   // for roll labels
        let unsorted = await photoService.fetchUnsorted(userId: userId)
        unsortedPhotos = unsorted
        // The sort row only ever shows up to three thumbnails, so only those three need signed
        // URLs, batched in one call rather than a round trip per preview cell.
        let previews = DarkroomDayUnit.pickPreview(from: unsorted)
        if !previews.isEmpty {
            let map = await photoService.signedURLs(for: previews.map(\.displayPath))
            for previewPhoto in previews {
                if let url = map[previewPhoto.displayPath] { unsortedURLCache[previewPhoto.id] = url }
            }
        }
        // One batched query for the whole grid's "shared to your page" badge, not a `hasPosted`
        // round trip per tile.
        await feed.loadMyPostedPhotoIds(userId: userId)
        checkForReveal()
        // The library is loaded now, so a pending widget tap can finally be answered — or
        // recognised as pointing at something that is gone.
        openRequestedPhoto()
    }

    /// Celebrate shots that have finished developing since the last time the Darkroom was open.
    private func checkForReveal() {
        let now = Date().timeIntervalSince1970
        if lastRevealCheck > 0, !showReveal, !isSelecting {
            // Roll shots only, personal instants get the sort deck as their reveal moment.
            let newlyReady = vm.developedPhotos.filter {
                $0.rollId != nil && $0.developsAt.timeIntervalSince1970 > lastRevealCheck && $0.isReady
            }
            if !newlyReady.isEmpty {
                revealCount = newlyReady.count
                Haptics.reveal()
                SoundFX.reveal()
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { showReveal = true }
            }
        }
        lastRevealCheck = now
    }

    private var revealOverlay: some View {
        ZStack {
            Color.black.opacity(0.94).ignoresSafeArea()
            // A soft glow that blooms behind the icon as it lands.
            RadialGradient(colors: [accent.opacity(0.28), .clear],
                           center: .center, startRadius: 2, endRadius: 280)
                .ignoresSafeArea()
                .scaleEffect(revealAnim ? 1 : 0.5)
                .opacity(revealAnim ? 1 : 0)

            VStack(spacing: 14) {
                ZStack {
                    Circle().fill(accent.opacity(0.12)).frame(width: 112, height: 112)
                    Image(systemName: "sparkles")
                        .font(.system(size: 48, weight: .ultraLight))
                        .foregroundStyle(accent)
                        .symbolEffect(.pulse)
                }
                .scaleEffect(revealAnim ? 1 : 0.4)

                VStack(spacing: 6) {
                    Text("Your photos are ready")
                        .flimFont(27, weight: .thin)
                        .foregroundStyle(.white)
                    Text("\(revealCount) new \(revealCount == 1 ? "shot" : "shots") developed")
                        .flimFont(14)
                        .foregroundStyle(FlimTheme.textSecondary)
                }
                .opacity(revealAnim ? 1 : 0)
                .offset(y: revealAnim ? 0 : 14)

                Button { dismissReveal() } label: {
                    Text("See them")
                        .flimFont(16, weight: .semibold)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 34).padding(.vertical, 14)
                        .background(accent, in: Capsule())
                        .shadow(color: accent.opacity(0.5), radius: 12)
                }
                .opacity(revealAnim ? 1 : 0)
                .padding(.top, 10)
            }
        }
        .transition(.opacity)
        .onAppear {
            if reduceMotion {
                revealAnim = true   // no spring/scale, appear settled
            } else {
                revealAnim = false
                withAnimation(.spring(response: 0.55, dampingFraction: 0.68).delay(0.05)) { revealAnim = true }
            }
        }
        .onTapGesture { dismissReveal() }
    }

    private func dismissReveal() {
        withAnimation(.easeOut(duration: 0.25)) { revealAnim = false }
        withAnimation(.easeInOut(duration: 0.3)) { showReveal = false }
    }
}
