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
    /// Serialises every read/modify/write of the log. Entries are now appended by MetricKit's
    /// callback and flagged by upload completions on separate tasks, so unsynchronised
    /// read-modify-write would drop entries under a burst of diagnostics.
    private let fileQueue = DispatchQueue(label: "com.flim.app.crash-log")

    /// MetricKit requires a subscriber added on (ideally) every launch to receive payloads
    /// queued since the last one, safe to call multiple times, `add` is idempotent per instance.
    func start() {
        MXMetricManager.shared.add(self)
        retryPendingUploads()
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for diagnostic in payload.crashDiagnostics ?? [] {
                record(kind: "crash", detail: Self.crashSummary(diagnostic),
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

    /// A one-line cause for a crash row: why iOS killed the process, plus the exception/signal it
    /// used. `detail` previously held `applicationVersion`, the same value already going into the
    /// `app_version` column beside it, so a crash row recorded WHICH version crashed and nothing
    /// at all about why; you had to read the call stack tree to learn anything. Hangs and CPU
    /// exceptions already carried a real number (duration, CPU time), crashes were the one kind
    /// that didn't.
    static func crashSummary(_ diagnostic: MXCrashDiagnostic) -> String {
        var parts: [String] = []
        if let reason = diagnostic.terminationReason { parts.append(reason) }
        if let type = diagnostic.exceptionType { parts.append("exception \(type)") }
        if let code = diagnostic.exceptionCode { parts.append("code \(code)") }
        if let signal = diagnostic.signal { parts.append("signal \(signal)") }
        return parts.isEmpty ? "unknown" : parts.joined(separator: " · ")
    }

    private func record(kind: String, detail: String, appVersion: String, tree: MXCallStackTree) {
        logger.fault("[\(kind, privacy: .public)] \(detail, privacy: .public)")
        let treeData = tree.jsonRepresentation()
        let treeJSONObject = (try? JSONSerialization.jsonObject(with: treeData)) ?? [:]
        let id = UUID().uuidString
        let entry: [String: Any] = [
            "id": id,
            "kind": kind,
            "detail": detail,
            "appVersion": appVersion,
            "loggedAt": ISO8601DateFormatter().string(from: .now),
            // False until the insert lands. `retryPendingUploads()` re-sends anything still
            // false on a later launch, so a diagnostic captured while offline isn't lost.
            "uploaded": false,
            "callStackTree": treeJSONObject
        ]
        if let line = try? JSONSerialization.data(withJSONObject: entry),
           let text = String(data: line, encoding: .utf8) {
            append(text)
        }
        let treeString = String(data: treeData, encoding: .utf8) ?? "{}"
        upload(id: id, kind: kind, detail: detail, appVersion: appVersion, callStackTree: treeString)
    }

    /// Re-sends diagnostics that were captured but never reached the server.
    ///
    /// MetricKit hands over a payload exactly once, so before this, an insert that failed
    /// (offline at that moment, a transient error, the app killed before the Task ran) meant the
    /// diagnostic existed ONLY in the on-device log, with nothing to ever retry it. A crash could
    /// be captured correctly and still never appear in the table, which is indistinguishable from
    /// no crash having happened, the worst possible failure mode for a crash reporter.
    private func retryPendingUploads() {
        fileQueue.async { [weak self] in
            guard let self else { return }
            for entry in self.readEntries() where (entry["uploaded"] as? Bool) == false {
                guard let id = entry["id"] as? String,
                      let kind = entry["kind"] as? String,
                      let detail = entry["detail"] as? String,
                      let appVersion = entry["appVersion"] as? String else { continue }
                let tree = entry["callStackTree"].flatMap { object -> String? in
                    guard JSONSerialization.isValidJSONObject(object),
                          let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
                    return String(data: data, encoding: .utf8)
                } ?? "{}"
                self.upload(id: id, kind: kind, detail: detail, appVersion: appVersion, callStackTree: tree)
            }
        }
    }

    private func readEntries() -> [[String: Any]] {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
    }

    /// Flips an entry's `uploaded` flag so a later launch doesn't send it again.
    private func markUploaded(_ id: String) {
        fileQueue.async { [weak self] in
            guard let self else { return }
            var entries = self.readEntries()
            guard let index = entries.firstIndex(where: { $0["id"] as? String == id }) else { return }
            entries[index]["uploaded"] = true
            self.writeEntries(entries)
        }
    }

    private func writeEntries(_ entries: [[String: Any]]) {
        let lines = entries.compactMap { entry -> String? in
            guard let data = try? JSONSerialization.data(withJSONObject: entry) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        try? (lines.joined(separator: "\n") + "\n").write(to: logURL, atomically: true, encoding: .utf8)
    }

    /// Pulled off a device via Xcode's Devices window (Installed Apps → gear icon → Download
    /// Container → Application Support), no in-app export UI exists for this, and now that
    /// upload() below is the primary path, this is only worth reaching for if a specific
    /// device's uploads look like they never made it (offline at the time, etc).
    private func append(_ line: String) {
        fileQueue.async { [weak self] in
            guard let self else { return }
            var lines = (try? String(contentsOf: self.logURL, encoding: .utf8))?
                .split(separator: "\n").map(String.init) ?? []
            lines.append(line)
            if lines.count > self.maxStoredEntries { lines.removeFirst(lines.count - self.maxStoredEntries) }
            try? (lines.joined(separator: "\n") + "\n").write(to: self.logURL, atomically: true, encoding: .utf8)
        }
    }

    /// Best-effort: a failed upload (offline, transient network) just means this diagnostic
    /// stays local-only in the on-device log above, nothing here retries or surfaces a failure,
    /// since there's no user-facing action a crash/hang report could ever warrant blocking on.
    /// user_id is nil for a diagnostic that arrives before the device has ever signed in; RLS
    /// requires exactly that pairing (a real session's own uid, or no session and no claimed
    /// uid) so a forged upload can't attribute diagnostics to someone else.
    private func upload(id: String, kind: String, detail: String, appVersion: String, callStackTree: String) {
        struct Insert: Encodable {
            let user_id: UUID?
            let kind: String
            let detail: String
            let app_version: String
            let call_stack_tree: String
        }
        Task { [weak self] in
            let userId = (try? await supabase.auth.session)?.user.id
            let insert = Insert(user_id: userId, kind: kind, detail: detail,
                                 app_version: appVersion, call_stack_tree: callStackTree)
            do {
                try await supabase.from("crash_diagnostics").insert(insert).execute()
                // Only now is it safe to stop retrying this one.
                self?.markUploaded(id)
            } catch {
                // Left flagged pending; `retryPendingUploads()` picks it up next launch.
                self?.logger.error("crash diagnostic upload failed, will retry next launch")
            }
        }
    }
}
