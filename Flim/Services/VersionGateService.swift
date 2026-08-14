import Foundation
import Observation
import Supabase

/// What `VersionGateService.check()` decided after comparing the running build against the
/// server's single-row `app_release_gate` table.
enum VersionGateDecision: Equatable {
    /// At or above `latest_version` — or the row/versions couldn't be trusted, see
    /// `versionGateDecision`, which fails open to this on any doubt. Nothing shown.
    case none
    /// Below `latest_version` but not below `minimum_version`: a dismissible reminder to update.
    case nudge
    /// Below `minimum_version`: the build can no longer be used. A hard, undismissable block.
    case blocked
}

/// Parses a dot-separated version string ("1.10.2") into numeric components for a SEMANTIC
/// compare, never a string compare: "1.10.0" must sort after "1.9.0", and `"1.10.0" > "1.9.0"`
/// as plain strings gets that backwards (the character '1' < '9'). Returns nil for anything that
/// doesn't parse — empty, or any component that isn't a plain non-negative integer — which is
/// exactly the signal `versionGateDecision` needs to fail open instead of guessing.
private func parseVersion(_ raw: String) -> [Int]? {
    let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
    guard !parts.isEmpty else { return nil }
    var components: [Int] = []
    for part in parts {
        guard let n = Int(part), n >= 0 else { return nil }
        components.append(n)
    }
    return components
}

/// True if `lhs` is strictly less than `rhs`, comparing component by component and padding the
/// shorter side with zeros, so differing lengths compare correctly ("1.4" == "1.4.0", which is
/// less than "1.4.1").
private func isVersion(_ lhs: [Int], lessThan rhs: [Int]) -> Bool {
    for i in 0..<max(lhs.count, rhs.count) {
        let l = i < lhs.count ? lhs[i] : 0
        let r = i < rhs.count ? rhs[i] : 0
        if l != r { return l < r }
    }
    return false
}

/// The pure comparison behind the gate: the running app's version against the server's
/// `minimum_version` and `latest_version`.
///
/// FAILS OPEN on every kind of doubt, always to `.none`, never to `.blocked` or `.nudge`. An
/// unparseable `current` leaves nothing trustworthy to compare against; an unparseable
/// `minimum`/`latest` (a bad row, a typo made server-side) is treated as "no requirement" rather
/// than blocking every install until it's fixed. Nobody is ever kept out of the app because a
/// version string failed to parse.
///
/// Pure so the rule is structural rather than a claim in a comment, the way `shouldTreatAsDeleted`
/// and `resolvedCaption` pin `FeedService`'s rules.
func versionGateDecision(current: String, minimum: String, latest: String) -> VersionGateDecision {
    guard let currentVersion = parseVersion(current) else { return .none }
    if let minimumVersion = parseVersion(minimum), isVersion(currentVersion, lessThan: minimumVersion) {
        return .blocked
    }
    if let latestVersion = parseVersion(latest), isVersion(currentVersion, lessThan: latestVersion) {
        return .nudge
    }
    return .none
}

/// Whether the dismissible nudge should present, given what was last dismissed.
///
/// Keyed on the actual `latestVersion` string, not a plain "already shown" flag: dismissing the
/// nudge for 1.5.0 must not silently swallow a later, genuinely newer 1.6.0 nudge, so a
/// dismissal only suppresses that exact version.
func shouldPresentVersionNudge(decision: VersionGateDecision, latestVersion: String, dismissedVersion: String) -> Bool {
    decision == .nudge && latestVersion != dismissedVersion
}

/// Reads `app_release_gate` and decides whether this build should be nudged to update or
/// blocked outright. Checked on launch and on return to the foreground (see `ContentView`);
/// never polls.
@MainActor
@Observable
final class VersionGateService {
    private(set) var decision: VersionGateDecision = .none
    /// The row's `latest_version`, kept alongside `decision` so the nudge can be dismissed
    /// per-version (see `shouldPresentVersionNudge`). Starts at the row's own inert default so an
    /// unchecked service never claims a real version is newer.
    private(set) var latestVersion = "0.0.0"
    /// The row's optional copy. Nil means the caller falls back to its own wording.
    private(set) var message: String?

    private struct GateRow: Decodable {
        let minimumVersion: String
        let latestVersion: String
        let message: String?
        enum CodingKeys: String, CodingKey {
            case minimumVersion = "minimum_version"
            case latestVersion = "latest_version"
            case message
        }
    }

    /// Refreshes `decision`/`latestVersion`/`message` from the server.
    ///
    /// Skipped entirely off the public App Store: DEBUG and TestFlight both report
    /// `AppInfo.isAppStore == false`, so nothing here can lock the team out of an intentionally
    /// old test build, or stall an in-flight release ahead of the App Store row being updated.
    ///
    /// Fails open on anything that goes wrong: no row, a network error, or a response that
    /// doesn't decode all reset to `.none` rather than holding on to a stale `.blocked`/`.nudge`
    /// from a previous, successful check.
    func check() async {
        guard let row: GateRow = try? await supabase
            .from("app_release_gate")
            .select()
            .single()
            .execute()
            .value
        else {
            decision = .none
            message = nil
            return
        }
        let raw = versionGateDecision(current: AppInfo.shortVersion,
                                      minimum: row.minimumVersion, latest: row.latestVersion)
        decision = softenedOffAppStore(raw, isAppStore: AppInfo.isAppStore)
        latestVersion = row.latestVersion
        message = row.message
    }
}

/// Downgrades a hard block to a nudge on anything that isn't a public App Store build.
///
/// The obvious safety measure is to skip the gate entirely off the App Store, and that was the
/// first shape of this. It has a bad property: the one feature whose failure mode is locking every
/// user out would then never run anywhere before production, so the first real execution is also
/// the one that matters. Softening instead of skipping means the whole path (the query, the
/// comparison, the sheet) is exercised on TestFlight, while `.blocked` stays impossible there, so
/// a wrong `minimum_version` still cannot strand the team on a build they need.
func softenedOffAppStore(_ decision: VersionGateDecision, isAppStore: Bool) -> VersionGateDecision {
    guard !isAppStore else { return decision }
    return decision == .blocked ? .nudge : decision
}
