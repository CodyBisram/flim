import SwiftUI
import UIKit
import AVFoundation
import AVKit

/// Full-screen echo of the same capture session, used purely as the blurred/dimmed backdrop
/// behind the boxed 3:4 viewfinder (see `CameraView`). A session happily drives multiple
/// preview layers, so this costs no extra capture work. Deliberately NOT `CameraPreview`:
/// this view must carry no gestures (taps outside the box should do nothing) and must never
/// push its bounds into `CameraViewModel.previewAspectRatio` — only the real viewfinder's
/// bounds may feed the capture-crop math, and a full-screen echo reporting its own aspect
/// ratio would silently re-crop every photo back to the screen's shape.
struct CameraBackdropPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> BackdropView {
        let view = BackdropView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: BackdropView, context: Context) {}

    final class BackdropView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        // The blur must be a UIVisualEffectView INSIDE this view, not SwiftUI's `.blur`:
        // SwiftUI blurs by sampling the view's contents into a texture, and a video preview
        // layer's frames aren't sampleable that way — the result was a solid black backdrop
        // on device. An effect view instead blurs whatever the render server composites
        // beneath it, live video included.
        private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .dark))

        override init(frame: CGRect) {
            super.init(frame: frame)
            blurView.frame = bounds
            blurView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(blurView)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let camera: CameraViewModel
    /// Called by a hardware volume-button press (iOS 17.2+).
    var onShutter: () -> Void = {}
    /// Screen-space (window/global coordinate) rects the top bar, zoom pills, shutter, etc.
    /// occupy. The preview's own tap/double-tap/pinch recognizers never claim a touch that
    /// starts inside one of these, so a control's own action always wins over tap-to-focus,
    /// no matter how SwiftUI and this UIKit view's hit-testing happen to interleave.
    var excludedRegions: [CGRect] = []

    func makeCoordinator() -> Coordinator { Coordinator(camera: camera, onShutter: onShutter) }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        context.coordinator.view = view

        // Push the preview's REAL on-screen bounds up to the view model every layout pass,
        // so a captured photo can later be cropped to match what this boxed (3:4, see
        // CameraView.swift), `.resizeAspectFill` preview actually showed (see
        // `CameraViewModel.previewAspectRatio`). Reading the live view's bounds, rather than
        // hardcoding the 3:4 ratio here too, keeps the crop correct even if the box's ratio
        // ever changes or a device's actual sensor/layout math doesn't land exactly on 3:4.
        weak var coordinator = context.coordinator
        view.onLayout = { size in
            guard size.width > 0, size.height > 0 else { return }
            coordinator?.camera.previewAspectRatio = size.width / size.height
        }

        // Single tap = focus/exposure; double tap = flip; they can't both fire.
        let single = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        let double = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        double.numberOfTapsRequired = 2
        single.require(toFail: double)
        single.delegate = context.coordinator
        double.delegate = context.coordinator
        view.addGestureRecognizer(single)
        view.addGestureRecognizer(double)

        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:)))
        pinch.delegate = context.coordinator
        view.addGestureRecognizer(pinch)

        // Hardware volume button as a shutter (the sanctioned API).
        if #available(iOS 17.2, *) {
            let interaction = AVCaptureEventInteraction { event in
                if event.phase == .ended { context.coordinator.onShutter() }
            }
            view.addInteraction(interaction)
        }
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        context.coordinator.onShutter = onShutter
        context.coordinator.excludedRegions = excludedRegions
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        /// Fires with this view's real bounds every layout pass — the mechanism for pushing
        /// the live preview's aspect ratio up to `CameraViewModel` (see `makeUIView` above).
        var onLayout: ((CGSize) -> Void)?

        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout?(bounds.size)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let camera: CameraViewModel
        var onShutter: () -> Void
        weak var view: PreviewView?
        var excludedRegions: [CGRect] = []
        private var zoomBase: CGFloat = 1

        init(camera: CameraViewModel, onShutter: @escaping () -> Void) {
            self.camera = camera
            self.onShutter = onShutter
        }

        /// Buttons always win: a touch that begins inside a known control rect (top bar,
        /// zoom pills, shutter, bottom pill) is never handed to the preview's own
        /// focus/flip/pinch recognizers, regardless of how the touch would otherwise hit-test.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard !excludedRegions.isEmpty else { return true }
            let point = touch.location(in: nil)   // window coordinates, matching SwiftUI's `.global` space
            return !excludedRegions.contains { $0.contains(point) }
        }

        @objc func tap(_ gesture: UITapGestureRecognizer) {
            guard let view else { return }
            let point = gesture.location(in: view)
            let devicePoint = view.previewLayer.captureDevicePointConverted(fromLayerPoint: point)
            camera.focus(atDevicePoint: devicePoint, viewPoint: point)
            Haptics.tap()
        }

        @objc func doubleTap(_ gesture: UITapGestureRecognizer) {
            guard camera.permission == .authorized else { return }
            camera.flipCamera()
            Haptics.tap()
        }

        @objc func pinch(_ gesture: UIPinchGestureRecognizer) {
            if gesture.state == .began { zoomBase = camera.currentZoom }
            camera.zoom(to: zoomBase * gesture.scale)
        }
    }
}
