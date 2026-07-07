import SwiftUI
import AVFoundation
import UIKit

struct CameraView: View {
    @Environment(AuthService.self) private var auth
    @Environment(PhotoService.self) private var photos
    @Environment(RollService.self) private var rolls
    @Environment(NotificationService.self) private var notifications
    @Environment(\.openURL) private var openURL

    @State private var camera = CameraViewModel()
    @State private var selectedRoll: Roll? = nil
    @State private var showRollPicker = false

    // Controls fade out when idle so the shutter stays the focal point; any
    // interaction wakes them back up.
    @State private var filmStripActive = false
    @State private var dimTask: Task<Void, Never>?

    // FLIM ships a single signature look.
    private var selectedStock: FilmStock { .original }

    // One-time intro that teaches the shoot → develop → darkroom loop.
    @AppStorage("hasSeenCameraCoach") private var hasSeenCoach = false
    // Self-timer: 0 (off), 3, or 10 seconds.
    @AppStorage("selfTimerSeconds") private var selfTimerSeconds = 0
    @State private var countdown: Int? = nil

    // Persisted hardware-flash mode (AVCaptureDevice.FlashMode rawValue: off=0, on=1, auto=2).
    @AppStorage("flashModeRaw") private var flashModeRaw = 0
    // Whether to schedule a local "your photo developed" reminder (toggled in Profile).
    @AppStorage("developNotificationsEnabled") private var notificationsEnabled = true
    @State private var unsortedCount = 0
    @State private var showSortDeck = false
    private var flashMode: AVCaptureDevice.FlashMode { AVCaptureDevice.FlashMode(rawValue: flashModeRaw) ?? .off }
    private var flashIcon: String {
        switch flashMode {
        case .on: return "bolt.fill"
        case .auto: return "bolt.badge.a.fill"
        default: return "bolt.slash.fill"
        }
    }
    private func cycleFlash() {
        let next: AVCaptureDevice.FlashMode = flashMode == .off ? .auto : (flashMode == .auto ? .on : .off)
        flashModeRaw = next.rawValue
        camera.flashMode = next
        Haptics.tap()
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreview(session: camera.session, camera: camera, onShutter: { shutter() })
                .ignoresSafeArea()
                // Tap-to-focus reticle.
                .overlay {
                    if let reticle = camera.focusReticle {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(FlimTheme.accent, lineWidth: 1.5)
                            .frame(width: 72, height: 72)
                            .position(reticle.point)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: camera.focusReticle)

            // Shutter flash overlay
            Color.white
                .opacity(camera.flashOpacity)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            if camera.permission == .denied {
                cameraDeniedOverlay
            } else {
                // Controls respect the safe area so they sit ABOVE the tab bar — only the
                // camera preview / flash bleed full-screen (they ignore safe area individually).
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    VStack(spacing: 16) {
                        bottomBar
                    }
                    // Zoom floats just above the shutter row.
                    .overlay(alignment: .top) { zoomControl.offset(y: -36) }
                    // Lifts the shutter off the tab bar so it sits ~centered between the film
                    // pills and the bottom bar, rather than hugging the tabs.
                    .padding(.bottom, 34)
                }

                coachOverlay

                // Self-timer countdown.
                if let countdown, countdown > 0 {
                    Text("\(countdown)")
                        .font(.system(size: 104, weight: .thin))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.4), radius: 12)
                        .transition(.scale.combined(with: .opacity))
                        .id(countdown)
                        .allowsHitTesting(false)
                }
            }
        }
        .fullScreenCover(isPresented: $showSortDeck, onDismiss: { Task { await refreshUnsorted() } }) {
            SortDeckView()
        }
        .onAppear {
            camera.flashMode = flashMode
            bindCapture()
            Task { await refreshUnsorted() }
            wakeFilmStrip()
            Task {
                await camera.start()
                if let userId = auth.currentUser?.id {
                    try? await rolls.fetchRolls(for: userId)
                }
            }
        }
        .onDisappear { camera.stopRunning() }
        .sheet(isPresented: $showRollPicker) {
            RollPickerSheet(rolls: rolls.rolls, closed: rolls.closedRollIds, selected: $selectedRoll)
        }
    }

    private func shutter() {
        if countdown != nil { countdown = nil; return }   // tapping again cancels the timer
        if selfTimerSeconds > 0 { startCountdown() } else { capture() }
    }

    private func capture() {
        Haptics.shutter()
        SoundFX.shutter()
        camera.capturePhoto()
    }

    private func startCountdown() {
        var remaining = selfTimerSeconds
        withAnimation(.snappy) { countdown = remaining }
        Task {
            while remaining > 0 {
                Haptics.tap()
                try? await Task.sleep(for: .seconds(1))
                guard countdown != nil else { return }   // cancelled
                remaining -= 1
                withAnimation(.snappy) { countdown = remaining }
            }
            countdown = nil
            capture()
        }
    }

    // MARK: - Zoom control

    private var zoomPresets: [CGFloat] {
        camera.supportsUltraWide ? [0.5, 1, 2] : [1, 2]
    }
    private var activeZoomPreset: CGFloat {
        zoomPresets.min(by: { abs($0 - camera.zoomFactor) < abs($1 - camera.zoomFactor) }) ?? 1
    }
    private func zoomLabel(_ z: CGFloat) -> String {
        z.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(z))×" : String(format: "%.1f×", z)
    }

    private var zoomControl: some View {
        HStack(spacing: 8) {
            ForEach(zoomPresets, id: \.self) { level in
                let active = level == activeZoomPreset
                Button {
                    withAnimation(.snappy(duration: 0.2)) { camera.zoom(to: level) }
                    Haptics.tap()
                    wakeFilmStrip()
                } label: {
                    Text(active ? zoomLabel(camera.zoomFactor) : zoomLabel(level))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(active ? .black : .white)
                        .frame(minWidth: 34, minHeight: 30)
                        .padding(.horizontal, active ? 5 : 0)
                        .background(active ? FlimTheme.accent : Color.black.opacity(0.35), in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(active ? 0 : 0.15), lineWidth: 1))
                }
                .accessibilityLabel("\(zoomLabel(level)) zoom")
                .accessibilityAddTraits(active ? [.isSelected] : [])
            }
        }
        .animation(.snappy(duration: 0.2), value: camera.zoomFactor)
        .opacity(filmStripActive ? 1 : 0.55)
        .animation(.easeInOut(duration: 0.35), value: filmStripActive)
    }

    private func refreshUnsorted() async {
        guard let uid = auth.currentUser?.id else { return }
        let count = await photos.fetchUnsorted(userId: uid).count
        await MainActor.run { withAnimation { unsortedCount = count } }
    }

    // MARK: - Top bar

    private var topBar: some View {
        glassGroup {
            HStack {
                // Roll target selector
                Button { showRollPicker = true; wakeFilmStrip() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: selectedRoll == nil ? "person.fill" : "film.stack")
                            .font(.system(size: 12))
                        Text(selectedRoll?.name ?? "Personal")
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: true, vertical: false)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                }
                .glassCapsule(interactive: true)
                .accessibilityLabel("Send photos to")
                .accessibilityValue(selectedRoll?.name ?? "Personal")

                // Flash toggle (Off → Auto → On) — hidden on the front camera (no flash).
                if camera.isFlashSupported {
                    Button {
                        cycleFlash()
                        wakeFilmStrip()
                    } label: {
                        Image(systemName: flashIcon)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(flashMode == .off ? .white : FlimTheme.accent)
                            .frame(width: 38, height: 38)
                    }
                    .glassCapsule(interactive: true)
                    .padding(.leading, 8)
                    .accessibilityLabel("Flash")
                    .accessibilityValue(flashMode == .off ? "Off" : (flashMode == .auto ? "Auto" : "On"))
                }

                // Flip between back and front cameras.
                Button {
                    camera.flipCamera()
                    Haptics.tap()
                    wakeFilmStrip()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                }
                .glassCapsule(interactive: true)
                .padding(.leading, 8)
                .accessibilityLabel("Flip camera")

                // Self-timer (Off → 3s → 10s). Minimal: dim when off, accent + value when set.
                Button {
                    selfTimerSeconds = selfTimerSeconds == 0 ? 3 : (selfTimerSeconds == 3 ? 10 : 0)
                    Haptics.tap()
                    wakeFilmStrip()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "timer").font(.system(size: 14, weight: .semibold))
                        if selfTimerSeconds > 0 {
                            Text("\(selfTimerSeconds)").font(.system(size: 12, weight: .bold))
                        }
                    }
                    .foregroundStyle(selfTimerSeconds == 0 ? .white : FlimTheme.accent)
                    .frame(minWidth: 38, minHeight: 38)
                    .padding(.horizontal, selfTimerSeconds > 0 ? 5 : 0)
                }
                .glassCapsule(interactive: true)
                .padding(.leading, 8)
                .accessibilityLabel("Self timer")
                .accessibilityValue(selfTimerSeconds == 0 ? "Off" : "\(selfTimerSeconds) seconds")

                Spacer()

                // Upload status — compact spinner only, so it can't crowd the top row.
                if photos.isUploading {
                    ProgressView().tint(.white).controlSize(.mini)
                        .frame(width: 38, height: 38)
                        .glassCapsule()
                        .accessibilityLabel("Developing")
                } else if photos.hasFailedUploads {
                    Button {
                        Task { await photos.retryFailedUploads() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.arrow.circlepath")
                                .font(.system(size: 12))
                            Text("Retry \(photos.failedUploads.count)")
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1).fixedSize()
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Color(red: 0.8, green: 0.2, blue: 0.2).opacity(0.85), in: Capsule())
                    }
                } else if unsortedCount > 0 {
                    // Shortcut into the sort deck — sits where the "Developing…" pill does.
                    Button { showSortDeck = true } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "square.stack.3d.up.fill").font(.system(size: 12))
                            Text("\(unsortedCount) to sort").font(.system(size: 13, weight: .semibold))
                                .lineLimit(1).fixedSize()
                        }
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(FlimTheme.accent, in: Capsule())
                    }
                    .accessibilityLabel("\(unsortedCount) to sort")
                }
            }
        }
        .padding(.top, 12)
        .padding(.horizontal, 20)
        .opacity(filmStripActive ? 1 : 0.55)
        .animation(.easeInOut(duration: 0.35), value: filmStripActive)
    }

    /// Brings the controls to full opacity, then fades them back out after a few idle seconds.
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
        ShutterButton(isCapturing: camera.isCapturing) { shutter() }
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

    // MARK: - Camera permission denied

    private var cameraDeniedOverlay: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(FlimTheme.accent)
            Text("Camera access needed")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.white)
            Text("FLIM needs your camera to take photos. Turn it on in Settings.")
                .font(.system(size: 14))
                .foregroundStyle(FlimTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 44)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            } label: {
                Text("Open Settings")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 13)
                    .background(FlimTheme.accent, in: Capsule())
            }
            .padding(.top, 8)
        }
        .padding(.bottom, 60)
    }

    // MARK: - First-run coachmark

    @ViewBuilder
    private var coachOverlay: some View {
        if !hasSeenCoach {
            ZStack {
                Color.black.opacity(0.74).ignoresSafeArea()

                VStack(spacing: 16) {
                    Image(systemName: "camera.aperture")
                        .font(.system(size: 38, weight: .ultraLight))
                        .foregroundStyle(FlimTheme.accent)

                    Text("Shoot now.\nSee it later.")
                        .font(.system(size: 24, weight: .light))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)

                    Text("Tap the shutter to take a photo. It stays hidden, then develops in a few minutes — your shots appear in the Darkroom.")
                        .font(.system(size: 15))
                        .foregroundStyle(FlimTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                        .padding(.top, 2)

                    Button {
                        Haptics.tap()
                        withAnimation(.easeInOut(duration: 0.3)) { hasSeenCoach = true }
                    } label: {
                        Text("Got it")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 40)
                            .padding(.vertical, 13)
                            .background(FlimTheme.accent, in: Capsule())
                    }
                    .padding(.top, 10)
                }
            }
            .transition(.opacity)
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
            // Serial pipeline: bakes the film look in + uploads one shot at a time, so a
            // rapid burst can't race and fail. Fires a local develop reminder on success.
            photos.enqueueCapture(rawData: data, stock: stock, userId: userId, rollId: rollId) { photo in
                await refreshUnsorted()   // keep the "to sort" count live as shots come in
                guard notificationsEnabled else { return }
                // Personal instants are ready immediately (no reminder). Roll shots share a
                // reveal — schedule ONE collapsed notification per roll, with your shot count.
                if let rollId, let rollName {
                    await notifications.requestAuthorizationIfNeeded()
                    let count = photos.photos.filter { $0.rollId == rollId && $0.userId == userId }.count
                    await notifications.scheduleRollDevelopNotification(
                        rollId: rollId, rollName: rollName,
                        developsAt: photo.developsAt, photoCount: count
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
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            ZStack {
                // A slow breathing halo that quietly invites the tap.
                Circle()
                    .stroke(.white.opacity(0.18), lineWidth: 2)
                    .frame(width: 84, height: 84)
                    .scaleEffect(pulse ? 1.14 : 0.94)
                    .opacity(pulse ? 0 : 0.9)
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
        .accessibilityLabel("Take photo")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.9).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}

// MARK: - Roll picker sheet

private struct RollPickerSheet: View {
    let rolls: [Roll]
    var closed: Set<UUID> = []
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
                        let isClosed = closed.contains(roll.id)
                        Button {
                            selected = roll
                            dismiss()
                        } label: {
                            HStack {
                                Label(roll.name, systemImage: "film.stack")
                                    .foregroundStyle(isClosed ? FlimTheme.textTertiary : .white)
                                if isClosed {
                                    Text("· developed")
                                        .font(.system(size: 12))
                                        .foregroundStyle(FlimTheme.textTertiary)
                                }
                                Spacer()
                                if selected?.id == roll.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(FlimTheme.accent)
                                }
                            }
                        }
                        .disabled(isClosed)
                        .listRowBackground(FlimTheme.bgElevated)
                    }

                    if rolls.isEmpty {
                        Text("Start a roll in the Rolls tab to share photos with friends — they'll all develop together.")
                            .font(.system(size: 13))
                            .foregroundStyle(FlimTheme.textTertiary)
                            .padding(.vertical, 8)
                            .listRowBackground(Color.clear)
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
