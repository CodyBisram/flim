import SwiftUI

/// The five honest capture states (v2 foundations, 2026-09-14), derived from what
/// `PhotoService` already knows. A photograph is only called saved once it is on disk, and only
/// uploaded once the transfer finished. The accent border marks the two that are not yet
/// durable, and stays until they are. "Developing" is reserved for shared rolls and never used
/// for a transfer.
enum CaptureStatus: Equatable {
    case notSavedYet
    case savedOnPhone
    case uploading(count: Int)
    case queued(count: Int, offline: Bool)
    case uploaded

    /// Pure, so the mapping is testable without a camera.
    static func derive(localSaveFailed: Bool, pendingCount: Int, isUploading: Bool,
                       failedCount: Int, connected: Bool, justUploaded: Bool) -> CaptureStatus? {
        if localSaveFailed { return .notSavedYet }
        if isUploading { return .uploading(count: max(1, pendingCount)) }
        if pendingCount > 0 { return .savedOnPhone }
        if failedCount > 0 { return .queued(count: failedCount, offline: !connected) }
        if justUploaded { return .uploaded }
        return nil
    }

    var title: String {
        switch self {
        case .notSavedYet: "Not saved yet"
        case .savedOnPhone: "Saved on this phone"
        case .uploading(let n): n > 1 ? "Uploading \(n)" : "Uploading"
        case .queued(let n, _): n > 1 ? "\(n) queued on this phone" : "Queued on this phone"
        case .uploaded: "Uploaded"
        }
    }

    var detail: String {
        switch self {
        case .notSavedYet: "Keep FLIM open for a moment."
        case .savedOnPhone: "Safe even if you close FLIM."
        case .uploading: "Saved on this phone. Sending the copy now."
        case .queued(_, let offline): offline ? "No connection. It will send when you're back online." : "Safe here. Retry to send it now."
        case .uploaded: "In your Darkroom, ready to sort."
        }
    }

    var glyph: String {
        switch self {
        case .notSavedYet: "exclamationmark.triangle"
        case .savedOnPhone: "checkmark"
        case .uploading: "icloud.and.arrow.up"
        case .queued(_, let offline): offline ? "wifi.slash" : "arrow.clockwise"
        case .uploaded: "checkmark.circle.fill"
        }
    }

    /// The two states that are not yet durable carry the accent border; the rest do not.
    var attention: Bool {
        switch self {
        case .notSavedYet, .queued: true
        default: false
        }
    }

    var canRetry: Bool {
        if case .queued = self { return true }
        return false
    }
}

/// The chip itself: glyph, title, one line of detail, an optional Retry. Sits on the camera's
/// top row, over the viewfinder, so it is drawn on the status fill with a scrim behind.
struct CaptureStatusChip: View {
    @Environment(\.flimAccent) private var accent
    let status: CaptureStatus
    var onRetry: (() -> Void)? = nil

    private var tint: Color {
        switch status {
        case .uploaded, .savedOnPhone: FlimTheme.success
        default: FlimTheme.warning(accent)
        }
    }

    var body: some View {
        HStack(spacing: FlimSpace.m) {
            if case .uploading = status {
                ProgressView().tint(.white).controlSize(.mini)
            } else {
                Image(systemName: status.glyph)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(status.title)
                    .flimType(.label)
                    .foregroundStyle(.white)
                Text(status.detail)
                    .flimType(.micro)
                    .foregroundStyle(FlimTheme.textSecondary)
                    .lineLimit(2)
            }
            if status.canRetry, let onRetry {
                Button("Retry", action: onRetry)
                    .flimType(.label)
                    .foregroundStyle(accent)
                    .frame(minHeight: 44)
                    .padding(.leading, FlimSpace.xs)
            }
        }
        .padding(.horizontal, FlimSpace.l)
        .padding(.vertical, FlimSpace.s)
        .frame(minHeight: 44)
        .background(FlimTheme.sheetSurface, in: RoundedRectangle(cornerRadius: FlimRadius.panel))
        .overlay(RoundedRectangle(cornerRadius: FlimRadius.panel)
            .strokeBorder(status.attention ? accent.opacity(0.7) : FlimTheme.divider, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(status.title). \(status.detail)")
    }
}
