import SwiftUI

/// An opened roll's prints in full, after its screening: everyone's prints by day, each foot
/// naming who shot it. A print opens on its own (`V2RollPrintView`) to turn over for its notes.
///
/// Not drawn on the boards past the screening; it follows Kept's month by day so the two read
/// alike. The App Store roll screen's extras (members, save all, start another) stay there for
/// now: its overflow is one tap away under More.
struct V2RollPrints: View {
    let roll: Roll
    var pendingPhotoIntent: Binding<RollPhotoIntent?> = .constant(nil)

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.v2Palette) private var palette
    @Environment(AuthService.self) private var auth
    @Environment(PhotoService.self) private var photos
    @Environment(RollService.self) private var rolls
    @Environment(FeedService.self) private var feed

    @State private var prints: [Photo] = []
    @State private var names: [UUID: String] = [:]
    @State private var loaded = false
    @State private var opened: Opened?
    @State private var showMore = false

    struct Opened: Identifiable {
        let index: Int
        let onBack: Bool
        var id: Int { index }
    }

    private var days: [(day: Date, photos: [Photo])] {
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: prints) { calendar.startOfDay(for: $0.takenAt) }
        return byDay.keys.sorted().map { day in (day, (byDay[day] ?? []).sorted { $0.takenAt < $1.takenAt }) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Text("Back").font(V2Type.control()).frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 8)
                Text(roll.name).font(V2Type.serif(15, relativeTo: .subheadline)).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button { showMore = true } label: {
                    Text("More").font(V2Type.control()).foregroundStyle(palette.ink3).frame(minHeight: 44)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, V2Metrics.margin)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text(summary)
                        .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
                        .foregroundStyle(palette.ink2)
                        .padding(.top, 8)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 28, alignment: .topLeading),
                                             count: sizeClass == .regular ? 2 : 1),
                              alignment: .leading, spacing: 0) {
                        ForEach(days, id: \.day) { day in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(day.day.formatted(.dateTime.weekday(.wide).day()))
                                    .font(V2Type.serif(13, italic: true, relativeTo: .footnote))
                                    .foregroundStyle(palette.ink3)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 112), spacing: 10, alignment: .leading)],
                                          alignment: .leading, spacing: 10) {
                                    ForEach(day.photos) { photo in
                                        Button { open(photo, onBack: false) } label: { print(photo) }
                                            .buttonStyle(.plain)
                                    }
                                }
                            }
                            .padding(.top, 18)
                        }
                    }
                    if loaded, prints.isEmpty {
                        Text("No shots in this roll.")
                            .font(V2Type.serif(15, italic: true, relativeTo: .body))
                            .foregroundStyle(palette.ink3)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    }
                }
                .padding(.horizontal, V2Metrics.margin)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .refreshable { await load() }
        }
        .background { V2Desktop(palette: palette) }
        .foregroundStyle(palette.ink)
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $showMore) {
            RollDetailView(roll: roll, pendingPhotoIntent: pendingPhotoIntent)
        }
        .fullScreenCover(item: $opened) { opened in
            V2RollPrintView(roll: roll, prints: prints, names: names, index: opened.index,
                            startsOnBack: opened.onBack) { self.opened = nil }
                .modifier(V2DeskEnvironment())
                .undoCapsuleHost()
                #if DEBUG
                .modifier(V2DemoFrame())
                #endif
        }
        .task { await load() }
    }

    private var summary: String {
        let people = Set(prints.map(\.userId)).count
        let n = prints.count
        let opened = roll.revealAt.formatted(.dateTime.day().month(.wide))
        return "\(n) \(n == 1 ? "print" : "prints") from \(people) \(people == 1 ? "person" : "people") · opened \(opened)"
    }

    private func print(_ photo: Photo) -> some View {
        V2PrintCard(width: 104, borderFraction: 6.0 / 104, footFraction: 20.0 / 104) {
            V2Image(path: photo.thumbPath ?? photo.viewPath, maxPixel: 240)
        } foot: {
            Text(names[photo.userId] ?? "")
                .font(V2Type.serif(9, italic: true, relativeTo: .caption2))
                .foregroundStyle(V2Color.printInk2)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityLabel("\(names[photo.userId] ?? "Someone")'s print from \(photo.takenAt.formatted(date: .abbreviated, time: .shortened))")
    }

    private func open(_ photo: Photo, onBack: Bool) {
        guard let index = prints.firstIndex(where: { $0.id == photo.id }) else { return }
        Haptics.tap()
        opened = Opened(index: index, onBack: onBack)
    }

    private func load() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-v2DemoRolls") {
            let owners = [UUID(), UUID(), UUID()]
            names = [owners[0]: "nadia", owners[1]: "gem", owners[2]: "you"]
            prints = (1...7).map { n in
                let path = "demo/p" + String(format: "%02d", n) + ".jpg"
                return Photo(id: UUID(), userId: owners[n % 3], rollId: roll.id, storagePath: path, thumbPath: path,
                             feedPath: path, takenAt: roll.revealAt.addingTimeInterval(Double(n - 9) * 20_000),
                             developsAt: roll.revealAt, isDeveloped: true, caption: nil)
            }
            loaded = true
            // `-v2OpenRollPrint`: opens the first print, on its back with `-v2GroupBack`.
            if ProcessInfo.processInfo.arguments.contains("-v2OpenRollPrint"), let first = prints.first {
                try? await Task.sleep(for: .seconds(0.6))
                open(first, onBack: ProcessInfo.processInfo.arguments.contains("-v2GroupBack"))
            }
            return
        }
        #endif
        let epoch = AccountEpoch.current
        async let photoRead = try? photos.fetchRollPhotosSnapshot(rollId: roll.id)
        async let memberRead = try? rolls.fetchMembers(for: roll.id)
        let (p, m) = await (photoRead, memberRead)
        guard AccountEpoch.isCurrent(epoch) else { return }
        if let p { prints = p.filter { !feed.isBlocked($0.userId) }.sorted { $0.takenAt < $1.takenAt } }
        if let m {
            let me = auth.currentUser?.id
            names = Dictionary(uniqueKeysWithValues: m.map { ($0.id, $0.id == me ? "you" : ($0.username ?? "someone")) })
        }
        loaded = true
        // A push about one print and its thread opens that print on its back.
        if let intent = pendingPhotoIntent.wrappedValue, intent.rollId == roll.id,
           let photo = prints.first(where: { $0.id == intent.photoId }) {
            pendingPhotoIntent.wrappedValue = nil
            open(photo, onBack: intent.comments)
        }
    }
}

/// One roll print, as a friend's print opens (`V2GroupView`): tap or swipe for the next, Flip
/// over for the notes on the back, replies under the note they answer, the quick four reactions
/// under it. Roll prints keep their own notes and reactions (`photo_comments`, photo reactions).
struct V2RollPrintView: View {
    let roll: Roll
    let prints: [Photo]
    let names: [UUID: String]
    @State var index: Int
    var startsOnBack = false
    var close: () -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.v2Palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AuthService.self) private var auth
    @Environment(PhotoService.self) private var photos
    @Environment(FeedService.self) private var feed

    @State private var showsBack = false
    @State private var notes: [UUID: [PhotoComment]] = [:]
    @State private var reactions: [UUID: [PhotoReaction]] = [:]
    @State private var draft = ""
    @State private var replyParentId: UUID?
    @State private var sending = false
    @FocusState private var composing: Bool

    private var photo: Photo { prints[min(index, prints.count - 1)] }
    private var me: UUID? { auth.currentUser?.id }

    var body: some View {
        GeometryReader { proxy in
            let open = sizeClass == .regular
            let width = min(V2DarkroomMetrics.maxStackWidth,
                            V2PrintGeometry.width(fitting: CGSize(width: open ? (proxy.size.width - V2Metrics.margin * 3) / 2
                                                                         : proxy.size.width - V2CameraMetrics.printInset * 2,
                                                                  height: proxy.size.height - 230)))
            VStack(spacing: 0) {
                HStack {
                    Button(action: close) {
                        Text("Back").font(V2Type.control()).frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 8)
                    Text(names[photo.userId] ?? roll.name).font(V2Type.serif(15, relativeTo: .subheadline)).lineLimit(1)
                    Spacer(minLength: 8)
                    if open {
                        Text("\(index + 1) / \(prints.count)").font(V2Type.data(10)).tracking(1).foregroundStyle(palette.ink3)
                    } else {
                        Button { turn() } label: {
                            Text(showsBack ? "Flip back" : "Flip over").font(V2Type.control())
                                .foregroundStyle(palette.ink3).frame(minHeight: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, V2Metrics.margin)
                HStack(alignment: .firstTextBaseline) {
                    Text("\(roll.name), \(photo.takenAt.formatted(.dateTime.weekday(.wide).hour().minute()))")
                        .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
                        .foregroundStyle(palette.ink2)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if !open {
                        Text("\(index + 1) / \(prints.count)").font(V2Type.data(10)).tracking(1).foregroundStyle(palette.ink3)
                    }
                }
                .padding(.horizontal, V2Metrics.margin)
                .padding(.top, 10)
                Spacer(minLength: 12)
                if open {
                    HStack(alignment: .top, spacing: V2Metrics.margin) {
                        front(width: width)
                        back(width: width)
                    }
                } else {
                    ZStack {
                        front(width: width).opacity(showsBack ? 0 : 1)
                        back(width: width)
                            .rotation3DEffect(.degrees(reduceMotion ? 0 : 180), axis: (x: 0, y: 1, z: 0))
                            .opacity(showsBack ? 1 : 0)
                    }
                    .rotation3DEffect(.degrees(reduceMotion ? 0 : (showsBack ? 180 : 0)), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
                }
                Spacer(minLength: 12)
                composer.padding(.horizontal, V2Metrics.margin)
                HStack(spacing: 16) {
                    ForEach(V2GroupView.quickReactions, id: \.self) { emoji in
                        let mine = (reactions[photo.id] ?? []).contains { $0.userId == me && $0.emoji == emoji }
                        Button { react(emoji) } label: {
                            Text(emoji).font(.system(size: 18)).opacity(mine ? 1 : 0.55)
                                .frame(minWidth: 36, minHeight: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("React \(emoji)")
                        .accessibilityAddTraits(mine ? .isSelected : [])
                    }
                    Spacer()
                }
                .padding(.horizontal, V2Metrics.margin)
                .padding(.top, 10)
                .padding(.bottom, 8)
            }
            .gesture(DragGesture(minimumDistance: 24).onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                step(value.translation.width < 0 ? 1 : -1)
            })
        }
        .background { V2Desktop(palette: palette) }
        .foregroundStyle(palette.ink)
        .onAppear { showsBack = startsOnBack }
        .task(id: photo.id) { await loadPrint() }
    }

    private func front(width: CGFloat) -> some View {
        Button { step(1) } label: {
            V2PrintCard(width: width) {
                V2Image(path: photo.viewPath, maxPixel: width * 1.4)
                    .overlay(alignment: .bottomTrailing) {
                        V2DateStamp(text: BrandedExport.dateText(.init(date: photo.takenAt)), cellHeight: width * 0.04, stamp: .amber)
                            .padding(.trailing, width * 0.04).padding(.bottom, width * 0.03)
                    }
            } foot: {
                HStack {
                    Text(names[photo.userId] ?? "")
                        .font(V2Type.serif(17 * width / 340, italic: true, relativeTo: .body))
                        .foregroundStyle(V2Color.printInk)
                    Spacer(minLength: 8)
                    let count = (notes[photo.id] ?? []).count
                    if count > 0 {
                        Text(count == 1 ? "1 note" : "\(count) notes")
                            .font(V2Type.serif(13, italic: true, relativeTo: .footnote))
                            .foregroundStyle(V2Color.printInk3)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Print \(index + 1) of \(prints.count) by \(names[photo.userId] ?? "someone")")
    }

    private func back(width: CGFloat) -> some View {
        let threads = CommentThreads.build((notes[photo.id] ?? []).filter { !feed.isBlocked($0.userId) })
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(names[photo.userId].map { "\($0)'s print" } ?? "")
                    .font(V2Type.serif(17, italic: true, relativeTo: .body))
                Spacer(minLength: 0)
                Text(BrandedExport.dateText(.init(date: photo.takenAt)))
                    .font(V2Type.data(10)).tracking(1.4).foregroundStyle(V2Stamp.amber.paperColor)
            }
            Rectangle().fill(V2Color.printInk.opacity(0.6)).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if threads.isEmpty {
                        Text("Nothing on the back yet.")
                            .font(V2Type.serif(15, italic: true, relativeTo: .body))
                            .foregroundStyle(V2Color.printInk3)
                    }
                    ForEach(threads) { thread in
                        if let root = thread.root { note(root) }
                        ForEach(thread.replies) { reply in
                            note(reply).padding(.leading, CommentThreads.replyIndent)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
        }
        .foregroundStyle(V2Color.printInk)
        .padding(EdgeInsets(top: 22, leading: 22, bottom: 18, trailing: 22))
        .frame(width: width, height: V2PrintGeometry.height(width: width))
        .background(
            Rectangle().fill(V2Color.printBack)
                .shadow(color: palette.shadowNear.color, radius: palette.shadowNear.radius, y: palette.shadowNear.y)
                .shadow(color: palette.shadowFar.color, radius: palette.shadowFar.radius, y: palette.shadowFar.y)
        )
    }

    private func note(_ comment: PhotoComment) -> some View {
        let name = comment.userId == me ? "you" : (names[comment.userId] ?? "someone")
        return (Text(name).font(V2Type.serif(15, bold: true, relativeTo: .body))
                + Text(" " + comment.body).font(V2Type.serif(15, relativeTo: .body)))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
            .onTapGesture { reply(to: comment, name: name) }
            .contextMenu {
                Button { reply(to: comment, name: name) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                if comment.userId == me {
                    Button(role: .destructive) { delete(comment) } label: { Label("Delete", systemImage: "trash") }
                }
            }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("", text: $draft,
                      prompt: Text("write on the back").font(V2Type.serif(16, italic: true, relativeTo: .body)).foregroundStyle(palette.ink3),
                      axis: .vertical)
                .font(V2Type.serif(16, relativeTo: .body))
                .foregroundStyle(palette.ink)
                .lineLimit(1...3)
                .focused($composing)
                .submitLabel(.send)
                .onSubmit { post() }
            Button { post() } label: {
                Text("Post").font(V2Type.control())
                    .foregroundStyle(canPost ? palette.ink : palette.ink3)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.plain)
            .disabled(!canPost)
        }
        .overlay(alignment: .bottom) { Rectangle().fill(palette.ink).frame(height: 1.5) }
    }

    private var canPost: Bool { !sending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // MARK: Actions

    private func step(_ delta: Int) {
        guard prints.count > 1 else { return }
        Haptics.tap()
        withAnimation(V2Motion.slide) {
            index = (index + delta + prints.count) % prints.count
            showsBack = false
            replyParentId = nil
        }
    }

    private func turn() {
        Haptics.tap()
        withAnimation(.easeInOut(duration: reduceMotion ? 0.2 : V2Motion.turnSeconds)) { showsBack.toggle() }
    }

    private func reply(to comment: PhotoComment, name: String) {
        Haptics.tap()
        draft = prefillingReply(to: "@\(name)", in: draft)
        replyParentId = comment.parentId ?? comment.id
        composing = true
    }

    private func post() {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !sending, let me else { return }
        sending = true
        let photoId = photo.id, parent = replyParentId
        Task {
            let created = await photos.addPhotoComment(photoId: photoId, body: body, userId: me, parentId: parent)
            sending = false
            if let created {
                notes[photoId, default: []].append(created)
                draft = ""
                replyParentId = nil
                composing = false
                if sizeClass != .regular, !showsBack { turn() }
            } else {
                Haptics.error()
            }
        }
    }

    private func delete(_ comment: PhotoComment) {
        Haptics.tap()
        notes[photo.id]?.removeAll { $0.id == comment.id }
        Task { await photos.deletePhotoComment(id: comment.id) }
    }

    /// As the reveal's reactions (`RollRevealViewModel.toggleReaction`): shown now, put back if
    /// the write fails.
    private func react(_ emoji: String) {
        guard let me else { return }
        Haptics.tap()
        let id = photo.id
        let mine = (reactions[id] ?? []).contains { $0.emoji == emoji && $0.userId == me }
        let key = "photo|\(id)|\(emoji)|\(me)"
        let service = photos
        if mine {
            reactions[id]?.removeAll { $0.emoji == emoji && $0.userId == me }
            OptimisticToggle.shared.perform(key: key, write: { await service.removeReaction(photoId: id, emoji: emoji, userId: me) }) {
                reactions[id, default: []].append(PhotoReaction(id: UUID(), photoId: id, userId: me, emoji: emoji))
            }
        } else {
            reactions[id, default: []].append(PhotoReaction(id: UUID(), photoId: id, userId: me, emoji: emoji))
            OptimisticToggle.shared.perform(key: key, write: { await service.addReaction(photoId: id, emoji: emoji, userId: me) }) {
                reactions[id]?.removeAll { $0.emoji == emoji && $0.userId == me }
            }
        }
    }

    private func loadPrint() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-v2DemoRolls") { return }
        #endif
        let id = photo.id
        async let n = photos.fetchPhotoComments(photoId: id)
        async let r = photos.fetchReactions(photoId: id)
        let (fetchedNotes, fetchedReactions) = await (n, r)
        notes[id] = fetchedNotes
        reactions[id] = fetchedReactions
    }
}
