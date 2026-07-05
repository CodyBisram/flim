import Foundation
import UIKit

/// App metadata + distribution channel — used for the Settings footer, feedback email, and to
/// gate the temporary password sign-in so it can't ship to the public App Store.
enum AppInfo {
    /// Where in-app feedback is emailed. Change to your address.
    static let feedbackEmail = "codyysb@gmail.com"

    /// Hosted privacy policy (required for the App Store). Replace with your real URL once hosted.
    static let privacyPolicyURL = URL(string: "https://flim.app/privacy")!

    /// e.g. "1.0 (42)"
    static var versionString: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    /// True ONLY for a public App Store build (production receipt). DEBUG and TestFlight are false —
    /// so the password sign-in stays available while testing but auto-disappears on public release.
    static var isAppStore: Bool {
        #if DEBUG
        return false
        #else
        guard let url = Bundle.main.appStoreReceiptURL else { return false }
        return url.lastPathComponent != "sandboxReceipt"
        #endif
    }

    /// A pre-filled feedback email (Mail app), stamped with the build so bug reports self-identify.
    static var feedbackMailURL: URL? {
        let body = "\n\n——\nApp: FLIM \(versionString)\niOS: \(UIDevice.current.systemVersion)"
        var comps = URLComponents()
        comps.scheme = "mailto"
        comps.path = feedbackEmail
        comps.queryItems = [
            URLQueryItem(name: "subject", value: "FLIM feedback"),
            URLQueryItem(name: "body", value: body)
        ]
        return comps.url
    }
}
