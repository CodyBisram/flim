import AVFoundation
import XCTest
@testable import Flim

/// FLIM's own notification sounds. A push naming a file the app does not carry, or one longer
/// than 30 seconds, plays the iOS default instead and nothing says so, which is how a renamed or
/// dropped file would go unnoticed. The names here are the ones the push functions send.
final class NotificationSoundTests: XCTestCase {

    private let files = ["flim_developed", "flim_social", "flim_spotlight"]

    func testEverySoundIsBundledAndUnderThirtySeconds() throws {
        for name in files {
            let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: "caf"),
                                    "\(name).caf is not in the app bundle")
            let file = try AVAudioFile(forReading: url)
            let seconds = Double(file.length) / file.fileFormat.sampleRate
            XCTAssertGreaterThan(seconds, 0.2, "\(name) looks empty")
            XCTAssertLessThan(seconds, 30, "iOS plays the default for a notification sound of 30 s or more")
        }
    }

    func testTheRevealAndTheDevelopReminderUseTheDevelopedSound() {
        XCTAssertEqual(SoundFX.developedFile, "flim_developed.caf")
        XCTAssertNotNil(Bundle.main.url(forResource: "flim_developed", withExtension: "caf"))
    }
}
