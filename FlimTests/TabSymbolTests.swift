import Testing
import UIKit
@testable import Flim

/// A symbol name the running system does not know renders as nothing: an empty tab, a blank
/// circle beside the shutter. The app runs on iOS 18 and 26, which ship different SF Symbols
/// sets, so each name is checked on whichever runtime the suite runs on (CI and the local
/// suite run 18.5; run it on a 26 simulator too when a name changes).
struct TabSymbolTests {
    @Test(arguments: MainTabSymbol.all)
    func tabSymbolResolves(_ name: String) {
        #expect(UIImage(systemName: name) != nil, "\(name) is not a system symbol on this runtime")
    }

    @Test func tabSymbolsAreBaseNames() {
        // The tab bar fills the selected tab itself; a `.fill` name would be filled on every tab.
        for name in MainTabSymbol.all {
            #expect(!name.hasSuffix(".fill"), "\(name) should be a base name")
        }
    }

    @Test func flipCameraSymbolResolves() {
        #expect(UIImage(systemName: CameraView.flipCameraSymbol) != nil)
    }
}
