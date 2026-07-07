import Foundation
import UIKit

/// App metadata + distribution channel — used for the Settings footer, feedback email, and to
/// gate the temporary password sign-in so it can't ship to the public App Store.
enum AppInfo {
    /// The app's display name, used in all user-facing copy. To rename the app, change this here
    /// (covers the whole UI) plus CFBundleDisplayName in project.yml (the home-screen name).
    static let appName = "FLIM"

    /// Where in-app feedback is emailed. Change to your address.
    static let feedbackEmail = "codyysb@gmail.com"

    /// Hosted legal pages (required for the App Store).
    static let privacyPolicyURL = URL(string: "https://flim-app.com/privacy")!
    static let termsURL = URL(string: "https://flim-app.com/terms")!

    /// A roll invite as a real https link — tappable in Messages. It lands on flim-app.com/join
    /// (which shows the code + an "Open" button), and opens the app directly once the
    /// Associated Domains entitlement is live (universal links).
    static func rollInviteLink(code: String) -> URL {
        URL(string: "https://flim-app.com/join/\(code)")!
    }

    /// The share-sheet message for inviting someone to a roll.
    static func rollInviteMessage(rollName: String, code: String) -> String {
        "Join my roll “\(rollName)” on \(appName) 🎞\n\(rollInviteLink(code: code).absoluteString)\n(code: \(code))"
    }

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
        let body = "\n\n——\nApp: \(appName) \(versionString)\niOS: \(UIDevice.current.systemVersion)"
        var comps = URLComponents()
        comps.scheme = "mailto"
        comps.path = feedbackEmail
        comps.queryItems = [
            URLQueryItem(name: "subject", value: "\(appName) feedback"),
            URLQueryItem(name: "body", value: body)
        ]
        return comps.url
    }
}
