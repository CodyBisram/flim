import SwiftUI
import UIKit

// MARK: - Zoom rules
//
// Free functions rather than logic buried in a gesture handler, for the same reason the pager's
// `pagingStep` is one: the feel of a zoom is arithmetic, and arithmetic can be pinned by tests
// instead of only by eye on a device.

/// The scale a pinch should produce, given where the photo was RESTING when the pinch began.
///
/// Relative, not absolute. Reading a gesture's magnification as the scale itself means a pinch
/// begun on an already-zoomed photo snaps it to 1x before your fingers have moved, which is what
/// the full-screen viewers used to do. Never below 1: a photo at rest has nowhere to shrink to.
func pinchScale(restingAt resting: CGFloat, magnification: CGFloat, maxScale: CGFloat = 4) -> CGFloat {
    min(maxScale, max(1, resting * magnification))
}

/// Where a lifted photo's centre belongs when scaled about `anchor` and dragged by `translation`,
/// all in window coordinates.
///
/// The property that matters: the anchor point stays put. Scaling a rect about an arbitrary point
/// means moving its centre away from that point in proportion to the scale, which is the whole
/// reason the photo appears to grow from between your fingers rather than from its middle.
func zoomedCenter(origin: CGRect, anchor: CGPoint, scale: CGFloat,
                  translation: CGPoint = .zero) -> CGPoint {
    let center = CGPoint(x: origin.midX, y: origin.midY)
    return CGPoint(x: anchor.x + (center.x - anchor.x) * scale + translation.x,
                   y: anchor.y + (center.y - anchor.y) * scale + translation.y)
}

/// How dark the backdrop behind a lifted photo goes. Ramped with the zoom rather than switched on,
/// so a small accidental pinch barely dims and a real one puts the photo alone on screen.
func zoomDimAlpha(scale: CGFloat, maxAlpha: CGFloat = 0.72, ramp: CGFloat = 0.55) -> CGFloat {
    min(maxAlpha, max(0, (scale - 1) * ramp))
}

/// Instagram-style pinch zoom: the photo lifts off the page while you pinch and drops back the
/// moment you let go.
///
/// Attach with `.pinchToZoom()` on any photo. Two fingers scale it about the point between them
/// and carry it around; one finger still does whatever the host already does (tap to open, double
/// tap to like, scroll the feed), because nothing here sits in front of the photo.
///
/// Why this is not a `MagnifyGesture` and a `.scaleEffect`:
///
/// 1. A scaled photo has to escape its container. In the feed the photo lives in a rounded card
///    inside a `ScrollView`, and both clip, so a SwiftUI-only zoom is cropped to the card the
///    instant it grows. Here the lifted photo is a snapshot in a window ABOVE the app, so nothing
///    can clip it and the rest of the feed dims out behind it.
/// 2. Anchoring has to follow the fingers. Zoom should grow from the point between the two
///    fingers, not the middle of the photo, and should track them as they move. A
///    `UIPinchGestureRecognizer` reports both; a `MagnifyGesture` composed with a `DragGesture`
///    fights the ScrollView for the same touches.
///
/// The recognizers live on the WINDOW rather than on the photo. A view laid over the photo would
/// have to swallow touches to receive them, which kills the taps underneath; a view behind it
/// never sees them at all. From the window they see every touch, and a two-finger touch is matched
/// to whichever registered photo contains both fingers, so a single-finger touch is never
/// intercepted at all.
extension View {
    /// Lets two fingers lift this view off the page and zoom it, springing back on release.
    func pinchToZoom() -> some View {
        background(PinchZoomProbe())
    }
}

/// The other half of the zoom story: a pinch for a photo that ALREADY fills a black screen.
///
/// `pinchToZoom()` exists to get a photo out of a container that would clip it. A full-screen
/// viewer has no such container, so lifting it into another window would build a dimming backdrop
/// over an already-black screen and a snapshot on top of the thing it is a snapshot of. This does
/// the same job with a plain `scaleEffect`: magnify while the fingers are down, spring back to
/// whatever the photo was resting at when they lift.
///
/// It reports the anchor as well as the scale. Without that, a full-screen photo can only ever
/// grow from its own middle, so the one thing you pinch a photograph to do (look at the face in
/// the corner) is the one thing it cannot do. `startAnchor` is where your fingers went down, so
/// the photo grows from there.
struct TransientPinch: Gesture {
    @Binding var scale: CGFloat
    @Binding var anchor: UnitPoint
    /// Where the photo was resting when this pinch started, and the flag for "a pinch is in
    /// flight". Nil between pinches.
    @Binding var restingScale: CGFloat?
    var maxScale: CGFloat = 4
    /// Called once, when a pinch actually starts. Screens that move on their own use it to stop.
    var onBegin: () -> Void = {}
    /// Called inside the settling animation, for state that has to come back with the scale.
    var onSettle: (CGFloat) -> Void = { _ in }

    var body: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if restingScale == nil {
                    restingScale = scale
                    onBegin()
                }
                anchor = value.startAnchor
                scale = pinchScale(restingAt: restingScale ?? 1,
                                   magnification: value.magnification, maxScale: maxScale)
            }
            .onEnded { _ in
                let resting = restingScale ?? 1
                restingScale = nil
                // Reduce Motion drops the spring and returns the photo directly. A spring is a
                // large, bouncing movement of the whole frame, which is exactly what the setting
                // exists to suppress; the zoom itself still works, it just stops overshooting.
                //
                // Read from UIAccessibility rather than @Environment because this is a Gesture,
                // not a View, and the environment is not available here.
                let settle: Animation? = UIAccessibility.isReduceMotionEnabled
                    ? nil : .spring(response: 0.32, dampingFraction: 0.86)
                withAnimation(settle) {
                    scale = resting
                    onSettle(resting)
                }
            }
    }
}

// MARK: - Probe

/// A non-interactive UIView sitting behind the photo, used only to answer two questions: where is
/// this photo on screen right now, and which window and view controller is it in. It never takes
/// part in hit testing.
private struct PinchZoomProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        context.coordinator.probe = view
        PinchZoomController.shared.register(context.coordinator)
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {}

    func makeCoordinator() -> PinchZoomRegion { PinchZoomRegion() }

    static func dismantleUIView(_ uiView: ProbeView, coordinator: PinchZoomRegion) {
        PinchZoomController.shared.unregister(coordinator)
    }
}

/// The probe view proper. It exists as a subclass for one reason: `didMoveToWindow` is the first
/// moment the window is known, and the window is where the recognizers have to be installed.
/// Installing from `makeUIView` was the original bug here, where the view has no window yet, so
/// the recognizers were never added and no pinch ever arrived.
private final class ProbeView: UIView {
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let window { PinchZoomController.shared.install(on: window) }
    }
}

/// One registered photo. The probe is held weakly, so a scrolled-away feed card cannot keep
/// anything alive.
@MainActor
final class PinchZoomRegion {
    fileprivate weak var probe: UIView?

    /// The photo's frame in window coordinates, or nil if it is not currently on screen.
    fileprivate var frameInWindow: CGRect? {
        guard let probe, let window = probe.window, probe.bounds.width > 0 else { return nil }
        return probe.convert(probe.bounds, to: window)
    }

    /// The view controller this photo belongs to, used to tell a photo that is genuinely on top
    /// from one sitting behind a presented sheet.
    fileprivate var owningController: UIViewController? { probe?.owningViewController }

    fileprivate var enclosingScrollViews: [UIScrollView] {
        var found: [UIScrollView] = []
        var view: UIView? = probe
        while let current = view {
            if let scrollView = current as? UIScrollView { found.append(scrollView) }
            view = current.superview
        }
        return found
    }
}

// MARK: - Controller

/// Owns the window-level recognizers and the single zoom session that can be running at a time.
///
/// Shared rather than per-photo because the recognizers belong to the window, and a feed with ten
/// cards should install two recognizers, not twenty.
@MainActor
final class PinchZoomController: NSObject {
    static let shared = PinchZoomController()

    private var regions: [ObjectIdentifier: PinchZoomRegion] = [:]
    private weak var installedWindow: UIWindow?
    private var pinch: UIPinchGestureRecognizer?
    private var pan: UIPanGestureRecognizer?

    private var session: Session?

    /// A zoom in progress: everything needed to drive it and to put the world back afterwards.
    private struct Session {
        let overlay: UIWindow
        let dim: UIView
        let image: UIImageView
        /// Where the photo started, in window coordinates. The spring returns to exactly this.
        let origin: CGRect
        /// The midpoint between the two fingers when the pinch began, in window coordinates.
        /// Scaling happens about this point, so the photo grows from where you are looking.
        let anchor: CGPoint
        /// Scroll views frozen for the duration, so the feed cannot slide out from under the zoom.
        let frozenScrollViews: [UIScrollView]
        /// Carried here rather than read from the pan recognizer on demand: a third finger ends
        /// the pan while the pinch is still going, and reading `translation` then would report
        /// zero and snap the photo back to the anchor mid-zoom.
        var translation: CGPoint = .zero
    }

    // MARK: Registration

    fileprivate func register(_ region: PinchZoomRegion) {
        // Drop any region whose probe is gone. `dismantleUIView` normally does this, but it is
        // SwiftUI's to call and this dictionary would otherwise only ever grow across a long
        // scrolling session.
        regions = regions.filter { $0.value.probe != nil }
        regions[ObjectIdentifier(region)] = region
    }

    fileprivate func unregister(_ region: PinchZoomRegion) {
        regions[ObjectIdentifier(region)] = nil
    }

    /// Adds the recognizers to the window the first time a zoomable photo appears in it, and
    /// re-adds them if the app's window changed underneath us (a new scene, for instance).
    fileprivate func install(on window: UIWindow) {
        guard installedWindow !== window else { return }
        if let pinch { installedWindow?.removeGestureRecognizer(pinch) }
        if let pan { installedWindow?.removeGestureRecognizer(pan) }

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2

        // These sit on the window, in front of every touch the app receives, so they must not
        // hold single-finger touches back on their way to the views. Only a gesture that actually
        // begins cancels anything, and one finger can never begin either of these.
        for recognizer in [pinch, pan] as [UIGestureRecognizer] {
            recognizer.delegate = self
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            window.addGestureRecognizer(recognizer)
        }

        self.pinch = pinch
        self.pan = pan
        installedWindow = window
    }

    // MARK: Matching a touch to a photo

    private func midpoint(of recognizer: UIGestureRecognizer, in view: UIView) -> CGPoint? {
        guard recognizer.numberOfTouches == 2 else { return nil }
        let a = recognizer.location(ofTouch: 0, in: view)
        let b = recognizer.location(ofTouch: 1, in: view)
        return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    /// Called for two-finger touches anywhere in the window, which is why it rejects almost
    /// everything: only a touch with BOTH fingers inside one registered photo that is genuinely
    /// on top is ours.
    private func region(under recognizer: UIGestureRecognizer) -> PinchZoomRegion? {
        guard recognizer.numberOfTouches == 2,
              let window = recognizer.view as? UIWindow else { return nil }
        let a = recognizer.location(ofTouch: 0, in: window)
        let b = recognizer.location(ofTouch: 1, in: window)

        return regions.values.first { region in
            guard let frame = region.frameInWindow, frame.contains(a), frame.contains(b) else { return false }
            // A photo sitting behind a presented sheet is still on screen and still has a frame,
            // so without this the feed would answer a pinch made on the sheet covering it.
            //
            // Asked as "is anything presented over MY controller" rather than by hit-testing for
            // whoever owns the touch: hit testing has to resolve a SwiftUI view back to a view
            // controller, and the failure mode when that resolves to something unexpected is that
            // no pinch is ever recognised anywhere, which is silent. This question has an answer
            // that is either right or harmlessly permissive.
            return region.owningController?.presentedViewController == nil
        }
    }

    // MARK: Gesture handling

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            guard session == nil,
                  let window = recognizer.view as? UIWindow,
                  let region = region(under: recognizer),
                  let anchor = midpoint(of: recognizer, in: window) else { return }
            begin(region: region, in: window, anchor: anchor)
            apply()
        case .changed:
            apply()
        case .ended, .cancelled, .failed:
            end()
        default:
            break
        }
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        // Pan is a passenger: it moves an existing zoom and never starts one. Its `.ended` is
        // deliberately ignored, because lifting one finger ends the pan while the pinch (and so
        // the zoom) is still going. The pinch alone decides when the photo drops back.
        guard session != nil, recognizer.state == .changed else { return }
        let translation = recognizer.translation(in: recognizer.view)
        session?.translation = CGPoint(x: translation.x, y: translation.y)
        apply()
    }

    // MARK: Session lifecycle

    private func begin(region: PinchZoomRegion, in window: UIWindow, anchor: CGPoint) {
        guard let frame = region.frameInWindow,
              let scene = window.windowScene,
              let snapshot = snapshot(of: window, in: frame) else { return }

        // A separate window, not an overlay view, so nothing in the app's own hierarchy (a
        // clipping ScrollView, a card's corner radius, a navigation bar) can crop the zoom.
        let overlay = UIWindow(windowScene: scene)
        overlay.frame = window.bounds
        overlay.windowLevel = .normal + 1
        overlay.backgroundColor = .clear
        overlay.isUserInteractionEnabled = false
        let host = UIViewController()
        host.view.backgroundColor = .clear
        overlay.rootViewController = host
        overlay.isHidden = false
        host.view.layoutIfNeeded()

        let dim = UIView(frame: overlay.bounds)
        dim.backgroundColor = .black
        dim.alpha = 0
        dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.view.addSubview(dim)

        let image = UIImageView(image: snapshot)
        image.frame = frame
        image.contentMode = .scaleToFill
        host.view.addSubview(image)

        // Freeze every scroll view the photo sits inside. Two fingers on a UIScrollView still
        // scroll it, so without this the feed slides while the photo is lifted and the snapshot
        // springs back to a frame that has since moved.
        let frozen = region.enclosingScrollViews.filter(\.isScrollEnabled)
        frozen.forEach { $0.isScrollEnabled = false }

        session = Session(overlay: overlay, dim: dim, image: image,
                          origin: frame, anchor: anchor, frozenScrollViews: frozen)
    }

    /// Recomputes the lifted photo's transform from whatever the recognizers currently say. Both
    /// call this, so it does not matter which one fired.
    private func apply() {
        guard let session, let pinch else { return }

        // A lift always starts from rest, so the resting scale is 1 here.
        let scale = pinchScale(restingAt: 1, magnification: pinch.scale)

        session.image.transform = CGAffineTransform(scaleX: scale, y: scale)
        session.image.center = zoomedCenter(origin: session.origin, anchor: session.anchor,
                                            scale: scale, translation: session.translation)
        session.dim.alpha = zoomDimAlpha(scale: scale)
    }

    private func end() {
        guard let session else { return }
        self.session = nil

        session.frozenScrollViews.forEach { $0.isScrollEnabled = true }

        // Back to exactly where it started. Damped rather than bouncy: this is a photo returning
        // to its place in a page, not a control being flicked.
        //
        // Under Reduce Motion the whole lifted photo is a large moving object, so it drops
        // straight back with no spring at all rather than travelling and overshooting.
        let duration = UIAccessibility.isReduceMotionEnabled ? 0.0 : 0.32
        UIView.animate(withDuration: duration, delay: 0,
                       usingSpringWithDamping: 0.86, initialSpringVelocity: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            session.image.transform = .identity
            session.image.center = CGPoint(x: session.origin.midX, y: session.origin.midY)
            session.dim.alpha = 0
        } completion: { _ in
            // Tearing the window down is what actually returns the app to normal, so it has to
            // happen whether the spring finished or was interrupted.
            session.overlay.isHidden = true
            session.overlay.rootViewController = nil
        }
    }

    /// The lifted photo is a picture of the real pixels, so the grain overlay, the corner radius
    /// and anything else drawn on top come along and the lift is seamless.
    private func snapshot(of window: UIWindow, in frame: CGRect) -> UIImage? {
        guard frame.width > 0, frame.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.traitCollection.displayScale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: frame.size, format: format)
        return renderer.image { _ in
            window.drawHierarchy(in: CGRect(x: -frame.minX, y: -frame.minY,
                                            width: window.bounds.width, height: window.bounds.height),
                                 afterScreenUpdates: false)
        }
    }
}

extension PinchZoomController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === pan { return session != nil }
        return region(under: gestureRecognizer) != nil
    }

    /// The pinch and the pan have to run together to zoom and carry at once, and both have to run
    /// alongside whatever the host already had (the feed's scroll, a double tap to like). Anything
    /// we should not be stealing was already rejected in `gestureRecognizerShouldBegin`.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

private extension UIResponder {
    /// The nearest view controller up the responder chain.
    var owningViewController: UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }
}
