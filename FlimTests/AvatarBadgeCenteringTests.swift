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

    // MARK: - Uniform pill width

    /// Renders the real flanking component and measures the two gold founding pills by pixel, the
    /// only way to catch what actually broke twice here. `BadgePillMetrics` was correct both
    /// times; what failed was the wiring, first a `PreferenceKey` collecting from a subtree that
    /// did not contain the pills, then an environment value set on `avatar()` before the overlays
    /// that hold them. Neither is visible to a unit test of the measurement, and both shipped a
    /// truncated FOUNDING 100 to a real phone.
    ///
    /// Founding pills are used because their fill is a solid gold gradient, unmistakable against
    /// the black ground and the red stand-in avatar: gold is bright in red AND green, the avatar
    /// is bright in red alone.
    private func goldPillWidths() -> [CGFloat] {
        let content = ZStack {
            Color.black
            AvatarBadgeFlanking(
                leftBadges: [ProfileBadge(id: "founder", kind: .founder, earnedAt: .now)],
                rightBadges: [ProfileBadge(id: "founding_100", kind: .founding100, earnedAt: .now)]
            ) {
                Circle().fill(Color.red).frame(width: 88, height: 88)
            }
        }
        .frame(width: 420, height: 160)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        guard let image = renderer.cgImage,
              let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return [] }
        let length = CFDataGetLength(data)
        let bytesPerRow = image.bytesPerRow
        let bytesPerPixel = max(image.bitsPerPixel / 8, 1)
        let y = image.height / 2

        // Gold pixel positions, split by which side of the avatar they fall on. Deliberately an
        // EXTENT per side rather than contiguous runs: the label is dark ink on gold, so a run
        // scan measures the gap between two letters, which is how the first version of this test
        // reported a 27-point pill and failed against correct code.
        var left: (min: Int, max: Int)?
        var right: (min: Int, max: Int)?
        let midpoint = image.width / 2
        for x in 0..<image.width {
            let offset = y * bytesPerRow + x * bytesPerPixel
            guard offset + 2 < length else { continue }
            let c = [Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2])]
            // Solid gold: two channels bright, one dark. Order-agnostic like the avatar scan
            // above, and strict enough that the pill's own soft glow (the same gold at low alpha
            // over black, so far dimmer) cannot satisfy it.
            let isGold = c.filter { $0 > 150 }.count == 2 && c.filter { $0 < 140 }.count == 1
            guard isGold else { continue }
            if x < midpoint {
                left = left.map { (Swift.min($0.min, x), Swift.max($0.max, x)) } ?? (x, x)
            } else {
                right = right.map { (Swift.min($0.min, x), Swift.max($0.max, x)) } ?? (x, x)
            }
        }
        return [left, right].compactMap { side in
            side.map { CGFloat($0.max - $0.min + 1) }
        }
    }

    @Test("both founding pills render at the same width")
    func flankingPillsShareOneWidth() {
        let widths = goldPillWidths()
        #expect(widths.count == 2, "expected two gold pills, found \(widths.count): \(widths)")
        guard widths.count == 2 else { return }
        #expect(abs(widths[0] - widths[1]) <= 1.5,
                "pills differ: \(widths[0]) vs \(widths[1]) — the group width is not reaching them")
    }

    @Test("the shared width fits the wider of the two labels")
    func flankingPillsFitTheWidestLabel() {
        let widths = goldPillWidths()
        guard let rendered = widths.first else {
            Issue.record("no gold pill rendered")
            return
        }
        // What FOUNDING 100 needs. Rendering meaningfully narrower than this is the truncation
        // bug. The tolerance is the rim: `BadgePillLabel` strokes a 0.75pt near-white border, and
        // those two edges are not gold, so a gold-extent measurement always lands about 1.5pt
        // under the true frame. Three points of slack absorbs that without being loose enough to
        // let a genuinely squeezed pill through, since the failure mode here was pills at the
        // avatar's 88 points against a required 107.
        let needed = BadgePillMetrics.uniformWidth(for: [.founder, .founding100]) ?? 0
        #expect(rendered >= needed - 3,
                "pill rendered at \(rendered) but FOUNDING 100 needs \(needed)")
    }
}
