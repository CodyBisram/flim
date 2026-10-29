#if DEBUG
import SwiftUI

/// `-v2Demo`: v2's frame on stand-in places, no account and no network, for checking the three
/// arrangements on the simulator (an iPhone, and the iPhone Duo closed and open). The places are
/// prints of flat colour; the real ones are the App Store app's screens, wired in `MainTabView`.
/// `-v2DemoPlace darkroom` (or `friends`) opens on another place.
struct V2DemoHost: View {
    @State private var place: V2Place = V2Place.allCases.first {
        $0.title.lowercased() == UserDefaults.standard.string(forKey: "v2DemoPlace")
    } ?? .personal

    var body: some View {
        root.modifier(V2DemoFrame())
    }

    private var root: some View {
        V2RootView(place: $place,
                   darkroomCount: 4,
                   content: { place, _ in V2DemoPlace(place: place) },
                   columnFoot: { _ in V2RollsButton(hasUnwatched: true) {} })
    }

}

/// `-v2DemoFrame 669x951` draws whatever it wraps at another display's size, scaled to fit, with
/// the open display's size class when that is regular: for the arrangement the simulator cannot be
/// folded into from the command line. Without the flag it changes nothing.
struct V2DemoFrame: ViewModifier {
    func body(content: Content) -> some View {
        if let frame = Self.frame {
            GeometryReader { proxy in
                let scale = min(proxy.size.width / frame.size.width, proxy.size.height / frame.size.height)
                content
                    .environment(\.horizontalSizeClass, frame.sizeClass)
                    .frame(width: frame.size.width, height: frame.size.height)
                    .scaleEffect(scale)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .background(Color.black.ignoresSafeArea())
        } else {
            content
        }
    }

    static var frame: (size: CGSize, sizeClass: UserInterfaceSizeClass)? {
        guard let text = UserDefaults.standard.string(forKey: "v2DemoFrame") else { return nil }
        let parts = text.split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        // Regular from 600 points across, as the open display is; the closed one is compact.
        return (CGSize(width: parts[0], height: parts[1]), parts[0] >= 600 ? .regular : .compact)
    }
}

private struct V2DemoPlace: View {
    let place: V2Place

    @Environment(\.v2Palette) private var palette

    private static let swatches: [UInt32] = [0x6E7F8D, 0xB0846A, 0x55705A, 0x8C6F96, 0xC9A15A, 0x4F6C8C]
    private static let day = Date(timeIntervalSince1970: 1_793_000_000)

    var body: some View {
        GeometryReader { proxy in
            switch place {
            case .personal:
                // The camera's place: one print the width the viewfinder will be.
                let width = V2PrintGeometry.width(fitting: CGSize(width: proxy.size.width - V2Metrics.margin * 2,
                                                                  height: proxy.size.height - 24))
                V2Print(width: width, caption: "Personal", date: Self.day) { swatch(0) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .darkroom:
                ScrollView {
                    let columns = Array(repeating: GridItem(.flexible(), spacing: V2Metrics.gutter), count: 3)
                    LazyVGrid(columns: columns, spacing: V2Metrics.gutter * 2) {
                        ForEach(0..<12, id: \.self) { index in
                            V2Print(width: (proxy.size.width - V2Metrics.margin * 2 - V2Metrics.gutter * 2) / 3,
                                    showsShadow: true) { swatch(index) }
                        }
                    }
                    .padding(V2Metrics.margin)
                }
            case .friends:
                ScrollView {
                    VStack(spacing: 28) {
                        ForEach(0..<4, id: \.self) { index in
                            V2Print(width: min(340, proxy.size.width - V2Metrics.margin * 2),
                                    caption: "A friend's evening", date: Self.day,
                                    tilt: .degrees(index.isMultiple(of: 2) ? -1 : 1.2)) { swatch(index + 2) }
                        }
                    }
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .background(palette.background)
    }

    private func swatch(_ index: Int) -> some View {
        V2Color.rgb(Self.swatches[index % Self.swatches.count])
    }
}
#endif
