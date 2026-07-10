import XCTest
@testable import Flim

/// The film catalog + look lookup. FLIM ships a single, signature look — see
/// `FilmStock.swift`. These tests lock down that shape and the invariants of
/// `FilmStock.original` that the rest of the app (grading, swatches) depends on.
final class FilmStockTests: XCTestCase {
    func testCatalogIsSingleStock() {
        XCTAssertEqual(FilmStock.catalog.count, 1)
        XCTAssertEqual(FilmStock.catalog.map(\.id), ["flim_original"])
        XCTAssertEqual(FilmStock.catalog.first?.id, FilmStock.original.id)
    }

    func testKnownIdResolvesToOriginal() {
        XCTAssertEqual(FilmStock.stock(id: "flim_original").id, FilmStock.original.id)
    }

    func testUnknownIdFallsBackToOriginal() {
        XCTAssertEqual(FilmStock.stock(id: "does-not-exist").id, FilmStock.original.id)
    }

    func testEmptyIdFallsBackToOriginal() {
        XCTAssertEqual(FilmStock.stock(id: "").id, FilmStock.original.id)
    }

    func testOriginalUsesFittedLUT() {
        XCTAssertEqual(FilmStock.original.params.lut, "flim")
    }

    func testOriginalIsNotMonochrome() {
        XCTAssertFalse(FilmStock.original.params.monochrome)
    }

    func testOriginalParamsAreInSaneRanges() {
        let params = FilmStock.original.params
        XCTAssertGreaterThan(params.temperature, 1000)
        XCTAssertLessThan(params.temperature, 12000)
        XCTAssertGreaterThan(params.saturation, 0)
        XCTAssertLessThan(params.saturation, 2)
        XCTAssertGreaterThan(params.contrast, 0)
        XCTAssertLessThan(params.contrast, 2)
        XCTAssertGreaterThanOrEqual(params.blackLift, 0)
        XCTAssertLessThan(params.blackLift, 1)
        XCTAssertGreaterThan(params.highlightRolloff, 0)
        XCTAssertLessThanOrEqual(params.highlightRolloff, 1)
        XCTAssertGreaterThanOrEqual(params.vignetteIntensity, 0)
        XCTAssertGreaterThanOrEqual(params.vignetteRadius, 0)
        XCTAssertGreaterThanOrEqual(params.grain, 0)
        XCTAssertLessThan(params.grain, 0.2)
        XCTAssertGreaterThanOrEqual(params.bloom, 0)
    }

    func testEverySwatchHasTwoStops() {
        for stock in FilmStock.catalog {
            XCTAssertEqual(stock.swatch.count, 2, "\(stock.id) swatch should be a 2-stop gradient")
        }
    }
}
