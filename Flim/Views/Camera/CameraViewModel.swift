import AVFoundation
import CoreMedia
import Observation
import SwiftUI
import UIKit
import os

/// Main-actor isolated, like `PhotoService` and `DarkroomViewModel`.
///
/// This was the one `@Observable` view model left with no class-level isolation: only
/// `start()`, `capturePhoto()` and `startCaptureWatchdog` were individually marked `@MainActor`,
/// which left `focus(atDevicePoint:viewPoint:)` and the `AVCapturePhotoCaptureDelegate` callbacks
/// free to write tracked `@Observable` properties (`focusReticle`, `flashOpacity`, `isCapturing`,
/// `capturedData`) from whatever thread AVFoundation happened to call back on. `focus(...)`'s own
/// `Task { ... }` resumed on an arbitrary executor after its sleep and wrote `focusReticle` there;
/// `photoOutput(_:willCapturePhotoFor:)` read `isFront`/`flashMode` synchronously on AVFoundation's
/// delegate queue, one line above its own documented `@MainActor` hop. That is the same bug class
/// as the crash written up at the top of `DarkroomViewModel.swift`: a background thread mutating
/// state SwiftUI is reading on the main thread inside `libswiftObservation`.
///
/// Isolating the whole type makes the compiler enforce the hop instead of trusting every call site
/// to remember it. The genuinely off-main entry point is the `AVCapturePhotoCaptureDelegate`
/// conformance below, which AVFoundation invokes on its own queue, not main, those methods are
/// `nonisolated`, with an explicit hop where they need tracked state. `startRunning()`/
/// `stopRunning()` stay main-actor isolated like everything else here; they already hand the
/// actual blocking `session.startRunning()`/`stopRunning()` call to a detached task rather than
/// running it themselves, so being called from the main actor costs nothing more than kicking that
/// task off. `previewAspectRatio` stays `nonisolated` too: it is deliberately lock-protected,
/// written from the preview view's own main-thread layout pass and read from the capture
/// delegate's queue, and that cross-thread contract predates this change and is unrelated to
/// `@Observable` tracking.
@MainActor
@Observable
final class CameraViewModel: NSObject {
    /// `nonisolated` because `startRunning()`/`stopRunning()` call into it from a detached task
    /// (session start/stop are blocking calls that must never run on the main actor), and the
    /// capture delegate callbacks below reference it off-main too. `AVCaptureSession` manages its
    /// own internal synchronization for this kind of use; nothing here reassigns the reference
    /// after `init`, so the only thing crossing actors is the sharing of that one fixed instance.
    nonisolated let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    /// Face detection, purely to draw the viewfinder's focus rectangles. Nothing about capture or
    /// the film look reads this.
    let metadataOutput = AVCaptureMetadataOutput()

    /// Detected faces as rects in the PREVIEW VIEW's own coordinate space, already converted from
    /// the metadata coordinate space (which is buffer-relative, and mirrored on the front camera)
    /// by `CameraPreview`, the only place that owns the preview layer needed to do it.
    var faceRects: [CGRect] = []

    var flashOpacity: Double = 0
    var isCapturing = false
    var capturedData: Data?
    var onPhotoCapture: ((Data) -> Void)?

    /// Bumped at the start of every `capturePhoto()` call so the watchdog Task it starts can
    /// tell whether it's still describing the current capture by the time it wakes up, see
    /// `capturePhoto()` for why this matters.
    private var captureGeneration = 0

    /// True between `willCapturePhotoFor` (exposure beginning) and `didCapturePhotoFor` (exposure
    /// done). The watchdog reads this so it never tears down the screen flash while the sensor is
    /// genuinely mid-exposure, which would darken the shot it was lighting.
    private var isExposing = false

    /// The screen-flash's REAL light source: raises the display's actual backlight to full for a
    /// front-camera flash capture, restored afterwards. Before this, "screen flash" only drew a
    /// white SwiftUI overlay (`flashOpacity` below) on top of whatever brightness the display
    /// already happened to be at, which in a dark room (auto-brightness near its floor, exactly
    /// when anyone reaches for a screen flash) emitted almost no light. See
    /// `RestorableOverride`'s own doc for why restoration is structured this way rather than
    /// called by hand at every exit path (success, error, watchdog timeout, backgrounding,
    /// flipping cameras, navigating away).
    private let screenBrightness = RestorableOverride<CGFloat>()

    /// Caps continuous AE's own worst-case exposure duration to 1/8s (clamped into whatever the
    /// active format actually allows) for the duration of a front-camera screen-flash capture,
    /// restored afterwards exactly like `screenBrightness` above.
    ///
    /// This was prototyped alongside `screenBrightness` and deliberately left unshipped on the
    /// theory that `screenBrightness` alone would remove the slow-exposure "hang" this whole fix
    /// exists for, since AE would meter a genuinely lit scene instead of gathering light for
    /// several seconds. Reported on-device as not enough on its own: the screen is a much weaker,
    /// more diffuse light source than a real flash, so in the dim rooms this feature exists for, a
    /// brightened screen can still leave AE reaching for a multi-second exposure. That is the
    /// leading candidate for the remaining three seconds, not a second, OS-driven flash stacked on
    /// top of this one: front-camera `AVCapturePhotoSettings.flashMode` can only ever resolve to
    /// `.off`
    /// (see `capturePhoto()`'s own `output.supportedFlashModes.contains(flashMode)` guard, and
    /// `AVCaptureDevice.hasFlash`, which gates it, is hardware-only and false for every front
    /// camera), so there is no Retina-Flash-style second sequence to strip out here, only a real,
    /// uncapped exposure to bound. `waitForExposureToSettle` already polls
    /// `device.isAdjustingExposure` rather than assuming a fixed time, but it cannot make AE
    /// converge faster than AE itself is willing to, and once `output.capturePhoto` is triggered
    /// the still capture's own exposure is entirely outside that wait's control; this cap bounds
    /// both. A hard ceiling can underexpose a scene the screen genuinely can't reach, which is why
    /// this is scoped to the front-flash path only (see `capturePhoto()`) rather than applied
    /// globally, same tradeoff `waitForExposureToSettle`'s own cap already makes.
    private let exposureCeiling = RestorableOverride<CMTime>()

    /// Hardware flash mode for the LED (distinct from `flashOpacity`, the on-screen
    /// shutter blink). Off by default; the camera UI cycles Off → Auto → On.
    var flashMode: AVCaptureDevice.FlashMode = .off

    /// Whether this device/camera actually has a flash to toggle.
    var isFlashSupported: Bool { output.supportedFlashModes.contains(.on) }

    enum Permission { case unknown, authorized, denied }
    var permission: Permission = .unknown

    /// Guards `Activation.log(.cameraAuthorized)` against firing on every single tab visit.
    /// `start()` runs on every `CameraView` appearance (see that file's own comment on
    /// `startCameraFlow()`), so without this an instance that lives for the whole app session
    /// would fire one RPC per tab switch back to Camera. The server already dedupes per
    /// (user, event), so this is purely a call-volume optimization, not a correctness guard,
    /// which is why it is safe to key on an in-memory, per-instance flag rather than a
    /// persisted one: it resets on every fresh launch (one harmless extra call, dropped by the
    /// server's own dedupe) instead of surviving a reinstall or account switch the way a
    /// `UserDefaults`-backed flag would, which is exactly the "local flag that lies" failure
    /// mode the other activation events avoid by leaning on server-side dedupe in the first
    /// place.
    private var hasLoggedCameraAuthorized = false

    /// Which camera is active. Front has no hardware flash, so the UI hides the flash toggle.
    var cameraPosition: AVCaptureDevice.Position = .back
    var isFront: Bool { cameraPosition == .front }

    /// Backing storage for `previewAspectRatio`, guarded by a lock: written from the main
    /// thread (`CameraPreview.PreviewView.layoutSubviews`) and read from
    /// `AVCapturePhotoOutput`'s delegate queue in `photoOutput(_:didFinishProcessingPhoto:error:)`
    ///, this file already documents elsewhere that delegate callbacks arrive off-main (see
    /// the flash-overlay handling above), so this cross-thread value needs the same kind of
    /// synchronization, unlike the plain properties above that are only ever mutated from
    /// inside a `Task { @MainActor in ... }` hop. `nonisolated` for the same reason: the lock,
    /// not the main actor, is what makes this one safe to touch from either side.
    nonisolated private let previewAspectRatioLock = OSAllocatedUnfairLock<CGFloat?>(initialState: nil)

    /// Live aspect ratio (width / height) the boxed (3:4) `.resizeAspectFill` viewfinder is
    /// actually showing on screen right now, pushed up from `CameraPreview`'s real view
    /// bounds every layout pass (mirrors how `excludedRegions` is threaded from the view
    /// layer, rather than sourced from a `UIScreen` constant). `nil` until the preview has
    /// laid out at least once. Used to crop the captured photo down to what was framed,
    /// see `photoOutput(_:didFinishProcessingPhoto:error:)`. Deliberately NOT `@Observable`-
    /// tracked in the way that matters here, since it is written and read from off-main threads
    /// (this class's own main-actor isolation does not apply to it, see the lock above).
    nonisolated var previewAspectRatio: CGFloat? {
        get { previewAspectRatioLock.withLock { $0 } }
        set { previewAspectRatioLock.withLock { $0 = newValue } }
    }

    /// Maps an in-flight capture's own `AVCapturePhotoSettings.uniqueID` to the `captureGeneration`
    /// it was taken under, so `photoOutput(_:didFinishProcessingPhoto:error:)` can tell a callback
    /// for the capture actually in flight now from a late callback for one the watchdog already
    /// gave up on (see `captureGeneration`). Keyed by uniqueID rather than just reading
    /// `captureGeneration` directly, because more than one capture can be in flight at once here:
    /// the watchdog resets `isCapturing` and lets the user shoot again while an abandoned capture's
    /// delegate call is still outstanding, so a single "current generation" value could not tell
    /// the two apart once a THIRD shot starts, it would already have moved past the second one too.
    /// Lock-protected for the same reason `previewAspectRatio` is: this delegate method is called
    /// off the main actor.
    nonisolated private let captureGenerationLock = OSAllocatedUnfairLock<[Int64: Int]>(initialState: [:])

    private nonisolated func rememberCaptureGeneration(_ generation: Int, forSettingsID id: Int64) {
        captureGenerationLock.withLock { $0[id] = generation }
    }

    /// Looks up and forgets the generation a given capture's settings ID was taken under. Removed
    /// on read so this map can't grow across a long session of shooting.
    private nonisolated func takeCaptureGeneration(forSettingsID id: Int64) -> Int? {
        captureGenerationLock.withLock { $0.removeValue(forKey: id) }
    }

    // MARK: - Setup

    /// Requests camera access (if needed), then configures + starts the session. Sets
    /// `permission` so the UI can show a "grant access" state instead of a black screen.
    @MainActor
    func start() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permission = .authorized
            if !hasLoggedCameraAuthorized {
                hasLoggedCameraAuthorized = true
                Activation.log(.cameraAuthorized)
            }
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
        if session.canAddOutput(metadataOutput) {
            session.addOutput(metadataOutput)
        }
        addVideoInput()
        session.commitConfiguration()
        enableFaceMetadata()
    }

    /// Requests face metadata for the viewfinder's focus rectangles.
    ///
    /// Must run AFTER the video input is in place and the configuration is committed.
    /// `availableMetadataObjectTypes` is derived from the output's active CONNECTION, not merely
    /// from having joined a session, so while the session still has no input the list is empty.
    /// The guard below is required (assigning an unsupported type raises), but asked too early it
    /// silently answers "no faces here" on every device, which is exactly how the first version of
    /// this shipped with face detection permanently disabled. Hence: after the input, after the
    /// commit, every time the session is reconfigured.
    private func enableFaceMetadata() {
        guard metadataOutput.availableMetadataObjectTypes.contains(.face) else { return }
        metadataOutput.metadataObjectTypes = [.face]
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
        resumeContinuousFocus(on: device)
    }

    /// Puts the device back into CONTINUOUS focus + exposure, metering at the centre.
    ///
    /// Set explicitly rather than relying on the device default, and re-applied after every
    /// tap-to-focus (see `subjectAreaDidChange`) and on every lens flip. `focus(atDevicePoint:)`
    /// uses `.autoFocus`/`.autoExpose`, which are ONE-SHOT modes: the device converges once and
    /// then holds that focus distance and exposure indefinitely. Nothing used to restore
    /// continuous afterwards, so a single tap on the viewfinder locked focus for the rest of the
    /// session, and any later shot framed at a different distance came out soft.
    private func resumeContinuousFocus(on device: AVCaptureDevice) {
        guard (try? device.lockForConfiguration()) != nil else { return }
        if device.isFocusPointOfInterestSupported {
            device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
        }
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if device.isExposurePointOfInterestSupported {
            device.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5)
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        // Only meaningful while a one-shot lock is in effect; turned on by a tap, off here.
        device.isSubjectAreaChangeMonitoringEnabled = false
        device.unlockForConfiguration()
    }

    /// The `.photo` preset's default format pick optimizes for full-resolution stills, not
    /// a smooth preview, on most devices that pick tops out at 24-30fps, which read as
    /// visibly choppier panning next to Lapse's 60fps viewfinder. This looks for a format
    /// that is a PARITY match for that `.photo` baseline (same or better photo resolution,
    /// same field of view, same pixel format, and, for virtual multi-lens devices, the
    /// same constituent-lens zoom breakpoints) and only differs in frame rate. That keeps
    /// the fast path structurally identical to the default pick, just faster: it can never
    /// silently drop a lens (0.5× pill disappearing), narrow the field of view, change the
    /// pixel format (e.g. HDR x420 vs 420f), pick a format whose live video stream is a
    /// pathologically small fraction of what it advertises for stills (a format can claim a
    /// full-res `supportedMaxPhotoDimensions` while actually streaming a tiny binned/upscaled
    /// preview, the still photo looks fine but the live feed reads as pixelated), or win a
    /// tie by undocumented array order, because a non-matching format is never a candidate in
    /// the first place. If nothing beats the baseline's frame rate under those constraints,
    /// this leaves `.photo`'s own pick alone, preview smoothness is never traded for photo
    /// quality, zoom behavior, or live resolution.
    private func configurePreviewFormat(for device: AVCaptureDevice) {
        // The `.photo` preset's own pick, captured before anything is touched, every
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
            // Self-referential check, not a cross-format one: a format is only suspect when
            // ITS OWN live video stream is a pathologically small fraction of ITS OWN
            // advertised photo size, the literal signature of "advertises big stills,
            // streams a tiny binned/upscaled preview." Comparing against some OTHER format's
            // (e.g. the baseline's) video area would wrongly punish legitimate high-frame-rate
            // formats that bin their video proportionally to go faster, which is normal and
            // healthy on modern sensors, not a bug.
            // Floor set below (not at) the most common legitimate binning ratio: standard 2x2
            // sensor binning is an exact 4x area reduction (ratio 0.25), so a hard 0.25 cutoff
            // would sit exactly on that boundary with no room for aspect-crop/stabilization
            // rounding to knock a healthy format fractionally under it. 0.15 clears the reported
            // pathological case by a wide margin (~480p video against ~12MP+ photo is ~0.028,
            // roughly 5x below this floor) while giving 2x2-binned formats (~0.25) real headroom.
            // A 3x3-binned format (~0.111) still fails this floor and falls back to a slower
            // candidate or .photo; that is an acceptable tradeoff, since this check exists to
            // guarantee "never pixelated" over "always the fastest possible format on every
            // sensor," and the fallback path is always the safe, previously-shipped behavior.
            let videoDimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let videoArea = Int(videoDimensions.width) * Int(videoDimensions.height)
            guard Double(videoArea) >= Double(photoArea) * 0.15 else { return false }
            return true
        }
        guard let target = candidates.max(by: {
            ($0.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0) <
            ($1.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
        }) else { return }

        let ceiling = target.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
        guard ceiling > 30.5 else { return }
        let targetFPS = min(ceiling, 60)
        // The candidate must actually declare support for the fps we're about to request, 
        // `maxFrameRate` alone doesn't guarantee every rate up to it is achievable.
        guard target.videoSupportedFrameRateRanges.contains(where: {
            $0.minFrameRate <= targetFPS && targetFPS <= $0.maxFrameRate
        }) else { return }

        guard (try? device.lockForConfiguration()) != nil else { return }
        // Manual format selection needs input-priority, `.photo` would otherwise snap the
        // format back to its own pick the moment configuration commits.
        session.sessionPreset = .inputPriority
        device.activeFormat = target
        // The constituent-lens switch-over breakpoints can only be verified once the format
        // is actually active, this is a no-op equality check on non-virtual devices (both
        // arrays are empty). If activating the format changed them, the 0.5×/1×/2× pill
        // mapping would silently break, so revert to the untouched baseline instead.
        guard device.virtualDeviceSwitchOverVideoZoomFactors == baselineSwitchOverFactors else {
            device.activeFormat = baseline
            device.unlockForConfiguration()
            session.sessionPreset = .photo
            return
        }
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(targetFPS))
        // Floor the frame rate as well as capping it.
        //
        // This used to leave the floor at the format's default, on the reasoning that auto
        // exposure dropping the frame rate in low light is expected behaviour. It is expected, and
        // it is also exactly what was reported as the viewfinder "degrading" in a dark room: AE
        // lengthens the exposure per frame to gather light, which drops the preview to a slideshow
        // AND makes it visibly noisier, with no indicator to explain why. Reported as looking like
        // a night mode nobody asked for.
        //
        // A floor of 24fps means AE reaches for gain instead of unbounded exposure time, so the
        // preview stays smooth. It costs some preview brightness in near-darkness, which is the
        // right trade for a camera whose viewfinder is the product: a dim but fluid preview reads
        // as a camera, a bright juddering one reads as a broken app.
        //
        // PREVIEW ONLY. `activeVideoMaxFrameDuration` bounds the video stream; the still capture
        // sets its own exposure and is untouched by this, so photo quality in the dark is exactly
        // as before.
        let floorFPS = 24.0
        if target.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= floorFPS }) {
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: Int32(floorFPS))
        }
        // Low-light boost is a gain-based brightening of the video stream that visibly adds noise.
        // Never configured before, so this pins the default rather than trusting it to stay off.
        if device.isLowLightBoostSupported {
            device.automaticallyEnablesLowLightBoostWhenAvailable = false
        }
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
        // Flipping away from a front-flash capture still in flight must not leave the screen
        // pinned at full brightness, restore() is a no-op when nothing is outstanding. Before
        // the input swap below, ahead of anything that could touch the device being swapped out.
        screenBrightness.restore()
        exposureCeiling.restore()
        cameraPosition = isFront ? .back : .front
        // A pending handback belongs to the lens being swapped out; `addVideoInput` puts the new
        // one into continuous focus itself.
        subjectAreaTask?.cancel()
        session.beginConfiguration()
        // Reset to the known-good baseline before re-deriving it for the new lens, 
        // `configurePreviewFormat(for:)` (called from `addVideoInput`) only upgrades to
        // `.inputPriority` when it finds a format that beats this, so a lens without a
        // faster-than-30fps full-res option deterministically lands back on `.photo`
        // rather than inheriting `.inputPriority` left over from the other camera.
        session.sessionPreset = .photo
        session.inputs.forEach { session.removeInput($0) }
        addVideoInput()   // re-reads the new lens layout + resets zoom to 1×
        session.commitConfiguration()
        // Faces belong to the lens we just swapped away from; the new one reports its own.
        faceRects = []
        enableFaceMetadata()   // swapping the input can clear the requested types
    }

    // MARK: - Focus & zoom

    /// The screen point of the last tap-to-focus, for a brief reticle. `nil` when hidden.
    struct FocusReticle: Equatable { let id = UUID(); let point: CGPoint }
    var focusReticle: FocusReticle?

    /// Live only between a tap-to-focus and the handback to continuous focus that follows it.
    private var subjectAreaTask: Task<Void, Never>?

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
    ///
    /// A deliberate, TEMPORARY override of the continuous focus the camera otherwise runs in.
    /// `.autoFocus`/`.autoExpose` converge once and then hold, so subject-area monitoring is
    /// switched on here and `subjectAreaDidChange` hands control back to continuous once the
    /// scene moves on. Without that handback a single tap locked focus for the whole session,
    /// which is the likeliest explanation for shots that come back soft after someone tapped
    /// once to focus on something close and then photographed something else.
    func focus(atDevicePoint devicePoint: CGPoint, viewPoint: CGPoint) {
        if let device = currentDevice, (try? device.lockForConfiguration()) != nil {
            if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                device.focusPointOfInterest = devicePoint
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.autoExpose) {
                device.exposurePointOfInterest = devicePoint
                device.exposureMode = .autoExpose
            }
            device.isSubjectAreaChangeMonitoringEnabled = true
            device.unlockForConfiguration()
        }
        let reticle = FocusReticle(point: viewPoint)
        focusReticle = reticle
        // `focus(...)` is main-actor isolated (the whole type is now), and a plain `Task { }`
        // inherits the actor of the context that creates it, so this already resumes on the
        // main actor after the sleep. Spelled out explicitly anyway: this exact spot used to be
        // the one place a stray Task wrote `focusReticle`, an @Observable tracked property SwiftUI
        // reads in `body`, from whatever arbitrary executor it happened to resume on.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            if focusReticle?.id == reticle.id { focusReticle = nil }
        }
        observeSubjectAreaChange()
    }

    /// Waits for the one subject-area-change notification that follows a tap-to-focus (the scene
    /// in front of the lens moved enough that the locked focus/exposure no longer describes it)
    /// and hands control back to continuous. This is what makes a tap a temporary override rather
    /// than a lock that outlives the shot it was meant for.
    private func observeSubjectAreaChange() {
        subjectAreaTask?.cancel()
        subjectAreaTask = Task { [weak self] in
            let notifications = NotificationCenter.default.notifications(
                named: AVCaptureDevice.subjectAreaDidChangeNotification
            )
            for await _ in notifications {
                guard let self, !Task.isCancelled else { return }
                if let device = self.currentDevice { self.resumeContinuousFocus(on: device) }
                return   // one handback per tap; the next tap re-arms this
            }
        }
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
        // Navigating away (tab switch, `CameraView.onDisappear`) mid-capture must not leave the
        // screen pinned at full brightness. Unconditional and ahead of the early-return below, so
        // it still fires even if the session was already stopped by an earlier call.
        screenBrightness.restore()
        exposureCeiling.restore()
        guard session.isRunning else { return }
        // No more metadata is coming, so the last frame's rectangles would otherwise still be on
        // screen when the viewfinder comes back, hanging over a scene that has since changed.
        faceRects = []
        Task.detached(priority: .userInitiated) { [weak self] in
            self?.session.stopRunning()
        }
    }

    // MARK: - Capture

    @MainActor
    func capturePhoto() {
        guard !isCapturing else { return }
        isCapturing = true
        captureGeneration += 1
        let generation = captureGeneration

        // The on-screen flash overlay is NOT triggered here anymore. A real LED flash needs a
        // beat for AE/AF + preflash metering before it actually fires, so lighting up the screen
        // at tap time made the white flash arrive a full 1-2s before the real flash, reading as
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

        // Front camera has no hardware LED: "flash on" here means screen-as-flash, brightening
        // the display to light the subject instead. Triggering the capture at the same instant
        // as the brighten (the old behavior) meant the sensor's continuous auto-exposure was
        // still metered against the dim pre-flash scene, in a dark room, where AE had already
        // cranked exposure way up expecting darkness, the sudden extra light blew the shot out;
        // in a brighter room the same shot looked fine. Reported on-device as the screen-flash
        // being "either really good or really bad" with no in-between. Brightening the screen
        // FIRST and giving AE a beat to re-converge against the now-lit scene before triggering
        // the actual capture means exposure is metered for the scene the sensor is about to see,
        // not the one before the flash.
        //
        // `flashOpacity` alone (a SwiftUI overlay) never emitted real light, it was drawn at
        // whatever brightness the display already happened to be at. `screenBrightness.begin`
        // below is the actual fix: it raises the display's real backlight to full, restored on
        // every exit path (see `RestorableOverride`'s doc). Set instantly rather than ramped:
        // `UIScreen.brightness` has no native animation, and the SwiftUI overlay's own 0.12s fade
        // already supplies the perceived ramp on top of light that's already at full output
        // underneath it.
        if isFront && flashMode == .on {
            screenBrightness.begin(
                get: { activeScreen()?.brightness ?? 1 },
                set: { activeScreen()?.brightness = $0 },
                to: 1.0
            )
            // Bounds AE's worst case so a scene the screen can't fully light doesn't turn into a
            // multi-second exposure, see `exposureCeiling`'s own doc. Clamped into the active
            // format's own allowed range: setting `activeMaxExposureDuration` outside
            // `minExposureDuration...maxExposureDuration` raises.
            if let device = currentDevice {
                let format = device.activeFormat
                let cap = CMTimeMaximum(
                    format.minExposureDuration,
                    CMTimeMinimum(CMTime(value: 1, timescale: 8), format.maxExposureDuration)
                )
                exposureCeiling.begin(
                    get: { device.activeMaxExposureDuration },
                    set: { duration in
                        guard (try? device.lockForConfiguration()) != nil else { return }
                        device.activeMaxExposureDuration = duration
                        device.unlockForConfiguration()
                    },
                    to: cap
                )
            }
            Self.shutterTappedAt = Date()
            Self.log.notice("shutter tapped, front flash path")
            withAnimation(.easeOut(duration: 0.12)) { flashOpacity = 1 }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.waitForExposureToSettle()
                Self.log.notice("AE settled \(Self.sinceShutterMS(), privacy: .public)ms after the tap")
                guard generation == self.captureGeneration else { return }
                self.rememberCaptureGeneration(generation, forSettingsID: settings.uniqueID)
                self.output.capturePhoto(with: settings, delegate: self)
                Self.log.notice("capturePhoto called \(Self.sinceShutterMS(), privacy: .public)ms after the tap")
                self.startCaptureWatchdog(generation: generation)
            }
        } else {
            rememberCaptureGeneration(generation, forSettingsID: settings.uniqueID)
            output.capturePhoto(with: settings, delegate: self)
            startCaptureWatchdog(generation: generation)
        }
    }

    /// Waits for continuous auto-exposure to actually settle against the newly-lit scene.
    ///
    /// Replaces a flat 260ms guess. That was wrong in both directions: in a lit room AE
    /// re-converges almost immediately, so it was pure added latency on every single front-flash
    /// shot, and in a dim room, which is when anyone reaches for the screen flash, 260ms is
    /// nowhere near enough, so the shot metered against a half-adapted scene. That is the
    /// "either really good or really bad, no in-between" behaviour, still half-present after the
    /// fixed wait was introduced.
    ///
    /// Capped so a scene AE can never settle on (a pitch-dark room) still takes a photo rather
    /// than hanging on the white screen forever. Re-checked after `screenBrightness` above landed,
    /// on the reasoning that a genuinely brightened screen should make AE converge fast: this loop
    /// is already adaptive (it polls `isAdjustingExposure` and returns the moment AE reports
    /// settled, in 20ms steps), not a flat wait, so in the common case it should now exit in well
    /// under 700ms without any code change here. The 700ms ceiling itself is left alone rather
    /// than shrunk further: it only matters for the pathological case (brightness change not yet
    /// visually propagated, or a room the screen still can't reach), and it is exactly what
    /// protects against the "either really good or really bad" regression this file already
    /// describes above, shrinking it trades a small latency win in the common case (which no
    /// longer needs it) for real risk in the uncommon one (which still does).
    private func waitForExposureToSettle(cap: Duration = .milliseconds(700)) async {
        guard let device = currentDevice else { return }
        // A short beat first: `isAdjustingExposure` doesn't flip true the instant the scene
        // changes, so polling immediately would read "settled" from before the screen lit up.
        try? await Task.sleep(for: .milliseconds(60))
        let deadline = ContinuousClock.now.advanced(by: cap)
        while device.isAdjustingExposure, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Recovers the UI if AVFoundation's completion callbacks never arrive.
    ///
    /// Timed from when the capture is actually TRIGGERED, not from the shutter tap. It used to
    /// start at tap, which on the front-flash path meant the pre-capture wait above, plus
    /// however long AE/AF convergence took, was spent inside the watchdog's own budget. In a dim
    /// room, exactly the case this exists for, convergence can eat most of three seconds, so the
    /// watchdog could fire DURING a perfectly healthy exposure and kill the screen flash
    /// mid-shot, darkening the very photo it was lighting.
    ///
    /// It also refuses to clear the overlay while an exposure is genuinely in flight (between
    /// `willCapturePhotoFor` and `didCapturePhotoFor`), extending once instead, so a slow but
    /// working capture is never cut short. Only a capture that is still unfinished after that
    /// gets forcibly reset.
    @MainActor
    /// Timing instrumentation for the front-flash duration, which four separate fixes have now
    /// failed to shift. Every theory so far has been argued from source and none could separate
    /// "the exposure genuinely takes seconds" from "the delegate callback never arrives and the
    /// watchdog is what ends the flash at its own 3s timeout". Those need opposite fixes, so the
    /// next attempt is measured rather than reasoned. Read with Console.app, subsystem
    /// com.flim.app, category camera.
    private static let log = Logger(subsystem: "com.flim.app", category: "camera")
    nonisolated(unsafe) private static var shutterTappedAt: Date?

    nonisolated private static func sinceShutterMS() -> Int {
        guard let start = shutterTappedAt else { return -1 }
        return Int(Date().timeIntervalSince(start) * 1000)
    }

    private func startCaptureWatchdog(generation: Int) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, generation == self.captureGeneration, self.isCapturing else { return }
            // Reaching here at all means didCapturePhoto never fired. If the flash duration is
            // pinned near 3s, THIS is what is ending it, and no amount of exposure tuning will
            // help: the callback is missing, not late.
            Self.log.error("""
                WATCHDOG fired \(Self.sinceShutterMS(), privacy: .public)ms after the tap. \
                didCapturePhoto never arrived. isExposing=\(self.isExposing, privacy: .public)
                """)
            if self.isExposing {
                try? await Task.sleep(for: .seconds(2))
                guard generation == self.captureGeneration, self.isCapturing else { return }
            }
            self.isCapturing = false
            withAnimation(.easeOut(duration: 0.3)) { self.flashOpacity = 0 }
            self.screenBrightness.restore()
            self.exposureCeiling.restore()
        }

    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraViewModel: AVCapturePhotoCaptureDelegate {
    /// `nonisolated`: AVFoundation calls the capture delegate back on its own queue, not main
    /// (no delegate queue was given to `output.capturePhoto(with:delegate:)`), so this cannot be
    /// main-actor isolated the way the rest of the type now is. Every write of tracked
    /// `@Observable` state below hops through `Task { @MainActor in ... }` instead.
    ///
    /// Fires right as the real exposure begins (after AE/AF + any preflash metering), this is
    /// the correct moment for a flash-adjacent overlay, not the shutter tap.
    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings
    ) {
        if resolvedSettings.isFlashEnabled {
            // The rear LED is about to fire, it IS the flash. A white screen overlay on top of
            // it reads as a glitch, so the rear+flash case shows no overlay at all.
            return
        }
        // Front camera has no LED, so an explicit "flash on" there means screen-as-flash: brighten
        // the display itself in place of hardware flash, timed to the real exposure. Every other
        // no-flash shot (front or rear) keeps a subtle blink so the shutter still feels responsive.
        // `isFront` and `flashMode` are main-actor isolated, like the rest of this type, so they
        // are read INSIDE the hop below, not out here on AVFoundation's delegate queue. Reading
        // them here used to race whatever main-actor code was mutating them at the same instant
        // (a flip-camera or flash-toggle tap), one line above the hop that this file's own
        // comment already said every other write on this delegate goes through.
        Task { @MainActor in
            let opacity: Double = (self.isFront && self.flashMode == .on) ? 1 : 0.35
            self.isExposing = true
            self.flashOpacity = opacity
        }
    }

    /// Fires once the exposure itself is finished, fade the overlay out here so its length always
    /// tracks the real capture instead of a timer guessed at tap time.
    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings
    ) {
        Self.log.notice("""
            didCapturePhoto \(Self.sinceShutterMS(), privacy: .public)ms after the tap, \
            flashEnabled=\(resolvedSettings.isFlashEnabled, privacy: .public)
            """)
        let fade = resolvedSettings.isFlashEnabled ? 0.15 : 0.3
        Task { @MainActor in
            self.isExposing = false
            withAnimation(.easeOut(duration: fade)) { self.flashOpacity = 0 }
            // The sensor has already captured the frame, there is nothing left for the extra
            // screen light (or the exposure ceiling that bounded it) to do. `restore()` is a
            // no-op on the (common) captures that never called `begin()` in the first place.
            self.screenBrightness.restore()
            self.exposureCeiling.restore()
        }
    }

    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        // Looked up (and forgotten) up front, off the main actor: this callback can arrive for a
        // capture the watchdog already gave up on and let the user re-shoot (thermal throttling,
        // an older device, a slow capture). Without checking this, a late callback for that
        // abandoned capture would still write `capturedData` and fire `onPhotoCapture` below,
        // silently enqueuing and uploading a photo the user believes never happened, and would
        // reset `isCapturing`/`flashOpacity` out from under whatever capture is genuinely in
        // flight now. `nil` (the ID was never recorded, which `capturePhoto()` should always do
        // before triggering a capture) fails open rather than closed: a capture is not
        // reproducible, so an unexpected miss here must not risk dropping a real photo.
        let expectedGeneration = takeCaptureGeneration(forSettingsID: photo.resolvedSettings.uniqueID)

        let rawData = photo.fileDataRepresentation()
        // Crop to match what the full-bleed viewfinder actually framed: `.resizeAspectFill`
        // center-crops the LIVE PREVIEW to fill the screen, but AVCapturePhotoOutput always
        // delivers the full, uncropped sensor frame, so the saved photo otherwise shows more
        // scene at the left/right edges than what was on screen at capture time. Done here,
        // synchronously, on this delegate's own background queue (like `fileDataRepresentation()`
        // just above) since decode/redraw/re-encode is real CPU work that shouldn't run after
        // the `@MainActor` hop below. Falls back to the untouched bytes if the aspect ratio
        // isn't known yet or the crop fails, a photo must never be lost to this.
        let data = rawData.flatMap { raw -> Data in
            guard let targetAspectRatio = previewAspectRatio,
                  // `previewAspectRatio` is written from the preview view's LIVE bounds on every
                  // layout pass, so a transient pass (before `.aspectRatio(3:4)` settles, during a
                  // tab change, any momentary layout) can briefly report something near a
                  // full-screen ratio. Cropping a 4:3 capture to ~0.46 throws away roughly 40% of
                  // the frame width, symmetrically, so subjects at the far left and far right
                  // vanish while the middle of the shot looks completely normal, intermittently,
                  // depending on catching a bad layout pass. The viewfinder is a fixed 3:4 box, so
                  // anything outside that band did not come from it.
                  //
                  // Skipping the crop can only ever keep MORE of the photo than was framed, which
                  // is the safe direction: slightly wider edges beats deleting whoever was
                  // standing at the sides.
                  CapturedPhotoCropper.isPlausibleTargetAspect(targetAspectRatio),
                  let cropped = CapturedPhotoCropper.croppedJPEGData(from: raw, targetAspectRatio: targetAspectRatio)
            else { return raw }
            return cropped
        }
        Task { @MainActor in
            // Stale: the watchdog already reset `isCapturing`/`flashOpacity` and let the user
            // shoot again, possibly already mid a NEWER capture that owns those same properties
            // now. Touching them here, or delivering this photo, would step on that one.
            guard expectedGeneration == nil || expectedGeneration == self.captureGeneration else { return }
            self.isCapturing = false
            self.flashOpacity = 0   // safety net in case the capture errored before the callbacks above fired
            self.screenBrightness.restore()   // same safety net; a no-op if already restored
            self.exposureCeiling.restore()   // same safety net; a no-op if already restored
            guard let data else {
                // A genuine capture failure (hardware fault, interrupted session, no file data
                // at all), rare, but silent otherwise: the shutter had already animated and
                // fired its haptic as if the shot landed, with nothing to show it didn't.
                Haptics.error()
                return
            }
            self.capturedData = data
            self.onPhotoCapture?(data)
        }
    }
}
