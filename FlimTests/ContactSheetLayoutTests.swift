import Testing
import CoreGraphics
@testable import Flim

/// The contact sheet's grid arithmetic: where each frame goes for anything from a single photo to
/// a full roll. This is the part most likely to be quietly wrong (an off-by-one that overlaps two
/// frames, or a lone photo that overflows a tall canvas), and it is pure geometry, so it is cheap
/// to pin exactly rather than only eyeballing a render.
struct ContactSheetLayoutTests {

    // A representative grid rect: the middle band of the actual 1080x1920 canvas, after the
    // header/footer/inset are carved out, not some arbitrary square.
    private var gridRect: CGRect {
        ContactSheetLayout.regions(canvas: ContactSheetRenderer.canvasSize).grid
    }

    private func rectsOverlap(_ a: CGRect, _ b: CGRect) -> Bool {
        let intersection = a.intersection(b)
        // A hairline float-rounding touch isn't a real overlap; a shared chunk of area is.
        return !intersection.isNull && intersection.width > 0.5 && intersection.height > 0.5
    }

    private func isContained(_ inner: CGRect, in outer: CGRect, epsilon: CGFloat = 0.5) -> Bool {
        inner.minX >= outer.minX - epsilon && inner.maxX <= outer.maxX + epsilon &&
        inner.minY >= outer.minY - epsilon && inner.maxY <= outer.maxY + epsilon
    }

    // MARK: - Frame counts

    @Test("a single photo fills its rect without overflowing either dimension", arguments: [1])
    func singleFrame(count: Int) {
        let rects = ContactSheetLayout.frameRects(count: count, in: gridRect)
        #expect(rects.count == count)
        for rect in rects {
            #expect(isContained(rect, in: gridRect))
        }
    }

    @Test("two photos are laid out without overlapping or leaving the canvas")
    func twoFrames() {
        let rects = ContactSheetLayout.frameRects(count: 2, in: gridRect)
        #expect(rects.count == 2)
        for rect in rects { #expect(isContained(rect, in: gridRect)) }
        #expect(!rectsOverlap(rects[0], rects[1]))
    }

    @Test("three photos, an underfull last row, still don't overlap or overflow")
    func threeFrames() {
        let rects = ContactSheetLayout.frameRects(count: 3, in: gridRect)
        #expect(rects.count == 3)
        for rect in rects { #expect(isContained(rect, in: gridRect)) }
        for i in 0..<rects.count {
            for j in (i + 1)..<rects.count {
                #expect(!rectsOverlap(rects[i], rects[j]), "frame \(i) and \(j) overlap")
            }
        }
    }

    @Test("four photos land in a clean grid, fully inside the canvas")
    func fourFrames() {
        let rects = ContactSheetLayout.frameRects(count: 4, in: gridRect)
        #expect(rects.count == 4)
        for rect in rects { #expect(isContained(rect, in: gridRect)) }
        for i in 0..<rects.count {
            for j in (i + 1)..<rects.count {
                #expect(!rectsOverlap(rects[i], rects[j]))
            }
        }
    }

    @Test("a full roll (30, the cap) still tiles without overlapping or spilling out")
    func largeRoll() {
        let count = ContactSheetRenderer.maxFrames
        let rects = ContactSheetLayout.frameRects(count: count, in: gridRect)
        #expect(rects.count == count)
        for rect in rects {
            #expect(isContained(rect, in: gridRect))
            // A degenerate (zero-area) cell would mean the grid silently gave up on fitting
            // everything rather than shrinking frames to fit.
            #expect(rect.width > 0)
            #expect(rect.height > 0)
        }
        for i in 0..<rects.count {
            for j in (i + 1)..<rects.count {
                #expect(!rectsOverlap(rects[i], rects[j]), "frame \(i) and \(j) overlap")
            }
        }
    }

    @Test("every count from 1 through the cap produces exactly that many non-overlapping, contained frames")
    func everyCountUpToTheCap() {
        for count in 1...ContactSheetRenderer.maxFrames {
            let rects = ContactSheetLayout.frameRects(count: count, in: gridRect)
            #expect(rects.count == count, "count \(count)")
            for rect in rects {
                #expect(isContained(rect, in: gridRect), "count \(count) overflowed the canvas")
            }
            for i in 0..<rects.count {
                for j in (i + 1)..<rects.count {
                    #expect(!rectsOverlap(rects[i], rects[j]), "count \(count): frame \(i) and \(j) overlap")
                }
            }
        }
    }

    // MARK: - Degenerate input

    @Test("zero photos produces zero frames, not a crash")
    func zeroFrames() {
        #expect(ContactSheetLayout.frameRects(count: 0, in: gridRect).isEmpty)
    }

    @Test("a zero-size rect produces zero frames rather than dividing by zero")
    func zeroSizeRect() {
        let degenerate = CGRect(x: 0, y: 0, width: 0, height: 0)
        #expect(ContactSheetLayout.frameRects(count: 5, in: degenerate).isEmpty)
    }

    // MARK: - Regions

    @Test("header, grid and footer partition the canvas without overlapping")
    func regionsPartitionTheCanvas() {
        let canvas = ContactSheetRenderer.canvasSize
        let regions = ContactSheetLayout.regions(canvas: canvas)
        #expect(regions.header.minY == 0)
        #expect(regions.footer.maxY == canvas.height)
        #expect(regions.header.maxY == regions.grid.minY)
        #expect(regions.grid.maxY == regions.footer.minY)
        #expect(regions.grid.width < canvas.width, "the grid is inset from the canvas edges")
    }

    @Test("the grid region never goes negative even if header + footer would overrun the canvas")
    func regionsClampWhenBandsOverrun() {
        let canvas = CGSize(width: 400, height: 300)
        let regions = ContactSheetLayout.regions(canvas: canvas, headerHeight: 200, footerHeight: 200, inset: 20)
        #expect(regions.grid.height == 0)
    }
}
