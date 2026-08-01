import SwiftUI
import UIKit
import AVFoundation
import AVKit

/// True when two sets of face rectangles are close enough that redrawing would be wasted work.
///
/// Face metadata arrives at the video frame rate and jitters by a pixel or two even on a
/// perfectly still subject. Publishing every frame would invalidate the whole viewfinder 30-60
/// times a second for movement nobody can see, so an update only goes through once something has
/// actually moved. Free function so the threshold is testable.
func faceRectsAreSettled(_ a: [CGRect], _ b: [CGRect], tolerance: CGFloat = 4) -> Bool {
    guard a.count == b.count else { return false }
    for (lhs, rhs) in zip(a, b) {
        if abs(lhs.minX - rhs.minX) > tolerance { return false }
        if abs(lhs.minY - rhs.minY) > tolerance { return false }
        if abs(lhs.width - rhs.width) > tolerance { return false }
        if abs(lhs.height - rhs.height) > tolerance { return false }
    }
    return true
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

        // Face rectangles. The delegate lives here rather than on the view model because
        // converting a metadata object's bounds into on-screen coordinates requires the preview
        // layer (the metadata space is buffer-relative, rotated with the connection, and mirrored
        // on the front camera); `transformedMetadataObject(for:)` is the only thing that gets all
        // of that right. Main queue so the layer read and the model write are both safe.
        camera.metadataOutput.setMetadataObjectsDelegate(context.coordinator, queue: .main)

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

        /// Fires with this view's real bounds every layout pass, the mechanism for pushing
        /// the live preview's aspect ratio up to `CameraViewModel` (see `makeUIView` above).
        var onLayout: ((CGSize) -> Void)?

        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout?(bounds.size)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate, AVCaptureMetadataOutputObjectsDelegate {
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

        // MARK: - Face metadata

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard let view else { return }
            let maxWidth: CGFloat = view.bounds.width * 0.95
            var rects: [CGRect] = []
            for object in metadataObjects {
                guard let transformed = view.previewLayer.transformedMetadataObject(for: object) else { continue }
                let bounds: CGRect = transformed.bounds
                // A rect that spans nearly the whole preview is a detector artefact, not a face,
                // and drawing it reads as the viewfinder flashing a border.
                guard bounds.width > 8, bounds.height > 8, bounds.width < maxWidth else { continue }
                rects.append(bounds)
            }
            guard !faceRectsAreSettled(rects, camera.faceRects) else { return }
            camera.faceRects = rects
        }
    }
}
