import XCTest
@testable import Flim

/// The film catalog + look lookup.
final class FilmStockTests: XCTestCase {
    func testCatalogContainsAllPacks() {
        let ids = Set(FilmStock.catalog.map(\.id))
        XCTAssertEqual(FilmStock.catalog.count, 4)
        XCTAssertEqual(ids, ["flim_original", "noir", "sunwash", "faded88"])
    }

    func testUnknownIdFallsBackToOriginal() {
        XCTAssertEqual(FilmStock.stock(id: "does-not-exist").id, FilmStock.original.id)
    }

    func testKnownIdResolves() {
        XCTAssertEqual(FilmStock.stock(id: "noir").id, "noir")
    }

    func testNoirIsMonochromeAndOriginalIsNot() {
        XCTAssertTrue(FilmStock.noir.params.monochrome)
        XCTAssertFalse(FilmStock.original.params.monochrome)
    }

    func testEverySwatchHasTwoStops() {
        for stock in FilmStock.catalog {
            XCTAssertEqual(stock.swatch.count, 2, "\(stock.id) swatch should be a 2-stop gradient")
        }
    }
}
