#if DEBUG
import SwiftUI
import UIKit

/// Fixture frames for `RollDetailDemoHost`: a roll, its photos, and a file URL per photo.
struct RollDetailDemoFixture {
    let roll: Roll
    let photos: [Photo]
    let urls: [UUID: URL]

    /// A developed roll of nine frames by default; with `developing`, the same roll before its
    /// reveal, every frame still dark.
    static func make(developing: Bool) -> RollDetailDemoFixture {
        let owner = UUID(uuidString: "00000000-0000-0000-0000-000000009200") ?? UUID()
        let created = Date.now.addingTimeInterval(developing ? -3600 : -86_400)
        let reveal = developing ? Date.now.addingTimeInterval(4 * 3600) : created.addingTimeInterval(12 * 3600)
        let roll = Roll(id: UUID(uuidString: "00000000-0000-0000-0000-000000009201") ?? UUID(),
                        name: "Test, day 2", inviteCode: "DEMO42", createdBy: owner,
                        createdAt: created, revealAt: reveal)
        var photos: [Photo] = []
        var urls: [UUID: URL] = [:]
        for index in 0..<9 {
            let id = UUID()
            let path = "rollDetailDemo/p\(index).jpg"
            photos.append(Photo(id: id, userId: owner, rollId: roll.id, storagePath: path,
                                thumbPath: path, feedPath: path,
                                takenAt: created.addingTimeInterval(TimeInterval(600 * (index + 1))),
                                developsAt: reveal, isDeveloped: !developing, caption: nil, isSorted: true))
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("rollDetailDemo-\(index).jpg")
            if let data = gradient(hue: CGFloat(index) / 9).jpegData(compressionQuality: 0.85),
               (try? data.write(to: file)) != nil {
                urls[id] = file
            }
        }
        return RollDetailDemoFixture(roll: roll, photos: photos, urls: urls)
    }

    private static func gradient(hue: CGFloat) -> UIImage {
        let size = CGSize(width: 600, height: 800)
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

/// Simulator-only harness for a roll's detail screen, launched with `-rollDetailDemo`: a
/// developed roll pushed onto the Rolls tab's stack, as a member sees it after the reveal, or
/// the same roll still developing with `-rollDetailDeveloping`. Sign-in is OTP-only, so the
/// screen is otherwise unreachable on a simulator. Nothing here touches the network: the view
/// takes the fixture in place of its load (`RollDetailView.demoFixture`).
struct RollDetailDemoHost: View {
    @Environment(\.flimAccent) private var accent
    @Environment(RollService.self) private var rolls
    // Built before the stack exists, not in `.task`: a destination closure that first ran with
    // no fixture is not asked again, and the pushed screen stayed blank.
    @State private var fixture = RollDetailDemoFixture.make(
        developing: ProcessInfo.processInfo.arguments.contains("-rollDetailDeveloping"))
    @State private var path: [Roll] = []
    @State private var selection = 2

    var body: some View {
        TabView(selection: $selection) {
            Tab("Camera", systemImage: MainTabSymbol.camera, value: 0) { Color.black }
            Tab("Darkroom", systemImage: MainTabSymbol.darkroom, value: 1) { Color.black }
            Tab("Rolls", systemImage: MainTabSymbol.rolls, value: 2) {
                NavigationStack(path: $path) {
                    FlimTheme.bg.ignoresSafeArea()
                        .navigationDestination(for: Roll.self) { roll in
                            RollDetailView(roll: roll, demoFixture: fixture)
                        }
                }
            }
            Tab("Feed", systemImage: MainTabSymbol.feed, value: 3) { Color.black }
        }
        .tint(accent)
        .preferredColorScheme(.dark)
        .task {
            guard path.isEmpty else { return }
            rolls.memberCounts[fixture.roll.id] = 1
            path = [fixture.roll]
        }
    }
}
#endif
