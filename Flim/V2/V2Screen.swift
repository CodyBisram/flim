import SwiftUI

/// The frame for a v2 screen past the places: on the phone and the open display a header row,
/// Back, the title, an action; closed, the content fills the left and the controls stand in the
/// trailing column, Back first and the main action last (round 16's rule for the outer display).
struct V2Screen<Content: View, Trailing: View>: View {
    let title: String
    var back: String = "Back"
    var onBack: () -> Void
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.v2Palette) private var palette

    var body: some View {
        GeometryReader { proxy in
            let mode = V2LayoutMode.resolve(horizontalSizeClass: sizeClass, proxy: proxy)
            Group {
                if mode == .outer {
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(title)
                                .font(V2Type.serif(22, relativeTo: .title2))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .padding(.horizontal, V2Metrics.margin)
                                .padding(.top, 12)
                                .accessibilityAddTraits(.isHeader)
                            content()
                        }
                        VStack(alignment: .trailing) {
                            backButton
                            Spacer()
                            trailing()
                        }
                        .padding(.vertical, 12)
                        .padding(.trailing, 14)
                        .frame(width: V2RootMetrics.columnWidth, alignment: .trailing)
                    }
                } else {
                    VStack(spacing: 0) {
                        HStack {
                            backButton
                            Spacer(minLength: 8)
                            Text(title)
                                .font(V2Type.serif(15, relativeTo: .subheadline))
                                .lineLimit(1)
                                .accessibilityAddTraits(.isHeader)
                            Spacer(minLength: 8)
                            // Balances the title on the row when there is no action.
                            ZStack(alignment: .trailing) {
                                backButton.hidden()
                                trailing()
                            }
                        }
                        .padding(.horizontal, V2Metrics.margin)
                        content()
                    }
                }
            }
            .environment(\.v2LayoutMode, mode)
        }
        .background { V2Desktop(palette: palette) }
        .foregroundStyle(palette.ink)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var backButton: some View {
        Button(action: onBack) {
            Text(back).font(V2Type.control()).frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension V2Screen where Trailing == EmptyView {
    init(title: String, back: String = "Back", onBack: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, back: back, onBack: onBack, trailing: { EmptyView() }, content: content)
    }
}

/// Shows its content only on the closed display (or, with `hidesWhenClosed`, everywhere but),
/// for an action that moves into the column when the display is closed.
struct V2ClosedOnly<Content: View>: View {
    var hidesWhenClosed = false
    @ViewBuilder var content: () -> Content

    @Environment(\.v2LayoutMode) private var mode

    var body: some View {
        if (mode == .outer) != hidesWhenClosed { content() }
    }
}
