import SwiftUI

/// The rolls shelf (board 4a, 16-1a, 16-1b; prototype): rolls still developing stand as sealed
/// boxes with their clocks, opened ones as their prints. A sealed roll opens to its box; an opened
/// one to the App Store app's roll screen until the screening lands. Open, the shelf narrows to
/// the left and the chosen roll fills the right.
///
/// It declares the roll destination itself (`Roll`), so a route that pushes a roll onto the
/// Rolls path lands on the right screen, sealed or opened, as it does in the App Store app.
struct V2RollsView: View {
    var pendingPhotoIntent: Binding<RollPhotoIntent?> = .constant(nil)
    var push: (Roll) -> Void
    var close: () -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.v2Palette) private var palette
    @Environment(AuthService.self) private var auth
    @Environment(RollService.self) private var rolls
    @Environment(PhotoService.self) private var photos

    @State private var shots: [UUID: Int] = [:]
    @State private var showNewRoll = false
    /// Open, the roll beside the shelf.
    @State private var selected: Roll?

    private var sealed: [Roll] {
        rolls.rolls.filter { !$0.isDeveloped }.sorted { $0.revealAt < $1.revealAt }
    }
    private var opened: [Roll] {
        rolls.rolls.filter(\.isDeveloped).sorted { $0.revealAt > $1.revealAt }
    }

    var body: some View {
        GeometryReader { proxy in
            let mode = V2LayoutMode.resolve(horizontalSizeClass: sizeClass, size: proxy.size)
            Group {
                switch mode {
                case .phone: phone
                case .outer: outer
                case .inner: inner(proxy.size)
                }
            }
            .environment(\.v2LayoutMode, mode)
        }
        .background { V2Desktop(palette: palette) }
        .foregroundStyle(palette.ink)
        .toolbar(.hidden, for: .navigationBar)
        .containerBackground(.clear, for: .navigation)
        .navigationDestination(for: Roll.self) { roll in
            if roll.isDeveloped {
                RollDetailView(roll: roll, pendingPhotoIntent: pendingPhotoIntent)
            } else {
                V2SealedRollView(roll: roll)
            }
        }
        .fullScreenCover(isPresented: $showNewRoll) {
            V2NewRollView { roll in
                showNewRoll = false
                if let roll { open(roll) }
            }
            .environment(\.v2Palette, palette)
            #if DEBUG
            .modifier(V2DemoFrame())
            #endif
        }
        .task(id: auth.currentUser?.id) { await load() }
        #if DEBUG
        // `-v2OpenNewRoll`: opens New roll at launch, for screenshots.
        .task {
            guard ProcessInfo.processInfo.arguments.contains("-v2OpenNewRoll") else { return }
            try? await Task.sleep(for: .seconds(1))
            showNewRoll = true
        }
        #endif
    }

    // MARK: Arrangements

    private var phone: some View {
        VStack(spacing: 0) {
            HStack {
                backButton
                Spacer(minLength: 8)
                title
                Spacer(minLength: 8)
                newRollButton
            }
            .padding(.horizontal, V2Metrics.margin)
            shelf
            footnote
                .padding(.horizontal, V2Metrics.margin)
                .padding(.bottom, 16)
        }
    }

    /// Closed: the shelf on the left; Back first in the column and New roll at its foot, where
    /// the shutter sits on the camera (16-1a).
    private var outer: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Rolls")
                    .font(V2Type.serif(28, relativeTo: .largeTitle))
                    .padding(.horizontal, V2Metrics.margin)
                    .padding(.top, 12)
                    .accessibilityAddTraits(.isHeader)
                shelf
            }
            VStack(alignment: .trailing) {
                backButton
                Spacer()
                newRollButton
                    .underline()
            }
            .padding(.vertical, 12)
            .padding(.trailing, 14)
            .frame(width: V2RootMetrics.columnWidth, alignment: .trailing)
        }
    }

    /// Open: the shelf narrows to the left and the chosen roll fills the right (16-1b).
    private func inner(_ size: CGSize) -> some View {
        VStack(spacing: 0) {
            HStack {
                backButton
                Spacer(minLength: 8)
                title
                Spacer(minLength: 8)
                newRollButton
            }
            .padding(.horizontal, V2Metrics.margin)
            HStack(spacing: 0) {
                shelf
                    .frame(width: min(360, size.width * 0.36))
                Rectangle().fill(palette.rule).frame(width: 1)
                Group {
                    if let selected, !selected.isDeveloped {
                        V2SealedRollView(roll: selected, embedded: true)
                            .id(selected.id)
                    } else {
                        footnote.padding(V2Metrics.margin)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: sealed.first?.id) {
            if selected == nil { selected = sealed.first }
        }
    }

    private var title: some View {
        Text("Rolls")
            .font(V2Type.serif(15, relativeTo: .subheadline))
            .accessibilityAddTraits(.isHeader)
    }

    private var backButton: some View {
        Button(action: close) {
            Text("Back").font(V2Type.control()).frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var newRollButton: some View {
        Button { showNewRoll = true } label: {
            Text("New roll").font(V2Type.control()).frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footnote: some View {
        Text("A roll is a pack you fill together. It opens for everyone at once.")
            .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
            .foregroundStyle(palette.ink3)
            .multilineTextAlignment(.center)
            .lineSpacing(3)
            .frame(maxWidth: .infinity)
    }

    // MARK: The shelf

    @ViewBuilder
    private var shelf: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if rolls.rolls.isEmpty {
                    empty
                        .padding(.top, 12)
                }
                if !sealed.isEmpty {
                    sectionTitle("Developing")
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(sealed) { roll in
                            Button { open(roll) } label: { row(roll, art: AnyView(V2RollBox(roll: roll, width: 118))) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 14)
                    .padding(.bottom, 34)
                }
                if !opened.isEmpty {
                    sectionTitle("Opened")
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(opened) { roll in
                            Button { open(roll) } label: { row(roll, art: AnyView(prints(roll))) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 14)
                }
            }
            .padding(.horizontal, V2Metrics.margin)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
        .refreshable { await load() }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
            .foregroundStyle(palette.ink2)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ roll: Roll, art: AnyView) -> some View {
        HStack(spacing: 18) {
            art
            VStack(alignment: .leading, spacing: 6) {
                Text(roll.name)
                    .font(V2Type.serif(17, relativeTo: .headline))
                    .lineLimit(2)
                Text(meta(roll))
                    .font(.system(.footnote))
                    .foregroundStyle(palette.ink2)
                Text(roll.isDeveloped ? "opened \(roll.revealAt.formatted(.dateTime.day().month(.abbreviated)))"
                                      : "opens \(V2RollTime.label(roll.revealAt))")
                    .font(V2Type.serif(13, italic: true, relativeTo: .footnote))
                    .foregroundStyle(palette.ink3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .overlay(alignment: .leading) {
            if selected?.id == roll.id, sizeClass == .regular {
                Rectangle().fill(palette.ink).frame(width: 1.5).offset(x: -12)
            }
        }
    }

    /// Two prints, the top one the roll's cover (prototype).
    private func prints(_ roll: Roll) -> some View {
        ZStack {
            Rectangle().fill(V2Color.print)
                .frame(width: 118, height: 150)
                .shadow(color: V2Color.rgb(0x2A2420, opacity: 0.16), radius: 4, y: 2)
                .rotationEffect(.degrees(-3))
            V2PrintCard(width: 118, borderFraction: 8.0 / 118, footFraction: 24.0 / 118) {
                V2Image(path: rolls.coverPaths[roll.id] ?? roll.coverPath, maxPixel: 240)
            } foot: { Color.clear }
            .rotationEffect(.degrees(2))
        }
        .frame(width: 118, height: 158)
        .accessibilityHidden(true)
    }

    private func meta(_ roll: Roll) -> String {
        let people = rolls.memberCounts[roll.id] ?? 1
        let n = shots[roll.id] ?? 0
        let peopleText = people == 1 ? "1 person" : "\(people) people"
        let printsText = n == 1 ? "1 print" : "\(n) prints"
        return "\(peopleText) · \(printsText)\(roll.isDeveloped ? "" : " so far")"
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Text("No rolls yet.")
                .font(V2Type.serif(22, relativeTo: .title2))
            Text("Start one for a trip or a night out. Everyone shoots into it, and it opens for all of you at once.")
                .font(V2Type.serif(14, italic: true, relativeTo: .callout))
                .foregroundStyle(palette.ink2)
            Button { showNewRoll = true } label: {
                Text("Start a roll")
                    .font(V2Type.control(.subheadline))
                    .underline()
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 34)
        .frame(maxWidth: .infinity, minHeight: 360)
        .overlay {
            Rectangle().strokeBorder(palette.ink3, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        }
    }

    // MARK: Actions

    private func open(_ roll: Roll) {
        Haptics.tap()
        if sizeClass == .regular, !roll.isDeveloped {
            withAnimation(V2Motion.slide) { selected = roll }
        } else {
            push(roll)
        }
    }

    private func load() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-v2DemoRolls") {
            V2RollsFixture.seed(into: rolls)
            shots = Dictionary(uniqueKeysWithValues: rolls.rolls.enumerated().map { ($1.id, [7, 5, 4][$0 % 3]) })
            // `-v2OpenSealed`: opens the sealed roll, for screenshots.
            if ProcessInfo.processInfo.arguments.contains("-v2OpenSealed"), let first = sealed.first {
                try? await Task.sleep(for: .seconds(0.8))
                open(first)
            }
            return
        }
        #endif
        guard let uid = auth.currentUser?.id else { return }
        try? await rolls.fetchRolls(for: uid)
        await withTaskGroup(of: (UUID, Int).self) { group in
            for roll in rolls.rolls {
                group.addTask { (roll.id, await photos.rollTotalShotCount(rollId: roll.id)) }
            }
            for await (id, n) in group { shots[id] = n }
        }
    }
}

/// A sealed roll: a box with its lid, the clock to its opening, and its name (prototype). Two
/// sizes: on the shelf (118 wide) and on the roll's own screen (260 wide), each with the
/// prototype's own type sizes rather than one scaled up.
struct V2RollBox: View {
    let roll: Roll
    let width: CGFloat
    var count: String?
    var subtitle: String?

    private var large: Bool { width >= 200 }

    var body: some View {
        let height = width * 150 / 118
        ZStack(alignment: .top) {
            Rectangle().fill(V2Color.box)
                .shadow(color: V2Color.rgb(0x2A2420, opacity: 0.16), radius: 4, y: 2)
            Rectangle().fill(V2Color.boxLid).frame(height: large ? 78 : 36)
            HStack(alignment: .firstTextBaseline) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(V2Clock.until(roll.revealAt, now: context.date))
                        .foregroundStyle(V2Color.rgb(0x8F5F22))
                }
                Spacer(minLength: 6)
                if let count {
                    Text(count).foregroundStyle(V2Color.printInk3)
                }
            }
            .font(V2Type.data(large ? 11 : 10))
            .tracking(large ? 1.5 : 1.4)
            .lineLimit(1)
            .padding(.horizontal, large ? 18 : 10)
            .padding(.top, large ? 18 : 12)
            VStack(spacing: 8) {
                Text(roll.name)
                    .font(V2Type.serif(large ? 26 : 15, relativeTo: .headline))
                    .foregroundStyle(V2Color.printInk)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                if let subtitle {
                    Text(subtitle)
                        .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
                        .foregroundStyle(V2Color.printInk2)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, large ? 12 : 8)
            .frame(maxHeight: .infinity, alignment: large ? .top : .bottom)
            .padding(.top, large ? 124 : 0)
            .padding(.bottom, large ? 0 : 14)
        }
        .frame(width: width, height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(roll.name), opens \(V2RollTime.label(roll.revealAt))")
    }
}

/// A roll that has not opened: its box, who is in and how many prints each, and Shoot into it
/// (prototype "one roll, sealed"). Nobody sees inside until it opens.
struct V2SealedRollView: View {
    let roll: Roll
    /// Beside the shelf on the open display: no header of its own.
    var embedded = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.v2Palette) private var palette
    @Environment(AuthService.self) private var auth
    @Environment(RollService.self) private var rolls
    @Environment(PhotoService.self) private var photos

    @State private var members: [AppUser] = []
    @State private var counts: [UUID: Int] = [:]
    @State private var confirmLeave = false
    @State private var problem: String?

    private var total: Int { counts.values.reduce(0, +) }

    var body: some View {
        VStack(spacing: 0) {
            if !embedded {
                HStack {
                    Button { dismiss() } label: {
                        Text("Rolls").font(V2Type.control()).frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 8)
                    Text(roll.name)
                        .font(V2Type.serif(15, relativeTo: .subheadline))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    invite
                }
                .padding(.horizontal, V2Metrics.margin)
            }
            ScrollView {
                VStack(spacing: 26) {
                    V2RollBox(roll: roll, width: 260, count: "\(total) / ∞",
                              subtitle: "sealed until \(V2RollTime.label(roll.revealAt))")
                        .overlay(alignment: .bottom) {
                            HStack(spacing: 6) {
                                ForEach(members.prefix(8), id: \.id) { member in
                                    AvatarView(path: member.avatarPath, name: member.username, size: 24)
                                }
                            }
                            .padding(.bottom, 28)
                        }
                        .padding(.top, 16)
                    Text("Everyone's prints go in the box. Nobody sees inside until it opens.")
                        .font(V2Type.serif(15, italic: true, relativeTo: .body))
                        .foregroundStyle(palette.ink2)
                        .multilineTextAlignment(.center)
                    VStack(spacing: 12) {
                        ForEach(members, id: \.id) { member in
                            HStack {
                                Text(member.id == auth.currentUser?.id ? "You" : (member.username ?? "someone"))
                                Spacer()
                                let n = counts[member.id] ?? 0
                                Text(n == 0 ? "nothing yet" : (n == 1 ? "1 print" : "\(n) prints"))
                                    .foregroundStyle(palette.ink2)
                            }
                            .font(.system(.footnote))
                            .padding(.bottom, 10)
                            .overlay(alignment: .bottom) { Rectangle().fill(palette.rule).frame(height: 1) }
                        }
                    }
                    if let problem {
                        Text(problem)
                            .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
                            .foregroundStyle(Color.red)
                    }
                }
                .padding(.horizontal, V2Metrics.margin)
            }
            .scrollIndicators(.hidden)
            HStack {
                Button { confirmLeave = true } label: {
                    Text("Leave roll").font(V2Type.control()).foregroundStyle(palette.ink3).frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                if embedded {
                    Spacer()
                    invite
                }
                Spacer()
                Button { shootInto() } label: {
                    Text("Shoot into it").font(V2Type.control()).underline().frame(minHeight: 44)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, V2Metrics.margin)
            .padding(.bottom, 12)
        }
        .background { if !embedded { V2Desktop(palette: palette) } }
        .foregroundStyle(palette.ink)
        .toolbar(.hidden, for: .navigationBar)
        .confirmationDialog("Leave \(roll.name)?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave roll", role: .destructive) { leave() }
        }
        .task { await load() }
    }

    private var invite: some View {
        ShareLink(item: AppInfo.rollInviteMessage(rollName: roll.name, code: roll.inviteCode)) {
            Text("Invite").font(V2Type.control()).foregroundStyle(palette.ink3).frame(minHeight: 44)
        }
    }

    private func shootInto() {
        guard let uid = auth.currentUser?.id else { return }
        Haptics.tap()
        CameraRollSelection.select(roll, for: uid)
        NotificationCenter.default.post(name: .openCamera, object: nil)
    }

    private func leave() {
        guard let uid = auth.currentUser?.id else { return }
        Task {
            do {
                try await rolls.leaveRoll(rollId: roll.id, userId: uid)
                dismiss()
            } catch {
                Haptics.error()
                problem = (error as? LocalizedError)?.errorDescription ?? UserFacingError.genericMessage
            }
        }
    }

    private func load() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-v2DemoRolls") { return }
        #endif
        async let memberRead = try? rolls.fetchMembers(for: roll.id)
        async let photoRead = try? photos.fetchRollPhotosSnapshot(rollId: roll.id)
        let (m, p) = await (memberRead, photoRead)
        if let m { members = m }
        if let p { counts = Dictionary(grouping: p, by: \.userId).mapValues(\.count) }
    }
}

/// New roll, and join by code (prototype; board 12a, 16-1c, 16-1d): name it, choose when it
/// opens, and Start; or type a code. Who is in comes by invite from the roll once it exists.
struct V2NewRollView: View {
    /// The roll made or joined, or nil for Cancel.
    var done: (Roll?) -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.v2Palette) private var palette
    @Environment(AuthService.self) private var auth
    @Environment(RollService.self) private var rolls

    @State private var name = ""
    @State private var opens = V2RollTime.Choice.tomorrow
    @State private var code = ""
    @State private var working = false
    @State private var problem: String?
    @FocusState private var focus: Field?

    private enum Field { case name, code }

    var body: some View {
        GeometryReader { proxy in
            let mode = V2LayoutMode.resolve(horizontalSizeClass: sizeClass, size: proxy.size)
            Group {
                if mode == .inner {
                    VStack(spacing: 0) {
                        header
                        HStack(alignment: .top, spacing: V2Metrics.margin * 2) {
                            ScrollView { form }.frame(maxWidth: .infinity)
                            VStack(spacing: 16) {
                                preview
                                hint
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                } else {
                    VStack(spacing: 0) {
                        header
                        ScrollView {
                            VStack(spacing: 20) {
                                form
                                preview
                                hint
                                codeRow
                            }
                        }
                        .scrollDismissesKeyboard(.interactively)
                    }
                }
            }
            .padding(.horizontal, V2Metrics.margin)
            .environment(\.v2LayoutMode, mode)
        }
        .background { V2Desktop(palette: palette) }
        .foregroundStyle(palette.ink)
    }

    private var header: some View {
        HStack {
            Button { done(nil) } label: {
                Text("Cancel").font(V2Type.control()).foregroundStyle(palette.ink3).frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            Text("New roll").font(V2Type.serif(15, relativeTo: .subheadline))
            Spacer(minLength: 8)
            Button { start() } label: {
                Text("Start")
                    .font(V2Type.control())
                    .foregroundStyle(canStart ? palette.ink : palette.ink3)
                    .underline(canStart)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .disabled(!canStart)
        }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canStart: Bool { !working && !trimmedName.isEmpty }

    @ViewBuilder
    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            label("Name it")
            TextField("", text: $name, prompt: Text("a trip, a night, a birthday")
                .font(V2Type.serif(24, relativeTo: .title))
                .foregroundStyle(palette.ink3))
                .font(V2Type.serif(24, relativeTo: .title))
                .foregroundStyle(palette.ink)
                .focused($focus, equals: .name)
                .submitLabel(.done)
                .frame(minHeight: 46)
                .overlay(alignment: .bottom) { Rectangle().fill(palette.ink).frame(height: 1.5) }
            label("Opens").padding(.top, 26)
            HStack(spacing: 22) {
                ForEach(V2RollTime.Choice.available(), id: \.self) { choice in
                    Button { opens = choice } label: {
                        Text(choice.title)
                            .font(V2Type.control(.subheadline))
                            .foregroundStyle(opens == choice ? palette.ink : palette.ink3)
                            .padding(.bottom, 2)
                            .overlay(alignment: .bottom) {
                                if opens == choice { Rectangle().fill(palette.ink).frame(height: 1.5) }
                            }
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(opens == choice ? .isSelected : [])
                }
            }
            if sizeClass == .regular {
                codeRow.padding(.top, 30)
            }
            if let problem {
                Text(problem)
                    .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
                    .foregroundStyle(Color.red)
                    .padding(.top, 14)
            }
        }
        .padding(.top, 12)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(V2Type.serif(13, italic: true, relativeTo: .footnote))
            .foregroundStyle(palette.ink3)
            .padding(.bottom, 6)
    }

    /// The box the roll will be, updating as you type (16-1d).
    private var preview: some View {
        let date = opens.date()
        return ZStack(alignment: .top) {
            Rectangle().fill(V2Color.box)
                .shadow(color: palette.shadowNear.color, radius: palette.shadowNear.radius, y: palette.shadowNear.y)
                .shadow(color: palette.shadowFar.color, radius: palette.shadowFar.radius, y: palette.shadowFar.y)
            Rectangle().fill(V2Color.boxLid).frame(height: 52)
            HStack {
                Text(V2RollTime.clock(date))
                Spacer()
            }
            .font(V2Type.data(9))
            .tracking(1.3)
            .foregroundStyle(V2Color.rgb(0x8F5F22))
            .padding(12)
            Text(trimmedName.isEmpty ? "Untitled" : trimmedName)
                .font(V2Type.serif(20, relativeTo: .title3))
                .foregroundStyle(V2Color.printInk)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 10)
                .padding(.top, 96)
        }
        .frame(width: 180, height: 220)
        .accessibilityHidden(true)
    }

    private var hint: some View {
        Text("Everyone shoots into it. Nobody sees inside until it opens.")
            .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
            .foregroundStyle(palette.ink2)
            .multilineTextAlignment(.center)
    }

    /// Have a code? Six slots and Join, under a rule (prototype).
    private var codeRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(palette.rule).frame(height: 1)
            label("Have a code?").padding(.top, 10)
            HStack(alignment: .bottom) {
                ZStack(alignment: .leading) {
                    HStack(spacing: 8) {
                        ForEach(0..<6, id: \.self) { index in
                            Rectangle()
                                .fill(index < code.count ? palette.ink : palette.ink3)
                                .frame(width: 34, height: 1.5)
                                .frame(height: 44, alignment: .bottom)
                        }
                    }
                    HStack(spacing: 8) {
                        ForEach(Array(code.enumerated()), id: \.offset) { _, char in
                            Text(String(char)).font(V2Type.data(20)).frame(width: 34, height: 40)
                        }
                    }
                    .allowsHitTesting(false)
                    TextField("", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .foregroundStyle(.clear)
                        .tint(.clear)
                        .focused($focus, equals: .code)
                        .frame(width: 252, height: 44)
                        .onChange(of: code) { _, new in
                            let cleaned = String(new.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(6))
                            if cleaned != new { code = cleaned }
                        }
                        .accessibilityLabel("Roll code")
                }
                Spacer()
                Button { join() } label: {
                    Text("Join")
                        .font(V2Type.control())
                        .foregroundStyle(code.count == 6 && !working ? palette.ink : palette.ink3)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .disabled(code.count != 6 || working)
            }
        }
    }

    // MARK: Actions

    private func start() {
        guard canStart, let uid = auth.currentUser?.id else { return }
        working = true
        problem = nil
        let when = opens.date()
        Task {
            do {
                var roll = try await rolls.createRoll(name: trimmedName, createdBy: uid)
                // The server opens a new roll twelve hours after it starts; move it to the choice.
                if abs(roll.revealAt.timeIntervalSince(when)) > 60,
                   let moved = try? await rolls.setRevealAt(rollId: roll.id, to: when) {
                    roll = Roll(id: roll.id, name: roll.name, inviteCode: roll.inviteCode, createdBy: roll.createdBy,
                                createdAt: roll.createdAt, coverPath: roll.coverPath, revealAt: moved,
                                parentRollId: roll.parentRollId)
                }
                CameraRollSelection.select(roll, for: uid)
                Haptics.success()
                done(roll)
            } catch {
                Haptics.error()
                problem = (error as? LocalizedError)?.errorDescription ?? UserFacingError.genericMessage
                working = false
            }
        }
    }

    private func join() {
        guard code.count == 6, !working, let uid = auth.currentUser?.id else { return }
        working = true
        problem = nil
        Task {
            do {
                let roll = try await rolls.joinRoll(inviteCode: code, userId: uid)
                CameraRollSelection.select(roll, for: uid)
                Haptics.success()
                done(roll)
            } catch {
                Haptics.error()
                problem = (error as? LocalizedError)?.errorDescription ?? UserFacingError.genericMessage
                working = false
            }
        }
    }
}

/// When a roll opens, in words and on the box.
enum V2RollTime {
    enum Choice: CaseIterable, Hashable {
        case tonight, tomorrow, week

        var title: String {
            switch self {
            case .tonight: "Tonight, 10 PM"
            case .tomorrow: "Tomorrow, 6 PM"
            case .week: "In a week"
            }
        }

        /// Tonight only while there is still an evening to fill.
        static func available(now: Date = .now, calendar: Calendar = .current) -> [Choice] {
            calendar.component(.hour, from: now) < 21 ? allCases : [.tomorrow, .week]
        }

        /// A roll may open up to seven days after it starts (`set_roll_reveal_at`), so "in a
        /// week" is the same evening next week, kept inside that window.
        func date(now: Date = .now, calendar: Calendar = .current) -> Date {
            let today = calendar.startOfDay(for: now)
            switch self {
            case .tonight:
                return calendar.date(byAdding: .hour, value: 22, to: today) ?? now
            case .tomorrow:
                let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? now
                return calendar.date(byAdding: .hour, value: 18, to: tomorrow) ?? now
            case .week:
                let nextWeek = calendar.date(byAdding: .day, value: 7, to: today) ?? now
                let evening = calendar.date(byAdding: .hour, value: 18, to: nextWeek) ?? now
                return min(evening, now.addingTimeInterval(7 * 86_400 - 600))
            }
        }
    }

    /// "tonight, 6 PM", "tomorrow, 6 PM", "Tuesday, 6 PM", "7 Oct, 6 PM" (prototype).
    static func label(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let time = date.formatted(.dateTime.hour().minute())
        if calendar.isDate(date, inSameDayAs: now) { return "tonight, \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow, \(time)"
        }
        if date.timeIntervalSince(now) < 6 * 86_400 { return "\(date.formatted(.dateTime.weekday(.wide))), \(time)" }
        return "\(date.formatted(.dateTime.day().month(.abbreviated))), \(time)"
    }

    /// The lid's clock is always 24-hour, like a stamp.
    private static let lidTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// "TOMORROW 18:00", "7 OCT 18:00" on the box's lid (prototype).
    static func clock(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let time = Self.lidTime.string(from: date)
        let day: String
        if calendar.isDate(date, inSameDayAs: now) { day = "TONIGHT" }
        else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { day = "TOMORROW" }
        else { day = date.formatted(.dateTime.day().month(.abbreviated)).uppercased() }
        return "\(day) \(time)"
    }
}

#if DEBUG
/// `-v2DemoRolls`: one sealed roll and two opened, for checking the shelf without an account.
enum V2RollsFixture {
    @MainActor
    static func seed(into service: RollService, now: Date = .now) {
        guard service.rolls.isEmpty else { return }
        let me = UUID()
        func roll(_ name: String, opensIn hours: Double, cover: Int) -> Roll {
            Roll(id: UUID(), name: name, inviteCode: "BALI26", createdBy: me, createdAt: now.addingTimeInterval(-86_400),
                 coverPath: "demo/p\(String(format: "%02d", cover)).jpg", revealAt: now.addingTimeInterval(hours * 3_600))
        }
        service.rolls = [roll("Bali week", opensIn: 2.24, cover: 3), roll("Noor's 30th", opensIn: -48, cover: 6),
                         roll("Rooftop, no plan", opensIn: -400, cover: 13)]
        for (index, roll) in service.rolls.enumerated() { service.memberCounts[roll.id] = [6, 9, 4][index] }
    }
}
#endif
