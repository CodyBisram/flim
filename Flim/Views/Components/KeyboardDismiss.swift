import SwiftUI
import UIKit

// MARK: - Policy

/// The rule an app-level "tap outside to dismiss the keyboard" gesture uses to decide whether a
/// given touch should close the keyboard. Kept separate from the gesture recognizer itself so it
/// can be exercised without a window, a text field, or a running app.
///
/// Two carve-outs, both load-bearing: a tap ON the field being edited must not steal its own focus
/// away mid-edit, and a tap on a transient overlay above it (mention autocomplete) must reach its
/// own button instead of losing the tap to a global dismiss.
enum KeyboardDismissPolicy {
    /// True when a tap at `location`, having hit-tested to `touchedView`, should end editing.
    /// `exemptRects` are in the same coordinate space as `location` (window coordinates in
    /// practice) and come from every view currently marked `.keyboardDismissExempt()`.
    static func shouldDismiss(touchedView: UIView?, location: CGPoint, exemptRects: [CGRect]) -> Bool {
        if isTextInput(touchedView) { return false }
        if exemptRects.contains(where: { $0.contains(location) }) { return false }
        return true
    }

    /// Whether `view`, or anything it sits inside, is a text input. Walks up rather than checking
    /// only `view` itself: the view a tap hit-tests to inside a focused field is often an internal
    /// subview (the field editor, a clear button), not the text field itself.
    static func isTextInput(_ view: UIView?) -> Bool {
        var current = view
        while let v = current {
            if v is UITextField || v is UITextView { return true }
            current = v.superview
        }
        return false
    }
}

// MARK: - Exempt zones

extension View {
    /// Marks a subtree the app-level keyboard-dismiss tap must never dismiss through, even though
    /// it sits inside otherwise-plain content above the keyboard.
    ///
    /// Used for `MentionSuggestions`: without it, picking a mention would both insert it AND close
    /// the keyboard out from under the person still typing, because the same tap that presses the
    /// suggestion also lands on the app-level recognizer.
    func keyboardDismissExempt() -> some View {
        background(KeyboardDismissExemptProbe())
    }
}

/// A non-interactive probe used only to learn a marked view's frame in window coordinates. Never
/// takes part in hit testing itself.
private struct KeyboardDismissExemptProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> KeyboardDismissExemptProbeView {
        let view = KeyboardDismissExemptProbeView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        context.coordinator.probe = view
        KeyboardDismissController.shared.register(context.coordinator)
        return view
    }

    func updateUIView(_ uiView: KeyboardDismissExemptProbeView, context: Context) {
        // Re-registering keeps the recorded rect in sync as MentionSuggestions grows or shrinks
        // with the number of matches. `register` is a cheap dictionary write, not a fresh install.
        KeyboardDismissController.shared.register(context.coordinator)
    }

    func makeCoordinator() -> KeyboardDismissExemptZone { KeyboardDismissExemptZone() }

    static func dismantleUIView(_ uiView: KeyboardDismissExemptProbeView, coordinator: KeyboardDismissExemptZone) {
        KeyboardDismissController.shared.unregister(coordinator)
    }
}

/// The probe view proper. It exists as a subclass for one reason, matching `PinchZoomProbe`:
/// `didMoveToWindow` is the first moment the window is known, and the window is where the
/// app-level recognizer has to live.
private final class KeyboardDismissExemptProbeView: UIView {
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let window { KeyboardDismissController.shared.install(on: window) }
    }
}

/// One registered exempt zone. Held weakly by the probe so a dismissed sheet or a scrolled-away
/// suggestion row cannot keep anything alive.
@MainActor
final class KeyboardDismissExemptZone {
    fileprivate weak var probe: UIView?

    fileprivate var rectInWindow: CGRect? {
        guard let probe, let window = probe.window, probe.bounds.width > 0 else { return nil }
        return probe.convert(probe.bounds, to: window)
    }
}

// MARK: - App-level installation

extension View {
    /// Installs the single, app-level "tap anywhere to dismiss the keyboard" gesture. Meant for
    /// exactly one call site at the root of the view hierarchy — every other screen just gets the
    /// behaviour for free, the same way `.keyboardDismissExempt()` opts specific content out of it.
    func dismissesKeyboardOnBackgroundTap() -> some View {
        background(KeyboardDismissRootProbe())
    }
}

/// The same window-discovery trick as `KeyboardDismissExemptProbe`, used once at the app root so
/// the recognizer's home window is known even on a launch with no mention suggestions on screen.
private struct KeyboardDismissRootProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> KeyboardDismissExemptProbeView {
        let view = KeyboardDismissExemptProbeView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ uiView: KeyboardDismissExemptProbeView, context: Context) {}
}

// MARK: - Controller

/// Owns the window-level tap recognizer and the set of currently-exempt rects.
///
/// The recognizer is attached only between `keyboardWillShow` and `keyboardWillHide`, so a device
/// with no keyboard up has nothing extra intercepting touches at all. `cancelsTouchesInView` is
/// false: this OBSERVES taps, it never swallows one, so every reaction chip, Reply, the like heart,
/// and the composer's own buttons keep working exactly as they did before this existed.
@MainActor
final class KeyboardDismissController: NSObject {
    static let shared = KeyboardDismissController()

    private var zones: [ObjectIdentifier: KeyboardDismissExemptZone] = [:]
    private weak var window: UIWindow?
    private var tap: UITapGestureRecognizer?
    private var observersInstalled = false

    fileprivate func register(_ zone: KeyboardDismissExemptZone) {
        zones = zones.filter { $0.value.probe != nil }
        zones[ObjectIdentifier(zone)] = zone
    }

    fileprivate func unregister(_ zone: KeyboardDismissExemptZone) {
        zones[ObjectIdentifier(zone)] = nil
    }

    /// Records the app's window and, the first time this is called, starts listening for the
    /// keyboard's own show/hide notifications. Idempotent, so a sheet with a `MentionSuggestions`
    /// host presenting and dismissing repeatedly can never stack observers or leave a stray
    /// recognizer behind — `keyboardWillHide` always tears down whatever `keyboardWillShow` built.
    fileprivate func install(on window: UIWindow) {
        self.window = window
        guard !observersInstalled else { return }
        observersInstalled = true
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow),
                                                name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide),
                                                name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    @objc private func keyboardWillShow() { attachTap() }
    @objc private func keyboardWillHide() { detachTap() }

    private func attachTap() {
        guard tap == nil, let window else { return }
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        // The whole point: observe without consuming, so nothing underneath ever loses a touch.
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
        window.addGestureRecognizer(recognizer)
        tap = recognizer
    }

    private func detachTap() {
        guard let tap else { return }
        tap.view?.removeGestureRecognizer(tap)
        self.tap = nil
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        // `false`: ask politely rather than force it. A field that genuinely refuses to resign
        // (there are none of those here) is left alone rather than yanked out of edit mode.
        window?.endEditing(false)
    }
}

extension KeyboardDismissController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let window else { return true }
        let location = touch.location(in: window)
        let exemptRects = zones.values.compactMap(\.rectInWindow)
        return KeyboardDismissPolicy.shouldDismiss(touchedView: touch.view, location: location, exemptRects: exemptRects)
    }
}
