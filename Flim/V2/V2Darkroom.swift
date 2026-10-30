import SwiftUI

/// The Darkroom: what developed and waits to be sorted, as a stack of prints, and the last few
/// you kept (prototype, board 15d's right half). Tapping the stack opens the sort deck.
///
/// "Kept" opens the App Store app's Darkroom for now.
struct V2DarkroomPlace: View {
    /// Signals from routes that open the sort deck (a push, the camera's old "to sort"), as the
    /// App Store Darkroom takes them.
    var openSortDeckSignal: Int = 0
    var goToCamera: () -> Void
    var openRolls: () -> Void

    @Environment(\.v2LayoutMode) private var mode
    @Environment(\.v2Palette) private var palette
    @Environment(AuthService.self) private var auth
    @Environment(PhotoService.self) private var photos
    @Environment(RollService.self) private var rolls
    @Environment(\.scenePhase) private var scenePhase

    @State private var unsorted: [Photo]?
    @State private var kept: [Photo] = []
    @State private var keptCount: Int?
    @State private var showSortDeck = false
    @State private var showKept = false
    @State private var pagerStart: Int?

    var body: some View {
        GeometryReader { proxy in
            if showSortDeck, mode == .inner {
                // Open, the deck takes the Darkroom's half only, so the camera stays live beside
                // it (board 15d).
                V2SortDeck { closeSortDeck() }
                    .transition(.opacity)
            } else {
                ScrollView {
                    content(width: proxy.size.width, height: proxy.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
                .refreshable { await reload() }
            }
        }
        .task(id: auth.currentUser?.id) { await reload() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await reload() } }
        }
        .onChange(of: photos.pendingCaptureCount) { old, new in
            // A shot finished uploading: it is in the stack now.
            if new < old { Task { await reload() } }
        }
        .onChange(of: openSortDeckSignal) { _, _ in showSortDeck = true }
        #if DEBUG
        // `-v2OpenSort`: opens the sort deck at launch, for screenshots.
        .task {
            guard ProcessInfo.processInfo.arguments.contains("-v2OpenSort") else { return }
            try? await Task.sleep(for: .seconds(1.5))
            showSortDeck = true
        }
        #endif
        .fullScreenCover(isPresented: Binding(get: { showSortDeck && mode != .inner },
                                              set: { if !$0 { showSortDeck = false } })) {
            V2SortDeck { closeSortDeck() }
                .environment(\.v2Palette, palette)
                #if DEBUG
                .modifier(V2DemoFrame())
                #endif
        }
        .fullScreenCover(item: Binding(get: { pagerStart.map(PagerStart.init) },
                                       set: { pagerStart = $0?.index })) { start in
            PhotoPagerView(photos: kept, startIndex: start.index, signedURLs: [:])
        }
        .navigationDestination(isPresented: $showKept) {
            DarkroomView()
        }
        .toolbar(.hidden, for: .navigationBar)
        // The desk shows through the stack, which otherwise paints its own background over it.
        .containerBackground(.clear, for: .navigation)
    }

    private func closeSortDeck() {
        withAnimation(V2Motion.slide) { showSortDeck = false }
        Task { await reload() }
    }

    private struct PagerStart: Identifiable {
        let index: Int
        var id: Int { index }
    }

    private func content(width: CGFloat, height: CGFloat) -> some View {
        let margin = mode == .phone ? V2Metrics.margin : 20
        let stackWidth = min(V2DarkroomMetrics.maxStackWidth,
                             V2PrintGeometry.width(fitting: CGSize(width: width - V2CameraMetrics.printInset * 2,
                                                                  height: height - V2DarkroomMetrics.chrome)))
        return VStack(alignment: .leading, spacing: 0) {
            V2PageTitle(title: "Darkroom", subtitle: subtitle)
                .padding(.horizontal, margin)
            .padding(.top, 8)

            Group {
                if let unsorted, !unsorted.isEmpty {
                    stack(unsorted, width: stackWidth)
                } else if unsorted != nil, (keptCount ?? 0) == 0 {
                    dayOne(width: stackWidth)
                } else if unsorted != nil {
                    allSorted(width: stackWidth)
                } else {
                    Color.clear.frame(width: stackWidth, height: stackWidth * V2PrintGeometry.height(width: 1))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 22)

            keptRow(margin: margin)
                .padding(.top, 22)
                .padding(.bottom, 24)
        }
    }

    // MARK: The stack

    private func stack(_ unsorted: [Photo], width: CGFloat) -> some View {
        let top = unsorted.first
        return Button { showSortDeck = true } label: {
            ZStack {
                // Two loose prints under the top one (prototype: 4 and -3 degrees).
                blank(width: width).rotationEffect(.degrees(4)).offset(x: 6, y: 2)
                blank(width: width).rotationEffect(.degrees(-3)).offset(x: -4, y: 4)
                V2PrintCard(width: width) {
                    V2Image(path: top?.feedPath ?? top?.storagePath, maxPixel: width * 1.2)
                        // Faded under the label, so it reads as waiting, not posted.
                        .saturation(0.35)
                        .brightness(-0.12)
                        .overlay(V2Color.rgb(0x704214, opacity: 0.18))
                        .overlay {
                            Text("\(unsorted.count) waiting to be sorted")
                                .font(V2Type.serif(18, italic: true, relativeTo: .title3))
                                .foregroundStyle(V2Color.print)
                                .multilineTextAlignment(.center)
                                .shadow(color: .black.opacity(0.6), radius: 4, y: 1)
                                .padding(.horizontal, 40)
                        }
                } foot: {
                    HStack {
                        Text("Sort them")
                            .font(V2Type.control())
                            .foregroundStyle(V2Color.printInk)
                        Spacer()
                        if let top {
                            Text("from \(V2When.relativeDay(top.takenAt))")
                                .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
                                .foregroundStyle(V2Color.printInk3)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(unsorted.count) waiting to be sorted")
        .accessibilityHint("Opens the sort deck")
        .accessibilityAddTraits(.isButton)
    }

    private func blank(width: CGFloat) -> some View {
        Rectangle()
            .fill(V2Color.print)
            .frame(width: width, height: V2PrintGeometry.height(width: width))
            .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
    }

    // MARK: Empty

    /// Day one: nothing shot yet (prototype "Day one").
    private func dayOne(width: CGFloat) -> some View {
        dashed(width: width) {
            VStack(spacing: 18) {
                ZStack {
                    Rectangle().fill(V2Color.print).frame(width: 96, height: 128)
                        .shadow(color: V2Color.rgb(0x2A2420, opacity: 0.14), radius: 3, y: 2)
                        .rotationEffect(.degrees(-6))
                    V2PrintCard(width: 96, showsShadow: false) {
                        V2Color.box
                    } foot: { Color.clear }
                    .shadow(color: V2Color.rgb(0x2A2420, opacity: 0.14), radius: 3, y: 2)
                    .rotationEffect(.degrees(4))
                }
                .accessibilityHidden(true)
                Text("Nothing developing yet.")
                    .font(V2Type.serif(22, relativeTo: .title2))
                    .foregroundStyle(palette.ink)
                Text("Shoot from the camera next door. Prints come here first, and nobody sees them until you post.")
                    .font(V2Type.serif(14, italic: true, relativeTo: .callout))
                    .foregroundStyle(palette.ink2)
                Button(action: goToCamera) {
                    Text("Go to the camera")
                        .font(V2Type.control(.subheadline))
                        .foregroundStyle(palette.ink)
                        .underline()
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 36)
        }
    }

    private func allSorted(width: CGFloat) -> some View {
        dashed(width: width) {
            Text("All sorted. New prints develop here after you shoot.")
                .font(V2Type.serif(17, italic: true, relativeTo: .body))
                .foregroundStyle(palette.ink2)
                .multilineTextAlignment(.center)
                .padding(40)
        }
    }

    private func dashed(width: CGFloat, @ViewBuilder content: () -> some View) -> some View {
        content()
            .frame(width: width, height: V2PrintGeometry.height(width: width))
            .overlay {
                Rectangle()
                    .strokeBorder(palette.ink3, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
    }

    // MARK: Kept

    private func keptRow(margin: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Button { showKept = true } label: {
                    Text(keptCount.map { "Kept · \($0)" } ?? "Kept")
                        .font(V2Type.control())
                        .foregroundStyle(palette.ink2)
                        .frame(minHeight: 32)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 8)
                Button(action: openRolls) {
                    Text(rollsLine)
                        .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
                        .foregroundStyle(palette.ink3)
                        .lineLimit(1)
                        .frame(minHeight: 32)
                }
                .buttonStyle(.plain)
            }
            if !kept.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Array(kept.enumerated()), id: \.element.id) { index, photo in
                            Button { pagerStart = index } label: {
                                V2PrintCard(width: 52, borderFraction: 4.0 / 52, footFraction: 8.0 / 52) {
                                    V2Image(path: photo.thumbPath ?? photo.storagePath, maxPixel: 120)
                                } foot: { Color.clear }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Kept print from \(photo.takenAt.formatted(date: .abbreviated, time: .omitted))")
                        }
                    }
                    .padding(.horizontal, margin)
                    .padding(.vertical, 6)
                }
                .scrollIndicators(.hidden)
                .padding(.horizontal, -margin)
            }
        }
        .padding(.horizontal, margin)
    }

    /// "Rolls · Bali week, 2h left" for the next sealed roll, or just "Rolls" (prototype).
    private var rollsLine: String {
        let sealed = rolls.rolls.filter { !$0.isDeveloped }.min { $0.revealAt < $1.revealAt }
        guard let sealed else { return "Rolls" }
        return "Rolls · \(sealed.name), \(V2When.left(until: sealed.revealAt))"
    }

    private var subtitle: String {
        guard let unsorted else { return "" }
        return unsorted.isEmpty ? "quiet" : "developed \(V2When.relativeDay(unsorted.last?.takenAt ?? .now))"
    }

    private func reload() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-v2DemoDarkroom") {
            let fixture = V2DarkroomFixture.make()
            unsorted = fixture.unsorted
            kept = fixture.kept
            keptCount = 36
            return
        }
        #endif
        guard let uid = auth.currentUser?.id else { return }
        let epoch = AccountEpoch.current
        async let unsortedRead = photos.fetchUnsorted(userId: uid)
        async let keptRead = try? photos.fetchDarkroomPage(userId: uid, limit: 12, before: nil)
        async let countRead = photos.personalPhotoCount(userId: uid)
        let (u, k, c) = await (unsortedRead, keptRead, countRead)
        guard AccountEpoch.isCurrent(epoch) else { return }
        // A dropped read keeps what is on screen (the services' nil-on-failure contract).
        if let u { withAnimation(V2Motion.setDown) { unsorted = u } }
        if let k { kept = k.photos }
        if let c { keptCount = c }
    }
}

#if DEBUG
/// `-v2DemoDarkroom`: four prints waiting and six kept, on the demo images the feed fixtures use
/// (`demo/pNN.jpg`, planted in the disk cache before launch), for checking the place without an
/// account.
enum V2DarkroomFixture {
    static func make(now: Date = .now) -> (unsorted: [Photo], kept: [Photo]) {
        let owner = UUID()
        func photo(_ n: Int, hoursAgo: Double, sorted: Bool) -> Photo {
            let path = "demo/p\(String(format: "%02d", n)).jpg"
            return Photo(id: UUID(), userId: owner, rollId: nil, storagePath: path, thumbPath: path,
                         feedPath: path, takenAt: now.addingTimeInterval(-hoursAgo * 3_600),
                         developsAt: .distantPast, isDeveloped: true, caption: nil, isSorted: sorted)
        }
        return ((1...4).map { photo($0, hoursAgo: Double(5 - $0) * 0.2, sorted: false) },
                (5...10).map { photo($0, hoursAgo: Double($0) * 20, sorted: true) })
    }
}
#endif

/// A place's title in the serif at 28 with its italic line: beside it on the phone and the open
/// display, under it in the closed display's narrower place (prototype; board 15).
struct V2PageTitle: View {
    let title: String
    let subtitle: String

    @Environment(\.v2LayoutMode) private var mode
    @Environment(\.v2Palette) private var palette

    var body: some View {
        let layout = mode == .outer
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        layout {
            Text(title)
                .font(V2Type.serif(28, relativeTo: .largeTitle))
                .foregroundStyle(palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityAddTraits(.isHeader)
            if mode != .outer { Spacer(minLength: 8) }
            Text(subtitle)
                .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
                .foregroundStyle(palette.ink2)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

enum V2DarkroomMetrics {
    static let maxStackWidth: CGFloat = 340
    /// Everything on the page but the stack: title, the kept row and their gaps.
    static let chrome: CGFloat = 230
}

/// A photograph from storage, signed and cached the same way as everywhere else in the app
/// (`CachedImage`, keyed on the storage path so a fresh token never refetches it). It develops
/// the first time it is seen (`V2Develop`).
struct V2Image: View {
    let path: String?
    var maxPixel: CGFloat = 800

    @Environment(FeedService.self) private var feed
    @State private var url: URL?

    var body: some View {
        Color(white: 0.07)
            .overlay {
                if let path {
                    CachedImage(url: url, maxPixel: maxPixel, cacheKey: path) {
                        $0.resizable().scaledToFill().modifier(V2Develop(key: path))
                    } placeholder: {
                        Color(white: 0.07)
                    }
                }
            }
            .clipped()
            .task(id: path) {
                guard let path else { return }
                url = await feed.signedURL(for: path)
            }
    }
}

/// Day and time words for prints: "tonight", "today", "yesterday", "Tuesday".
enum V2When {
    static func relativeDay(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return calendar.component(.hour, from: date) >= 17 ? "tonight" : "today"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday"
        }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                              to: calendar.startOfDay(for: now)).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.month(.wide).day())
    }

    /// "2h left", "40m left", "3d left" (prototype's roll line).
    static func left(until date: Date, now: Date = .now) -> String {
        let seconds = max(0, date.timeIntervalSince(now))
        if seconds >= 86_400 { return "\(Int(seconds / 86_400))d left" }
        if seconds >= 3_600 { return "\(Int(seconds / 3_600))h left" }
        return "\(max(1, Int(seconds / 60)))m left"
    }
}
