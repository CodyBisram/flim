import AudioToolbox
import Foundation

/// A tiny sound cue for the one moment that earns it, the reveal. FLIM's own "developed" sound,
/// the same one its develop notification plays, so the chime you hear in your pocket is the one
/// the photos arrive to. Gated by a Settings toggle so it's never forced.
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

    /// The bundled sound files. Push payloads name them the same way (`aps.sound`), in the
    /// send-develop-push, send-social-push, send-daily-digest and send-one-shot-push functions.
    static let developedFile = "flim_developed.caf"

    /// Registered once. A system sound (not an audio session) on purpose: it follows the ringer
    /// switch and the alert volume exactly as the old built-in chime did.
    private static let developedID: SystemSoundID? = {
        guard let url = Bundle.main.url(forResource: "flim_developed", withExtension: "caf") else { return nil }
        var id: SystemSoundID = 0
        return AudioServicesCreateSystemSoundID(url as CFURL, &id) == noErr ? id : nil
    }()

    /// A light chime when photos develop.
    static func reveal() {
        guard enabled else { return }
        AudioServicesPlaySystemSound(developedID ?? 1057)   // 1057 is Tink, if the file is missing
    }
}
