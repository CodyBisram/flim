import SwiftUI
import UIKit
import AVFoundation
import AVKit

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let camera: CameraViewModel
    /// Called by a hardware volume-button press (iOS 17.2+).
    var onShutter: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(camera: camera, onShutter: onShutter) }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        context.coordinator.view = view

        // Single tap = focus/exposure; double tap = flip; they can't both fire.
        let single = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        let double = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        double.numberOfTapsRequired = 2
        single.require(toFail: double)
        view.addGestureRecognizer(single)
        view.addGestureRecognizer(double)

        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:)))
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
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    final class Coordinator: NSObject {
        let camera: CameraViewModel
        var onShutter: () -> Void
        weak var view: PreviewView?
        private var zoomBase: CGFloat = 1

        init(camera: CameraViewModel, onShutter: @escaping () -> Void) {
            self.camera = camera
            self.onShutter = onShutter
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
