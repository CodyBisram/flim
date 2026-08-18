import Testing
import SwiftUI
@testable import Flim

/// Pixel-level regression test for the "one badge shoves the avatar off-centre" bug fixed in
/// `AvatarBadgeFlanking`. The old layout put the avatar and both badge columns in a single
/// HStack and centred that whole group, so a badge on only one side (nothing opposite it) pulled
/// the avatar visibly off the page's true centre, worse the wider that one label was.
///
/// This renders the exact shared component both `UserPageView.pageHeader` and `FlankPreview`
/// build on, with a solid, unmistakable stand-in avatar (pure red, nothing else on screen is
/// ever this saturated), then finds the avatar's rendered horizontal extent by scanning raw
/// pixels and asserts its centre never moves, at 0 through 4 badges and in the specific
/// single-badge case that was actually broken.
@MainActor
struct AvatarBadgeCenteringTests {

    // MARK: - Rendering

    private func avatarCenterX(leftCount: Int, rightCount: Int) -> CGFloat? {
        let content = ZStack {
            Color.black
            AvatarBadgeFlanking(
                leftBadges: badges(count: leftCount, offset: 0),
                rightBadges: badges(count: rightCount, offset: leftCount)
            ) {
                Circle().fill(Color.red).frame(width: 88, height: 88)
            }
        }
        .frame(width: 320, height: 160)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        guard let cgImage = renderer.cgImage else { return nil }
        return redExtentCenterX(in: cgImage)
    }

    private func badges(count: Int, offset: Int) -> [ProfileBadge] {
        // A mix of short ("Shared") and long ("Founding 100") labels, since label width is
        // exactly what used to make the off-centre shove worse.
        let kinds: [ProfileBadgeKind] = [.founding100, .shared, .darkroom, .rollMaker, .wellMet, .fullHouse]
        return (0..<count).map { i in
            let kind = kinds[(offset + i) % kinds.count]
            return ProfileBadge(id: "\(kind.rawValue)-\(offset + i)", kind: kind, earnedAt: .now)
        }
    }

    /// Scans the rendered image's vertical-centre row for the solid red avatar fill and returns
    /// the midpoint of its horizontal extent, in points. Channel order is deliberately not
    /// assumed (RGBA vs BGRA): a pure-red pixel has exactly one channel far above 200 and the
    /// other two far below 80 regardless of which byte holds which channel, and nothing else in
    /// this composition (a black background, translucent accent-wash badge pills) can satisfy
    /// that in any ordering.
    private func redExtentCenterX(in image: CGImage) -> CGFloat? {
        let width = image.width
        let height = image.height
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        let length = CFDataGetLength(data)
        let bytesPerRow = image.bytesPerRow
        let bytesPerPixel = max(image.bitsPerPixel / 8, 1)
        let y = height / 2
        var minX: Int?
        var maxX: Int?
        for x in 0..<width {
            let offset = y * bytesPerRow + x * bytesPerPixel
            guard offset + 2 < length else { continue }
            let channels = [Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2])]
            let isSolidRed = channels.filter { $0 > 200 }.count == 1 && channels.filter { $0 < 80 }.count == 2
            if isSolidRed {
                if minX == nil { minX = x }
                maxX = x
            }
        }
        guard let minX, let maxX else { return nil }
        return CGFloat(minX + maxX) / 2.0
    }

    // MARK: - Tests

    @Test("avatar centre is identical at 0 through 4 badges")
    func avatarStaysCentered() {
        let counts: [(left: Int, right: Int)] = [(0, 0), (0, 1), (1, 1), (1, 2), (2, 2)]
        var centers: [CGFloat] = []
        for (left, right) in counts {
            guard let center = avatarCenterX(leftCount: left, rightCount: right) else {
                Issue.record("Failed to render or locate the avatar for left=\(left) right=\(right)")
                continue
            }
            centers.append(center)
        }
        #expect(centers.count == counts.count)
        guard let first = centers.first else { return }
        for center in centers {
            #expect(abs(center - first) < 1.5)
        }
    }

    @Test("a single flanking badge does not push the avatar off centre (the regression)")
    func singleBadgeDoesNotShiftAvatar() {
        // `badges(count: 1, offset: 0)` picks `founding100`, "Founding 100", the widest label in
        // the catalog and the one Cody's own note calls out as pushing the avatar furthest.
        guard let zero = avatarCenterX(leftCount: 0, rightCount: 0),
              let oneRight = avatarCenterX(leftCount: 0, rightCount: 1),
              let oneLeft = avatarCenterX(leftCount: 1, rightCount: 0)
        else {
            Issue.record("Failed to render")
            return
        }
        #expect(abs(oneRight - zero) < 1.5)
        #expect(abs(oneLeft - zero) < 1.5)
    }
}
