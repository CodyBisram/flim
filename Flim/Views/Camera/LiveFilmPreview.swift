import SwiftUI
import AVFoundation
import MetalKit
import CoreImage

/// A filtered viewfinder: renders the live camera through the selected film look with Metal +
/// Core Image, using the SAME `InstantFilmProcessor.filtered` transform as capture — so what you
/// see is what develops. It sits ON TOP of the raw `CameraPreview` with touches disabled, so the
/// existing focus / zoom / flip / volume-shutter gestures keep working underneath and the raw
/// preview is the fallback. Off by default (Settings → Live film preview).
struct LiveFilmPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var stock: FilmStock
    var isFront: Bool

    func makeUIView(context: Context) -> FilmMetalView {
        FilmMetalView(session: session, stock: stock, isFront: isFront)
    }

    func updateUIView(_ uiView: FilmMetalView, context: Context) {
        uiView.stock = stock
        uiView.isFront = isFront
    }

    static func dismantleUIView(_ uiView: FilmMetalView, coordinator: ()) {
        uiView.tearDown()
    }
}

final class FilmMetalView: MTKView, AVCaptureVideoDataOutputSampleBufferDelegate {
    var stock: FilmStock
    var isFront: Bool { didSet { updateMirror() } }

    private let captureSession: AVCaptureSession
    private let output = AVCaptureVideoDataOutput()
    private let frameQueue = DispatchQueue(label: "flim.livefilm.frames")
    private let ciContext: CIContext
    private let commandQueue: MTLCommandQueue?
    private var latest: CIImage?
    private weak var videoConnection: AVCaptureConnection?

    init(session: AVCaptureSession, stock: FilmStock, isFront: Bool) {
        self.captureSession = session
        self.stock = stock
        self.isFront = isFront
        let device = MTLCreateSystemDefaultDevice()
        self.commandQueue = device?.makeCommandQueue()
        self.ciContext = device.map { CIContext(mtlDevice: $0) } ?? CIContext()
        super.init(frame: .zero, device: device)

        isUserInteractionEnabled = false      // touches fall through to the raw preview below
        framebufferOnly = false               // CIContext renders into the drawable's texture
        isOpaque = true
        backgroundColor = .black
        preferredFramesPerSecond = 30
        enableSetNeedsDisplay = false
        isPaused = (device == nil)             // no Metal device (e.g. Simulator) → stay inert

        guard device != nil else { return }
        configureOutput()
    }

    required init(coder: NSCoder) { fatalError("init(coder:) not used") }

    private func configureOutput() {
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: frameQueue)

        captureSession.beginConfiguration()
        if captureSession.canAddOutput(output) { captureSession.addOutput(output) }
        captureSession.commitConfiguration()

        videoConnection = output.connection(with: .video)
        if let c = videoConnection {
            if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }   // portrait
            c.automaticallyAdjustsVideoMirroring = false
            updateMirror()
        }
    }

    private func updateMirror() {
        guard let c = videoConnection, c.isVideoMirroringSupported else { return }
        c.isVideoMirrored = isFront
    }

    func tearDown() {
        captureSession.beginConfiguration()
        captureSession.removeOutput(output)
        captureSession.commitConfiguration()
    }

    // MARK: - Frames

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let source = CIImage(cvPixelBuffer: pixelBuffer)
        // Grain off for the live view (CIRandomGenerator per frame would shimmer + cost); the
        // captured photo still bakes grain in.
        latest = InstantFilmProcessor.filtered(source, params: stock.params, extent: source.extent, grain: false)
    }

    // MARK: - Render

    override func draw(_ rect: CGRect) {
        guard let drawable = currentDrawable,
              let commandBuffer = commandQueue?.makeCommandBuffer(),
              let image = latest else { return }

        let target = drawableSize
        guard target.width > 0, image.extent.width > 0 else { return }

        // Aspect-fill the frame into the drawable, centered.
        let scale = max(target.width / image.extent.width, target.height / image.extent.height)
        let scaledW = image.extent.width * scale
        let scaledH = image.extent.height * scale
        let tx = (target.width - scaledW) / 2
        let ty = (target.height - scaledH) / 2
        let display = image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: tx, y: ty))

        ciContext.render(display,
                         to: drawable.texture,
                         commandBuffer: commandBuffer,
                         bounds: CGRect(origin: .zero, size: target),
                         colorSpace: CGColorSpaceCreateDeviceRGB())
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
