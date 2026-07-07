import AppIntents
import Foundation

/// "Take a FLIM Photo" — opens the app straight to the camera. Powers Siri, the Action Button,
/// Spotlight, and the Shortcuts app. (Camera is the default tab, so even a cold launch lands right;
/// a warm launch gets nudged over by the notification.)
struct OpenCameraIntent: AppIntent {
    static var title: LocalizedStringResource = "Take a Photo"
    static var description = IntentDescription("Opens the camera, ready to shoot.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .openCamera, object: nil)
        return .result()
    }
}

/// Registers the app's Siri phrases / Shortcuts actions. Assignable to the Action Button.
struct FlimShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenCameraIntent(),
            phrases: [
                "Take a photo in \(.applicationName)",
                "Open the \(.applicationName) camera",
                "Shoot on \(.applicationName)"
            ],
            shortTitle: "Take Photo",
            systemImageName: "camera.aperture"
        )
    }
}
