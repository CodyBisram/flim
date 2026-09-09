import Foundation

/// Keeps the accent colour on the account, not just the phone.
///
/// The pick lived only in UserDefaults (`accentColor`), so a reinstall or a second phone came
/// back amber (the owner, 2026-09-09, after reinstalling for a test). The row now carries
/// `users.accent_color`; this is the one place that decides which side wins when the profile
/// loads. The server wins whenever it has a known name, because it is the account's record.
/// When it has nothing yet (every account from before the column), the phone's pick is sent up,
/// so existing users keep what they chose and the row is filled in without anyone doing a thing.
enum AccentSync {
    enum Decision: Equatable {
        case applyServer(String)
        case uploadLocal(String)
        case nothing
    }

    static let key = "accentColor"

    static func decision(local: String?, server: String?) -> Decision {
        let known = Set(FlimAccentPalette.names)
        let serverName = server.flatMap { known.contains($0) ? $0 : nil }
        let localName = local.flatMap { known.contains($0) ? $0 : nil } ?? FlimAccentPalette.fallback
        if let serverName {
            return serverName == localName ? .nothing : .applyServer(serverName)
        }
        return .uploadLocal(localName)
    }
}
