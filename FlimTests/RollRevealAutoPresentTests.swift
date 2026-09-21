import Testing
import Foundation
@testable import Flim

/// `RollRevealViewModel.shouldAutoPresent`: whether a developed roll's reveal should pop up on
/// its own the moment the roll's photos finish loading. Four independent inputs, so this pins
/// each one flipping the answer on its own rather than trusting the combined `if` at the call
/// site (`RollDetailView`'s own `.task`).
struct RollRevealAutoPresentTests {
    @Test("an undeveloped roll never auto-presents, regardless of everything else")
    func undevelopedNeverPresents() {
        #expect(!RollRevealViewModel.shouldAutoPresent(developed: false, hasPhotos: true, seen: false, dismissedThisLaunch: false))
    }

    @Test("a developed roll with no photos yet has nothing to show")
    func noPhotosNeverPresents() {
        #expect(!RollRevealViewModel.shouldAutoPresent(developed: true, hasPhotos: false, seen: false, dismissedThisLaunch: false))
    }

    @Test("a genuinely watched reveal never auto-presents again")
    func alreadySeenNeverPresents() {
        #expect(!RollRevealViewModel.shouldAutoPresent(developed: true, hasPhotos: true, seen: true, dismissedThisLaunch: false))
    }

    @Test("an unfinished reveal dismissed earlier this launch does not pop back up")
    func dismissedThisLaunchNeverPresents() {
        #expect(!RollRevealViewModel.shouldAutoPresent(developed: true, hasPhotos: true, seen: false, dismissedThisLaunch: true))
    }

    @Test("developed, with photos, never watched, not yet dismissed this launch: the one true case")
    func theOneCaseThatPresents() {
        #expect(RollRevealViewModel.shouldAutoPresent(developed: true, hasPhotos: true, seen: false, dismissedThisLaunch: false))
    }
}
