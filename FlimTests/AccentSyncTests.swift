import Testing
@testable import Flim

/// Which side wins when the profile loads. The server is the account's record, so it wins when
/// it has a known name; a row that has nothing yet gets the phone's pick sent up once.
struct AccentSyncTests {
    @Test func serverWinsWhenItHasAName() {
        #expect(AccentSync.decision(local: "amber", server: "teal") == .applyServer("teal"))
        #expect(AccentSync.decision(local: nil, server: "rose") == .applyServer("rose"))
    }

    @Test func nothingToDoWhenBothAgree() {
        #expect(AccentSync.decision(local: "sky", server: "sky") == .nothing)
        #expect(AccentSync.decision(local: nil, server: "amber") == .nothing)
    }

    @Test func emptyRowGetsThePhonesPick() {
        #expect(AccentSync.decision(local: "violet", server: nil) == .uploadLocal("violet"))
        #expect(AccentSync.decision(local: nil, server: nil) == .uploadLocal("amber"))
    }

    @Test func unknownNamesAreTreatedAsMissing() {
        #expect(AccentSync.decision(local: "amber", server: "plaid") == .uploadLocal("amber"))
        #expect(AccentSync.decision(local: "plaid", server: nil) == .uploadLocal("amber"))
        #expect(AccentSync.decision(local: "plaid", server: "lime") == .applyServer("lime"))
    }
}
