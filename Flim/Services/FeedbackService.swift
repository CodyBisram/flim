import Foundation
import Supabase
import UIKit

/// Sends an in-app feedback report straight to the database via `submit_feedback`, instead of
/// through Mail. A mailto draft depends on the person actually switching apps and pressing
/// send, an easy step to lose a report on, and it can carry no diagnostics beyond what they
/// choose to type. This captures the report the moment Send is tapped and stamps it with the
/// same build and device context that would otherwise cost a round trip to ask for.
enum FeedbackService {
    /// Requires a signed-in user; the server records who sent it via `auth.uid()`, nothing is
    /// passed here for that.
    ///
    /// Returns whatever `submit_feedback` returns: `true` once the report is stored, `false` if
    /// the server itself saw an empty message. Callers should also trim/guard client-side so that
    /// `false` is only ever the server double-checking, not the normal path.
    static func submit(_ message: String) async throws -> Bool {
        try await supabase
            .rpc("submit_feedback", params: [
                "p_message": message,
                "p_app_version": AppInfo.shortVersion,
                "p_app_build": AppInfo.buildNumber,
                "p_os_version": UIDevice.current.systemVersion,
                "p_device_model": deviceModel
            ])
            .execute()
            .value
    }

    /// The raw hardware identifier (e.g. "iPhone14,2"), not the marketing name. MetricKit reports
    /// the same kind of raw identifier as `deviceType` on a crash row (see CrashReporter), so a
    /// feedback report and a crash from the same device read the same way when lined up side by
    /// side.
    private static var deviceModel: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) { pointer -> String in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
}
