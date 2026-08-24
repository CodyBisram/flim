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
    @State private var showRollDeleteConfirm = false
    @State private var pendingRollDeleteBatch: [Photo] = []
    @State private var shareItem: ShareImage?
    /// Set by the grid's "Tag people" action so the viewer opens straight into the share
    /// composer's tag step. Cleared on dismiss so a later ordinary tap opens the photo normally.
    @State private var openForTagging = false
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

    /// Bands render only when the loaded library actually spans two or more calendar months.
    private var showsMonthBands: Bool { monthGroups.count >= 2 }

    private var lastUnitId: Date? { monthGroups.last?.units.last?.id }

    /// The flattened READY photos in render order (units newest first, frames oldest first
    /// inside each), what the pager pages through and where pagination's trigger frame lives.
    private var renderOrderReadyPhotos: [Photo] {
        dayUnits.flatMap(\.developed)
    }

    private var sortPreviewPhotos: [Photo] {
        DarkroomDayUnit.pickPreview(from: unsortedPhotos)
    }

    var body: some View {
        ZStack {
            FlimTheme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                FlimNavTitle("Darkroom")

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
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if !vm.photos.isEmpty {
                    Button(isSelecting ? "Cancel" : "Select") {
                        isSelecting.toggle()
                        selectedIDs = []
                    }
                    .foregroundStyle(.white)
                }
            }
            #if DEBUG
            ToolbarItem(placement: .topBarTrailing) {
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
            }
            #endif
            // A glanceable total, whenever there is one — it no longer loses its slot to a
            // sort-shortcut pill; that shortcut lives in the in-scroll sort row now.
            if let total = vm.totalCount, total > 0 {
                ToolbarItem(placement: .topBarTrailing) {
                    Text("\(total) shot\(total == 1 ? "" : "s")")
                        .flimFont(13, weight: .medium)
                        .foregroundStyle(FlimTheme.textTertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                }
            }
        }
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
        // The 60s develop poll only needs to run while this screen is on it.
        .onDisappear { vm.stopRefreshing() }
        .fullScreenCover(item: $selectedPhoto, onDismiss: { openForTagging = false }) { photo in
            pager(for: photo)
        }
        .fullScreenCover(isPresented: $showSortDeck, onDismiss: { Task { await reload() } }) {
            SortDeckView(onFinish: {})
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

    /// One unit per night, sticky month bands when the library spans more than one month, and
    /// the sort row above all of it. `Section` per month keeps the header pin working even when
    /// there is exactly one month to show (its header is then just empty).
    private var nightList: some View {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: showsMonthBands ? [.sectionHeaders] : []) {
            if !isSelecting, !unsortedPhotos.isEmpty {
                DarkroomSortRowView(
                    accent: accent,
                    count: unsortedPhotos.count,
                    previewPhotos: sortPreviewPhotos,
                    previewURLs: unsortedURLCache,
                    onTap: { showSortDeck = true }
                )
            }
            ForEach(monthGroups) { group in
                Section {
                    ForEach(group.units) { unit in
                        DarkroomDayUnitView(
                            unit: unit,
                            capacity: stripCapacity,
                            showsMonth: showsMonthBands,
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
                    if showsMonthBands { DarkroomMonthBandView(group: group) }
                }
            }
        }
        .padding(.bottom, 12)
    }

    /// Resolves a frame's signed URL if it isn't cached yet (freshly-loaded pages aren't covered
    /// by `reload()`'s batched prefetch), and loads the next page once the last READY frame in
    /// render order appears — the pagination trigger, unchanged from the old grid's.
    private func onFrameAppear(_ photo: Photo) async {
        if photo.isReady, vm.signedURLCache[photo.id] == nil {
            _ = await vm.signedURL(for: photo, photoService: photoService)
        }
        if photo.id == renderOrderReadyPhotos.last?.id, let uid = auth.currentUser?.id {
            await vm.loadMore(photoService: photoService, userId: uid)
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
        // Tags belong to a post, so there is nothing to attach them to until the photo is being
        // shared. This opens the viewer straight into the share composer with the tag sheet up,
        // so tagging is one action from the grid rather than three.
        Button {
            selectedURL = vm.signedURLCache[photo.id]
            openForTagging = true
            selectedPhoto = photo
        } label: { Label("Tag people", systemImage: "person.crop.circle.badge.plus") }
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
            if ok {
                // Confirmed gone server-side, so any post among these photos has to go too, or
                // this device's already-loaded feed keeps showing an imageless card for it.
                feed.dropPosts(forDeletedPhotoIds: batch.map(\.id))
            } else {
                restoreAfterFailedDelete(batch)
            }
        }
    }

    private func undoDelete() {
        undoTask?.cancel()
        showUndoToast = false
        pendingDelete = []
        Task { await reload() }   // restore from the server, nothing was actually deleted
    }

    /// Flush a still-pending delete immediately (e.g. leaving the view or starting a new delete).
    private func commitPendingDelete() {
        guard !pendingDelete.isEmpty else { return }
        undoTask?.cancel()
        let batch = pendingDelete
        pendingDelete = []
        showUndoToast = false
        Task {
            let ok = await photoService.deletePhotos(batch)
            if ok {
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
        vm.photos.sort { $0.developsAt > $1.developsAt }
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
        // so swiping plays a night forward and then continues into the adjacent one.
        let orderedPhotos = renderOrderReadyPhotos
        let index = orderedPhotos.firstIndex(where: { $0.id == photo.id })
        if let index {
            PhotoPagerView(photos: orderedPhotos,
                           startIndex: index,
                           signedURLs: vm.signedURLCache,
                           rollName: { rollName(for: $0) },
                           onDelete: { Task { await reload() } },
                           startTagging: openForTagging)
                .navigationTransition(.zoom(sourceID: photo.id, in: photoNS))
        } else {
            PhotoPagerView(photos: [photo],
                           startIndex: 0,
                           signedURLs: vm.signedURLCache,
                           rollName: { rollName(for: $0) },
                           onDelete: { Task { await reload() } },
                           startTagging: openForTagging)
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

    private func reload() async {
        guard let userId = auth.currentUser?.id else { return }
        await vm.load(photoService: photoService, userId: userId)
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
