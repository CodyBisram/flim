import Foundation
import MetricKit
import os

/// Captures crash, hang, and CPU-exception diagnostics via MetricKit — Apple's own on-device
/// mechanism, so this adds no third-party SDK, no new network egress, and no App Store privacy
/// label changes. There was previously no crash visibility beyond whatever a tester happened to
/// notice; MetricKit payloads arrive automatically (usually within 24h of the event, on a later
/// launch) so the moment a crash occurred can be reconstructed after the fact instead of only
/// when someone remembers to report it.
///
/// This is a SUPPLEMENT to Xcode Organizer (Window → Organizer → Crashes), which already
/// receives symbolicated crash reports for TestFlight/App Store builds with zero code required
/// — check there first. What this adds: hang and CPU-exception diagnostics (which Organizer's
/// Crashes tab doesn't show), and a local on-disk log so a report can be pulled straight off a
/// device (Console.app, or the Settings row that shares the log file) without needing the
/// crashing user to reproduce anything.
final class CrashReporter: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashReporter()

    private let logger = Logger(subsystem: "com.flim.app", category: "crash")

    /// Diagnostics are appended as line-delimited JSON so a partial write from a killed process
    /// never corrupts earlier entries. Capped by trimming on write, not by rotating files —
    /// simplest thing that keeps this from growing unbounded on a device that's never synced.
    private let logURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("crash-diagnostics.jsonl")
    }()
    private let maxStoredEntries = 20

    /// MetricKit requires a subscriber added on (ideally) every launch to receive payloads
    /// queued since the last one — safe to call multiple times, `add` is idempotent per instance.
    func start() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for diagnostic in payload.crashDiagnostics ?? [] {
                record(kind: "crash", detail: diagnostic.applicationVersion, tree: diagnostic.callStackTree)
            }
            for diagnostic in payload.hangDiagnostics ?? [] {
                record(kind: "hang", detail: "\(diagnostic.hangDuration)", tree: diagnostic.callStackTree)
            }
            for diagnostic in payload.cpuExceptionDiagnostics ?? [] {
                record(kind: "cpuException", detail: "\(diagnostic.totalCPUTime)", tree: diagnostic.callStackTree)
            }
        }
    }

    private func record(kind: String, detail: String, tree: MXCallStackTree) {
        logger.fault("[\(kind, privacy: .public)] \(detail, privacy: .public)")
        let entry: [String: Any] = [
            "kind": kind,
            "detail": detail,
            "loggedAt": ISO8601DateFormatter().string(from: .now),
            "callStackTree": (try? JSONSerialization.jsonObject(with: tree.jsonRepresentation())) ?? [:]
        ]
        guard let line = try? JSONSerialization.data(withJSONObject: entry), let text = String(data: line, encoding: .utf8) else { return }
        append(text)
    }

    /// Pulled off a device via Xcode's Devices window (Installed Apps → gear icon → Download
    /// Container → Application Support) — no in-app export UI exists for this yet.
    private func append(_ line: String) {
        var lines = (try? String(contentsOf: logURL, encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
        lines.append(line)
        if lines.count > maxStoredEntries { lines.removeFirst(lines.count - maxStoredEntries) }
        try? (lines.joined(separator: "\n") + "\n").write(to: logURL, atomically: true, encoding: .utf8)
    }
}
