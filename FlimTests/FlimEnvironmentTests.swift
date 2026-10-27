import Testing
import Foundation
@testable import Flim

/// `FlimEnvironment.resolve` decides which database a build talks to. The App Store app must keep
/// production's values whatever its plist says or lacks; FLIM Beta must never reach production.
struct FlimEnvironmentTests {

    private let beta: [String: Any] = [
        "FLIMEnvironment": "beta",
        "FLIMSupabaseURL": "https://betaproject.supabase.co",
        "FLIMSupabaseKey": "sb_publishable_beta",
        "FLIMAppGroup": "group.com.flim.app.beta",
        "FLIMURLScheme": "com.flim.app.beta",
    ]

    @Test("the app under test is the production app, with production's values")
    func testHostIsProduction() {
        #expect(FlimEnvironment.current == FlimEnvironment.production)
        #expect(WidgetLink.scheme == "com.lapse.app")
        #expect(WidgetStore.appGroup == "group.com.flim.app")
        #expect(PushImage.host == "wxvwamwrjlrvqmuaafjv.supabase.co")
    }

    @Test("a production plist without the keys, or with them unset, still resolves to production")
    func productionFallsBack() {
        #expect(FlimEnvironment.resolve([:]) == .success(FlimEnvironment.production))
        let unset: [String: Any] = ["FLIMEnvironment": "production", "FLIMSupabaseURL": "", "FLIMSupabaseKey": "",
                                    "FLIMAppGroup": "", "FLIMURLScheme": ""]
        #expect(FlimEnvironment.resolve(unset) == .success(FlimEnvironment.production))
    }

    @Test("a complete beta plist resolves to the beta's own project")
    func betaResolves() throws {
        let values = try FlimEnvironment.resolve(beta).get()
        #expect(values.name == "beta" && !values.isProduction)
        #expect(values.supabaseURL.host == "betaproject.supabase.co")
        #expect(values.appGroup == "group.com.flim.app.beta")
        #expect(values.urlScheme == "com.flim.app.beta")
    }

    @Test("a beta without its project set never falls back to production")
    func betaMissingProjectRefuses() {
        var info = beta
        info["FLIMSupabaseURL"] = ""
        #expect(FlimEnvironment.resolve(info) == .failure(.missing("FLIMSupabaseURL")))
        info = beta
        info.removeValue(forKey: "FLIMSupabaseKey")
        #expect(FlimEnvironment.resolve(info) == .failure(.missing("FLIMSupabaseKey")))
        info = beta
        info["FLIMAppGroup"] = ""
        #expect(FlimEnvironment.resolve(info) == .failure(.missing("FLIMAppGroup")))
    }

    @Test("a beta pointed at production's database refuses, whatever the case")
    func betaOnProductionRefuses() {
        var info = beta
        info["FLIMSupabaseURL"] = "https://WXVWAMWRJLRVQMUAAFJV.supabase.co"
        #expect(FlimEnvironment.resolve(info) == .failure(.betaOnProduction))
    }
}
