import Foundation
import MetricKit
import Supabase
import os

/// Captures crash, hang, and CPU-exception diagnostics via MetricKit, Apple's own on-device
/// mechanism, so this adds no third-party SDK, no new network egress beyond our own Supabase
/// project. There was previously no crash visibility beyond whatever a tester happened to
/// notice; MetricKit payloads arrive automatically (usually within 24h of the event, on a later
/// launch) so the moment a crash occurred can be reconstructed after the fact instead of only
/// when someone remembers to report it.
///
/// This is a SUPPLEMENT to Xcode Organizer (Window → Organizer → Crashes), which already
/// receives symbolicated crash reports for TestFlight/App Store builds with zero code required
///, check there first for actual crashes. What this adds: hang and CPU-exception diagnostics
/// (which Organizer's Crashes tab doesn't show), and now, every diagnostic uploaded to
/// crash_diagnostics so the owner can see what's happening across real testers' devices, not
/// just whichever one is physically plugged into Xcode.
final class CrashReporter: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashReporter()

    private let logger = Logger(subsystem: "com.flim.app", category: "crash")

    /// Diagnostics are appended as line-delimited JSON so a partial write from a killed process
    /// never corrupts earlier entries. Capped by trimming on write, not by rotating files, 
    /// simplest thing that keeps this from growing unbounded on a device that's never synced.
    /// Kept as a local fallback alongside the Supabase upload below, a device with no network
    /// at the moment a payload arrives still has SOMETHING recoverable via Xcode's Devices
    /// window, even though the upload is now the primary way this data actually gets seen.
    private let logURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("crash-diagnostics.jsonl")
    }()
    private let maxStoredEntries = 20

    /// MetricKit requires a subscriber added on (ideally) every launch to receive payloads
    /// queued since the last one, safe to call multiple times, `add` is idempotent per instance.
    func start() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for diagnostic in payload.crashDiagnostics ?? [] {
                record(kind: "crash", detail: diagnostic.applicationVersion,
                       appVersion: diagnostic.applicationVersion, tree: diagnostic.callStackTree)
            }
            for diagnostic in payload.hangDiagnostics ?? [] {
                record(kind: "hang", detail: "\(diagnostic.hangDuration)",
                       appVersion: diagnostic.applicationVersion, tree: diagnostic.callStackTree)
            }
            for diagnostic in payload.cpuExceptionDiagnostics ?? [] {
                record(kind: "cpuException", detail: "\(diagnostic.totalCPUTime)",
                       appVersion: diagnostic.applicationVersion, tree: diagnostic.callStackTree)
            }
        }
    }

    private func record(kind: String, detail: String, appVersion: String, tree: MXCallStackTree) {
        logger.fault("[\(kind, privacy: .public)] \(detail, privacy: .public)")
        let treeData = tree.jsonRepresentation()
        let treeJSONObject = (try? JSONSerialization.jsonObject(with: treeData)) ?? [:]
        let entry: [String: Any] = [
            "kind": kind,
            "detail": detail,
            "loggedAt": ISO8601DateFormatter().string(from: .now),
            "callStackTree": treeJSONObject
        ]
        if let line = try? JSONSerialization.data(withJSONObject: entry),
           let text = String(data: line, encoding: .utf8) {
            append(text)
        }
        let treeString = String(data: treeData, encoding: .utf8) ?? "{}"
        upload(kind: kind, detail: detail, appVersion: appVersion, callStackTree: treeString)
    }

    /// Pulled off a device via Xcode's Devices window (Installed Apps → gear icon → Download
    /// Container → Application Support), no in-app export UI exists for this, and now that
    /// upload() below is the primary path, this is only worth reaching for if a specific
    /// device's uploads look like they never made it (offline at the time, etc).
    private func append(_ line: String) {
        var lines = (try? String(contentsOf: logURL, encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
        lines.append(line)
        if lines.count > maxStoredEntries { lines.removeFirst(lines.count - maxStoredEntries) }
        try? (lines.joined(separator: "\n") + "\n").write(to: logURL, atomically: true, encoding: .utf8)
    }

    /// Best-effort: a failed upload (offline, transient network) just means this diagnostic
    /// stays local-only in the on-device log above, nothing here retries or surfaces a failure,
    /// since there's no user-facing action a crash/hang report could ever warrant blocking on.
    /// user_id is nil for a diagnostic that arrives before the device has ever signed in; RLS
    /// requires exactly that pairing (a real session's own uid, or no session and no claimed
    /// uid) so a forged upload can't attribute diagnostics to someone else.
    private func upload(kind: String, detail: String, appVersion: String, callStackTree: String) {
        struct Insert: Encodable {
            let user_id: UUID?
            let kind: String
            let detail: String
            let app_version: String
            let call_stack_tree: String
        }
        Task {
            let userId = (try? await supabase.auth.session)?.user.id
            let insert = Insert(user_id: userId, kind: kind, detail: detail,
                                 app_version: appVersion, call_stack_tree: callStackTree)
            _ = try? await supabase.from("crash_diagnostics").insert(insert).execute()
        }
    }
}
