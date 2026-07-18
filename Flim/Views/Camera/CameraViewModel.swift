import AVFoundation
import Observation
import SwiftUI

@Observable
final class CameraViewModel: NSObject {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()

    var flashOpacity: Double = 0
    var isCapturing = false
    var capturedData: Data?
    var onPhotoCapture: ((Data) -> Void)?

    /// Hardware flash mode for the LED (distinct from `flashOpacity`, the on-screen
    /// shutter blink). Off by default; the camera UI cycles Off → Auto → On.
    var flashMode: AVCaptureDevice.FlashMode = .off

    /// Whether this device/camera actually has a flash to toggle.
    var isFlashSupported: Bool { output.supportedFlashModes.contains(.on) }

    enum Permission { case unknown, authorized, denied }
    var permission: Permission = .unknown

    /// Which camera is active. Front has no hardware flash, so the UI hides the flash toggle.
    var cameraPosition: AVCaptureDevice.Position = .back
    var isFront: Bool { cameraPosition == .front }

    // MARK: - Setup

    /// Requests camera access (if needed), then configures + starts the session. Sets
    /// `permission` so the UI can show a "grant access" state instead of a black screen.
    @MainActor
    func start() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permission = .authorized
        case .notDetermined:
            permission = await AVCaptureDevice.requestAccess(for: .video) ? .authorized : .denied
        default:
            permission = .denied
        }
        guard permission == .authorized else { return }
        configure()
        startRunning()
    }

    func configure() {
        guard session.inputs.isEmpty else { return }

        session.beginConfiguration()
        session.sessionPreset = .photo
        // Output added before the input so `configurePreviewFormat(for:)` below can set
        // `output.maxPhotoDimensions` against an output that's already attached.
        if session.canAddOutput(output) {
            session.addOutput(output)
        }
        addVideoInput()
        session.commitConfiguration()
    }

    private func addVideoInput() {
        guard let device = bestDevice(for: cameraPosition),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        // Format first, zoom baseline second: reassigning `activeFormat` inside
        // `configurePreviewFormat` can reset the device's raw `videoZoomFactor`, so setting
        // the "open on the main lens" zoom before that would get silently clobbered back to
        // the ultra-wide's 1.0 raw factor on devices where the format swap actually happens.
        configurePreviewFormat(for: device)
        configureZoomBaseline(for: device)
    }

    /// The `.photo` preset's default format pick optimizes for full-resolution stills, not
    /// a smooth preview — on most devices that pick tops out at 24-30fps, which read as
    /// visibly choppier panning next to Lapse's 60fps viewfinder. This looks for a format
    /// that is a PARITY match for that `.photo` baseline (same or better photo resolution,
    /// same field of view, same pixel format, and — for virtual multi-lens devices — the
    /// same constituent-lens zoom breakpoints) and only differs in frame rate. That keeps
    /// the fast path structurally identical to the default pick, just faster: it can never
    /// silently drop a lens (0.5× pill disappearing), narrow the field of view, change the
    /// pixel format (e.g. HDR x420 vs 420f), or win a tie by undocumented array order,
    /// because a non-matching format is never a candidate in the first place. If nothing
    /// beats the baseline's frame rate under those constraints, this leaves `.photo`'s own
    /// pick alone — preview smoothness is never traded for photo quality or zoom behavior.
    private func configurePreviewFormat(for device: AVCaptureDevice) {
        // The `.photo` preset's own pick, captured before anything is touched — every
        // candidate below is compared against THIS, not the global best across formats.
        let baseline = device.activeFormat
        let baselineSwitchOverFactors = device.virtualDeviceSwitchOverVideoZoomFactors
        guard let baselinePhotoArea = baseline.supportedMaxPhotoDimensions
            .map({ Int($0.width) * Int($0.height) }).max() else { return }
        let baselineFOV = baseline.videoFieldOfView
        let baselineSubType = baseline.formatDescription.mediaSubType

        let candidates = device.formats.filter { format in
            let photoArea = format.supportedMaxPhotoDimensions
                .map { Int($0.width) * Int($0.height) }.max() ?? 0
            guard photoArea >= baselinePhotoArea else { return false }
            guard abs(format.videoFieldOfView - baselineFOV) < 0.1 else { return false }
            guard format.formatDescription.mediaSubType == baselineSubType else { return false }
            return true
        }
        guard let target = candidates.max(by: {
            ($0.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0) <
            ($1.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
        }) else { return }

        let ceiling = target.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
        guard ceiling > 30.5 else { return }
        let targetFPS = min(ceiling, 60)
        // The candidate must actually declare support for the fps we're about to request —
        // `maxFrameRate` alone doesn't guarantee every rate up to it is achievable.
        guard target.videoSupportedFrameRateRanges.contains(where: {
            $0.minFrameRate <= targetFPS && targetFPS <= $0.maxFrameRate
        }) else { return }

        guard (try? device.lockForConfiguration()) != nil else { return }
        // Manual format selection needs input-priority — `.photo` would otherwise snap the
        // format back to its own pick the moment configuration commits.
        session.sessionPreset = .inputPriority
        device.activeFormat = target
        // The constituent-lens switch-over breakpoints can only be verified once the format
        // is actually active — this is a no-op equality check on non-virtual devices (both
        // arrays are empty). If activating the format changed them, the 0.5×/1×/2× pill
        // mapping would silently break, so revert to the untouched baseline instead.
        guard device.virtualDeviceSwitchOverVideoZoomFactors == baselineSwitchOverFactors else {
            device.activeFormat = baseline
            device.unlockForConfiguration()
            session.sessionPreset = .photo
            return
        }
        // Only cap the ceiling at 60fps; leave the floor at the format's own default so
        // auto exposure can still legitimately drop the frame rate in low light (expected
        // behavior — not fought here).
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(targetFPS))
        device.unlockForConfiguration()

        if let maxDims = target.supportedMaxPhotoDimensions.max(by: { $0.width * $0.height < $1.width * $1.height }) {
            output.maxPhotoDimensions = maxDims
        }
    }

    /// Prefer a multi-lens back camera so 0.5× (ultra-wide) is available; fall back to the plain
    /// wide lens (and always wide for the selfie camera, which has no ultra-wide).
    private func bestDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        if position == .back {
            for type in [AVCaptureDevice.DeviceType.builtInTripleCamera, .builtInDualWideCamera] {
                if let device = AVCaptureDevice.default(type, for: .video, position: .back) { return device }
            }
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    }

    /// Switches between the back and front cameras.
    func flipCamera() {
        cameraPosition = isFront ? .back : .front
        session.beginConfiguration()
        // Reset to the known-good baseline before re-deriving it for the new lens —
        // `configurePreviewFormat(for:)` (called from `addVideoInput`) only upgrades to
        // `.inputPriority` when it finds a format that beats this, so a lens without a
        // faster-than-30fps full-res option deterministically lands back on `.photo`
        // rather than inheriting `.inputPriority` left over from the other camera.
        session.sessionPreset = .photo
        session.inputs.forEach { session.removeInput($0) }
        addVideoInput()   // re-reads the new lens layout + resets zoom to 1×
        session.commitConfiguration()
    }

    // MARK: - Focus & zoom

    /// The screen point of the last tap-to-focus, for a brief reticle. `nil` when hidden.
    struct FocusReticle: Equatable { let id = UUID(); let point: CGPoint }
    var focusReticle: FocusReticle?

    private var currentDevice: AVCaptureDevice? {
        session.inputs.compactMap { $0 as? AVCaptureDeviceInput }.first?.device
    }
    /// Live DISPLAY zoom (what the pills show: 0.5×, 1×, 2×…). Updated by pinch + preset taps.
    var zoomFactor: CGFloat = 1
    var currentZoom: CGFloat { zoomFactor }
    /// True when the active camera has an ultra-wide lens (so 0.5× is offered).
    var supportsUltraWide = false
    /// The raw `videoZoomFactor` that equals "1×" on this device. On a device with an ultra-wide
    /// lens, factor 1.0 is the 0.5× lens and the main lens starts at the switch-over factor.
    private var baseZoomFactor: CGFloat = 1
    /// Lowest display zoom (0.5 when an ultra-wide is present, else 1).
    var minDisplayZoom: CGFloat { 1 / baseZoomFactor }

    /// Reads the active device's lens layout to map display zoom ↔ raw zoom, and opens at 1×.
    private func configureZoomBaseline(for device: AVCaptureDevice) {
        let switchOver = device.virtualDeviceSwitchOverVideoZoomFactors.first?.doubleValue ?? 1
        baseZoomFactor = CGFloat(switchOver)
        supportsUltraWide = baseZoomFactor > 1.001
        if (try? device.lockForConfiguration()) != nil {
            device.videoZoomFactor = baseZoomFactor   // open at the main lens (1×), not 0.5×
            device.unlockForConfiguration()
        }
        zoomFactor = 1
    }

    /// Tap-to-focus + set exposure at a device point (0–1), plus a reticle at the view point.
    func focus(atDevicePoint devicePoint: CGPoint, viewPoint: CGPoint) {
        if let device = currentDevice, (try? device.lockForConfiguration()) != nil {
            if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = devicePoint; device.focusMode = .autoFocus }
            if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = devicePoint; device.exposureMode = .autoExpose }
            device.unlockForConfiguration()
        }
        let reticle = FocusReticle(point: viewPoint)
        focusReticle = reticle
        Task { try? await Task.sleep(for: .seconds(1)); if focusReticle?.id == reticle.id { focusReticle = nil } }
    }

    /// `displayZoom` is what the user sees (0.5×, 1×, 2×…). Convert to the device's raw factor.
    func zoom(to displayZoom: CGFloat) {
        guard let device = currentDevice, (try? device.lockForConfiguration()) != nil else { return }
        let deviceMax = min(device.activeFormat.videoMaxZoomFactor, baseZoomFactor * 3)
        let rawFactor = max(1, min(displayZoom * baseZoomFactor, deviceMax))
        device.videoZoomFactor = rawFactor
        device.unlockForConfiguration()
        zoomFactor = rawFactor / baseZoomFactor
    }

    func startRunning() {
        guard !session.isRunning else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            self?.session.startRunning()
        }
    }

    func stopRunning() {
        guard session.isRunning else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            self?.session.stopRunning()
        }
    }

    // MARK: - Capture

    @MainActor
    func capturePhoto() {
        guard !isCapturing else { return }
        isCapturing = true

        // The on-screen flash overlay is NOT triggered here anymore. A real LED flash needs a
        // beat for AE/AF + preflash metering before it actually fires, so lighting up the screen
        // at tap time made the white flash arrive a full 1-2s before the real flash — reading as
        // a glitch on-device. The overlay is now driven by the capture delegate's
        // willCapturePhotoFor/didCapturePhotoFor callbacks below, which fire right as the real
        // exposure happens.

        let settings = AVCapturePhotoSettings()
        if output.supportedFlashModes.contains(flashMode) {
            settings.flashMode = flashMode
        }
        // Mirror front-camera shots so the saved photo matches the (mirrored) preview.
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = isFront
        }
        output.capturePhoto(with: settings, delegate: self)
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraViewModel: AVCapturePhotoCaptureDelegate {
    /// Fires right as the real exposure begins (after AE/AF + any preflash metering) — this is
    /// the correct moment for a flash-adjacent overlay, not the shutter tap.
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings
    ) {
        if resolvedSettings.isFlashEnabled {
            // The rear LED is about to fire — it IS the flash. A white screen overlay on top of
            // it reads as a glitch, so the rear+flash case shows no overlay at all.
            return
        }
        // Front camera has no LED, so an explicit "flash on" there means screen-as-flash: brighten
        // the display itself in place of hardware flash, timed to the real exposure. Every other
        // no-flash shot (front or rear) keeps a subtle blink so the shutter still feels responsive.
        // Delegate callbacks arrive on AVFoundation's queue, not main — hop before touching UI state.
        let opacity: Double = (isFront && flashMode == .on) ? 1 : 0.35
        Task { @MainActor in self.flashOpacity = opacity }
    }

    /// Fires once the exposure itself is finished — fade the overlay out here so its length always
    /// tracks the real capture instead of a timer guessed at tap time.
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings
    ) {
        let fade = resolvedSettings.isFlashEnabled ? 0.15 : 0.3
        Task { @MainActor in
            withAnimation(.easeOut(duration: fade)) { self.flashOpacity = 0 }
        }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let data = photo.fileDataRepresentation()
        Task { @MainActor in
            self.isCapturing = false
            self.flashOpacity = 0   // safety net in case the capture errored before the callbacks above fired
            guard let data else { return }
            self.capturedData = data
            self.onPhotoCapture?(data)
        }
    }
}
