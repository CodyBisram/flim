import Foundation
import UserNotifications

/// The photo a push names, checked and turned into an attachment. Used by the notification service
/// extension (FlimNotificationService); compiled into the app too, as a second source entry in
/// project.yml, so the checks are tested with the rest of the suite.
enum PushImage {
    /// The project's own storage host (this build's, see `FlimEnvironment`). A URL anywhere else
    /// is not one the server signed.
    static let host = FlimEnvironment.current.supabaseURL.host ?? ""
    static let signedPathPrefix = "/storage/v1/object/sign/photos/"

    static func url(from userInfo: [AnyHashable: Any]) -> URL? {
        guard let flim = userInfo["flim"] as? [String: Any],
              let raw = flim["img"] as? String,
              let url = URL(string: raw),
              url.scheme == "https", url.host == host,
              url.path.hasPrefix(signedPathPrefix)
        else { return nil }
        return url
    }

    /// Feed renditions are JPEGs around 400 kB; anything far past that is not one.
    static let maxBytes = 8 * 1024 * 1024

    static func attachment(movingFrom location: URL) -> UNNotificationAttachment? {
        let size = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? Int) ?? nil
        guard let size, size > 0, size <= maxBytes else { return nil }
        // The attachment needs a file with an image extension, in a place the system can move it
        // from; the download's own temporary file is deleted when the handler returns.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jpg")
        do {
            try FileManager.default.moveItem(at: location, to: file)
            return try UNNotificationAttachment(identifier: "photo", url: file, options: nil)
        } catch {
            return nil
        }
    }
}
