import SwiftUI

/// One friend's group, print by print (prototype "an evening"; board 15e). Tap the print for the
/// next one; turn it over for what people wrote on the back, and write there yourself. Reactions
/// sit under the print, and the next friend's group is one tap away.
///
/// On the phone and the closed display it is a screen of its own over the places; open, the
/// print sits on the left and its back on the right, so nothing needs turning.
struct V2GroupView: View {
    let groups: [V2FeedGroup]
    @State var index: Int
    /// Opens on the back of the print: an Activity slip about a note goes straight to the notes.
    var startsOnBack = false
    /// Just the print and its back, side by side, for a pane beside a list (Activity, open,
    /// board 16-1k). Its host provides the desk and the way out.
    var embedded = false
    /// Pushed onto a navigation stack the host owns (a notification's route to a print), rather
    /// than presented with a stack of its own.
    var pushed = false
    var close: () -> Void = {}

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.v2Palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed

    @State private var frame = 0
    @State private var showsBack = false
    @State private var draft = ""
    @State private var replyParentId: UUID?
    @State private var sending = false
    @State private var profile: ProfileRoute?
    @State private var sharing = false
    @FocusState private var composing: Bool

    /// The prototype's quick four, under the print.
    static let quickReactions = ["❤️", "🔥", "😂", "🥹"]

    private var group: V2FeedGroup { groups[min(index, groups.count - 1)] }
    private var item: FeedItem { group.items[min(frame, group.items.count - 1)] }
    private var me: UUID? { auth.currentUser?.id }

    var body: some View {
        Group {
            if embedded {
                GeometryReader { proxy in pane(proxy.size) }
            } else {
                full
            }
        }
        .task(id: item.id) {
            FeedSeenStore.shared.markSeen(item.id)
            guard let me else { return }
            if let fresh = await feed.fetchComments(postId: item.id, currentUserId: me) {
                feed.commentsByPost[item.id] = fresh
            }
        }
        .onAppear {
            if startsOnBack { showsBack = true }
            #if DEBUG
            // `-v2GroupBack`: opens on the back of the print, for screenshots.
            if ProcessInfo.processInfo.arguments.contains("-v2GroupBack") { showsBack = true }
            // `-v2OpenShare`: opens Share this print, for screenshots.
            if ProcessInfo.processInfo.arguments.contains("-v2OpenShare") {
                Task { try? await Task.sleep(for: .seconds(0.8)); sharing = true }
            }
            #endif
        }
        .sheet(isPresented: $sharing) {
            V2SharePrintView(print: V2ShareablePrint(path: item.post.cardPath, takenAt: item.post.takenAt,
                                                     caption: item.post.caption,
                                                     handle: group.author.username ?? group.author.name))
                .modifier(V2DeskEnvironment())
        }
        .onChange(of: index) { _, _ in
            frame = 0
            showsBack = false
            replyParentId = nil
        }
    }

    @ViewBuilder
    private var full: some View {
        if pushed {
            screen
        } else {
            NavigationStack { screen }
        }
    }

    private var screen: some View {
        Group {
            GeometryReader { proxy in
                let mode = V2LayoutMode.resolve(horizontalSizeClass: sizeClass, size: proxy.size)
                Group {
                    switch mode {
                    case .phone: phone(proxy.size)
                    case .outer: outer(proxy.size)
                    case .inner: inner(proxy.size)
                    }
                }
                .environment(\.v2LayoutMode, mode)
            }
            .background { V2Desktop(palette: palette) }
            .foregroundStyle(palette.ink)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $profile) { V2PageView(userId: $0.id, openInvite: $0.openInvite) }
        }
    }

    /// The embedded pane: the print, and beside it the back with the composer under it.
    private func pane(_ size: CGSize) -> some View {
        let half = (size.width - V2Metrics.margin) / 2
        let width = printWidth(in: CGSize(width: half, height: size.height - 90))
        return VStack(spacing: 14) {
            HStack(alignment: .top, spacing: V2Metrics.margin) {
                stack(width: width, turnable: false)
                backFace(width: width, height: V2PrintGeometry.height(width: width))
            }
            composer
            quickReactions
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Arrangements

    private func phone(_ size: CGSize) -> some View {
        let width = printWidth(in: CGSize(width: size.width - V2CameraMetrics.printInset * 2, height: size.height - 260))
        return VStack(spacing: 0) {
            header
                .padding(.horizontal, V2Metrics.margin)
            subheader
                .padding(.horizontal, V2Metrics.margin)
                .padding(.top, 14)
            Spacer(minLength: 12)
            stack(width: width, turnable: true)
            Spacer(minLength: 12)
            composer
                .padding(.horizontal, V2Metrics.margin)
            HStack {
                quickReactions
                Spacer(minLength: 12)
                nextGroup
            }
            .padding(.horizontal, V2Metrics.margin)
            .padding(.top, 10)
            .padding(.bottom, 8)
        }
    }

    /// Closed: the print on the left with the composer under it; Back first in the column and
    /// the way on last (round 16's rule for the outer display).
    private func outer(_ size: CGSize) -> some View {
        let columnWidth = V2RootMetrics.columnWidth
        let width = printWidth(in: CGSize(width: size.width - columnWidth - V2Metrics.margin * 2, height: size.height - 120))
        return HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                subheader
                stack(width: width, turnable: true)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
                composer
            }
            .padding(.leading, V2Metrics.margin)
            .padding(.trailing, 12)
            .padding(.vertical, 12)
            VStack(alignment: .trailing, spacing: 6) {
                backButton
                authorButton
                flipButton
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 2) { quickReactionButtons }
                nextGroup
                    .multilineTextAlignment(.trailing)
            }
            .padding(.vertical, 12)
            .padding(.trailing, 14)
            .frame(width: columnWidth, alignment: .trailing)
        }
    }

    /// Open: the print on the left, its back on the right with the composer (board 15e).
    private func inner(_ size: CGSize) -> some View {
        let half = (size.width - V2Metrics.margin * 3) / 2
        let width = printWidth(in: CGSize(width: half, height: size.height - 170))
        return VStack(spacing: 0) {
            HStack {
                backButton
                Spacer()
                authorButton
                Spacer()
                nextGroup
            }
            .padding(.horizontal, V2Metrics.margin)
            subheader
                .padding(.horizontal, V2Metrics.margin)
                .padding(.top, 10)
            HStack(alignment: .top, spacing: V2Metrics.margin) {
                VStack(spacing: 16) {
                    stack(width: width, turnable: false)
                    quickReactions
                }
                .frame(width: half)
                VStack(spacing: 14) {
                    backFace(width: width, height: V2PrintGeometry.height(width: width))
                    composer
                }
                .frame(width: half)
            }
            .frame(maxHeight: .infinity)
            .padding(.vertical, 12)
        }
    }

    private func printWidth(in box: CGSize) -> CGFloat {
        min(V2DarkroomMetrics.maxStackWidth, V2PrintGeometry.width(fitting: box))
    }

    // MARK: Header

    private var header: some View {
        HStack {
            backButton
            Spacer(minLength: 8)
            authorButton
            Spacer(minLength: 8)
            flipButton
        }
    }

    private var backButton: some View {
        Button(action: close) {
            Text("Back")
                .font(V2Type.control())
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var authorButton: some View {
        Button { profile = ProfileRoute(id: group.author.id) } label: {
            Text(group.author.username ?? group.author.name)
                .font(V2Type.serif(15, relativeTo: .subheadline))
                .lineLimit(1)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens their page")
    }

    private var flipButton: some View {
        Button { turn() } label: {
            Text(showsBack ? "Flip back" : "Flip over")
                .font(V2Type.control())
                .foregroundStyle(palette.ink3)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var subheader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(V2FeedGrouping.span(group, now: .distantFuture))
                .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
                .foregroundStyle(palette.ink2)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button { sharing = true } label: {
                Text("Share").font(V2Type.control(.caption)).foregroundStyle(palette.ink2).frame(minHeight: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Share this print")
            counter
        }
    }

    private var counter: some View {
        Text("\(frame + 1) / \(group.items.count)")
            .font(V2Type.data(10))
            .tracking(1)
            .foregroundStyle(palette.ink3)
            .accessibilityLabel("Print \(frame + 1) of \(group.items.count)")
    }

    // MARK: The print

    /// The current print on top of the next one and a loose blank (prototype: -3 and 4 degrees).
    private func stack(width: CGFloat, turnable: Bool) -> some View {
        let next = group.items.count > 1 ? group.items[(frame + 1) % group.items.count] : nil
        let height = V2PrintGeometry.height(width: width)
        return ZStack {
            Rectangle().fill(V2Color.print)
                .frame(width: width, height: height)
                .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                .rotationEffect(.degrees(4))
                .offset(x: width * 0.08, y: 6)
                .opacity(0.9)
            if let next {
                V2PrintCard(width: width, showsShadow: true) {
                    V2Image(path: next.post.cardPath, maxPixel: width)
                        .opacity(0.85)
                } foot: { Color.clear }
                .rotationEffect(.degrees(-3))
                .offset(x: -width * 0.05, y: 4)
                .accessibilityHidden(true)
            }
            if turnable {
                turningCard(width: width, height: height)
            } else {
                front(width: width)
            }
        }
        .frame(width: width, height: height)
        .gesture(
            DragGesture(minimumDistance: 24).onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                step(value.translation.width < 0 ? 1 : -1)
            }
        )
    }

    /// The Turn motion: a 0.4 s flip about the vertical axis, the face changing at the half-way
    /// point; a crossfade with Reduce Motion (handoff 2).
    private func turningCard(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            front(width: width)
                .opacity(showsBack ? 0 : 1)
            backFace(width: width, height: height)
                .rotation3DEffect(.degrees(reduceMotion ? 0 : 180), axis: (x: 0, y: 1, z: 0))
                .opacity(showsBack ? 1 : 0)
        }
        .rotation3DEffect(.degrees(reduceMotion ? 0 : (showsBack ? 180 : 0)), axis: (x: 0, y: 1, z: 0),
                          perspective: 0.4)
    }

    private func front(width: CGFloat) -> some View {
        Button { step(1) } label: {
            V2PrintCard(width: width) {
                V2Image(path: item.post.cardPath, maxPixel: width * 1.4)
                    .overlay(alignment: .bottomTrailing) {
                        V2DateStamp(text: BrandedExport.dateText(.init(date: item.post.takenAt)),
                                    cellHeight: width * 0.04, stamp: .amber)
                            .padding(.trailing, width * 0.04)
                            .padding(.bottom, width * 0.03)
                    }
            } foot: {
                VStack(alignment: .leading, spacing: 6) {
                    if let caption = item.post.caption, !caption.isEmpty {
                        Text(caption)
                            .font(V2Type.serif(17 * width / 340, italic: true, relativeTo: .body))
                            .foregroundStyle(V2Color.printInk)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                    }
                    HStack(spacing: 14) {
                        reactionsLine
                        Spacer(minLength: 8)
                        Text(notesLabel)
                            .font(V2Type.serif(13, italic: true, relativeTo: .footnote))
                            .foregroundStyle(V2Color.printInk3)
                    }
                }
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(frontLabel)
        .accessibilityHint(group.items.count > 1 ? "Shows the next print" : "")
    }

    /// The back of the print: the caption and the date at the top, then what people wrote,
    /// replies under the note they answer; it scrolls past what fits (product rule 8).
    private func backFace(width: CGFloat, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(item.post.caption ?? "")
                    .font(V2Type.serif(17, italic: true, relativeTo: .body))
                    .lineLimit(3)
                Spacer(minLength: 0)
                Text(BrandedExport.dateText(.init(date: item.post.takenAt)))
                    .font(V2Type.data(10))
                    .tracking(1.4)
                    .foregroundStyle(V2Stamp.amber.paperColor)
                    .fixedSize()
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
                        if let root = thread.root {
                            note(root)
                        } else if !thread.replies.isEmpty {
                            Text("Comment unavailable")
                                .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
                                .foregroundStyle(V2Color.printInk3)
                        }
                        ForEach(thread.replies) { reply in
                            note(reply)
                                .padding(.leading, CommentThreads.replyIndent)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            HStack(spacing: 12) {
                reactionsLine
                Spacer(minLength: 8)
                Text("\(frame + 1) / \(group.items.count)")
                    .font(V2Type.serif(13, italic: true, relativeTo: .footnote))
                    .foregroundStyle(V2Color.printInk3)
            }
            .padding(.top, 10)
            .overlay(alignment: .top) { Rectangle().fill(V2Color.rgb(0xE2D3C4)).frame(height: 1) }
        }
        .foregroundStyle(V2Color.printInk)
        .padding(EdgeInsets(top: 22, leading: 22, bottom: 18, trailing: 22))
        .frame(width: width, height: height)
        .background(
            Rectangle().fill(V2Color.printBack)
                .shadow(color: palette.shadowNear.color, radius: palette.shadowNear.radius, y: palette.shadowNear.y)
                .shadow(color: palette.shadowFar.color, radius: palette.shadowFar.radius, y: palette.shadowFar.y)
        )
    }

    private func note(_ info: CommentInfo) -> some View {
        (Text(info.author?.username ?? "someone").font(V2Type.serif(15, bold: true, relativeTo: .body))
         + Text(" " + info.comment.body).font(V2Type.serif(15, relativeTo: .body)))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
            .contextMenu {
                Button { reply(to: info) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                if info.comment.userId == me {
                    Button(role: .destructive) { delete(info) } label: { Label("Delete", systemImage: "trash") }
                } else {
                    Button { report(info) } label: { Label("Report \(info.handle)", systemImage: "flag") }
                }
            }
            .onTapGesture { reply(to: info) }
            .accessibilityHint("Replies")
    }

    private var threads: [CommentThread<CommentInfo>] {
        let visible = (feed.commentsByPost[item.id] ?? []).filter { !feed.isBlocked($0.comment.userId) }
        return CommentThreads.build(visible)
    }

    private var notesLabel: String {
        let count = (feed.commentsByPost[item.id] ?? []).filter { !feed.isBlocked($0.comment.userId) }.count
        return count == 0 ? "" : (count == 1 ? "1 note" : "\(count) notes")
    }

    /// "❤️ noor, dev.k  🔥 rafi", the top three, then "and N more" (handoff 6).
    private var reactionsLine: some View {
        let reactions = feed.reactionsByPost[item.id] ?? []
        let byEmoji = Dictionary(grouping: reactions, by: \.emoji)
            .sorted { ($0.value.count, $0.key) > ($1.value.count, $1.key) }
        let more = byEmoji.dropFirst(3).reduce(0) { $0 + $1.value.count }
        return HStack(spacing: 12) {
            ForEach(byEmoji.prefix(3), id: \.key) { emoji, list in
                let names = Array(Set(list.map(\.userId)))
                    .compactMap { $0 == me ? "you" : feed.knownProfile(id: $0)?.username }
                    .sorted()
                Text(names.isEmpty ? "\(emoji) \(list.count)" : "\(emoji) \(names.prefix(2).joined(separator: ", "))")
                    .lineLimit(1)
            }
            if more > 0 { Text("and \(more) more") }
        }
        .font(.system(size: 12.5))
        .foregroundStyle(V2Color.printInk2)
    }

    private var frontLabel: String {
        var parts = ["Print \(frame + 1) of \(group.items.count)"]
        if let caption = item.post.caption, !caption.isEmpty { parts.append(caption) }
        if !notesLabel.isEmpty { parts.append(notesLabel) }
        return parts.joined(separator: ", ")
    }

    // MARK: Writing and reacting

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("", text: $draft,
                      prompt: Text("write on the back")
                        .font(V2Type.serif(16, italic: true, relativeTo: .body))
                        .foregroundStyle(palette.ink3),
                      axis: .vertical)
                .font(V2Type.serif(16, relativeTo: .body))
                .foregroundStyle(palette.ink)
                .lineLimit(1...3)
                .focused($composing)
                .submitLabel(.send)
                .onSubmit { post() }
            Button { post() } label: {
                Text("Post")
                    .font(V2Type.control())
                    .foregroundStyle(canPost ? palette.ink : palette.ink3)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.plain)
            .disabled(!canPost)
        }
        .padding(.bottom, 2)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.ink).frame(height: 1.5) }
    }

    private var canPost: Bool { !sending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var quickReactions: some View {
        HStack(spacing: 16) { quickReactionButtons }
    }

    @ViewBuilder
    private var quickReactionButtons: some View {
        let mine = Set((feed.reactionsByPost[item.id] ?? []).filter { $0.userId == me }.map(\.emoji))
        ForEach(Self.quickReactions, id: \.self) { emoji in
            Button {
                guard let me else { return }
                Haptics.tap()
                Task { await feed.reactToPost(item.id, emoji: emoji, userId: me, authorId: group.author.id) }
            } label: {
                Text(emoji)
                    .font(.system(size: 18))
                    .opacity(mine.contains(emoji) ? 1 : 0.55)
                    .frame(minWidth: 36, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("React \(emoji)")
            .accessibilityAddTraits(mine.contains(emoji) ? .isSelected : [])
        }
    }

    @ViewBuilder
    private var nextGroup: some View {
        if groups.count > 1 {
            let next = groups[(index + 1) % groups.count]
            Button {
                withAnimation(V2Motion.slide) { index = (index + 1) % groups.count }
            } label: {
                Text("next: \(next.author.username ?? next.author.name), \(next.items.count) \(next.items.count == 1 ? "shot" : "shots")")
                    .font(V2Type.serif(13, italic: true, relativeTo: .footnote))
                    .foregroundStyle(palette.ink3)
                    .lineLimit(2)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Actions

    private func step(_ delta: Int) {
        guard group.items.count > 1 else { return }
        Haptics.tap()
        withAnimation(V2Motion.slide) {
            frame = (frame + delta + group.items.count) % group.items.count
            showsBack = false
            replyParentId = nil
        }
    }

    private func turn() {
        Haptics.tap()
        withAnimation(.easeInOut(duration: reduceMotion ? 0.2 : V2Motion.turnSeconds)) { showsBack.toggle() }
    }

    private func reply(to info: CommentInfo) {
        Haptics.tap()
        draft = prefillingReply(to: info.handle, in: draft)
        replyParentId = info.comment.parentId ?? info.id
        composing = true
    }

    private func post() {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !sending, let me else { return }
        sending = true
        let postId = item.id, parent = replyParentId, author = group.author.id
        Task {
            let ok = await feed.commentOnPost(postId, body: body, userId: me, authorId: author,
                                              commenter: auth.currentUser, parentId: parent)
            sending = false
            if ok {
                draft = ""
                replyParentId = nil
                composing = false
                // What you wrote is on the back: show it there (prototype).
                if !showsBack { turn() }
            } else {
                Haptics.error()
            }
        }
    }

    private func delete(_ info: CommentInfo) {
        Haptics.tap()
        Task {
            await feed.deleteComment(id: info.comment.id)
            if let me, let fresh = await feed.fetchComments(postId: item.id, currentUserId: me) {
                feed.commentsByPost[item.id] = fresh
            }
        }
    }

    /// The same report the App Store app's comments sheet sends (`CommentsSheet.report`).
    private func report(_ info: CommentInfo) {
        guard let me, info.comment.userId != me else { return }
        Haptics.tap()
        let target = info.comment.userId
        let service = feed
        UndoCenter.shared.stage(
            title: "Reported \(info.handle). We'll look into it.",
            failureText: "Couldn't send that report",
            commit: { await service.reportUser(target, from: me, reason: "comment") })
    }
}

extension V2Stamp {
    /// The deepened stamp colour, for the Paper desk and the back of a print.
    var paperColor: Color { V2Color.rgb(paperHex) }
}
