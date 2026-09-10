import Foundation
import UIKit
import os

/// Breadcrumbs for one flow that cannot be reproduced off the owner's phone: the export sheet
/// opening from the chapter viewer and vanishing a moment later (2026-09-10). Each step writes
/// a row to `crash_diagnostics` (kind "breadcrumb"), the same table the crash reporter fills,
/// with the app's free memory at that instant, so the sequence and the memory picture can be
/// read back from the dashboard without a cable. Fire and forget, a handful of rows per share.
/// Remove once the cause is known; this is a probe, not telemetry.
enum ShareBreadcrumbs {
    private static let logger = Logger(subsystem: "com.flim.app", category: "share")
    private static let started = Date.now

    static func log(_ event: String, _ detail: String = "") {
        let free = Double(os_proc_available_memory()) / 1_048_576
        let line = "\(event) | \(detail) | free=\(Int(free))MB | t+\(String(format: "%.2f", Date.now.timeIntervalSince(started)))s"
        logger.info("\(line, privacy: .public)")
        struct Insert: Encodable {
            let user_id: UUID?; let kind: String; let detail: String
            let app_version: String; let app_build: String; let os_version: String
            let device_model: String; let occurred_at: Date; let call_stack_tree: String
        }
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let os = UIDevice.current.systemVersion
        var systemInfo = utsname(); uname(&systemInfo)
        let model = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        Task {
            guard let userId = (try? await supabase.auth.session)?.user.id else { return }
            let row = Insert(user_id: userId, kind: "breadcrumb", detail: line, app_version: version,
                             app_build: build, os_version: os, device_model: model,
                             occurred_at: .now, call_stack_tree: "{}")
            _ = try? await supabase.from("crash_diagnostics").insert(row).execute()
        }
    }
}
