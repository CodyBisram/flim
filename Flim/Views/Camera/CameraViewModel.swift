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
        addVideoInput()
        if session.canAddOutput(output) {
            session.addOutput(output)
        }
        session.commitConfiguration()
    }

    private func addVideoInput() {
        guard let device = bestDevice(for: cameraPosition),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        configureZoomBaseline(for: device)
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
