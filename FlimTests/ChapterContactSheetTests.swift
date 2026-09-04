import Testing
import UIKit
@testable import Flim

/// The chapter contact sheet's grid geometry: cell rects for N photos in a 3-wide grid, the
/// header/footer strips, and the total canvas size. Pure math, no image ever touches it, which is
/// what makes the trap this replaces ("does a partial last row stretch to fill the width") testable
/// without rendering a single pixel.
struct ChapterContactSheetTests {

    // MARK: - Cell count and ordering

    @Test("a full curated deck of 15 fills exactly 5 rows of 3")
    func fullDeckFillsGrid() {
        let layout = ChapterContactSheet.layout(photoCount: 15)
        #expect(layout.cellRects.count == 15)
        // Row-major, left to right then down: index 0 is the top-left cell, index 14 the
        // bottom-right one.
        #expect(layout.cellRects[0].minX < layout.cellRects[1].minX)
        #expect(layout.cellRects[0].minY == layout.cellRects[2].minY, "first row shares one y")
        #expect(layout.cellRects[3].minY > layout.cellRects[0].minY, "second row sits below the first")
        #expect(layout.cellRects.last!.minY > layout.cellRects[0].minY)
    }

    @Test("seven photos fill two full rows and leave the third partial")
    func partialLastRow() {
        let layout = ChapterContactSheet.layout(photoCount: 7)
        #expect(layout.cellRects.count == 7)
        // Exactly the placed cells exist. The grid does not stretch what's there to cover a
        // fuller row, it simply has fewer rects: cell 6 (index 6, the seventh photo) sits alone
        // in the third row, at the same width as every other cell.
        let cellWidth = ChapterContactSheet.cellSize().width
        for rect in layout.cellRects {
            #expect(abs(rect.width - cellWidth) < 0.01, "a partial row must not stretch its cells")
        }
        // Third row (index 6) starts a fresh row below the second (indices 3-5).
        #expect(layout.cellRects[6].minY > layout.cellRects[3].minY)
        #expect(layout.cellRects[6].minX == layout.cellRects[0].minX, "a lone cell still sits left")
    }

    @Test("a single photo occupies just the first cell")
    func onePhoto() {
        let layout = ChapterContactSheet.layout(photoCount: 1)
        #expect(layout.cellRects.count == 1)
        #expect(layout.cellRects[0].minX == ChapterContactSheet.outerMargin)
        #expect(layout.cellRects[0].minY == ChapterContactSheet.headerHeight)
    }

    @Test("zero photos places nothing and costs no grid height")
    func zeroPhotos() {
        let layout = ChapterContactSheet.layout(photoCount: 0)
        #expect(layout.cellRects.isEmpty)
        #expect(layout.gridHeight == 0)
    }

    @Test("more than the curated cap is clamped to one full sheet")
    func capsAtCapacity() {
        let layout = ChapterContactSheet.layout(photoCount: 40)
        #expect(layout.cellRects.count == ChapterContactSheet.capacity)
    }

    // MARK: - Header, footer, total height

    @Test("the header and footer strips are constant regardless of how many photos are placed")
    func headerAndFooterAreFixed() {
        for count in [0, 1, 7, 15] {
            let layout = ChapterContactSheet.layout(photoCount: count)
            #expect(layout.headerHeight == ChapterContactSheet.headerHeight)
            #expect(layout.footerHeight == ChapterContactSheet.footerHeight)
        }
    }

    @Test("total height follows the grid: fewer rows means a shorter sheet")
    func totalHeightFollowsRowCount() {
        let one = ChapterContactSheet.layout(photoCount: 1)
        let seven = ChapterContactSheet.layout(photoCount: 7)
        let fifteen = ChapterContactSheet.layout(photoCount: 15)

        // 1 row, 3 rows, 5 rows: strictly increasing height, and the header/footer alone
        // account for none of the difference.
        #expect(one.totalSize.height < seven.totalSize.height)
        #expect(seven.totalSize.height < fifteen.totalSize.height)

        let cellHeight = ChapterContactSheet.cellSize().height
        let gutter = ChapterContactSheet.gutter
        let expectedFifteen = ChapterContactSheet.headerHeight + ChapterContactSheet.footerHeight
            + 5 * cellHeight + 4 * gutter
        #expect(abs(fifteen.totalSize.height - expectedFifteen) < 0.01)
    }

    @Test("the sheet's width is fixed no matter how many photos are placed")
    func widthIsFixed() {
        for count in [0, 1, 7, 15] {
            #expect(ChapterContactSheet.layout(photoCount: count).totalSize.width == ChapterContactSheet.width)
        }
    }

    // MARK: - Rendering

    private func solidImage(_ size: CGSize = CGSize(width: 300, height: 400),
                            colour: UIColor = .darkGray) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            colour.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    @Test("rendering with no images at all returns nil rather than a blank sheet")
    func noImagesRendersNil() {
        let sheet = ChapterContactSheet.render(images: [], chapterCode: "08", monthName: "August",
                                               statsLine: "1 shot", appName: "FLIM")
        #expect(sheet == nil)
    }

    @Test("rendering N images produces a canvas matching that photo count's own layout")
    func renderMatchesLayout() {
        let images = (0..<7).map { _ in solidImage() }
        let sheet = ChapterContactSheet.render(images: images, chapterCode: "08", monthName: "August",
                                               statsLine: "34 shots · 2 rolls", appName: "FLIM")
        let expected = ChapterContactSheet.layout(photoCount: 7).totalSize
        // `UIGraphicsImageRenderer` pixel-aligns the canvas it actually allocates, so a
        // fractional layout height (the grid math divides cleanly by 3 but not always by a whole
        // pixel) can round up by under a point; the layout math itself stays exact.
        #expect(sheet?.size.width == expected.width)
        #expect(abs((sheet?.size.height ?? 0) - expected.height) < 1)
    }

    @Test("more images than the curated cap still renders exactly one sheet")
    func renderCapsAtCapacity() {
        let images = (0..<40).map { _ in solidImage() }
        let sheet = ChapterContactSheet.render(images: images, chapterCode: "08", monthName: "August",
                                               statsLine: "40 shots", appName: "FLIM")
        let expected = ChapterContactSheet.layout(photoCount: ChapterContactSheet.capacity).totalSize
        #expect(sheet?.size.width == expected.width)
        #expect(abs((sheet?.size.height ?? 0) - expected.height) < 1)
    }
}
