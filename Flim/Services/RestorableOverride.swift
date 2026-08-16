import Foundation
import UIKit

/// A value some external system owns (screen brightness, a capture device's exposure ceiling)
/// that gets pushed to a different value for a while and must always come back afterwards,
/// however that "while" ends.
///
/// Built for `CameraViewModel`'s front-camera screen flash, which raised the display's backlight
/// (see `capturePhoto()`) without ever putting it back. Restoring correctly on EVERY exit path
/// (a successful capture, a capture error, the watchdog giving up, the app backgrounding
/// mid-capture, the user switching cameras or navigating away mid-capture) matters more than any
/// individual call site remembering to do it, so this collapses all of those onto two rules
/// instead of trusting one call site per exit path:
///
/// 1. `restore()` is idempotent. Calling it when nothing is overridden is a no-op, so every exit
///    path can call it unconditionally instead of first working out whether THIS exit path is
///    the one responsible for cleanup right now.
/// 2. Backgrounding restores itself. `begin()` registers for
///    `UIApplication.willResignActiveNotification` and calls `restore()` when it fires, so the
///    exit path most likely to be forgotten by a call site (the user leaving the app mid-capture)
///    does not depend on any call site remembering it at all.
///
/// `get`/`set` are supplied per `begin()` call rather than fixed at `init`, so a caller can close
/// over context only known at that moment, e.g. `CameraViewModel.capturePhoto()` closing over the
/// specific `AVCaptureDevice` in use for THIS capture, which may not be the device still current
/// by the time `restore()` runs after a camera flip.
@MainActor
final class RestorableOverride<Value> {
    private var restoreAction: (() -> Void)?
    private var resignObserver: NSObjectProtocol?
    private let center: NotificationCenter
    private let resignNotification: Notification.Name

    init(
        center: NotificationCenter = .default,
        resignNotification: Notification.Name = UIApplication.willResignActiveNotification
    ) {
        self.center = center
        self.resignNotification = resignNotification
    }

    /// Whether a `begin()` is still outstanding and needs `restore()`.
    var isOverridden: Bool { restoreAction != nil }

    /// Saves whatever `get()` reads right now (unless a save is already outstanding), then
    /// pushes `value` via `set`.
    ///
    /// Calling this again while already overridden does NOT re-save: `get()` would read back the
    /// value THIS override already pushed, not the original one, which would make `restore()`
    /// "restore" to the overridden value instead of the real original.
    func begin(get: () -> Value, set: @escaping (Value) -> Void, to value: Value) {
        if restoreAction == nil {
            let saved = get()
            restoreAction = { set(saved) }
            resignObserver = center.addObserver(forName: resignNotification, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor in self?.restore() }
            }
        }
        set(value)
    }

    /// Puts the value back and clears the outstanding save. Safe to call with nothing
    /// outstanding, that is what lets every exit path call this unconditionally rather than
    /// tracking whether a `begin()` actually happened on the path that led here.
    func restore() {
        guard let restoreAction else { return }
        self.restoreAction = nil
        restoreAction()
        if let resignObserver {
            center.removeObserver(resignObserver)
            self.resignObserver = nil
        }
    }
}

/// The screen actually showing the camera UI right now. `UIScreen.main` is deprecated: with more
/// than one scene possible on screen there is no single "the" screen anymore. This app is
/// single-window, but the deprecation is on the API shape, not on that assumption, so this reads
/// the screen off the active window scene instead. Falls back to the first connected window
/// scene if none is reported foreground-active (e.g. mid-transition), rather than returning `nil`
/// and silently no-opping the brightness boost this backs.
@MainActor
func activeScreen() -> UIScreen? {
    let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    return (windowScenes.first { $0.activationState == .foregroundActive } ?? windowScenes.first)?.screen
}
