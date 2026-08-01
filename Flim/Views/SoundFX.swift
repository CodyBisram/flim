import AudioToolbox
import Foundation

/// A tiny sound cue for the one moment that earns it, the reveal. Uses a built-in system sound
/// (no bundled assets) and is gated by a Settings toggle so it's never forced.
///
/// There is deliberately no shutter sound here: `AVCapturePhotoOutput` plays the system
/// camera-shutter sound itself, correctly timed to the actual capture and after the flash fires.
/// This file used to carry a `shutter()` that nothing called, removed after playing our own on
/// top of the system one produced a double click with flash enabled (see CameraView.capture()).
enum SoundFX {
    private static var enabled: Bool {
        // Default on; users can silence it in Settings.
        UserDefaults.standard.object(forKey: "soundEffects") as? Bool ?? true
    }

    /// A light chime when photos develop.
    static func reveal() {
        guard enabled else { return }
        AudioServicesPlaySystemSound(1057)   // Tink
    }
}
