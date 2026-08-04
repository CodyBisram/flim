import Foundation
import UIKit

/// App metadata + distribution channel, used for the Settings footer, feedback email, and to
/// gate TestFlight-only surfaces (like Film Lab's neutral capture) so they can't ship to the
/// public App Store.
enum AppInfo {
    /// The app's display name, used in all user-facing copy. To rename the app, change this here
    /// (covers the whole UI) plus CFBundleDisplayName in project.yml (the home-screen name).
    static let appName = "FLIM"

    /// Where in-app feedback is emailed. Change to your address.
    static let feedbackEmail = "support@flim-app.com"

    /// Hosted legal pages (required for the App Store).
    static let privacyPolicyURL = URL(string: "https://flim-app.com/privacy")!
    static let termsURL = URL(string: "https://flim-app.com/terms")!

    /// The public App Store listing.
    static let appStoreURL = URL(string: "https://apps.apple.com/us/app/flim-disposable-camera/id6786079629")!

    /// A roll invite as a real https link, tappable in Messages. It lands on flim-app.com/join
    /// (which shows the code + an "Open" button), and opens the app directly once the
    /// Associated Domains entitlement is live (universal links).
    static func rollInviteLink(code: String) -> URL {
        URL(string: "https://flim-app.com/join/\(code)")!
    }

    /// The share-sheet message for inviting someone to a roll.
    static func rollInviteMessage(rollName: String, code: String) -> String {
        "Join my roll “\(rollName)” on \(appName) 🎞\n\(rollInviteLink(code: code).absoluteString)\n(code: \(code))"
    }

    /// The share-sheet message for inviting someone to join the app itself with a personal
    /// invite code. A personal invite goes to someone who doesn't have the app yet, so it links
    /// straight to the App Store (not the flim-app.com homepage, which used to dead-end on a
    /// "coming soon" page); the code is entered at sign-up.
    /// A universal link that carries the invite code into the app.
    static func personalInviteURL(code: String) -> URL {
        URL(string: "https://flim-app.com/i/\(code)")!
    }

    /// The message shared from the profile's Invite sheet.
    ///
    /// Leads with the link, because tapping it with the app installed fills the code in and the
    /// person only types their email. The code is ALSO written out in full, deliberately: a fresh
    /// install cannot recover the link that led to it (that needs deferred deep linking, i.e.
    /// third-party attribution), so someone installing for the first time still needs the code in
    /// readable form. The "open this link again" line is the shortest honest instruction for the
    /// path that does work after installing.
    static func personalInviteMessage(code: String) -> String {
        """
        Join me on \(appName).

        \(personalInviteURL(code: code).absoluteString)

        Already installed? Tap the link and your invite code fills itself in.
        New here? Install \(appName) first (\(appStoreURL.absoluteString)), then open the link \
        above again, or enter invite code \(code) when you sign up.
        """
    }

    /// e.g. "1.0 (42)"
    static var versionString: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    /// True ONLY for a public App Store build (production receipt). DEBUG and TestFlight are false,
    /// so TestFlight-only surfaces stay available while testing but auto-disappear on public release.
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
        let body = "\n\n--\nApp: \(appName) \(versionString)\niOS: \(UIDevice.current.systemVersion)"
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
