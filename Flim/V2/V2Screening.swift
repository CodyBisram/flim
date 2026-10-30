import SwiftUI

/// One print in a screening.
struct V2ScreeningPrint: Identifiable, Equatable {
    let id: UUID
    let path: String
    let takenAt: Date
    var who: String?
    var caption: String?
    /// "❤️ 4": the print's most-used reaction and how many, for the foot and the closing facts.
    var reaction: (emoji: String, count: Int)?

    static func == (a: V2ScreeningPrint, b: V2ScreeningPrint) -> Bool { a.id == b.id }
}

/// What a screening plays: a roll opening, or a month on your page (handoff 2, "Ceremony": the
/// roll opening and the month playing are the same thing, always on Slate).
enum V2ScreeningSource {
    case roll(Roll)
    case month(profileId: UUID, chapter: ChapterSummary)
}

/// The screening (board 9a, 15f; prototype): the lid comes off, each print is dealt, turned and
/// developed, then the box closes on its cover with a sentence and a fact or two. Tap to hurry,
/// hold to linger. Always on Slate.
///
/// A roll plays the App Store reveal's own deck (`RollRevealViewModel`: dead frames left out,
/// bursts as one), records that it opened, and counts as watched only when it reaches the end,
/// exactly as the reveal does.
struct V2ScreeningView: View {
    let source: V2ScreeningSource
    var close: () -> Void
    /// The closing card's way on, beside Play again: for a roll, its prints in full.
    var seeAll: (() -> Void)?
    /// A roll's next one, for everyone in it ("Start another with these six").
    var startAnother: (() -> Void)?

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AuthService.self) private var auth
    @Environment(PhotoService.self) private var photos
    @Environment(RollService.self) private var rolls
    @Environment(ChapterService.self) private var chapters
    @Environment(TabSignals.self) private var signals

    private enum Phase { case loading, lid, deal, close, empty }

    @State private var phase: Phase = .loading
    @State private var prints: [V2ScreeningPrint] = []
    @State private var index = 0
    @State private var dealt = false
    @State private var turned = false
    @State private var develop: Double = 0
    @State private var lidOff = false
    @State private var lingering = false
    /// The print a tap hurried (-1 for the lid): its waits end at once and the loop moves on.
    @State private var hurried: Int?
    @State private var run = 0
    @State private var reveal: RollRevealViewModel?
    @State private var people = 1

    private let palette = V2Palette.slate

    var body: some View {
        GeometryReader { proxy in
            let width = min(340, V2PrintGeometry.width(fitting: CGSize(width: proxy.size.width - 62,
                                                                       height: proxy.size.height - 260)))
            ZStack {
                V2Desktop(palette: palette)
                VStack(spacing: 0) {
                    header
                        .padding(.horizontal, V2Metrics.margin)
                    switch phase {
                    case .loading:
                        Spacer()
                        ProgressView().tint(palette.ink2)
                        Spacer()
                    case .empty:
                        Spacer()
                        Text("Nothing in this box.")
                            .font(V2Type.serif(17, italic: true, relativeTo: .body))
                            .foregroundStyle(palette.ink2)
                        Spacer()
                    case .lid:
                        lid
                    case .deal:
                        deal(width: width)
                    case .close:
                        closing
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .environment(\.v2Palette, palette)
            .foregroundStyle(palette.ink)
            .contentShape(Rectangle())
            // Tap to hurry, hold to linger (prototype).
            .onTapGesture { hurry() }
            .onLongPressGesture(minimumDuration: 0.25, perform: {}, onPressingChanged: { lingering = $0 })
        }
        .toolbar(.hidden, for: .navigationBar)
        .task(id: run) { await play() }
    }

    // MARK: Header

    private var title: String {
        switch source {
        case .roll(let roll): roll.name
        case .month(_, let chapter): chapter.monthStart.formatted(.dateTime.month(.wide))
        }
    }

    private var header: some View {
        HStack {
            Button(action: close) {
                Text("Close").font(V2Type.control()).foregroundStyle(palette.ink2).frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .frame(width: 70, alignment: .leading)
            Spacer(minLength: 8)
            Text(title).font(V2Type.serif(15, relativeTo: .subheadline)).lineLimit(1)
            Spacer(minLength: 8)
            Group {
                if phase == .deal {
                    Text("\(index + 1) / \(prints.count)")
                        .font(V2Type.data(11))
                        .tracking(1.5)
                        .foregroundStyle(palette.ink3)
                } else {
                    Color.clear.frame(height: 1)
                }
            }
            .frame(width: 70, alignment: .trailing)
        }
    }

    // MARK: Lid

    private var lid: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack(alignment: .top) {
                Rectangle().fill(V2Color.box)
                    .shadow(color: palette.shadowFar.color, radius: palette.shadowFar.radius, y: palette.shadowFar.y)
                Text(lidLine)
                    .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
                    .foregroundStyle(V2Color.printInk2)
                    .frame(maxHeight: .infinity)
                Rectangle().fill(V2Color.boxLid)
                    .frame(height: 78)
                    .overlay(alignment: .leading) {
                        Text(title.uppercased())
                            .font(V2Type.data(10))
                            .tracking(1.4)
                            .foregroundStyle(V2Color.rgb(0x8F5F22))
                            .padding(.leading, 18)
                    }
                    .offset(x: lidOff ? -30 : 0, y: lidOff ? -150 : 0)
                    .rotationEffect(.degrees(lidOff ? -10 : 0))
                    .opacity(lidOff ? 0 : 1)
            }
            .frame(width: 260, height: 300)
            Spacer()
            VStack(spacing: 4) {
                Text("The lid comes off.")
                    .font(V2Type.serif(15, italic: true, relativeTo: .body))
                    .foregroundStyle(palette.ink2)
                Text("tap to hurry · hold to linger")
                    .font(V2Type.serif(13, italic: true, relativeTo: .footnote))
                    .foregroundStyle(palette.ink3)
            }
            .padding(.bottom, 40)
        }
        .accessibilityElement(children: .combine)
    }

    private var lidLine: String {
        let n = prints.count
        switch source {
        case .roll: return "\(n) \(n == 1 ? "print" : "prints") · \(Self.number(people)) of you"
        case .month: return "\(n) \(n == 1 ? "print" : "prints") · \(days) \(days == 1 ? "day" : "days")"
        }
    }

    // MARK: Deal

    private func deal(width: CGFloat) -> some View {
        let current = prints[min(index, prints.count - 1)]
        return VStack(spacing: 0) {
            segments
                .padding(.horizontal, V2Metrics.margin)
                .padding(.top, 8)
            Text(line(for: current))
                .font(V2Type.serif(17, italic: true, relativeTo: .body))
                .foregroundStyle(palette.ink2)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, V2Metrics.margin)
                .padding(.top, 26)
                .frame(minHeight: 70, alignment: .top)
            Spacer(minLength: 8)
            ZStack(alignment: .bottomTrailing) {
                dealtPrint(current, width: width)
                    .frame(maxWidth: .infinity)
                if index > 0 { pile(width: width) }
            }
            Spacer(minLength: 30)
        }
    }

    /// One mark per print, filled as they are seen; past forty, one bar that fills.
    @ViewBuilder
    private var segments: some View {
        if prints.count <= 40 {
            HStack(spacing: 3) {
                ForEach(prints.indices, id: \.self) { i in
                    Rectangle()
                        .fill(i <= index ? palette.ink : palette.tick)
                        .frame(height: 1.5)
                }
            }
            .accessibilityHidden(true)
        } else {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(palette.tick)
                    Rectangle().fill(palette.ink)
                        .frame(width: proxy.size.width * CGFloat(index + 1) / CGFloat(max(prints.count, 1)))
                }
            }
            .frame(height: 1.5)
            .accessibilityHidden(true)
        }
    }

    /// Dealt up from below, turned over, developed (prototype `flimDeal`). Reduce Motion: no deal,
    /// the turn a crossfade, the develop quick.
    private func dealtPrint(_ print: V2ScreeningPrint, width: CGFloat) -> some View {
        ZStack {
            // The back, until the print turns.
            Rectangle().fill(V2Color.printBack)
                .frame(width: width, height: V2PrintGeometry.height(width: width))
                .opacity(turned ? 0 : 1)
            V2PrintCard(width: width) {
                V2Image(path: print.path, maxPixel: width * 1.4)
                    .saturation(develop)
                    .brightness((1 - develop) * 0.45)
                    .contrast(0.2 + 0.8 * develop)
                    .opacity(0.15 + 0.85 * develop)
                    .overlay(alignment: .bottomTrailing) {
                        V2DateStamp(text: BrandedExport.dateText(.init(date: print.takenAt)),
                                    cellHeight: width * 0.04, stamp: .amber)
                            .padding(.trailing, width * 0.04)
                            .padding(.bottom, width * 0.03)
                            .opacity(develop)
                    }
            } foot: {
                HStack {
                    Text(print.who ?? print.caption ?? "")
                        .font(V2Type.serif(17 * width / 340, italic: true, relativeTo: .body))
                        .foregroundStyle(V2Color.printInk)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let reaction = print.reaction {
                        Text("\(reaction.emoji) \(reaction.count)")
                            .font(.system(size: 13))
                            .foregroundStyle(V2Color.printInk2)
                    }
                }
                .padding(.horizontal, 4)
            }
            .opacity(turned ? 1 : 0)
        }
        .shadow(color: palette.shadowNear.color, radius: palette.shadowNear.radius, y: palette.shadowNear.y)
        .shadow(color: palette.shadowFar.color, radius: palette.shadowFar.radius, y: palette.shadowFar.y)
        .rotation3DEffect(.degrees(reduceMotion ? 0 : (turned ? 0 : 90)), axis: (x: 0, y: 1, z: 0))
        .rotationEffect(.degrees(reduceMotion ? 0 : -1.5))
        .offset(y: dealt || reduceMotion ? 0 : 560)
        .id(print.id)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line(for: print))
    }

    /// The prints already seen, face up in a small pile at the bottom right.
    private func pile(width: CGFloat) -> some View {
        let last = prints[index - 1]
        return VStack(spacing: 8) {
            ZStack {
                Rectangle().fill(V2Color.print).frame(width: 120, height: 160)
                    .rotationEffect(.degrees(-5)).offset(x: 4, y: 6)
                V2PrintCard(width: 120, borderFraction: 6.0 / 120, footFraction: 24.0 / 120) {
                    V2Image(path: last.path, maxPixel: 260)
                } foot: { Color.clear }
                .rotationEffect(.degrees(-1))
            }
            .shadow(color: .black.opacity(0.4), radius: 3, y: 2)
            Text("\(index) SEEN")
                .font(V2Type.data(9))
                .tracking(1.3)
                .foregroundStyle(palette.ink3)
        }
        .scaleEffect(0.62, anchor: .bottomTrailing)
        .padding(.trailing, V2Metrics.margin)
        .offset(y: 40)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func line(for print: V2ScreeningPrint) -> String {
        let day = print.takenAt.formatted(.dateTime.weekday(.wide))
        guard let caption = print.caption?.trimmingCharacters(in: .whitespacesAndNewlines), !caption.isEmpty else {
            return "\(day)."
        }
        let sentence = caption.prefix(1).uppercased() + caption.dropFirst()
        return sentence.hasSuffix(".") ? "\(day). \(sentence)" : "\(day). \(sentence)."
    }

    // MARK: Close

    private var closing: some View {
        let cover = prints.max { ($0.reaction?.count ?? 0) < ($1.reaction?.count ?? 0) } ?? prints.first
        return VStack(spacing: 0) {
            ZStack(alignment: .top) {
                Rectangle().fill(V2Color.box)
                    .shadow(color: palette.shadowNear.color, radius: palette.shadowNear.radius, y: palette.shadowNear.y)
                    .shadow(color: palette.shadowFar.color, radius: palette.shadowFar.radius, y: palette.shadowFar.y)
                Rectangle().fill(V2Color.boxLid).frame(height: 78)
                HStack {
                    Text("\(title.uppercased()) · \(prints.count)").foregroundStyle(V2Color.rgb(0x8F5F22))
                    Spacer(minLength: 6)
                    Text(boxRight).foregroundStyle(V2Color.printInk3)
                }
                .font(V2Type.data(10))
                .tracking(1.4)
                .lineLimit(1)
                .padding(18)
                if let cover {
                    V2PrintCard(width: 140, borderFraction: 8.0 / 140, footFraction: 26.0 / 140) {
                        V2Image(path: cover.path, maxPixel: 300)
                    } foot: {
                        Text(cover.who.map { "\($0)'s, \(cover.takenAt.formatted(.dateTime.weekday(.wide)))" } ?? (cover.caption ?? title))
                            .font(V2Type.serif(10, italic: true, relativeTo: .caption2))
                            .foregroundStyle(V2Color.printInk2)
                            .lineLimit(1)
                    }
                    .rotationEffect(.degrees(-2))
                    .padding(.top, 40)
                    .transition(.asymmetric(insertion: .offset(y: -140).combined(with: .opacity), removal: .opacity))
                }
            }
            .frame(width: 260, height: 330)
            .padding(.top, 20)
            Text(sentences)
                .font(V2Type.serif(17, italic: true, relativeTo: .body))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, V2Metrics.margin)
                .padding(.top, 30)
            VStack(spacing: 12) {
                ForEach(facts, id: \.0) { fact in
                    HStack(alignment: .firstTextBaseline) {
                        Text(fact.0).foregroundStyle(palette.ink2)
                        Spacer(minLength: 12)
                        Text(fact.1).multilineTextAlignment(.trailing)
                    }
                    .font(.system(.footnote))
                    .padding(.bottom, 10)
                    .overlay(alignment: .bottom) { Rectangle().fill(palette.rule).frame(height: 1) }
                }
            }
            .padding(.horizontal, V2Metrics.margin)
            .padding(.top, 24)
            if case .roll = source, let startAnother, people > 1 {
                Button(action: startAnother) {
                    Text("Start another with these \(Self.number(people))")
                        .font(V2Type.control())
                        .underline()
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .padding(.top, 14)
            }
            Spacer(minLength: 12)
            HStack {
                Button { replay() } label: {
                    Text("Play again").font(V2Type.control()).foregroundStyle(palette.ink2).frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                Spacer()
                Button {
                    if let seeAll { seeAll() } else { close() }
                } label: {
                    Text(nextLabel).font(V2Type.control()).underline().frame(minHeight: 44)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, V2Metrics.margin)
            .padding(.bottom, 16)
        }
    }

    private var boxRight: String {
        switch source {
        case .roll(let roll): "OPENED \(roll.revealAt.formatted(.dateTime.day().month(.abbreviated)).uppercased())"
        case .month: "\(days) DAYS"
        }
    }

    private var nextLabel: String {
        switch source {
        case .roll: seeAll == nil ? "Back to the shelf" : "See every print"
        case .month: "Back to your page"
        }
    }

    private var days: Int {
        Set(prints.map { Calendar.current.startOfDay(for: $0.takenAt) }).count
    }

    /// "Six of you. 7 prints over five days." / "Nadia shot the most; Gem shot the last."
    private var sentences: String {
        let n = prints.count
        let printsText = "\(n) \(n == 1 ? "print" : "prints") over \(Self.number(days)) \(days == 1 ? "day" : "days")."
        switch source {
        case .roll:
            var text = "\(Self.number(people).capitalized) of you. \(printsText)"
            let counts = Dictionary(grouping: prints.compactMap(\.who), by: { $0 }).mapValues(\.count)
            if n > 1, let most = counts.max(by: { $0.value < $1.value })?.key, let last = prints.last?.who {
                text += "\n\(most.prefix(1).uppercased() + most.dropFirst()) shot the most; \(last) shot the last."
            }
            return text
        case .month:
            return "\(title). \(printsText)"
        }
    }

    private var facts: [(String, String)] {
        var rows: [(String, String)] = []
        if let top = prints.filter({ $0.reaction != nil }).max(by: { $0.reaction!.count < $1.reaction!.count }),
           let reaction = top.reaction {
            let whose = top.who.map { "\($0)'s, " } ?? ""
            rows.append(("Most passed around",
                         "\(whose)\(top.takenAt.formatted(.dateTime.weekday(.wide))) · \(reaction.emoji) \(reaction.count)"))
        }
        if case .month = source {
            let byDay = Dictionary(grouping: prints) { Calendar.current.startOfDay(for: $0.takenAt) }
            if let busiest = byDay.max(by: { $0.value.count < $1.value.count }), busiest.value.count > 1 {
                rows.append(("Busiest day", "\(busiest.key.formatted(.dateTime.weekday(.wide).day())) · \(busiest.value.count) prints"))
            }
        }
        return rows
    }

    static func number(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        return n <= 12 ? (formatter.string(from: NSNumber(value: n)) ?? "\(n)") : "\(n)"
    }

    // MARK: Playing

    private func play() async {
        if prints.isEmpty {
            await load()
        }
        guard !prints.isEmpty else { phase = .empty; return }
        hurried = nil
        index = 0
        lidOff = false
        phase = .lid
        try? await Task.sleep(for: .milliseconds(300))
        withAnimation(.easeIn(duration: reduceMotion ? 0.3 : 1.2)) { lidOff = true }
        guard await wait(reduceMotion ? 0.3 : 1.2) else { return }
        phase = .deal
        while index < prints.count {
            await showPrint()
            guard await wait(1.0) else { return }   // rest
            if index == prints.count - 1 { break }
            index += 1
        }
        finish()
    }

    /// Deal 0.3, turn 0.4, develop 1.8 (handoff 2).
    private func showPrint() async {
        dealt = false
        turned = false
        develop = 0
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { dealt = true }
        _ = await wait(0.3)
        withAnimation(.easeInOut(duration: reduceMotion ? 0.2 : V2Motion.turnSeconds)) { turned = true }
        _ = await wait(reduceMotion ? 0.2 : V2Motion.turnSeconds)
        let seconds = reduceMotion ? V2Motion.developSecondsReduced : V2Motion.developSeconds
        withAnimation(.easeOut(duration: seconds)) { develop = 1 }
        _ = await wait(seconds)
    }

    /// Waits, holding while a finger lingers; false when the screening was closed or replayed.
    private func wait(_ seconds: Double) async -> Bool {
        var left = seconds
        while left > 0 {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return false }
            if phase == .lid, hurried == -1 { return true }
            if phase == .deal, hurried == index { return true }
            if !lingering { left -= 0.1 }
        }
        return true
    }

    /// Tap to hurry: the lid comes off now, or the print on screen finishes and the next comes.
    private func hurry() {
        switch phase {
        case .lid:
            hurried = -1
            withAnimation(.easeIn(duration: 0.2)) { lidOff = true }
        case .deal:
            Haptics.tap()
            hurried = index
            withAnimation(.easeOut(duration: 0.15)) {
                dealt = true
                turned = true
                develop = 1
            }
        default: break
        }
    }

    private func replay() {
        Haptics.tap()
        run += 1
    }

    /// The end, and only the end, counts as watched (as `RollRevealViewModel.finish`).
    private func finish() {
        guard phase != .close else { return }
        withAnimation(V2Motion.setDown) { phase = .close }
        guard case .roll(let roll) = source else { return }
        reveal?.finish()
        UserDefaults.standard.set(true, forKey: "rollRevealSeen.\(roll.id.uuidString)")
        signals.rollsHaveUnwatched = TabSignals.rollsDot(rolls: rolls.rolls, revealSeen: {
            UserDefaults.standard.bool(forKey: "rollRevealSeen.\($0.uuidString)")
        })
        WidgetSync.refresh()
    }

    // MARK: Loading

    private func load() async {
        switch source {
        case .roll(let roll):
            let model = reveal ?? RollRevealViewModel(rollId: roll.id, photos: [])
            reveal = model
            await model.loadDeckOnce(photoService: photos, auth: auth, rollService: rolls)
            let members = (try? await rolls.fetchMembers(for: roll.id)) ?? []
            let names = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0.id == auth.currentUser?.id ? "you" : ($0.username ?? "someone")) })
            people = max(1, members.count)
            prints = model.playedDeck.map { photo in
                let reactions = model.reactionsByPhoto[photo.id] ?? []
                let top = Dictionary(grouping: reactions, by: \.emoji).max { $0.value.count < $1.value.count }
                return V2ScreeningPrint(id: photo.id, path: photo.viewPath, takenAt: photo.takenAt,
                                        who: names[photo.userId], caption: photo.caption,
                                        reaction: top.map { ($0.key, $0.value.count) })
            }
        case .month(let profileId, let chapter):
            let photos = await chapters.photos(for: profileId, monthStart: chapter.monthStart)
            prints = photos.sorted { $0.takenAt < $1.takenAt }.map {
                V2ScreeningPrint(id: $0.id, path: $0.feedPath ?? $0.storagePath, takenAt: $0.takenAt)
            }
        }
        #if DEBUG
        if prints.isEmpty, ProcessInfo.processInfo.arguments.contains("-v2DemoScreening") {
            let names = ["nadia", "gem", "you", "rafi", "nadia", "dev.k"]
            var demo: [V2ScreeningPrint] = []
            for n in 1...6 {
                let path = "demo/p" + String(format: "%02d", n) + ".jpg"
                let taken = Date.now.addingTimeInterval(Double(n - 7) * 30_000)
                var print = V2ScreeningPrint(id: UUID(), path: path, takenAt: taken, who: names[n - 1])
                if n == 1 {
                    print.caption = "she waited all afternoon"
                    print.reaction = (emoji: "❤️", count: 4)
                }
                demo.append(print)
            }
            prints = demo
            people = 4
        }
        #endif
    }
}
