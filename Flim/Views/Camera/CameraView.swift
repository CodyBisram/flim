import SwiftUI

struct CameraView: View {
    @Environment(AuthService.self) private var auth
    @Environment(PhotoService.self) private var photos
    @Environment(RollService.self) private var rolls
    @Environment(NotificationService.self) private var notifications

    @State private var camera = CameraViewModel()
    @State private var selectedRoll: Roll? = nil
    @State private var showRollPicker = false

    // Film strip fades out when idle so the shutter stays the focal point; any
    // interaction wakes it back up.
    @State private var filmStripActive = false
    @State private var dimTask: Task<Void, Never>?

    // Persisted across launches so your last film pick sticks.
    @AppStorage("selectedFilmID") private var selectedFilmID: String = FilmStock.original.id
    private var selectedStock: FilmStock { FilmStock.stock(id: selectedFilmID) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreview(session: camera.session)
                .ignoresSafeArea()

            // Shutter flash overlay
            Color.white
                .opacity(camera.flashOpacity)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            // Controls respect the safe area so they sit ABOVE the tab bar — only the
            // camera preview / flash bleed full-screen (they ignore safe area individually).
            VStack(spacing: 0) {
                topBar
                Spacer()
                VStack(spacing: 26) {
                    filmStrip
                    bottomBar
                }
                .padding(.bottom, 8)
            }
        }
        .onAppear {
            camera.configure()
            camera.startRunning()
            bindCapture()
            wakeFilmStrip()
            Task {
                if let userId = auth.currentUser?.id {
                    try? await rolls.fetchRolls(for: userId)
                }
            }
        }
        .onDisappear { camera.stopRunning() }
        .sheet(isPresented: $showRollPicker) {
            RollPickerSheet(rolls: rolls.rolls, selected: $selectedRoll)
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        glassGroup {
            HStack {
                // Roll target selector
                Button { showRollPicker = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: selectedRoll == nil ? "person.fill" : "film.stack")
                            .font(.system(size: 12))
                        Text(selectedRoll?.name ?? "Personal")
                            .font(.system(size: 13, weight: .medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                }
                .glassCapsule(interactive: true)

                Spacer()

                // Upload status
                if photos.isUploading {
                    HStack(spacing: 6) {
                        ProgressView().tint(.white).controlSize(.mini)
                        Text("Developing…")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .glassCapsule()
                } else if photos.hasFailedUploads {
                    Button {
                        Task { await photos.retryFailedUploads() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.arrow.circlepath")
                                .font(.system(size: 12))
                            Text("Retry \(photos.failedUploads.count)")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Color(red: 0.8, green: 0.2, blue: 0.2).opacity(0.85), in: Capsule())
                    }
                }
            }
        }
        .padding(.top, 12)
        .padding(.horizontal, 20)
    }

    // MARK: - Film picker

    private var filmStrip: some View {
        VStack(spacing: 8) {
            Text("FILM")
                .font(.system(size: 10, weight: .semibold))
                .tracking(3)
                .foregroundStyle(FlimTheme.textTertiary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(FilmStock.catalog) { stock in
                        filmChip(stock)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 6)   // room for the selected chip's scale + glow
            }
            .scrollClipDisabled()
        }
        .opacity(filmStripActive ? 1 : 0.55)
        .animation(.easeInOut(duration: 0.35), value: filmStripActive)
    }

    @ViewBuilder
    private func filmChip(_ stock: FilmStock) -> some View {
        let isSelected = stock.id == selectedFilmID
        let label = Text(stock.name)
            .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? .black : .white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)

        Button {
            Haptics.tap()
            wakeFilmStrip()
            if stock.id != selectedFilmID {
                withAnimation(.snappy(duration: 0.25)) { selectedFilmID = stock.id }
            }
        } label: {
            if isSelected {
                label
                    .background(FlimTheme.accent, in: Capsule())
                    .shadow(color: FlimTheme.accent.opacity(0.55), radius: 8)
            } else {
                label.glassCapsule(interactive: true)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isSelected ? 1.06 : 0.94)
        .animation(.snappy(duration: 0.25), value: isSelected)
    }

    /// Brings the film strip to full opacity, then fades it back out after a few idle seconds.
    private func wakeFilmStrip() {
        filmStripActive = true
        dimTask?.cancel()
        dimTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.5)) { filmStripActive = false }
        }
    }

    // MARK: - Bottom bar (shutter)

    private var bottomBar: some View {
        ZStack {
            if #available(iOS 26, *) {
                Capsule()
                    .frame(width: 140, height: 96)
                    .glassEffect()
            } else {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .frame(width: 140, height: 96)
            }

            ShutterButton(isCapturing: camera.isCapturing) {
                Haptics.shutter()
                camera.capturePhoto()
            }
        }
    }

    // MARK: - Glass grouping

    /// Wraps glass children in a `GlassEffectContainer` on iOS 26 so they blend together;
    /// a plain passthrough on older systems.
    @ViewBuilder
    private func glassGroup<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: 16) { content() }
        } else {
            content()
        }
    }

    // MARK: - Wire capture → film filter → upload

    private func bindCapture() {
        camera.onPhotoCapture = { data in
            guard let userId = auth.currentUser?.id else { return }
            // Read the current roll + film selection at capture time.
            let rollId = selectedRoll?.id
            let rollName = selectedRoll?.name
            let stock = selectedStock
            Task {
                // Bake the instant-film look in, then upload. Fall back to the raw bytes
                // if processing ever fails so a photo is never lost.
                let processed = await InstantFilmProcessor.process(data, stock: stock) ?? data
                if let photo = await photos.captureAndUpload(imageData: processed, userId: userId, rollId: rollId) {
                    // Remind the user when this shot develops (local — no backend needed).
                    await notifications.requestAuthorizationIfNeeded()
                    notifications.scheduleDevelopNotification(
                        photoID: photo.id,
                        developsAt: photo.developsAt,
                        rollName: rollName
                    )
                }
            }
        }
    }
}

// MARK: - Shutter button

private struct ShutterButton: View {
    let isCapturing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.6), lineWidth: 3)
                    .frame(width: 70, height: 70)
                Circle()
                    .fill(.white)
                    .frame(width: 60, height: 60)
                    .scaleEffect(isCapturing ? 0.85 : 1)
            }
        }
        .animation(.spring(duration: 0.2, bounce: 0.4), value: isCapturing)
        .disabled(isCapturing)
    }
}

// MARK: - Roll picker sheet

private struct RollPickerSheet: View {
    let rolls: [Roll]
    @Binding var selected: Roll?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                FlimTheme.bg.ignoresSafeArea()
                List {
                    // Personal (no roll)
                    Button {
                        selected = nil
                        dismiss()
                    } label: {
                        HStack {
                            Label("Personal", systemImage: "person.fill")
                                .foregroundStyle(.white)
                            Spacer()
                            if selected == nil {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(FlimTheme.accent)
                            }
                        }
                    }
                    .listRowBackground(FlimTheme.bgElevated)

                    ForEach(rolls) { roll in
                        Button {
                            selected = roll
                            dismiss()
                        } label: {
                            HStack {
                                Label(roll.name, systemImage: "film.stack")
                                    .foregroundStyle(.white)
                                Spacer()
                                if selected?.id == roll.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(FlimTheme.accent)
                                }
                            }
                        }
                        .listRowBackground(FlimTheme.bgElevated)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Send to…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }.foregroundStyle(.white)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationBackground(FlimTheme.bg)
    }
}
