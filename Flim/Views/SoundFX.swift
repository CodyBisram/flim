import AudioToolbox
import Foundation

/// Tiny sound cues for the moments that earn them — the shutter and the reveal. Uses built-in
/// system sounds (no bundled assets) and is gated by a Settings toggle so it's never forced.
enum SoundFX {
    private static var enabled: Bool {
        // Default on; users can silence it in Settings.
        UserDefaults.standard.object(forKey: "soundEffects") as? Bool ?? true
    }

    /// The camera shutter click.
    static func shutter() {
        guard enabled else { return }
        AudioServicesPlaySystemSound(1108)   // photoShutter
    }

    /// A light chime when photos develop.
    static func reveal() {
        guard enabled else { return }
        AudioServicesPlaySystemSound(1057)   // Tink
    }
}
