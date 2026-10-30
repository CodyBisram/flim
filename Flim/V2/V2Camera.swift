import SwiftUI
import AVFoundation
import UIKit

/// Personal's camera, shared by the place and the closed display's column: the shutter sits in
/// the place on the phone and the open display, and at the foot of the column on the closed one
/// (board 15a), so the session, the roll it shoots into and the capture wiring live here rather
/// than in either view.
///
/// The capture path is the App Store camera's own (`CameraView`): the same `CameraViewModel`,
/// `CameraPreview` and `PhotoService.enqueueCapture`, with the same roll rules. Only the screen
/// around it is new. Where this repeats `CameraView`, it says so, so a fix to one is made in both.
@MainActor
@Observable
final class V2Camera {
    let model = CameraViewModel()

    /// The roll the next shot goes into; nil is Personal. Persisted per account through
    /// `CameraRollSelection`, as the App Store camera does.
    var selectedRoll: Roll?
    /// A shot meant for a roll that developed first landed in the Darkroom instead
    /// (`PhotoService.captureAsPersonalFallback`). Shown once in the footer.
    var fallbackNotice = false

    private(set) var flashOn: Bool = UserDefaults.standard.integer(forKey: V2Camera.flashKey) == AVCaptureDevice.FlashMode.on.rawValue

    private var auth: AuthService?
    private var photos: PhotoService?
    private var rolls: RollService?
    private var notifications: NotificationService?

    /// The App Store camera's key. FLIM Beta is its own app with its own defaults, so the two
    /// never share the value; the beta only offers off and on (the design's "flash off" and
    /// "flash on").
    static let flashKey = "flashModeRaw"

    func attach(auth: AuthService, photos: PhotoService, rolls: RollService, notifications: NotificationService) {
        self.auth = auth
        self.photos = photos
        self.rolls = rolls
        self.notifications = notifications
    }

    // MARK: Session

    /// Starts (or restarts) the session. Same order as `CameraView.startCameraFlow`: mark the
    /// session wanted in the appear's own turn, so a disappear that lands first can cancel it.
    func start() {
        #if DEBUG
        // `-v2NoCamera`: screenshots of the other places, which launch through Personal, without
        // the camera's access prompt over them.
        if ProcessInfo.processInfo.arguments.contains("-v2NoCamera") { return }
        #endif
        model.markSessionWanted()
        model.flashMode = flashOn ? .on : .off
        Haptics.prepare()
        bindCapture()
        Task {
            await model.start()
            if let userId = auth?.currentUser?.id, let rolls {
                try? await rolls.fetchRolls(for: userId)
                restoreSelectedRoll(userId: userId)
            }
        }
    }

    func stop() {
        model.stopRunning()
        // A countdown must not fire into a stopped session (as `CameraView.onDisappear`).
        countdown = nil
    }

    // MARK: Controls

    /// The self-timer: off, 3 or 10 seconds. The App Store camera's key, so the choice carries.
    var timerSeconds: Int = UserDefaults.standard.integer(forKey: V2Camera.timerKey) {
        didSet { UserDefaults.standard.set(timerSeconds, forKey: Self.timerKey) }
    }
    static let timerKey = "selfTimerSeconds"
    /// Seconds left on a running self-timer.
    var countdown: Int?

    /// Takes the picture, or starts the self-timer; pressed again during a countdown, cancels it
    /// (as `CameraView.shutter`).
    func shutter() {
        if countdown != nil { countdown = nil; return }
        guard !model.isInterrupted else { Haptics.error(); return }
        if timerSeconds > 0 { startCountdown() } else { capture() }
    }

    func cycleTimer() {
        timerSeconds = timerSeconds == 0 ? 3 : (timerSeconds == 3 ? 10 : 0)
        Haptics.tap()
    }

    static let firstShotKey = "v2FirstShotTaken"

    private func capture() {
        guard !model.isInterrupted else { Haptics.error(); return }
        UserDefaults.standard.set(true, forKey: Self.firstShotKey)
        Haptics.shutter()
        // No app shutter sound: AVCapturePhotoOutput plays the system one at the real capture.
        model.capturePhoto()
    }

    private func startCountdown() {
        var remaining = timerSeconds
        withAnimation(.snappy) { countdown = remaining }
        Task { @MainActor in
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

    func toggleFlash() {
        flashOn.toggle()
        let mode: AVCaptureDevice.FlashMode = flashOn ? .on : .off
        UserDefaults.standard.set(mode.rawValue, forKey: Self.flashKey)
        model.flashMode = mode
        Haptics.tap()
    }

    func flip() {
        model.flipCamera()
        Haptics.tap()
    }

    var zoomPresets: [CGFloat] { model.supportsUltraWide ? [0.5, 1, 2] : [1, 2] }

    var activeZoomPreset: CGFloat {
        zoomPresets.min(by: { abs($0 - model.zoomFactor) < abs($1 - model.zoomFactor) }) ?? 1
    }

    func zoom(to level: CGFloat) {
        withAnimation(.snappy(duration: 0.2)) { model.zoom(to: level) }
        Haptics.tap()
    }

    /// Back to Personal: the footer's "tap to stop".
    func stopShootingIntoRoll() {
        selectedRoll = nil
        persistSelectedRoll()
        Haptics.tap()
    }

    func select(_ roll: Roll) {
        guard !roll.isDeveloped else { return }
        selectedRoll = roll
        persistSelectedRoll()
    }

    // MARK: Roll selection (as `CameraView`)

    private func restoreSelectedRoll(userId: UUID) {
        guard let savedId = CameraRollSelection.savedRollId(for: userId) else { return }
        if let roll = rolls?.rolls.first(where: { $0.id == savedId }), !roll.isDeveloped {
            selectedRoll = roll
        } else {
            CameraRollSelection.save(nil, for: userId)
            selectedRoll = nil
        }
    }

    private func persistSelectedRoll() {
        guard let userId = auth?.currentUser?.id else { return }
        CameraRollSelection.save(selectedRoll?.id, for: userId)
    }

    // MARK: Capture → film look → upload (as `CameraView.bindCapture`)

    private func bindCapture() {
        model.onPhotoCapture = { [weak self] data in
            guard let self, let photos = self.photos, let userId = self.auth?.currentUser?.id else { return }
            let rollId = self.selectedRoll?.id
            let rollName = self.selectedRoll?.name
            let knownRevealAt = self.selectedRoll?.revealAt
            let notifications = self.notifications
            let notificationsEnabled = UserDefaults.standard.object(forKey: "developNotificationsEnabled") as? Bool ?? true
            photos.enqueueCapture(rawData: data, stock: .original, userId: userId, rollId: rollId,
                                  knownRevealAt: knownRevealAt,
                                  previewAspect: self.model.previewAspectRatio) { photo in
                guard notificationsEnabled, let notifications else { return }
                // Gated on the photo's own roll, not the one chosen at capture: a roll that
                // developed mid-upload sends the shot to the Darkroom instead.
                if let landedRollId = photo.rollId, let rollName {
                    await notifications.requestAuthorizationIfNeeded()
                    let count = await photos.rollPhotoCount(rollId: landedRollId, userId: userId)
                    await notifications.scheduleRollDevelopNotification(
                        rollId: landedRollId, rollName: rollName,
                        developsAt: photo.developsAt, photoCount: count, userId: userId
                    )
                }
            }
        }
    }
}

// MARK: - Personal

/// Personal: the viewfinder as a print on the desk (board 3a, prototype). On the phone the shutter
/// sits under it between Flip and Rolls; on the closed display it is in the column; open, it sits
/// beside the footer under the print, with Rolls.
struct V2PersonalPlace: View {
    let camera: V2Camera
    var rollsHaveUnwatched = false
    var openRolls: () -> Void

    @Environment(\.v2LayoutMode) private var mode
    @Environment(\.v2Palette) private var palette
    @Environment(AuthService.self) private var auth
    @Environment(PhotoService.self) private var photos
    @Environment(RollService.self) private var rolls
    @Environment(NotificationService.self) private var notifications
    @Environment(NetworkMonitor.self) private var network
    // The camera asks for access in `start()`, so it waits for onboarding, as `CameraView` does.
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @AppStorage(V2Camera.firstShotKey) private var firstShotTaken = false

    var body: some View {
        GeometryReader { proxy in
            switch mode {
            case .phone: phone(proxy.size)
            case .outer: outer(proxy.size)
            case .inner: inner(proxy.size)
            }
        }
        .onAppear {
            camera.attach(auth: auth, photos: photos, rolls: rolls, notifications: notifications)
            if hasOnboarded { camera.start() }
        }
        .onChange(of: hasOnboarded) { _, done in
            if done { camera.start() }
        }
        .onDisappear { camera.stop() }
        .onReceive(NotificationCenter.default.publisher(for: .selectCameraRoll)) { note in
            if let roll = note.object as? Roll { camera.select(roll) }
        }
        .onChange(of: photos.personalFallbackCount) { _, count in
            guard count > 0 else { return }
            Haptics.success()
            withAnimation { camera.fallbackNotice = true }
            Task {
                try? await Task.sleep(for: .seconds(4))
                withAnimation { camera.fallbackNotice = false }
            }
        }
    }

    // MARK: Arrangements

    /// Print, then Flip, the shutter and Rolls, then the footer line (prototype, 402 × 874).
    private func phone(_ size: CGSize) -> some View {
        let controls: CGFloat = 78 + 26 + 44
        let width = printWidth(in: CGSize(width: size.width - V2CameraMetrics.printInset * 2,
                                          height: size.height - controls - 8))
        return VStack(spacing: 0) {
            printCard(width: width, flipInFoot: false)
                .padding(.top, 6)
            Spacer(minLength: 16)
            ZStack {
                V2Shutter(camera: camera, diameter: 78)
                HStack {
                    word("Flip") { camera.flip() }
                        .accessibilityLabel("Flip camera")
                    Spacer()
                    V2RollsButton(hasUnwatched: rollsHaveUnwatched, open: openRolls)
                }
                .padding(.horizontal, 36)
            }
            Spacer(minLength: 10)
            footer
                .frame(maxWidth: .infinity)
                .padding(.bottom, 18)
        }
        .frame(width: size.width, height: size.height)
    }

    /// The print fills the left; the footer sits under it. Shutter and Rolls are in the column.
    private func outer(_ size: CGSize) -> some View {
        let width = printWidth(in: CGSize(width: size.width - V2Metrics.margin * 2,
                                          height: size.height - 64))
        return VStack(alignment: .leading, spacing: 0) {
            printCard(width: width, flipInFoot: true)
            footer
                .padding(.top, 18)
            Spacer(minLength: 0)
        }
        .padding(.top, 12)
        .padding(.horizontal, V2Metrics.margin)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    /// Open: the print, and under it the footer, Rolls and the shutter in one row (board 15d).
    private func inner(_ size: CGSize) -> some View {
        let row: CGFloat = 72
        let width = printWidth(in: CGSize(width: size.width - V2Metrics.margin * 2,
                                          height: size.height - row - 32))
        // Held together and centred: held upright, the half is tall and narrow, and a shutter
        // at the very bottom would sit a long way from the print it takes.
        return VStack(spacing: 18) {
            printCard(width: width, flipInFoot: true)
            HStack(spacing: 20) {
                footer
                Spacer(minLength: 8)
                V2RollsButton(hasUnwatched: rollsHaveUnwatched, open: openRolls)
                V2Shutter(camera: camera, diameter: 58)
            }
            .frame(width: max(width, 0))
        }
        .padding(.vertical, 12)
        .frame(width: size.width, height: size.height)
    }

    private func printWidth(in box: CGSize) -> CGFloat {
        min(V2CameraMetrics.maxPrintWidth, V2PrintGeometry.width(fitting: box))
    }

    // MARK: The print

    private func printCard(width: CGFloat, flipInFoot: Bool) -> some View {
        V2PrintCard(width: width) {
            viewfinder
        } foot: {
            HStack(spacing: 14) {
                ForEach(camera.zoomPresets, id: \.self) { level in
                    let active = level == camera.activeZoomPreset
                    Button { camera.zoom(to: level) } label: {
                        Text(Self.zoomLabel(level))
                            .font(V2Type.control())
                            .foregroundStyle(active ? V2Color.printInk : V2Color.printInk3)
                            .frame(minWidth: 28, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(Self.zoomLabel(level)) zoom")
                    .accessibilityAddTraits(active ? .isSelected : [])
                }
                Spacer(minLength: 8)
                Button { camera.cycleTimer() } label: {
                    Text(camera.timerSeconds == 0 ? "timer off" : "\(camera.timerSeconds)s")
                        .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
                        .foregroundStyle(camera.timerSeconds == 0 ? V2Color.printInk3 : V2Color.printInk)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Self timer")
                .accessibilityValue(camera.timerSeconds == 0 ? "Off" : "\(camera.timerSeconds) seconds")
                if camera.model.isFlashSupported {
                    Button { camera.toggleFlash() } label: {
                        Text(camera.flashOn ? "flash on" : "flash off")
                            .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
                            .foregroundStyle(V2Color.printInk3)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Flash")
                    .accessibilityValue(camera.flashOn ? "On" : "Off")
                }
                if flipInFoot {
                    Spacer(minLength: 8)
                    Button { camera.flip() } label: {
                        Text("Flip")
                            .font(V2Type.control())
                            .foregroundStyle(V2Color.printInk)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Flip camera")
                }
            }
            .padding(.horizontal, 4)
        }
        // The press: the print gives a little under the shutter (prototype, 0.12 s).
        .scaleEffect(camera.model.isCapturing ? 0.985 : 1)
        .animation(.easeOut(duration: 0.12), value: camera.model.isCapturing)
    }

    @ViewBuilder
    private var viewfinder: some View {
        if camera.model.permission == .denied {
            V2CameraDenied()
        } else {
            CameraPreview(session: camera.model.session, camera: camera.model, onShutter: { camera.shutter() })
                .overlay {
                    if let reticle = camera.model.focusReticle {
                        Rectangle()
                            .stroke(V2Color.print.opacity(0.9), lineWidth: 1)
                            .frame(width: 64, height: 64)
                            .position(reticle.point)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: camera.model.focusReticle)
                // The flash is the print's own cream, not white.
                .overlay {
                    V2Color.print
                        .opacity(camera.model.flashOpacity)
                        .allowsHitTesting(false)
                }
                .overlay { interrupted }
                // The self-timer counting down, in the stamp's segment type.
                .overlay {
                    if let countdown = camera.countdown, countdown > 0 {
                        Text("\(countdown)")
                            .font(V2Type.data(96))
                            .foregroundStyle(V2Color.print)
                            .shadow(color: .black.opacity(0.45), radius: 10)
                            .transition(.scale.combined(with: .opacity))
                            .id(countdown)
                            .allowsHitTesting(false)
                            .accessibilityLabel("\(countdown)")
                    }
                }
                .onChange(of: camera.model.isInterrupted) { _, now in if now { camera.countdown = nil } }
                .animation(.easeOut(duration: 0.2), value: camera.model.isInterrupted)
                .background(Color.black)
        }
    }

    /// The camera taken away: the last frame dimmed and one line saying why, never a blur (it
    /// does not work on the live video layer). Same states and copy as `CameraView`.
    @ViewBuilder
    private var interrupted: some View {
        if camera.model.isInterrupted {
            ZStack {
                Color.black.opacity(0.6)
                VStack(spacing: 10) {
                    Text("Camera unavailable")
                        .font(V2Type.serif(17, relativeTo: .headline))
                    if let reason = camera.model.interruptionReason {
                        Text(reason)
                            .font(V2Type.serif(13, italic: true, relativeTo: .footnote))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 28)
                    }
                    if camera.model.canRetryCamera {
                        Button {
                            Haptics.tap()
                            camera.model.retryCamera()
                        } label: {
                            Text(camera.model.isRestartingSession ? "Starting\u{2026}" : "Try again")
                                .font(V2Type.control())
                                .underline()
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .disabled(camera.model.isRestartingSession)
                    }
                }
                .foregroundStyle(V2Color.print)
            }
            .transition(.opacity)
        }
    }

    // MARK: The footer line

    /// Under the camera: the roll it shoots into, with its clock and a way back to Personal; a
    /// shot that still needs you; or the day, as a caption would be written.
    @ViewBuilder
    private var footer: some View {
        if camera.fallbackNotice {
            footerText("That roll isn't accepting shots anymore, so this one went to your Darkroom instead.")
        } else if let status = captureStatus, status.attention {
            Button {
                if status.canRetry { Task { await photos.retryFailedUploads() } }
            } label: {
                footerText(status.canRetry ? "\(status.title) · Retry" : status.title)
            }
            .buttonStyle(.plain)
            .disabled(!status.canRetry)
        } else if let roll = camera.selectedRoll, !roll.isDeveloped {
            Button { camera.stopShootingIntoRoll() } label: {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    footerText("Shooting into \(roll.name) · \(V2Clock.until(roll.revealAt, now: context.date)) · tap to stop")
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shoots into Personal again")
        } else if !firstShotTaken {
            // The first print is the tutorial: one line, until it is taken (board 9b).
            footerText("Take one. You'll see it in a while.")
        } else {
            TimelineView(.everyMinute) { context in
                footerText(V2Clock.dayPart(context.date))
            }
        }
    }

    private func footerText(_ text: String) -> some View {
        Text(text)
            .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
            .foregroundStyle(palette.ink3)
            .lineLimit(2)
            .multilineTextAlignment(mode == .phone ? .center : .leading)
    }

    private var captureStatus: CaptureStatus? {
        CaptureStatus.derive(localSaveFailed: photos.localSaveFailed,
                             pendingCount: photos.pendingCaptureCount,
                             isUploading: photos.isUploading,
                             failedCount: photos.failedUploads.count,
                             connected: network.isConnected,
                             justUploaded: false)
    }

    private func word(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(V2Type.control())
                .foregroundStyle(palette.ink2)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    static func zoomLabel(_ z: CGFloat) -> String {
        z.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(z))×" : String(format: "%.1f×", z)
    }
}


enum V2CameraMetrics {
    /// The prototype's print: 340 wide on a 402 phone, 31 in from each side.
    static let printInset: CGFloat = 31
    /// Past this the print would only grow, not show more: the open display keeps the phone's size.
    static let maxPrintWidth: CGFloat = 380
}

/// The shutter: a solid disc in ink with a ring inside, on any desk (prototype). One of only two
/// circles in v2, with avatars.
struct V2Shutter: View {
    let camera: V2Camera
    var diameter: CGFloat = 78

    @Environment(\.v2Palette) private var palette

    var body: some View {
        Button { camera.shutter() } label: {
            Circle()
                .fill(palette.ink)
                .frame(width: diameter, height: diameter)
                .overlay {
                    Circle()
                        .stroke(palette.background.opacity(0.35), lineWidth: 1.5)
                        .padding(diameter * 7 / 78)
                }
                .scaleEffect(camera.model.isCapturing ? 0.92 : 1)
                .shadow(color: palette.isDark ? .black.opacity(0.5) : V2Color.rgb(0x2A2420, opacity: 0.3),
                        radius: 9, y: 6)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(.spring(duration: 0.2, bounce: 0.3), value: camera.model.isCapturing)
        .disabled(camera.model.isCapturing || camera.model.isInterrupted)
        .opacity(camera.model.isInterrupted ? 0.35 : 1)
        .accessibilityLabel("Take photo")
        .accessibilityHint(camera.model.isInterrupted ? "Camera unavailable" : "")
    }
}

/// The window when camera access is off: where the switch is, and the rest of the app still
/// works. Same words as `CameraView`'s refusal.
private struct V2CameraDenied: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            V2Color.rgb(0x1C1917)
            VStack(spacing: 14) {
                Text("\(AppInfo.appName) can't use the camera")
                    .font(V2Type.serif(19, relativeTo: .title3))
                    .multilineTextAlignment(.center)
                Text("Camera access is off for \(AppInfo.appName) in iOS Settings. You can still see your friends' photos and reply to them.")
                    .font(V2Type.serif(13, italic: true, relativeTo: .footnote))
                    .multilineTextAlignment(.center)
                    .opacity(0.8)
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                } label: {
                    Text("Open Settings")
                        .font(V2Type.control())
                        .underline()
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(V2Color.print)
            .padding(.horizontal, 24)
        }
    }
}

/// The camera's footer clock and caption.
enum V2Clock {
    /// "02:14:09" to a roll opening, "1D 04:10" past a day; "OPEN" once it has (prototype).
    static func until(_ date: Date, now: Date) -> String {
        let remaining = max(0, Int(date.timeIntervalSince(now)))
        guard remaining > 0 else { return "OPEN" }
        let days = remaining / 86_400, hours = remaining % 86_400 / 3_600
        let minutes = remaining % 3_600 / 60, seconds = remaining % 60
        let pad = { (n: Int) in String(format: "%02d", n) }
        return days > 0 ? "\(days)D \(pad(hours)):\(pad(minutes))" : "\(pad(hours)):\(pad(minutes)):\(pad(seconds))"
    }

    /// "Tuesday evening": the day as the prototype writes it under the camera, without the
    /// place, which FLIM does not read.
    static func dayPart(_ date: Date, calendar: Calendar = .current) -> String {
        let weekday = date.formatted(.dateTime.weekday(.wide))
        let hour = calendar.component(.hour, from: date)
        let part: String
        switch hour {
        case 5..<12: part = "morning"
        case 12..<17: part = "afternoon"
        case 17..<21: part = "evening"
        default: part = "night"
        }
        return "\(weekday) \(part)"
    }
}
