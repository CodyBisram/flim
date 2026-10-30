import SwiftUI

/// What Appearance writes. The stamp is the App Store app's accent (`accentColor`): the same six
/// names with the same bright values, so the date burned into exports, the widget and every stamp
/// in v2 follow one choice.
enum V2Settings {
    static let stampKey = "accentColor"
    static let grainKey = "v2Grain"
    static let leakKey = "v2Leak"
    static let developKey = "v2Develop"
}

/// How long a print takes to develop the first time it is seen (handoff 2, "Develop").
enum V2DevelopMode: String, CaseIterable {
    case follow, always, quick

    var title: String {
        switch self {
        case .follow: "Follows Reduce Motion"
        case .always: "Always"
        case .quick: "Quick"
        }
    }

    func seconds(reduceMotion: Bool) -> Double {
        switch self {
        case .always: V2Motion.developSeconds
        case .quick: V2Motion.developSecondsReduced
        case .follow: reduceMotion ? V2Motion.developSecondsReduced : V2Motion.developSeconds
        }
    }
}

/// Appearance (board 4c, 16-1l, 16-1m; prototype): the desk, the stamp colour, the grain and the
/// camera's light leak, and how prints develop. Account and the rest of the settings sit under it.
struct V2AppearanceView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.v2Palette) private var palette
    @AppStorage(V2Desk.storageKey) private var deskRaw = V2Desk.system.rawValue
    @AppStorage(V2Settings.stampKey) private var stampRaw = V2Stamp.amber.rawValue
    @AppStorage(V2Settings.grainKey) private var grain = true
    @AppStorage(V2Settings.leakKey) private var leak = true
    @AppStorage(V2Settings.developKey) private var developRaw = V2DevelopMode.follow.rawValue
    @State private var showAccount = false

    private var stamp: V2Stamp { V2Stamp(rawValue: stampRaw) ?? .amber }

    var body: some View {
        GeometryReader { proxy in
            let mode = V2LayoutMode.resolve(horizontalSizeClass: sizeClass, proxy: proxy)
            Group {
                switch mode {
                case .phone:
                    VStack(spacing: 0) {
                        header.padding(.horizontal, V2Metrics.margin)
                        ScrollView { settings.padding(.horizontal, V2Metrics.margin) }
                        footnote.padding(.bottom, 16)
                    }
                case .outer:
                    // Settings have no main action, so the column holds Back alone (16-1l).
                    HStack(spacing: 0) {
                        ScrollView {
                            VStack(alignment: .leading) {
                                settings
                                footnote.padding(.top, 30)
                            }
                            .padding(.horizontal, V2Metrics.margin)
                            .padding(.vertical, 12)
                        }
                        VStack { backButton; Spacer() }
                            .padding(.vertical, 12)
                            .padding(.trailing, 14)
                            .frame(width: V2RootMetrics.columnWidth, alignment: .trailing)
                    }
                case .inner:
                    // Settings on the left, a live desk on the right (16-1m).
                    VStack(spacing: 0) {
                        header.padding(.horizontal, V2Metrics.margin)
                        HStack(spacing: 0) {
                            ScrollView {
                                VStack(alignment: .leading) {
                                    settings
                                    footnote.padding(.top, 30)
                                }
                                .padding(V2Metrics.margin)
                            }
                            .frame(maxWidth: .infinity)
                            preview
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            }
            .environment(\.v2LayoutMode, mode)
        }
        .background { V2Desktop(palette: palette) }
        .foregroundStyle(palette.ink)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showAccount) { ProfileView() }
    }

    private var header: some View {
        HStack {
            backButton
            Spacer(minLength: 8)
            Text("Appearance").font(V2Type.serif(15, relativeTo: .subheadline))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            backButton.hidden()
        }
    }

    private var backButton: some View {
        Button { dismiss() } label: {
            Text("Back").font(V2Type.control()).frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footnote: some View {
        Text("Prints are always cream. That part isn't a setting.")
            .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
            .foregroundStyle(palette.ink3)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    // MARK: Settings

    private var settings: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Desk").padding(.top, 14)
            HStack(spacing: 12) {
                deskSwatch(.paper)
                deskSwatch(.slate)
                deskSwatch(.system)
            }
            .padding(.top, 14)

            title("Stamp colour").padding(.top, 34)
            HStack(spacing: 14) {
                ForEach(V2Stamp.allCases, id: \.self) { option in
                    Button { stampRaw = option.rawValue; Haptics.tap() } label: {
                        Circle()
                            .fill(palette.isDark ? option.bright : option.paperColor)
                            .frame(width: 34, height: 34)
                            .overlay {
                                if option == stamp {
                                    Circle().stroke(palette.ink, lineWidth: 1.5).padding(-5)
                                }
                            }
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option.rawValue.capitalized)
                    .accessibilityAddTraits(option == stamp ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 8)
            HStack {
                Text("Burned into every print you take. Friends see it too.")
                    .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
                    .foregroundStyle(palette.ink3)
                Spacer(minLength: 8)
                V2DateStamp(text: BrandedExport.dateText(.init(date: .now)), cellHeight: 9, stamp: stamp)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(V2Color.rgb(0x151210))
                    .accessibilityHidden(true)
            }
            .padding(.top, 6)

            title("Dust and light").padding(.top, 34)
            VStack(spacing: 14) {
                toggleRow("Grain on the desk", value: grain) { grain.toggle() }
                toggleRow("Light leak in the camera", value: leak) { leak.toggle() }
                row("Develop animation", value: (V2DevelopMode(rawValue: developRaw) ?? .follow).title) {
                    let all = V2DevelopMode.allCases
                    let current = all.firstIndex(of: V2DevelopMode(rawValue: developRaw) ?? .follow) ?? 0
                    developRaw = all[(current + 1) % all.count].rawValue
                    Haptics.tap()
                }
                row("Account", value: "") { showAccount = true }
            }
            .padding(.top, 14)
        }
    }

    private func title(_ text: String) -> some View {
        Text(text).font(V2Type.serif(22, relativeTo: .title2)).accessibilityAddTraits(.isHeader)
    }

    private func deskSwatch(_ desk: V2Desk) -> some View {
        let selected = (V2Desk(rawValue: deskRaw) ?? .system) == desk
        return Button { deskRaw = desk.rawValue; Haptics.tap() } label: {
            ZStack(alignment: .bottom) {
                switch desk {
                case .paper: V2Color.rgb(0xF3E7DC)
                case .slate: V2Color.rgb(0x1C1917)
                case .system:
                    LinearGradient(stops: [.init(color: V2Color.rgb(0xF3E7DC), location: 0.5),
                                           .init(color: V2Color.rgb(0x1C1917), location: 0.5)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
                if desk != .system {
                    V2PrintCard(width: 52, showsShadow: false, borderFraction: 4.0 / 52, footFraction: 16.0 / 52) {
                        LinearGradient(colors: [V2Color.rgb(0xE9A05A), V2Color.rgb(0x5E3A2A)], startPoint: .top, endPoint: .bottom)
                    } foot: { Color.clear }
                    .shadow(color: .black.opacity(desk == .slate ? 0.5 : 0.16), radius: 3, y: 2)
                    .rotationEffect(.degrees(desk == .paper ? -3 : 3))
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 16)
                }
                Text(desk == .paper ? "Paper" : desk == .slate ? "Slate" : "System")
                    .font(V2Type.control(.caption))
                    .foregroundStyle(desk == .paper ? V2Color.printInk : V2Color.rgb(0xF3E7DC))
                    .shadow(color: desk == .system ? V2Color.rgb(0x1C1917) : .clear, radius: 3)
                    .padding(.bottom, 10)
            }
            .frame(height: 130)
            .frame(maxWidth: .infinity)
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            .overlay { if selected { Rectangle().stroke(palette.ink, lineWidth: 1.5).padding(-3) } }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(desk == .paper ? "Paper" : desk == .slate ? "Slate" : "System")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func toggleRow(_ label: String, value: Bool, toggle: @escaping () -> Void) -> some View {
        row(label, value: value ? "On" : "Off") { toggle(); Haptics.tap() }
            .accessibilityValue(value ? "On" : "Off")
    }

    private func row(_ label: String, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label).font(.system(.subheadline))
                Spacer()
                Text(value).font(V2Type.control(.subheadline)).foregroundStyle(palette.ink2)
            }
            .padding(.bottom, 12)
            .overlay(alignment: .bottom) { Rectangle().fill(palette.rule).frame(height: 1) }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Open: two loose prints on the chosen desk, with the chosen stamp (16-1m).
    private var preview: some View {
        ZStack {
            V2Desktop(palette: palette)
            ZStack {
                V2PrintCard(width: 150, tilt: .degrees(-4)) {
                    LinearGradient(colors: [V2Color.rgb(0x2E2620), V2Color.rgb(0x151210)], startPoint: .top, endPoint: .bottom)
                        .overlay(alignment: .bottomTrailing) {
                            V2DateStamp(text: BrandedExport.dateText(.init(date: .now)), cellHeight: 6, stamp: stamp)
                                .padding(8)
                        }
                } foot: { Color.clear }
                .offset(x: -40, y: -20)
                V2PrintCard(width: 150, tilt: .degrees(6)) {
                    LinearGradient(colors: [V2Color.rgb(0xE9A05A), V2Color.rgb(0x5E3A2A)], startPoint: .top, endPoint: .bottom)
                } foot: { Color.clear }
                .offset(x: 50, y: 30)
            }
            Text("Your desk, as it will look")
                .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
                .foregroundStyle(palette.ink2)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 24)
        }
        .accessibilityHidden(true)
    }
}

/// Develop (handoff 2): the first time a print is seen it comes up from blank cream through
/// sepia to the image. Seen prints show at once, this session and after.
struct V2Develop: ViewModifier {
    let key: String?

    @AppStorage(V2Settings.developKey) private var developRaw = V2DevelopMode.follow.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: Double = 1

    func body(content: Content) -> some View {
        content
            .sepia(1 - progress)
            .brightness((1 - progress) * 0.45)
            .contrast(0.2 + 0.8 * progress)
            .opacity(0.15 + 0.85 * progress)
            .onAppear {
                guard let key, !V2DevelopLedger.isDeveloped(key) else { return }
                V2DevelopLedger.markDeveloped(key)
                progress = 0
                let seconds = (V2DevelopMode(rawValue: developRaw) ?? .follow).seconds(reduceMotion: reduceMotion)
                withAnimation(.easeOut(duration: seconds)) { progress = 1 }
            }
    }
}

private extension View {
    /// Sepia as a hue-held colour shift, since SwiftUI has no sepia filter: desaturate, then warm.
    func sepia(_ amount: Double) -> some View {
        self.saturation(1 - amount * 0.8)
            .colorMultiply(Color(red: 1, green: 1 - 0.08 * amount, blue: 1 - 0.25 * amount))
    }
}

/// Which prints have developed on this device. Kept in memory and written in batches, so a feed
/// full of prints is one small write, not one per print.
@MainActor
enum V2DevelopLedger {
    private static let key = "v2Developed"
    private static let limit = 4_000
    private static var seen: Set<String> = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    private static var pendingWrite = false

    static func isDeveloped(_ id: String) -> Bool { seen.contains(id) }

    static func markDeveloped(_ id: String) {
        seen.insert(id)
        guard !pendingWrite else { return }
        pendingWrite = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            pendingWrite = false
            UserDefaults.standard.set(Array(seen.suffix(limit)), forKey: key)
        }
    }
}
