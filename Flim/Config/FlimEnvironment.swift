import Foundation

/// Which FLIM this build is, and what it talks to: the App Store app ("production") or FLIM Beta
/// ("beta"), the v2 test app with its own Supabase project and its own TestFlight (2026-10-27).
///
/// Read from the bundle's Info.plist, where project.yml writes each build configuration's
/// `FLIM_*` settings (Debug and Release are production; Debug-Beta and Release-Beta are beta). The
/// app, the widget and the notification extension each read their own Info.plist, so all three
/// carry the same keys.
///
/// Two rules keep the beta away from production:
/// - only the production app may fall back to production's values when a key is missing; a beta
///   build without its own project refuses to start rather than quietly using the live one;
/// - a beta build pointed at production's database refuses to start at all.
enum FlimEnvironment {
    struct Values: Equatable {
        let name: String
        let supabaseURL: URL
        let supabaseKey: String
        /// The App Group the app and the widget share (`WidgetStore`).
        let appGroup: String
        /// The custom URL scheme: widget taps, invite links, the auth callback (`WidgetLink`).
        let urlScheme: String

        var isProduction: Bool { name == FlimEnvironment.productionName }
    }

    enum Problem: Error, Equatable {
        /// A non-production build without this Info.plist key set.
        case missing(String)
        /// A non-production build pointed at production's database.
        case betaOnProduction
    }

    static let productionName = "production"

    /// The App Store app's values, the same ones this code carried as literals before builds
    /// could differ. The publishable key is public by design (row-level security guards the data).
    static let production = Values(
        name: productionName,
        supabaseURL: URL(string: "https://wxvwamwrjlrvqmuaafjv.supabase.co")!,
        supabaseKey: "sb_publishable_ze8KEytcVzvKOijlUQ8Kfw_nb3kJ-V4",
        appGroup: "group.com.flim.app",
        // The original bundle id, kept because a registered scheme cannot change without breaking
        // every link already in the wild, and it is on production's auth redirect allowlist.
        urlScheme: "com.lapse.app"
    )

    /// What a build with this Info.plist talks to. Pure, so both rules above are tested.
    static func resolve(_ info: [String: Any]) -> Result<Values, Problem> {
        let name = nonEmpty(info["FLIMEnvironment"]) ?? productionName
        let isProduction = name == productionName
        func value(_ key: String, production fallback: String) -> String? {
            nonEmpty(info[key]) ?? (isProduction ? fallback : nil)
        }
        guard let urlString = value("FLIMSupabaseURL", production: production.supabaseURL.absoluteString),
              let url = URL(string: urlString), url.host != nil
        else { return .failure(.missing("FLIMSupabaseURL")) }
        guard let key = value("FLIMSupabaseKey", production: production.supabaseKey)
        else { return .failure(.missing("FLIMSupabaseKey")) }
        guard let group = value("FLIMAppGroup", production: production.appGroup)
        else { return .failure(.missing("FLIMAppGroup")) }
        guard let scheme = value("FLIMURLScheme", production: production.urlScheme)
        else { return .failure(.missing("FLIMURLScheme")) }
        if !isProduction, url.host?.lowercased() == production.supabaseURL.host?.lowercased() {
            return .failure(.betaOnProduction)
        }
        return .success(Values(name: name, supabaseURL: url, supabaseKey: key, appGroup: group, urlScheme: scheme))
    }

    /// This build's values. A misconfigured beta stops here, at launch, with the reason.
    static let current: Values = {
        switch resolve(Bundle.main.infoDictionary ?? [:]) {
        case .success(let values):
            return values
        case .failure(let problem):
            fatalError("FLIM build configuration: \(problem). Set the FLIM_* settings for this configuration in project.yml.")
        }
    }()

    /// An unset build setting arrives as an empty string, which counts as missing.
    private static func nonEmpty(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return s
    }
}
