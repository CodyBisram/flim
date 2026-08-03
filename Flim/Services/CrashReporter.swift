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
            // `timeStampEnd` is when the diagnostic window closed, i.e. approximately when the
            // crash happened. Recorded because the row's `created_at` is when it was UPLOADED,
            // and MetricKit only hands payloads over on a LATER launch: six diagnostics arriving
            // at 19:48 look like six crashes at 19:48 when they are really a flush at app start.
            // Every statement anyone makes about when crashes happen is wrong without this.
            for diagnostic in payload.crashDiagnostics ?? [] {
                record(kind: "crash", detail: Self.crashSummary(diagnostic),
                       diagnostic: diagnostic, tree: diagnostic.callStackTree,
                       occurredAt: payload.timeStampEnd)
            }
            for diagnostic in payload.hangDiagnostics ?? [] {
                record(kind: "hang", detail: "\(diagnostic.hangDuration)",
                       diagnostic: diagnostic, tree: diagnostic.callStackTree,
                       occurredAt: payload.timeStampEnd)
            }
            for diagnostic in payload.cpuExceptionDiagnostics ?? [] {
                record(kind: "cpuException", detail: "\(diagnostic.totalCPUTime)",
                       diagnostic: diagnostic, tree: diagnostic.callStackTree,
                       occurredAt: payload.timeStampEnd)
            }
        }
    }

    /// Everything recorded about one diagnostic, in one value.
    ///
    /// Introduced because the fields were previously threaded individually through `record`,
    /// `retryPendingUploads` and `upload`, and adding one meant editing three signatures and the
    /// on-disk format in lockstep. Any field missed in that dance is silently dropped only for
    /// diagnostics that were retried, which is the hardest case to notice.
    private struct Record {
        let id: String
        let kind: String
        let detail: String
        let appVersion: String
        /// The BUILD, not just "1.2". Every CI build of a version has its own dSYM and a stack can
        /// only be symbolicated by its exact match, so without this you cannot tell which artifact
        /// to reach for. It is recoverable from the binary UUID buried in the call-stack JSON;
        /// this makes it a column instead of an excavation.
        let appBuild: String
        let osVersion: String
        let deviceModel: String
        let occurredAt: Date
        /// Call stack tree, already serialised to JSON.
        let tree: String
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

    // `tree` is passed separately because `callStackTree` lives on each concrete diagnostic
    // subclass, not on the MXDiagnostic base; `metaData` and `applicationVersion` do live on the
    // base, which is why the diagnostic itself is still worth taking.
    private func record(kind: String, detail: String, diagnostic: MXDiagnostic,
                        tree: MXCallStackTree, occurredAt: Date) {
        logger.fault("[\(kind, privacy: .public)] \(detail, privacy: .public)")
        let treeData = tree.jsonRepresentation()
        let treeJSONObject = (try? JSONSerialization.jsonObject(with: treeData)) ?? [:]
        let meta = diagnostic.metaData
        let record = Record(
            id: UUID().uuidString,
            kind: kind,
            detail: detail,
            appVersion: diagnostic.applicationVersion,
            appBuild: meta.applicationBuildVersion,
            osVersion: meta.osVersion,
            deviceModel: meta.deviceType,
            occurredAt: occurredAt,
            tree: String(data: treeData, encoding: .utf8) ?? "{}"
        )

        let entry: [String: Any] = [
            "id": record.id,
            "kind": record.kind,
            "detail": record.detail,
            "appVersion": record.appVersion,
            "appBuild": record.appBuild,
            "osVersion": record.osVersion,
            "deviceModel": record.deviceModel,
            "occurredAt": ISO8601DateFormatter().string(from: record.occurredAt),
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
        upload(record)
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
                // The new fields are read leniently: an entry written by a previous version of the
                // app has none of them, and a pending diagnostic from before an update is exactly
                // the kind a retry exists to rescue. Missing means unknown, never a dropped row.
                let occurred = (entry["occurredAt"] as? String)
                    .flatMap { ISO8601DateFormatter().date(from: $0) }
                    ?? (entry["loggedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
                    ?? Date.now
                self.upload(Record(
                    id: id, kind: kind, detail: detail, appVersion: appVersion,
                    appBuild: entry["appBuild"] as? String ?? "unknown",
                    osVersion: entry["osVersion"] as? String ?? "unknown",
                    deviceModel: entry["deviceModel"] as? String ?? "unknown",
                    occurredAt: occurred, tree: tree
                ))
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
    private func upload(_ record: Record) {
        struct Insert: Encodable {
            let user_id: UUID?
            let kind: String
            let detail: String
            let app_version: String
            let app_build: String
            let os_version: String
            let device_model: String
            let occurred_at: Date
            let call_stack_tree: String
        }
        Task { [weak self] in
            let userId = (try? await supabase.auth.session)?.user.id
            let insert = Insert(user_id: userId, kind: record.kind, detail: record.detail,
                                app_version: record.appVersion, app_build: record.appBuild,
                                os_version: record.osVersion, device_model: record.deviceModel,
                                occurred_at: record.occurredAt, call_stack_tree: record.tree)
            do {
                try await supabase.from("crash_diagnostics").insert(insert).execute()
                // Only now is it safe to stop retrying this one.
                self?.markUploaded(record.id)
            } catch {
                // Left flagged pending; `retryPendingUploads()` picks it up next launch.
                self?.logger.error("crash diagnostic upload failed, will retry next launch")
            }
        }
    }
}
