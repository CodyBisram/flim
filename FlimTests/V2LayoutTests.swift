import Testing
import SwiftUI
@testable import Flim

/// v2's frame decides its arrangement from the screen's shape, and drives the same tab selection
/// the App Store app's tab bar does, so every route that picks a tab lands in the right place.
struct V2LayoutTests {

    @Test("regular iPhones in portrait get the phone arrangement")
    func phones() {
        for size in [CGSize(width: 375, height: 667), CGSize(width: 393, height: 852),
                     CGSize(width: 402, height: 874), CGSize(width: 440, height: 956)] {
            #expect(V2LayoutMode.resolve(horizontalSizeClass: .compact, size: size) == .phone)
        }
    }

    @Test("a short, wide compact display is the Duo closed; a regular one is the Duo open")
    func duo() {
        #expect(V2LayoutMode.resolve(horizontalSizeClass: .compact, size: CGSize(width: 466, height: 678)) == .outer)
        #expect(V2LayoutMode.resolve(horizontalSizeClass: .regular, size: CGSize(width: 626, height: 890)) == .inner)
        #expect(V2LayoutMode.resolve(horizontalSizeClass: .regular, size: CGSize(width: 890, height: 626)) == .inner)
    }

    @Test("a zero size, before layout, is the phone arrangement")
    func zeroSize() {
        #expect(V2LayoutMode.resolve(horizontalSizeClass: nil, size: .zero) == .phone)
    }

    @Test("open, Personal and Darkroom are one page and Friends the other")
    func innerPages() {
        let inner = V2LayoutMode.inner
        #expect(inner.placeGroups == [[.personal, .darkroom], [.friends]])
        #expect(inner.page(of: .personal) == 0)
        #expect(inner.page(of: .darkroom) == 0)
        #expect(inner.page(of: .friends) == 1)
        #expect(inner.place(onPage: 0) == .personal)
        #expect(inner.place(onPage: 1) == .friends)
    }

    @Test("on the phone the pages run Darkroom, Personal, Friends, one each")
    func phonePages() {
        let phone = V2LayoutMode.phone
        #expect(phone.placeGroups.map { $0.count } == [1, 1, 1])
        for place in V2Place.allCases {
            #expect(phone.place(onPage: phone.page(of: place)) == place)
        }
        #expect(phone.page(of: .darkroom) == 0)
        #expect(phone.page(of: .personal) == 1)
        #expect(phone.place(onPage: 9) == .friends)
        #expect(phone.place(onPage: -1) == .darkroom)
    }

    @Test("places map to the tab bar's tabs and back; Rolls open over Personal")
    func tabs() {
        for place in V2Place.allCases {
            #expect(V2Place.forTab(place.tab) == place)
        }
        #expect(V2Place.personal.tab == 0)
        #expect(V2Place.darkroom.tab == 1)
        #expect(V2Place.friends.tab == 3)
        #expect(V2Place.forTab(V2Place.rollsTab) == .personal)
    }

    @Test("the print keeps the prototype's proportions at any width")
    func printGeometry() {
        let full: CGFloat = 340
        #expect(abs(V2PrintGeometry.border(width: full) - 16) < 0.001)
        #expect(abs(V2PrintGeometry.foot(width: full) - 93) < 0.001)
        #expect(abs(V2PrintGeometry.windowHeight(width: full) - 308 * 4 / 3) < 0.001)
        #expect(abs(V2PrintGeometry.height(width: full) - (16 + 308 * 4 / 3 + 93)) < 0.001)
        let half = V2PrintGeometry.height(width: full / 2)
        #expect(abs(half * 2 - V2PrintGeometry.height(width: full)) < 0.001)
    }

    @Test("a print fitted to a box never overflows it")
    func printFits() {
        for box in [CGSize(width: 300, height: 1000), CGSize(width: 1000, height: 300), CGSize(width: 366, height: 560)] {
            let width = V2PrintGeometry.width(fitting: box)
            #expect(width <= box.width + 0.001)
            #expect(V2PrintGeometry.height(width: width) <= box.height + 0.001)
        }
        #expect(V2PrintGeometry.width(fitting: .zero) == 0)
    }

    @Test("the date stamp keeps the App Store app's order, month first")
    func stampOrder() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 12))!
        let text = BrandedExport.dateText(.init(date: date))
        #expect(text == "10 03 '26")
    }
}
