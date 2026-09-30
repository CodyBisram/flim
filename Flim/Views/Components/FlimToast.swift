import SwiftUI

/// The app's one transient notice: a capsule that slides in from the screen edge it is anchored
/// to, says one thing, and leaves.
///
/// There used to be seventeen of these, each hand-built with its own font size, padding, icon and
/// haptic, so the same kind of news looked and felt slightly different on every screen. The kind
/// now decides the icon and the haptic; the host decides only the words, where the capsule sits,
/// and how long it stays.
///
/// - The icon is fixed per kind, so a failure always reads as a failure at a glance. The one
///   exception is `symbol:`, for a glyph that says more than the kind's (the offline pills).
/// - The haptic is paired with the kind (success chimes, error buzzes, info is silent, because an
///   info notice arrives unprompted). It plays when the toast appears or its words change, unless
///   the action that raised it already played one in the same beat (`Haptics.playedRecently`),
///   so a caller that buzzes on failure and then shows a toast is felt once, not twice.
/// - One transition: in from its own edge with a fade, or a plain fade under Reduce Motion.
/// - The surface is `glassCapsule()`: Liquid Glass on iOS 26, `.ultraThinMaterial` below, and an
///   opaque fill under Reduce Transparency on both.
/// - VoiceOver hears the words as they appear, since a toast is never focused, and hears the
///   same words once even when two hosts show them together.
///
/// The host still owns presentation: put it in an `if` inside an `overlay`, drive it with
/// `withAnimation`, and dismiss it on the host's own timer.
struct FlimToast: View {
    enum Kind: Equatable {
        case success, error, info

        var symbol: String {
            switch self {
            case .success: "checkmark.circle.fill"
            case .error: "exclamationmark.circle.fill"
            case .info: "info.circle"
            }
        }

        @MainActor
        fileprivate func playHaptic() {
            switch self {
            case .success: Haptics.success()
            case .error: Haptics.error()
            case .info: break
            }
        }
    }

    let text: String
    let kind: Kind
    /// Overrides the kind's icon where a more specific glyph reads faster at a glance (the
    /// offline pill's `wifi.slash`). The haptic still follows the kind.
    var symbol: String? = nil
    /// The edge the host anchors the toast to; the transition comes in from it.
    var edge: VerticalEdge = .top
    /// Off only where something else already owns the moment's haptic on its own schedule
    /// (the undo capsule's notices, whose callers buzz before `UndoCenter` shows them).
    var playsHaptic: Bool = true
    /// Centered for the usual one-liner; a long sentence that wraps reads better leading.
    var alignment: TextAlignment = .center

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ text: String, kind: Kind, symbol: String? = nil, edge: VerticalEdge = .top,
         playsHaptic: Bool = true, alignment: TextAlignment = .center) {
        self.text = text
        self.kind = kind
        self.symbol = symbol
        self.edge = edge
        self.playsHaptic = playsHaptic
        self.alignment = alignment
    }

    var body: some View {
        Label(text, systemImage: symbol ?? kind.symbol)
            .flimType(.label)
            .foregroundStyle(.white)
            .multilineTextAlignment(alignment)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .flimToastSurface()
            .accessibilityElement(children: .combine)
            .transition(Self.transition(edge: edge, reduceMotion: reduceMotion))
            .onChange(of: text, initial: true) { _, newText in
                if playsHaptic, !Haptics.playedRecently { kind.playHaptic() }
                Self.announce(newText)
            }
    }

    /// The text and system uptime of the last VoiceOver announcement. `UndoCapsuleHost` is
    /// mounted in more than one place at once (the tab root and a full-screen cover), so the
    /// same notice can appear in two or three toasts in the same beat; it is read once.
    @MainActor private static var lastAnnouncement: (text: String, time: TimeInterval)?

    @MainActor
    private static func announce(_ text: String) {
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastAnnouncement, last.text == text, now - last.time < 1 { return }
        lastAnnouncement = (text, now)
        AccessibilityNotification.Announcement(text).post()
    }

    /// The one toast transition. Public so a host-built capsule on the same shell (the undo
    /// capsule) can move the same way.
    static func transition(edge: VerticalEdge, reduceMotion: Bool) -> AnyTransition {
        reduceMotion
            ? .opacity
            : .move(edge: edge == .top ? .top : .bottom).combined(with: .opacity)
    }
}

/// The toast's capsule: glass on iOS 26, material below (both through `glassCapsule()`), and an
/// opaque fill with a hairline when the person has asked for less transparency.
private struct FlimToastSurface: ViewModifier {
    /// The pre-glass hairline the undo capsule has always drawn. Glass brings its own edge, so
    /// on iOS 26 the hairline is left off.
    var hairline: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(FlimTheme.sheetSurfaceSolid, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        } else if #available(iOS 26, *) {
            content.glassCapsule()
        } else if hairline {
            content
                .glassCapsule()
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        } else {
            content.glassCapsule()
        }
    }
}

extension View {
    /// The `FlimToast` capsule, for a host that needs its own contents on the same shell.
    func flimToastSurface(hairline: Bool = false) -> some View {
        modifier(FlimToastSurface(hairline: hairline))
    }
}
