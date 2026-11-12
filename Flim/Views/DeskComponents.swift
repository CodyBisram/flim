import SwiftUI

// 1.7's shared pieces (the Blend boards): pills, the empty-state block, the failed-state block.
// Only 1.7 screens use them (`AppInfo.is17`); they read the desk's tokens, so they draw right on
// Paper and Slate alike.

/// A pill button label: 46 tall, 15 semibold. `solid` is the main action (ink on the desk),
/// `box` the second one (the box tone), `outline` the camera's accent outline (1.6's pill),
/// `red` a destructive confirm.
struct DeskPill: View {
    enum Style { case solid, box, outline, red }
    let title: String
    var systemImage: String?
    var style: Style
    var small = false

    @Environment(\.flimAccent) private var accent

    init(_ title: String, systemImage: String? = nil, style: Style, small: Bool = false) {
        self.title = title
        self.systemImage = systemImage
        self.style = style
        self.small = small
    }

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage { Image(systemName: systemImage) }
            Text(title).lineLimit(1)
        }
        .flimFont(small ? 13 : 15, weight: .semibold, relativeTo: small ? .footnote : .body)
        .foregroundStyle(foreground)
        .padding(.horizontal, small ? 16 : 24)
        .frame(minHeight: small ? 34 : 46)
        .background(background, in: Capsule())
        .overlay {
            if style == .outline { Capsule().strokeBorder(FlimTheme.ink(accent), lineWidth: 1.5) }
        }
        .contentShape(Capsule())
    }

    private var foreground: Color {
        switch style {
        case .solid: DeskColor.onSolid
        case .box: FlimTheme.textPrimary
        case .outline: FlimTheme.ink(accent)
        case .red: Color(white: 0.98)
        }
    }

    private var background: Color {
        switch style {
        case .solid: DeskColor.solid
        case .box: FlimTheme.surface
        case .outline: .clear
        case .red: DeskColor.red
        }
    }
}

/// The empty-state block every 1.7 screen uses (Blend 2, part 8): a short accent rule, one
/// Caslon line, one sentence, then up to two actions.
struct DeskEmptyState<Actions: View>: View {
    let title: String
    let message: String
    @ViewBuilder var actions: () -> Actions

    @Environment(\.flimAccent) private var accent

    init(title: String, message: String, @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }) {
        self.title = title
        self.message = message
        self.actions = actions
    }

    var body: some View {
        VStack(spacing: 10) {
            Rectangle().fill(accent).frame(width: 36, height: 2)
            Text(title)
                .font(DeskType.serif(24, relativeTo: .title2))
                .foregroundStyle(FlimTheme.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .flimFont(15, relativeTo: .subheadline)
                .foregroundStyle(FlimTheme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
            // ViewThatFits: side by side when they fit, stacked at large text sizes.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { actions() }
                VStack(spacing: 10) { actions() }
            }
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
    }
}

/// "Couldn't load your …" with Try again (Blend 2, 8i). Each screen gives its own first line.
struct DeskFailedState: View {
    static let standardMessage = "Check your connection and try again."

    let title: String
    let message: String
    let retry: () async -> Void

    @State private var retrying = false

    var body: some View {
        DeskEmptyState(title: title, message: message) {
            Button {
                retrying = true
                Task { await retry(); retrying = false }
            } label: {
                DeskPill(retrying ? "Trying…" : "Try again", systemImage: "arrow.clockwise", style: .solid)
            }
            .disabled(retrying)
        }
    }
}

/// "You're offline." under a tab's title while the connection is gone (Blend 2, 8h). It goes on
/// its own when the connection comes back; saved shots stay readable under it.
struct DeskOfflineBanner: View {
    @Environment(NetworkMonitor.self) private var network

    var body: some View {
        if !network.isConnected {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(FlimTheme.textSecondary)
                    .padding(.top, 2)
                (Text("You're offline. ").fontWeight(.semibold).foregroundColor(FlimTheme.textPrimary)
                 + Text("Showing what was saved. The camera still works, and new shots upload when you're back.")
                    .foregroundColor(FlimTheme.textSecondary))
                    .flimFont(13.5, relativeTo: .footnote)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FlimTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .combine)
        }
    }
}


/// A screen title: Caslon in 1.7, the 1.6 treatment (passed in) otherwise.
struct DeskTitleOr<V1: View>: ViewModifier {
    let size: CGFloat
    let v1: (AnyView) -> V1

    init(size: CGFloat, @ViewBuilder v1: @escaping (AnyView) -> V1) {
        self.size = size
        self.v1 = v1
    }

    func body(content: Content) -> some View {
        if AppInfo.is17 {
            content.font(DeskType.serif(size, relativeTo: .title))
        } else {
            v1(AnyView(content))
        }
    }
}
