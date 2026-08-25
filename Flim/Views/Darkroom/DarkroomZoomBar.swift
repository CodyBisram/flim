import SwiftUI

/// The zoom ladder's persistent chrome: crumb + sub line, and the minus/plus rung control. Sits
/// below the pinned sort banner and above the swapped content region (PR 3 of the zoom redesign,
/// revision 2). Hidden entirely in select mode by the caller, same as the sort banner.
struct DarkroomZoomBar: View {
    let zoom: DarkroomZoom
    let anchor: DarkroomYearMonth
    /// "· N shots · N nights" etc, already formatted, `nil` to omit (see `DarkroomZoomChrome.sub`).
    let sub: String?
    let accent: Color
    let onZoomOut: () -> Void
    let onZoomIn: () -> Void

    private var crumb: String { DarkroomZoomChrome.crumb(zoom: zoom, anchor: anchor) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HStack(spacing: 6) {
                    Text(crumb)
                        .flimFont(12, weight: .semibold)
                        .tracking(1.1)
                        .foregroundStyle(FlimTheme.textSecondary)
                    if let sub {
                        Text(sub)
                            .flimFont(11.5)
                            .foregroundStyle(FlimTheme.textTertiary)
                    }
                }
                .accessibilityElement(children: .combine)

                Spacer(minLength: 8)

                zoomControl
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            LinearGradient(
                stops: [
                    .init(color: FlimTheme.stroke, location: 0),
                    .init(color: .clear, location: 0.6),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading, endPoint: .trailing)
                .frame(height: 1)
                .padding(.horizontal, 16)
        }
    }

    private var zoomControl: some View {
        HStack(spacing: 0) {
            controlHalf(systemName: "minus", enabled: zoom != .allTime, label: "Zoom out", action: onZoomOut)
            Rectangle().fill(FlimTheme.stroke).frame(width: 1, height: 26)
            controlHalf(systemName: "plus", enabled: zoom != .month, label: "Zoom in", action: onZoomIn)
        }
        .frame(height: 26)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(FlimTheme.stroke, lineWidth: 1))
    }

    /// Not `.disabled(...)`: at a ladder end the control stays reachable by VoiceOver (the design
    /// calls it out explicitly, "still focusable") and simply no-ops, rather than being pulled out
    /// of the accessibility tree the way `.disabled` risks.
    @ViewBuilder
    private func controlHalf(systemName: String, enabled: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button {
            guard enabled else { return }
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FlimTheme.textSecondary)
                .frame(width: 32, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(DarkroomZoomHalfButtonStyle(accent: accent))
        .opacity(enabled ? 1 : 0.45)
        .expandTapTarget(by: 9)
        .accessibilityLabel(label)
        .accessibilityValue(crumb)
    }
}

/// Tints a half of the zoom control while pressed, `accent.opacity(0.12)`, the same soft-fill
/// language every other pressed/selected control on this screen uses.
private struct DarkroomZoomHalfButtonStyle: ButtonStyle {
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? accent.opacity(0.12) : Color.clear)
    }
}
