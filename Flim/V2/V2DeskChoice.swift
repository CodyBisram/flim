import SwiftUI

/// First run's v2 questions (board 9b, 16-1n, 16-1o): where your prints lie, then your stamp.
/// Tapping a desk chooses it and carries on; "Match my phone" follows the system. The stamp is
/// shown on a real print with amber preselected. Shown once, after onboarding, to anyone who has
/// not chosen a desk yet. Open, each half of the screen is one desk.
struct V2DeskChoice: View {
    var chosen: () -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(V2Desk.storageKey) private var deskRaw = V2Desk.system.rawValue

    /// Set once a desk has been chosen here, so the question is asked once.
    static let askedKey = "v2DeskAsked"

    #if DEBUG
    // `-v2AskStamp`: opens on the stamp step, for screenshots.
    @State private var pickingStamp = ProcessInfo.processInfo.arguments.contains("-v2AskStamp")
    #else
    @State private var pickingStamp = false
    #endif

    var body: some View {
        if pickingStamp {
            V2StampChoice { chosen() }
                .modifier(V2DeskEnvironment())
                .transition(.opacity)
        } else {
            GeometryReader { proxy in
                let mode = V2LayoutMode.resolve(horizontalSizeClass: sizeClass, size: proxy.size)
                if mode == .inner {
                    halves
                } else {
                    cards(mode)
                }
            }
            // Open, the two desks run to the screen's edges.
            .ignoresSafeArea(edges: sizeClass == .regular ? .all : [])
        }
    }

    private var system: V2Palette { V2Palette.of(.system, scheme: colorScheme) }

    // MARK: Phone and closed

    private func cards(_ mode: V2LayoutMode) -> some View {
        VStack(alignment: mode == .outer ? .leading : .center, spacing: 0) {
            Text("Where should your prints lie?")
                .font(V2Type.serif(30, relativeTo: .largeTitle))
                .multilineTextAlignment(mode == .outer ? .leading : .center)
                .accessibilityAddTraits(.isHeader)
            Text("You can change it later in Appearance.")
                .font(V2Type.serif(15, italic: true, relativeTo: .body))
                .foregroundStyle(system.ink2)
                .padding(.top, 8)
            HStack(spacing: 18) {
                card(.paper)
                card(.slate)
            }
            .padding(.top, 44)
            Spacer()
            HStack {
                if mode == .outer { Spacer() }
                matchButton
            }
            .padding(.bottom, 24)
        }
        .padding(.horizontal, V2Metrics.margin)
        .padding(.top, mode == .outer ? 24 : 120)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(system.ink)
        .background { V2Desktop(palette: system) }
    }

    private func card(_ desk: V2Desk) -> some View {
        let palette: V2Palette = desk == .slate ? .slate : .paper
        return Button { choose(desk) } label: {
            VStack(spacing: 0) {
                samplePrint(width: 86, desk: desk)
                    .padding(.top, 26)
                Spacer()
                Text(desk == .paper ? "Paper" : "Slate")
                    .font(V2Type.control(.caption))
                    .foregroundStyle(palette.ink)
                    .padding(.bottom, 12)
            }
            .frame(width: 150, height: 200)
            .background(palette.background, in: RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(desk == .slate ? 0.35 : 0.25), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(desk == .paper ? "Paper" : "Slate")
        .accessibilityHint("Chooses this desk")
    }

    private var matchButton: some View {
        Button { choose(.system) } label: {
            Text("Match my phone")
                .font(V2Type.control())
                .foregroundStyle(system.ink2)
                .underline()
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
    }

    // MARK: Open

    private var halves: some View {
        HStack(spacing: 0) {
            half(.paper)
            half(.slate)
        }
        // The title crosses the fold, in each desk's own ink on its half.
        .overlay(alignment: .top) {
            GeometryReader { proxy in
                ZStack {
                    title(V2Palette.paper.ink)
                        .mask(alignment: .leading) { Rectangle().frame(width: proxy.size.width / 2) }
                    title(V2Palette.slate.ink)
                        .mask(alignment: .trailing) { Rectangle().frame(width: proxy.size.width / 2) }
                }
                .frame(width: proxy.size.width)
            }
            .padding(.top, 40)
            .allowsHitTesting(false)
        }
    }

    private func title(_ ink: Color) -> some View {
        Text("Where should your prints lie?")
            .font(V2Type.serif(30, relativeTo: .largeTitle))
            .foregroundStyle(ink)
            .frame(maxWidth: .infinity)
            .accessibilityAddTraits(.isHeader)
    }

    private func half(_ desk: V2Desk) -> some View {
        let palette: V2Palette = desk == .slate ? .slate : .paper
        return Button { choose(desk) } label: {
            ZStack {
                V2Desktop(palette: palette)
                VStack(spacing: 20) {
                    samplePrint(width: 150, desk: desk)
                    Text(desk == .paper ? "Paper" : "Slate")
                        .font(V2Type.control())
                        .foregroundStyle(palette.ink)
                }
                VStack {
                    Spacer()
                    HStack {
                        if desk == .paper {
                            Text("You can change it later in Appearance.")
                                .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
                                .foregroundStyle(palette.ink2)
                            Spacer()
                        } else {
                            Spacer()
                        }
                    }
                    .padding(V2Metrics.margin)
                }
            }
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottomTrailing) {
            if desk == .slate {
                Button { choose(.system) } label: {
                    Text("Match my phone")
                        .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
                        .foregroundStyle(palette.ink2)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .padding(V2Metrics.margin)
            }
        }
        .accessibilityLabel(desk == .paper ? "Paper" : "Slate")
    }

    /// A print with the burned-in date, the same on either desk: prints are always cream.
    private func samplePrint(width: CGFloat, desk: V2Desk) -> some View {
        V2PrintCard(width: width, showsShadow: false) {
            LinearGradient(colors: [V2Color.rgb(0xE9A05A), V2Color.rgb(0x3A2A22)], startPoint: .top, endPoint: .bottom)
                .overlay(alignment: .bottomTrailing) {
                    V2DateStamp(text: BrandedExport.dateText(.init(date: .now)), cellHeight: width * 0.045, stamp: .amber)
                        .padding(width * 0.05)
                }
        } foot: { Color.clear }
        .shadow(color: .black.opacity(desk == .slate ? 0.5 : 0.16), radius: 5, y: 3)
        .rotationEffect(.degrees(desk == .paper ? -3 : 3))
    }

    private func choose(_ desk: V2Desk) {
        Haptics.tap()
        deskRaw = desk.rawValue
        UserDefaults.standard.set(true, forKey: Self.askedKey)
        withAnimation(.easeInOut(duration: 0.35)) { pickingStamp = true }
    }
}

/// Your stamp (board 9b, screen 3): the colour burned into every print you take, shown on a real
/// print, amber preselected. It is the App Store app's accent, so it carries everywhere.
private struct V2StampChoice: View {
    var done: () -> Void

    @Environment(\.v2Palette) private var palette
    @AppStorage(V2Settings.stampKey) private var stampRaw = V2Stamp.amber.rawValue

    private var stamp: V2Stamp { V2Stamp(rawValue: stampRaw) ?? .amber }

    var body: some View {
        VStack(spacing: 0) {
            Text("Your stamp.")
                .font(V2Type.serif(30, relativeTo: .largeTitle))
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 70)
            Text("Burned into every print you take. Friends see it too.")
                .font(V2Type.serif(15, italic: true, relativeTo: .body))
                .foregroundStyle(palette.ink2)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .padding(.horizontal, V2Metrics.margin)
            Spacer(minLength: 20)
            V2PrintCard(width: 230, tilt: .degrees(-2)) {
                LinearGradient(colors: [V2Color.rgb(0xE9A05A), V2Color.rgb(0x3A2A22)], startPoint: .top, endPoint: .bottom)
                    .overlay(alignment: .bottomTrailing) {
                        V2DateStamp(text: BrandedExport.dateText(.init(date: .now)), cellHeight: 230 * 0.045, stamp: stamp)
                            .padding(12)
                    }
            } foot: { Color.clear }
            .accessibilityHidden(true)
            Spacer(minLength: 20)
            HStack(spacing: 14) {
                ForEach(V2Stamp.allCases, id: \.self) { option in
                    Button { stampRaw = option.rawValue; Haptics.tap() } label: {
                        Circle()
                            .fill(palette.isDark ? option.bright : option.paperColor)
                            .frame(width: 34, height: 34)
                            .overlay { if option == stamp { Circle().stroke(palette.ink, lineWidth: 1.5).padding(-5) } }
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option.rawValue.capitalized)
                    .accessibilityAddTraits(option == stamp ? .isSelected : [])
                }
            }
            Text(stamp == .amber ? "amber, the one most people keep" : stamp.rawValue)
                .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
                .foregroundStyle(palette.ink3)
                .padding(.top, 10)
            Spacer(minLength: 20)
            Button { Haptics.tap(); done() } label: {
                Text("Keep \(stamp.rawValue)")
                    .font(V2Type.control(.subheadline))
                    .foregroundStyle(palette.background)
                    .frame(maxWidth: 360, minHeight: 48)
                    .background(palette.ink, in: RoundedRectangle(cornerRadius: V2Metrics.radius))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, V2Metrics.margin)
            Text("change it any time")
                .font(.system(.caption))
                .foregroundStyle(palette.ink2)
                .padding(.top, 8)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { V2Desktop(palette: palette) }
        .foregroundStyle(palette.ink)
    }
}
