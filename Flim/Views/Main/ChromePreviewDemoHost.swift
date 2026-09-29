#if DEBUG
import SwiftUI
import UIKit

/// Simulator-only harness for the app's own chrome, launched with `-chromePreviewDemo`: the
/// real `MainTabView` (tab bar, Camera controls, the Feed and Rolls headers) without an
/// account. Sign-in is OTP-only, so none of it is otherwise reachable on a simulator.
///
/// The Feed tab runs on `FeedPreviewFixtures`, so there is a scrolling list to minimize the
/// tab bar against. Nobody is signed in, so Rolls lands on its empty state and nothing asks
/// the network for an account's data. Pick the tab with the existing launch arguments:
/// `-tabFeed` for Feed, `-seedRoll` for Rolls (with no account its seeding step is a no-op),
/// none for Camera.
///
/// The first-run covers (onboarding, the camera coach, the notification primer) are marked
/// done on the way in, or they would sit over every screenshot.
struct ChromePreviewDemoHost: View {
    @Environment(FeedService.self) private var feed
    @State private var seeded = false

    var body: some View {
        Group {
            if seeded {
                MainTabView()
            } else {
                Color.black.ignoresSafeArea()
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            guard !seeded else { return }
            let defaults = UserDefaults.standard
            for key in ["hasOnboarded", "hasSeenCameraCoach", "didShowNotifPrimer", "didRetryUnaskedNotifPrimer"] {
                defaults.set(true, forKey: key)
            }
            // Before `MainTabView` mounts, so `FeedView`'s first `.task` finds a loaded feed
            // and never tries to reload one for an account that is not there.
            FeedPreviewFixtures.seed(into: feed)
            seeded = true
        }
    }
}

/// Simulator-only harness for the full-screen photo viewer's top controls, launched with
/// `-pagerPreviewDemo`: the plain viewer by default, or the Darkroom's night rack with
/// `-pagerNight`. The frames belong to a fixture account that is "signed in" here, so the
/// own-photo controls (the manage menu) show.
struct PagerPreviewDemoHost: View {
    private static let ownerId = UUID(uuidString: "00000000-0000-0000-0000-000000009100") ?? UUID()
    @State private var auth = AuthService()
    @State private var fixture = PagerPreviewDemoHost.makeFixture()

    var body: some View {
        PhotoPagerView(photos: fixture.photos,
                       signedURLs: fixture.urls,
                       showsComments: true,
                       showsNightRack: ProcessInfo.processInfo.arguments.contains("-pagerNight"))
            .environment(auth)
            .preferredColorScheme(.dark)
            .task { auth.currentUser = AppUser(id: Self.ownerId, createdAt: .now) }
    }

    private struct Fixture {
        var photos: [Photo]
        var urls: [UUID: URL]
    }

    /// Four developed frames, each a gradient written to the app's temporary directory so the
    /// viewer has a real file URL to load.
    private static func makeFixture() -> Fixture {
        var fixture = Fixture(photos: [], urls: [:])
        for index in 0..<4 {
            let id = UUID()
            let path = "pagerDemo/p\(index).jpg"
            let takenAt = Date.now.addingTimeInterval(TimeInterval(-3600 * (index + 1)))
            fixture.photos.append(Photo(id: id, userId: ownerId, rollId: nil, storagePath: path,
                                        thumbPath: path, feedPath: path, takenAt: takenAt,
                                        developsAt: .distantPast, isDeveloped: true, caption: nil, isSorted: true))
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("pagerDemo-\(index).jpg")
            if let data = gradient(hue: CGFloat(index) / 4).jpegData(compressionQuality: 0.85),
               (try? data.write(to: file)) != nil {
                fixture.urls[id] = file
            }
        }
        return fixture
    }

    private static func gradient(hue: CGFloat) -> UIImage {
        let size = CGSize(width: 900, height: 1200)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [
                UIColor(hue: hue, saturation: 0.45, brightness: 0.85, alpha: 1).cgColor,
                UIColor(hue: hue, saturation: 0.7, brightness: 0.3, alpha: 1).cgColor,
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                ctx.cgContext.drawLinearGradient(gradient, start: .zero,
                                                 end: CGPoint(x: size.width, y: size.height), options: [])
            }
        }
    }
}
#endif
