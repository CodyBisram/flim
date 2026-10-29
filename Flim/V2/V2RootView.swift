import SwiftUI

/// v2's frame: the three places side by side in a native pager, with the top row (you, Find,
/// Activity) and the place names over them. Replaces the tab bar.
///
/// One view for every screen shape (owner, 2026-10-27: iPhone Duo and regular iPhones together):
/// - phone: the top row, then the place names with their ticks, then one place at a time.
/// - outer (Duo closed, short and wide): the places fill the display and the top row becomes a
///   column on the trailing edge, the place names in its middle and the place's action at its
///   foot, near the thumb (board 15a to 15c).
/// - inner (Duo open): Personal and Darkroom share the display as one page; Friends is the other
///   (board 15d, 15e).
///
/// The places themselves come from the caller, so this frame knows nothing about the camera, the
/// Darkroom or the feed, and the demo host can fill it with anything.
struct V2RootView<TopRow: View, Content: View, Foot: View>: View {
    @Binding var place: V2Place
    /// Tapping the name of the place already showing: scroll it to the top, as a re-tapped tab did.
    var onReselect: (V2Place) -> Void = { _ in }
    @ViewBuilder var topRow: () -> TopRow
    /// A place's screen, and whether its page is the one showing. The pager builds the pages
    /// beside the current one early, and their `onAppear` fires then, so anything that must run
    /// only on screen (the camera above all) is built only while this is true.
    @ViewBuilder var content: (_ place: V2Place, _ isShowing: Bool) -> Content
    /// Personal's own action under the camera (the Rolls shelf for now). In the outer column's
    /// foot when the display is closed.
    @ViewBuilder var foot: () -> Foot

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(V2Desk.storageKey) private var deskRaw = V2Desk.system.rawValue

    private var palette: V2Palette {
        V2Palette.of(V2Desk(rawValue: deskRaw) ?? .system, scheme: colorScheme)
    }

    var body: some View {
        GeometryReader { proxy in
            let mode = V2LayoutMode.resolve(horizontalSizeClass: sizeClass, size: proxy.size)
            Group {
                switch mode {
                case .phone, .inner: stacked(mode)
                case .outer: column(mode)
                }
            }
            .environment(\.v2LayoutMode, mode)
        }
        .background(palette.background.ignoresSafeArea())
        .environment(\.v2Palette, palette)
    }

    // MARK: Arrangements

    private func stacked(_ mode: V2LayoutMode) -> some View {
        VStack(spacing: 0) {
            topRow()
                .padding(.horizontal, V2Metrics.margin)
                .padding(.top, 6)
            V2PlaceRow(mode: mode, place: place, select: select)
                .padding(.top, 10)
                .padding(.bottom, 8)
            pager(mode)
        }
    }

    private func column(_ mode: V2LayoutMode) -> some View {
        HStack(spacing: 0) {
            pager(mode)
            Rectangle().fill(palette.rule).frame(width: 1).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                topRow()
                Spacer(minLength: 16)
                V2PlaceRow(mode: mode, place: place, select: select)
                Spacer(minLength: 16)
                if place == .personal { foot() }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 12)
            .frame(width: V2RootMetrics.columnWidth)
        }
    }

    private func pager(_ mode: V2LayoutMode) -> some View {
        let groups = mode.placeGroups
        return TabView(selection: pageBinding(mode)) {
            ForEach(groups.indices, id: \.self) { index in
                page(groups[index], mode: mode, isShowing: index == mode.page(of: place))
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        // Each arrangement is its own pager: the page count differs, and a pager kept across a
        // fold would hold an index from the other one.
        .id(mode)
    }

    @ViewBuilder
    private func page(_ group: [V2Place], mode: V2LayoutMode, isShowing: Bool) -> some View {
        if group.count == 1, let only = group.first {
            placeView(only, mode: mode, isShowing: isShowing)
        } else {
            // Open, the split sits on the fold, so nothing either side puts a control there.
            HStack(spacing: 0) {
                ForEach(group) { member in
                    if member != group.first {
                        Rectangle().fill(palette.rule).frame(width: 1)
                    }
                    placeView(member, mode: mode, isShowing: isShowing)
                }
            }
        }
    }

    @ViewBuilder
    private func placeView(_ member: V2Place, mode: V2LayoutMode, isShowing: Bool) -> some View {
        if member == .personal, mode != .outer {
            VStack(spacing: 0) {
                content(member, isShowing)
                foot()
                    .frame(maxWidth: .infinity)
                    .frame(height: V2RootMetrics.footHeight)
            }
        } else {
            content(member, isShowing)
        }
    }

    // MARK: Selection

    private func pageBinding(_ mode: V2LayoutMode) -> Binding<Int> {
        Binding(
            get: { mode.page(of: place) },
            set: { newPage in
                guard newPage != mode.page(of: place) else { return }
                place = mode.place(onPage: newPage)
            }
        )
    }

    private func select(_ target: V2Place) {
        if target == place {
            onReselect(target)
        } else {
            withAnimation(V2Motion.slide) { place = target }
        }
    }
}

enum V2RootMetrics {
    /// The outer display's trailing column: room for "Darkroom" in the place face plus margins.
    static let columnWidth: CGFloat = 104
    /// Personal's foot under the camera.
    static let footHeight: CGFloat = 44
    /// The page ticks under the place names.
    static let tickSize = CGSize(width: 12, height: 1.5)
    static let tickGap: CGFloat = 5
}

/// The place names. The active one is in the serif at 15 in ink; the others are controls, system
/// 13/600 in ink 3 (the handoff's "text is the control"). On the phone and the open display the
/// names sit in a row with a tick per page under them; in the closed display's column they stack.
struct V2PlaceRow: View {
    let mode: V2LayoutMode
    let place: V2Place
    let select: (V2Place) -> Void

    @Environment(\.v2Palette) private var palette

    var body: some View {
        let groups = mode.placeGroups
        let activePage = mode.page(of: place)
        if mode == .outer {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(groups.indices, id: \.self) { index in
                    ForEach(groups[index]) { name($0, active: index == activePage) }
                }
            }
        } else {
            VStack(spacing: 8) {
                HStack(spacing: 22) {
                    ForEach(groups.indices, id: \.self) { index in
                        HStack(spacing: 10) {
                            ForEach(groups[index]) { name($0, active: index == activePage) }
                        }
                    }
                }
                ticks(count: groups.count, active: activePage)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func name(_ member: V2Place, active: Bool) -> some View {
        Button { select(member) } label: {
            Text(member.title)
                .font(active ? V2Type.serif(15, relativeTo: .subheadline) : V2Type.control())
                .foregroundStyle(active ? palette.ink : palette.ink3)
                .lineLimit(1)
                .frame(minHeight: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(member == place ? .isSelected : [])
    }

    private func ticks(count: Int, active: Int) -> some View {
        HStack(spacing: V2RootMetrics.tickGap) {
            ForEach(0..<count, id: \.self) { index in
                Rectangle()
                    .fill(index == active ? palette.ink : palette.tick)
                    .frame(width: V2RootMetrics.tickSize.width, height: V2RootMetrics.tickSize.height)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct V2LayoutModeKey: EnvironmentKey {
    static let defaultValue: V2LayoutMode = .phone
}

extension EnvironmentValues {
    var v2LayoutMode: V2LayoutMode {
        get { self[V2LayoutModeKey.self] }
        set { self[V2LayoutModeKey.self] = newValue }
    }
}

extension V2Desk {
    /// The desk the person chose. Appearance and first run (not built yet) write it.
    static let storageKey = "v2Desk"
}
