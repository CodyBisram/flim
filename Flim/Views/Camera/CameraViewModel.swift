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

    // MARK: - Setup

    func configure() {
        guard session.inputs.isEmpty else { return }

        session.beginConfiguration()
        session.sessionPreset = .photo

        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }

        if session.canAddOutput(output) {
            session.addOutput(output)
        }

        session.commitConfiguration()
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

        // Shutter flash
        flashOpacity = 1
        withAnimation(.easeOut(duration: 0.4)) {
            flashOpacity = 0
        }

        let settings = AVCapturePhotoSettings()
        if output.supportedFlashModes.contains(flashMode) {
            settings.flashMode = flashMode
        }
        output.capturePhoto(with: settings, delegate: self)
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraViewModel: AVCapturePhotoCaptureDelegate {
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        isCapturing = false
        guard let data = photo.fileDataRepresentation() else { return }
        capturedData = data
        onPhotoCapture?(data)
    }
}
