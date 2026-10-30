import SwiftUI

/// v2's frame: the three places side by side in a native pager, with the top row (you, Find,
/// Activity) and the place names over them. Replaces the tab bar.
///
/// One view for every screen shape (owner, 2026-10-27: iPhone Duo and regular iPhones together):
/// - phone: the top row, then the place names spread across with their ticks, then one place at
///   a time (prototype).
/// - outer (Duo closed, short and wide): the places fill the display and the top row becomes a
///   column on the trailing edge: you, Find and Activity at the top, the place names in the
///   middle, the place's main action at the foot, near the thumb (board 15a to 15c).
/// - inner (Duo open): one line across the top, you, the place names and Find and Activity;
///   Personal and Darkroom share the display as one page, the fold between them, and Friends is
///   the other (board 15d, 15e).
///
/// The places themselves come from the caller, so this frame knows nothing about the camera, the
/// Darkroom or the feed, and the demo host can fill it with anything.
struct V2RootView<Content: View, Foot: View>: View {
    @Binding var place: V2Place
    /// Tapping the name of the place already showing: scroll it to the top, as a re-tapped tab did.
    var onReselect: (V2Place) -> Void = { _ in }
    /// Darkroom's count beside its name, as the prototype writes it ("Darkroom 4"). Nil or zero
    /// shows the name alone.
    var darkroomCount: Int? = nil
    /// A place's screen, and whether its page is the one showing. The pager builds the pages
    /// beside the current one early, and their `onAppear` fires then, so anything that must run
    /// only on screen (the camera above all) is built only while this is true.
    @ViewBuilder var content: (_ place: V2Place, _ isShowing: Bool) -> Content
    /// The closed display's column foot: the place's main action, last in the column (the shutter
    /// and Rolls on Personal). Unused on the phone and the open display, where the place holds it.
    @ViewBuilder var columnFoot: (_ place: V2Place) -> Foot

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(V2Desk.storageKey) private var deskRaw = V2Desk.system.rawValue
    @AppStorage(V2Settings.stampKey) private var stampRaw = V2Stamp.amber.rawValue

    private var palette: V2Palette {
        V2Palette.of(V2Desk(rawValue: deskRaw) ?? .system, scheme: colorScheme)
    }

    var body: some View {
        GeometryReader { proxy in
            let mode = V2LayoutMode.resolve(horizontalSizeClass: sizeClass, size: proxy.size)
            Group {
                switch mode {
                case .phone: stacked(mode)
                case .outer: column(mode)
                case .inner: open(mode)
                }
            }
            .environment(\.v2LayoutMode, mode)
        }
        .background { V2Desktop(palette: palette, leak: place == .personal) }
        .modifier(V2DeskEnvironment())
        .environment(\.v2Stamp, V2Stamp(rawValue: stampRaw) ?? .amber)
        .foregroundStyle(palette.ink)
    }

    // MARK: Arrangements

    private func stacked(_ mode: V2LayoutMode) -> some View {
        VStack(spacing: 0) {
            V2TopRow()
                .padding(.horizontal, V2Metrics.margin)
            V2PlaceRow(mode: mode, place: place, darkroomCount: darkroomCount, select: select)
                .padding(.horizontal, V2Metrics.margin)
            pager(mode)
                .padding(.top, 2)
        }
    }

    /// The column sits on the trailing edge for right-handed use (board 15a). Its names are
    /// right-aligned; the place is not divided from it by a rule.
    private func column(_ mode: V2LayoutMode) -> some View {
        HStack(spacing: 0) {
            pager(mode)
            VStack(alignment: .trailing, spacing: 0) {
                V2TopRow()
                Spacer(minLength: 16)
                V2PlaceRow(mode: mode, place: place, darkroomCount: darkroomCount, select: select)
                Spacer(minLength: 16)
                columnFoot(place)
            }
            .padding(.top, 12)
            .padding(.bottom, 10)
            .padding(.trailing, 14)
            .frame(width: V2RootMetrics.columnWidth, alignment: .trailing)
        }
    }

    private func open(_ mode: V2LayoutMode) -> some View {
        VStack(spacing: 0) {
            V2TopRow {
                V2PlaceRow(mode: mode, place: place, darkroomCount: darkroomCount, select: select)
            }
            .padding(.horizontal, V2Metrics.margin)
            .padding(.top, 2)
            pager(mode)
                .padding(.top, 10)
        }
    }

    private func pager(_ mode: V2LayoutMode) -> some View {
        let groups = mode.placeGroups
        return TabView(selection: pageBinding(mode)) {
            ForEach(groups.indices, id: \.self) { index in
                page(groups[index], isShowing: index == mode.page(of: place))
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        // Each arrangement is its own pager: the page count differs, and a pager kept across a
        // fold would hold an index from the other one.
        .id(mode)
    }

    @ViewBuilder
    private func page(_ group: [V2Place], isShowing: Bool) -> some View {
        if group.count == 1, let only = group.first {
            content(only, isShowing)
        } else {
            // Open, the two share the display and the fold runs between them: a dashed mark
            // that takes no space, and nothing either side puts a control on it (board 15d).
            HStack(spacing: 0) {
                ForEach(group) { member in
                    content(member, isShowing)
                        .frame(maxWidth: .infinity)
                }
            }
            .overlay {
                V2Fold(color: palette.tick)
                    .allowsHitTesting(false)
            }
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
    /// The outer display's trailing column: room for "Darkroom" and "Activity" plus margins.
    static let columnWidth: CGFloat = 104
    /// The page ticks under the place names.
    static let tickSize = CGSize(width: 12, height: 1.5)
    static let tickGap: CGFloat = 5
}

/// The desk under everything: its colour, the grain over it (3% on Paper, 4% on Slate, never on a
/// photograph), and on the camera one warm light leak from the top left (handoff 1, "Grain and
/// light").
struct V2Desktop: View {
    let palette: V2Palette
    var leak: Bool = false

    @AppStorage(V2Settings.grainKey) private var grain = true
    @AppStorage(V2Settings.leakKey) private var leakEnabled = true

    var body: some View {
        ZStack {
            palette.background
            Image(uiImage: V2Grain.tile)
                .resizable(resizingMode: .tile)
                .opacity(grain ? (palette.isDark ? 0.04 : 0.03) : 0)
                .blendMode(palette.isDark ? .screen : .multiply)
            GeometryReader { proxy in
                RadialGradient(colors: [V2Color.rgb(0xE9A05A, opacity: 0.32), V2Color.rgb(0xE9A05A, opacity: 0)],
                               center: UnitPoint(x: 0.08, y: 0.06), startRadius: 0,
                               endRadius: max(proxy.size.width, proxy.size.height) * 0.42)
                    .scaleEffect(x: 1.5, y: 1, anchor: UnitPoint(x: 0.08, y: 0.06))
            }
            .opacity(leak && leakEnabled ? 1 : 0)
            .animation(.easeInOut(duration: 0.4), value: leak && leakEnabled)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// A 256 pt noise tile, drawn once from a fixed seed so the grain never shimmers between launches.
enum V2Grain {
    static let tile: UIImage = {
        let size = 256
        var generator = SplitMix64(seed: 0x464C494D)
        var pixels = [UInt8](repeating: 0, count: size * size)
        for index in pixels.indices { pixels[index] = UInt8(truncatingIfNeeded: generator.next() >> 56) }
        let provider = CGDataProvider(data: Data(pixels) as CFData)
        guard let provider,
              let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 8,
                                  bytesPerRow: size, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return UIImage() }
        return UIImage(cgImage: image, scale: 1, orientation: .up)
    }()

    private struct SplitMix64 {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }
}

/// Where the open display folds: a dashed line down the middle (board 15d). Drawn, not laid out.
private struct V2Fold: View {
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                path.move(to: CGPoint(x: proxy.size.width / 2, y: 0))
                path.addLine(to: CGPoint(x: proxy.size.width / 2, y: proxy.size.height))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
        .accessibilityHidden(true)
    }
}

/// The place names. On the phone they spread across the width, the active one in the serif at 15
/// in ink, the others system 13/600 in ink 3, ticks under them (prototype). On the Duo, closed and
/// open, they are all system 13/600 and the active one is underlined 1.5 pt (handoff: "the active
/// one is underlined"; board 15); open, Personal and Darkroom are one name.
struct V2PlaceRow: View {
    let mode: V2LayoutMode
    let place: V2Place
    var darkroomCount: Int? = nil
    let select: (V2Place) -> Void

    @Environment(\.v2Palette) private var palette

    var body: some View {
        let groups = mode.placeGroups
        let activePage = mode.page(of: place)
        switch mode {
        case .phone:
            VStack(spacing: 6) {
                HStack {
                    ForEach(groups.indices, id: \.self) { index in
                        if index > 0 { Spacer(minLength: 8) }
                        serifName(groups[index][0], active: index == activePage)
                    }
                }
                ticks(count: groups.count, active: activePage)
            }
        case .outer:
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(groups.indices, id: \.self) { index in
                    underlinedName(groups[index], active: index == activePage)
                }
            }
        case .inner:
            HStack(spacing: 18) {
                ForEach(groups.indices, id: \.self) { index in
                    underlinedName(groups[index], active: index == activePage)
                }
            }
        }
    }

    private func serifName(_ member: V2Place, active: Bool) -> some View {
        Button { select(member) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(member.title)
                    .font(active ? V2Type.serif(15, relativeTo: .subheadline) : V2Type.control())
                    .foregroundStyle(active ? palette.ink : palette.ink3)
                if member == .darkroom, let darkroomCount, darkroomCount > 0 {
                    Text("\(darkroomCount)")
                        .font(V2Type.serif(active ? 15 : 13, italic: true, relativeTo: .subheadline))
                        .foregroundStyle(palette.ink2)
                }
            }
            .lineLimit(1)
            .frame(minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label(member))
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func underlinedName(_ group: [V2Place], active: Bool) -> some View {
        let first = group[0]
        let title = group.map(\.title).joined(separator: " and ")
        return Button { select(first) } label: {
            Text(title)
                .font(V2Type.control())
                .foregroundStyle(active ? palette.ink : palette.ink2)
                .lineLimit(1)
                .padding(.bottom, 3)
                .overlay(alignment: .bottom) {
                    if active {
                        Rectangle().fill(palette.ink).frame(height: 1.5)
                    }
                }
                .frame(minHeight: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(group.count == 1 ? label(first) : title)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func label(_ member: V2Place) -> String {
        if member == .darkroom, let darkroomCount, darkroomCount > 0 {
            return "Darkroom, \(darkroomCount) to sort"
        }
        return member.title
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
