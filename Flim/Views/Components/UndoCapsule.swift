import SwiftUI

/// The capsule that holds the door open on a staged action: the Darkroom's undo toast,
/// promoted to the app-wide pattern (confirmations redesign, option 1b). Renders whatever
/// `UndoCenter.shared` currently holds, so it carries no state of its own and any screen can
/// host it; after a commit that failed, it renders the failure notice in the same spot.
///
/// Hosted in two places: `MainTabView` (above the tab bar, for everything staged from the
/// tabs) and `PhotoPagerView` (a fullScreenCover paints over the tab host, and reports are
/// staged without leaving the pager). Both read the same center, and only one host is ever
/// visible, so the capsule cannot double-render.
struct UndoCapsuleHost: View {
    @Environment(\.flimAccent) private var accent
    private var center: UndoCenter { .shared }

    var body: some View {
        Group {
            if let staged = center.staged {
                capsule(for: staged)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let notice = center.failureNotice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .flimFont(13, weight: .medium)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: center.staged?.id)
        .animation(.snappy(duration: 0.25), value: center.failureNotice)
    }

    private func capsule(for staged: UndoCenter.Staged) -> some View {
        HStack(spacing: 13) {
            countdownRing(deadline: staged.deadline)
            VStack(alignment: .leading, spacing: 1) {
                Text(staged.title)
                    .flimFont(14)
                    .foregroundStyle(.white)
                if let subtitle = staged.subtitle {
                    Text(subtitle)
                        .flimFont(11.5, relativeTo: .caption)
                        .foregroundStyle(FlimTheme.textSecondary)
                }
            }
            .lineLimit(1)
            Button("Undo") { center.undo() }
                .flimFont(14, weight: .semibold)
                .foregroundStyle(accent)
                .padding(.leading, 2)
        }
        .padding(.leading, 16).padding(.trailing, 18).padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Undoes this in the next few seconds")
    }

    /// The shrinking ring: how much door is left. Driven by the wall-clock deadline, not a
    /// stored fraction, so a render hitch can't make it lie about the time remaining.
    private func countdownRing(deadline: Date) -> some View {
        TimelineView(.animation(minimumInterval: 0.1)) { context in
            let remaining = max(0, deadline.timeIntervalSince(context.date))
            let fraction = remaining / UndoCenter.window
            ZStack {
                Circle().stroke(Color.white.opacity(0.16), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(remaining.rounded(.up)))")
                    .flimFont(9, weight: .semibold, relativeTo: .caption2)
                    .foregroundStyle(accent)
            }
            .frame(width: 22, height: 22)
        }
        .accessibilityHidden(true)
    }
}

extension View {
    /// Hosts the shared undo capsule at the bottom of this screen; see `UndoCapsuleHost`.
    func undoCapsuleHost(bottomPadding: CGFloat = 90) -> some View {
        overlay(alignment: .bottom) {
            UndoCapsuleHost().padding(.bottom, bottomPadding).padding(.horizontal, 16)
        }
    }
}
