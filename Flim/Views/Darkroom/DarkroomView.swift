import SwiftUI
import TipKit

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
    var scrollToTop: Int = 0
    @Environment(AuthService.self) private var auth
    @Environment(PhotoService.self) private var photoService
    @Environment(RollService.self) private var rolls
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
    @AppStorage("lastRevealCheck") private var lastRevealCheck: Double = 0
    @State private var showReveal = false
    @State private var revealAnim = false
    @State private var revealCount = 0
    @State private var unsortedCount = 0
    @State private var showSortDeck = false
    @State private var showRollDeleteConfirm = false
    @State private var pendingRollDeleteBatch: [Photo] = []

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    var body: some View {
        ZStack {
            FlimTheme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                FlimNavTitle("Darkroom")

                if unsortedCount > 0 {
                    Button { showSortDeck = true } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "square.stack.3d.up.fill")
                            Text("\(unsortedCount) shot\(unsortedCount == 1 ? "" : "s") to sort")
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 12))
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(FlimTheme.accent)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .background(FlimTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 16).padding(.bottom, 4)
                    }
                }

                Group {
                    if vm.isLoading && vm.photos.isEmpty {
                        ScrollView { LoadingGrid().padding(.top, 8) }
                            .scrollDisabled(true)
                    } else if let error = vm.error, vm.photos.isEmpty {
                        ErrorState(message: error) { await reload() }
                    } else if vm.photos.isEmpty {
                        emptyState
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                Color.clear.frame(height: 0).id("top")
                                photoGrid
                                    .padding(.horizontal, 2)
                            }
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
                        SelectTip().invalidate(reason: .actionPerformed)   // used it → dismiss the tip
                    }
                    .foregroundStyle(.white)
                    .popoverTip(SelectTip())
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
            // Something to sort → the shortcut pill; otherwise a glanceable count (no empty button).
            if unsortedCount > 0 {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSortDeck = true } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "square.stack.3d.up.fill").font(.system(size: 11))
                            Text("\(unsortedCount)").font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(.black)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(FlimTheme.accent, in: Capsule())
                    }
                    .accessibilityLabel("\(unsortedCount) to sort")
                }
            } else if !vm.developedPhotos.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Text("\(vm.developedPhotos.count) shot\(vm.developedPhotos.count == 1 ? "" : "s")")
                        .font(.system(size: 13, weight: .medium))
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
                        .font(.system(size: 15, weight: .semibold))
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
        // Undo toast — deletes are deferred a few seconds so an accidental tap is recoverable.
        .overlay(alignment: .bottom) {
            if showUndoToast {
                HStack(spacing: 14) {
                    Text("Deleted \(pendingDelete.count) photo\(pendingDelete.count == 1 ? "" : "s")")
                        .font(.system(size: 14)).foregroundStyle(.white)
                    Button("Undo") { undoDelete() }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(FlimTheme.accent)
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 90)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: showUndoToast)
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
        .fullScreenCover(item: $selectedPhoto) { photo in
            FullScreenPhotoView(photo: photo, url: selectedURL, rollName: rollName(for: photo.rollId),
                               onDelete: { Task { await reload() } })
                .navigationTransition(.zoom(sourceID: photo.id, in: photoNS))
        }
        .fullScreenCover(isPresented: $showSortDeck, onDismiss: { Task { await reload() } }) {
            SortDeckView(onFinish: {})
        }
        .confirmationDialog("Delete this photo?", isPresented: $showRollDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                let batch = pendingRollDeleteBatch
                pendingRollDeleteBatch = []
                commitDeleteBatch(batch)
            }
            Button("Cancel", role: .cancel) { pendingRollDeleteBatch = [] }
        } message: {
            Text(rollDeleteMessage(for: pendingRollDeleteBatch))
        }
    }

    // MARK: - Grid

    @ViewBuilder
    private var photoGrid: some View {
        if !vm.developingPhotos.isEmpty {
            developingSection
        }
        if !vm.developedPhotos.isEmpty {
            developedSection
        }
    }

    private var developingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(vm.developingPhotos.count) DEVELOPING")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(2)
                    .foregroundStyle(Color(white: 0.4))
                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.top, 16)

            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(vm.developingPhotos) { photo in
                    PhotoGridCell(photo: photo, signedURL: nil, rollName: rollName(for: photo.rollId))
                        .overlay { if isSelecting { selectionMark(photo.id) } }
                        .onTapGesture { if isSelecting { toggleSelect(photo.id) } }
                        .onLongPressGesture { beginSelecting(photo.id) }
                }
            }
        }
    }

    private func selectionMark(_ id: UUID) -> some View {
        let selected = selectedIDs.contains(id)
        return ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(selected ? 0.4 : 0.001))
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18))
                .foregroundStyle(selected ? FlimTheme.accent : .white.opacity(0.85))
                .padding(6)
                .shadow(radius: 2)
        }
        .allowsHitTesting(false)
    }

    private func toggleSelect(_ id: UUID) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
        Haptics.tap()
    }

    /// Optimistically hides the selected photos and shows an Undo toast; the real (irreversible)
    /// server delete only commits after a few seconds if the user doesn't undo. Roll shots are
    /// shared, so if the selection includes any, confirm first (naming the roll) — personal
    /// photos keep the existing instant-hide-then-undo behavior.
    private func deleteSelected() {
        let toDelete = (vm.developedPhotos + vm.developingPhotos).filter { selectedIDs.contains($0.id) }
        guard !toDelete.isEmpty else { return }

        if toDelete.contains(where: { $0.rollId != nil }) {
            pendingRollDeleteBatch = toDelete
            showRollDeleteConfirm = true
        } else {
            commitDeleteBatch(toDelete)
        }
    }

    /// The roll-name message for a batch that includes shared shots — names the roll if every
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
            await photoService.deletePhotos(batch)
            showUndoToast = false
            pendingDelete = []
        }
    }

    private func undoDelete() {
        undoTask?.cancel()
        showUndoToast = false
        pendingDelete = []
        Task { await reload() }   // restore from the server — nothing was actually deleted
    }

    /// Flush a still-pending delete immediately (e.g. leaving the view or starting a new delete).
    private func commitPendingDelete() {
        guard !pendingDelete.isEmpty else { return }
        undoTask?.cancel()
        let batch = pendingDelete
        pendingDelete = []
        showUndoToast = false
        Task { await photoService.deletePhotos(batch) }
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

    private var developedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("DEVELOPED")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(2)
                    .foregroundStyle(Color(white: 0.4))
                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.top, 16)

            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(vm.developedPhotos) { photo in
                    PhotoGridCell(photo: photo, signedURL: vm.signedURLCache[photo.id], rollName: rollName(for: photo.rollId))
                        .matchedTransitionSource(id: photo.id, in: photoNS)
                        .overlay { if isSelecting { selectionMark(photo.id) } }
                        .onTapGesture {
                            if isSelecting {
                                toggleSelect(photo.id)
                            } else {
                                selectedURL = vm.signedURLCache[photo.id]
                                selectedPhoto = photo
                            }
                        }
                        .onLongPressGesture { beginSelecting(photo.id) }
                        .task {
                            if vm.signedURLCache[photo.id] == nil {
                                _ = await vm.signedURL(for: photo, photoService: photoService)
                            }
                            // Load the next page as the last photo scrolls into view.
                            if photo.id == vm.developedPhotos.last?.id, let uid = auth.currentUser?.id {
                                await vm.loadMore(photoService: photoService, userId: uid)
                            }
                        }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(FlimTheme.accent.opacity(0.8))
            Text("Your darkroom's empty.")
                .font(.system(size: 17, weight: .light))
                .foregroundStyle(FlimTheme.textSecondary)
            Text("Head to the camera and take your first shot. Sort it here, then keep it or share it.")
                .font(.system(size: 13))
                .foregroundStyle(FlimTheme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                NotificationCenter.default.post(name: .openCamera, object: nil)
            } label: {
                Label("Take a shot", systemImage: "camera.aperture")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 20).padding(.vertical, 11)
                    .background(FlimTheme.accent, in: Capsule())
            }
            .padding(.top, 4)
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
        unsortedCount = await photoService.fetchUnsorted(userId: userId).count
        checkForReveal()
    }

    /// Celebrate shots that have finished developing since the last time the Darkroom was open.
    private func checkForReveal() {
        let now = Date().timeIntervalSince1970
        if lastRevealCheck > 0, !showReveal, !isSelecting {
            // Roll shots only — personal instants get the sort deck as their reveal moment.
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
            RadialGradient(colors: [FlimTheme.accent.opacity(0.28), .clear],
                           center: .center, startRadius: 2, endRadius: 280)
                .ignoresSafeArea()
                .scaleEffect(revealAnim ? 1 : 0.5)
                .opacity(revealAnim ? 1 : 0)

            VStack(spacing: 14) {
                ZStack {
                    Circle().fill(FlimTheme.accent.opacity(0.12)).frame(width: 112, height: 112)
                    Image(systemName: "sparkles")
                        .font(.system(size: 48, weight: .ultraLight))
                        .foregroundStyle(FlimTheme.accent)
                        .symbolEffect(.pulse)
                }
                .scaleEffect(revealAnim ? 1 : 0.4)

                VStack(spacing: 6) {
                    Text("Your photos are ready")
                        .font(.system(size: 27, weight: .thin))
                        .foregroundStyle(.white)
                    Text("\(revealCount) new \(revealCount == 1 ? "shot" : "shots") developed")
                        .font(.system(size: 14))
                        .foregroundStyle(FlimTheme.textSecondary)
                }
                .opacity(revealAnim ? 1 : 0)
                .offset(y: revealAnim ? 0 : 14)

                Button { dismissReveal() } label: {
                    Text("See them")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 34).padding(.vertical, 14)
                        .background(FlimTheme.accent, in: Capsule())
                        .shadow(color: FlimTheme.accent.opacity(0.5), radius: 12)
                }
                .opacity(revealAnim ? 1 : 0)
                .padding(.top, 10)
            }
        }
        .transition(.opacity)
        .onAppear {
            if reduceMotion {
                revealAnim = true   // no spring/scale — appear settled
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
