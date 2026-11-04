import SwiftUI

/// Everything you kept, by month and day, newest first, as loose prints on the desk; it reads
/// back a page at a time as you scroll. A print opens in the full viewer, where it can be posted,
/// saved or deleted as in the App Store app.
///
/// Not drawn on the boards: it follows your page's month by day (board 8a) so the two read alike.
struct V2KeptView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.v2Palette) private var palette
    @Environment(AuthService.self) private var auth
    @Environment(PhotoService.self) private var photos

    @State private var kept: [Photo] = []
    @State private var cursor: PhotoService.PhotoCursor?
    @State private var exhausted = false
    @State private var loading = false
    @State private var failed = false
    @State private var viewing: Viewing?

    private struct Viewing: Identifiable {
        let index: Int
        var id: Int { index }
    }

    /// Months, newest first, each with its days, newest first.
    private var months: [(month: Date, days: [(day: Date, photos: [Photo])])] {
        let calendar = Calendar.current
        let byMonth = Dictionary(grouping: kept) { calendar.dateInterval(of: .month, for: $0.takenAt)?.start ?? $0.takenAt }
        return byMonth.keys.sorted(by: >).map { month in
            let byDay = Dictionary(grouping: byMonth[month] ?? []) { calendar.startOfDay(for: $0.takenAt) }
            return (month, byDay.keys.sorted(by: >).map { ($0, (byDay[$0] ?? []).sorted { $0.takenAt > $1.takenAt }) })
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let mode = V2LayoutMode.resolve(horizontalSizeClass: sizeClass, proxy: proxy)
            Group {
                if mode == .outer {
                    HStack(spacing: 0) {
                        list
                        VStack { back; Spacer() }
                            .padding(.vertical, 12)
                            .padding(.trailing, 14)
                            .frame(width: V2RootMetrics.columnWidth, alignment: .trailing)
                    }
                } else {
                    VStack(spacing: 0) {
                        HStack {
                            back
                            Spacer(minLength: 8)
                            Text("Kept").font(V2Type.serif(15, relativeTo: .subheadline))
                                .accessibilityAddTraits(.isHeader)
                            Spacer(minLength: 8)
                            back.hidden()
                        }
                        .padding(.horizontal, V2Metrics.margin)
                        list
                    }
                }
            }
            .environment(\.v2LayoutMode, mode)
        }
        .background { V2Desktop(palette: palette) }
        .foregroundStyle(palette.ink)
        .toolbar(.hidden, for: .navigationBar)
        .task { if kept.isEmpty { await loadMore() } }
        #if DEBUG
        // `-v2OpenOwnPrint`: opens the first kept print at launch, for screenshots.
        .task(id: kept.count) {
            guard ProcessInfo.processInfo.arguments.contains("-v2OpenOwnPrint"), viewing == nil, !kept.isEmpty else { return }
            try? await Task.sleep(for: .seconds(0.8))
            viewing = Viewing(index: 0)
        }
        #endif
        .fullScreenCover(item: $viewing) { viewing in
            V2OwnPrintsView(prints: kept, start: viewing.index, onDelete: {
                Task { await reload() }
            })
            .modifier(V2DeskEnvironment())
            .undoCapsuleHost()
        }
    }

    private var back: some View {
        Button { dismiss() } label: {
            Text("Back").font(V2Type.control()).frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(months, id: \.month) { month in
                    Text(month.month.formatted(.dateTime.month(.wide).year()))
                        .font(V2Type.serif(28, relativeTo: .largeTitle))
                        .padding(.top, 22)
                        .accessibilityAddTraits(.isHeader)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 28, alignment: .topLeading),
                                             count: sizeClass == .regular ? 2 : 1),
                              alignment: .leading, spacing: 0) {
                    ForEach(month.days, id: \.day) { day in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(day.day.formatted(.dateTime.weekday(.wide).day()))
                                .font(V2Type.serif(13, italic: true, relativeTo: .footnote))
                                .foregroundStyle(palette.ink3)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 112), spacing: 10, alignment: .leading)],
                                      alignment: .leading, spacing: 10) {
                                ForEach(day.photos) { photo in
                                    Button { open(photo) } label: { print(photo) }
                                        .buttonStyle(.plain)
                                        .onAppear { if photo.id == kept.last?.id { Task { await loadMore() } } }
                                }
                            }
                        }
                        .padding(.top, 18)
                    }
                    }
                }
                footer
                    .padding(.top, 30)
            }
            .padding(.horizontal, V2Metrics.margin)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .refreshable { await reload() }
    }

    private func print(_ photo: Photo) -> some View {
        V2PrintCard(width: 104, borderFraction: 6.0 / 104, footFraction: 18.0 / 104) {
            V2Image(path: photo.thumbPath ?? photo.viewPath, maxPixel: 240)
        } foot: { Color.clear }
        .accessibilityLabel(photo.caption?.isEmpty == false ? photo.caption! : "Kept print from \(photo.takenAt.formatted(date: .abbreviated, time: .shortened))")
    }

    @ViewBuilder
    private var footer: some View {
        if failed {
            Button { Task { await loadMore() } } label: {
                Text("Couldn't load more. Try again")
                    .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
                    .foregroundStyle(palette.ink2)
                    .underline()
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
        } else if loading {
            ProgressView().frame(maxWidth: .infinity)
        } else if exhausted {
            Text(kept.isEmpty ? "Nothing kept yet. Prints you keep from the sort land here." : "That's everything you kept.")
                .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
                .foregroundStyle(palette.ink3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    private func open(_ photo: Photo) {
        guard let index = kept.firstIndex(where: { $0.id == photo.id }) else { return }
        Haptics.tap()
        viewing = Viewing(index: index)
    }

    private func reload() async {
        cursor = nil
        exhausted = false
        kept = []
        await loadMore()
    }

    private func loadMore() async {
        guard !loading, !exhausted else { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-v2DemoDarkroom") {
            kept = V2DarkroomFixture.make().kept
            exhausted = true
            return
        }
        #endif
        guard let uid = auth.currentUser?.id else { exhausted = true; return }
        loading = true
        defer { loading = false }
        let epoch = AccountEpoch.current
        do {
            let page = try await photos.fetchDarkroomPage(userId: uid, limit: 60, before: cursor)
            guard AccountEpoch.isCurrent(epoch) else { return }
            failed = false
            let known = Set(kept.map(\.id))
            kept += page.photos.filter { !known.contains($0.id) }
            cursor = page.next
            if page.next == nil || page.photos.isEmpty { exhausted = true }
        } catch {
            failed = true
        }
    }
}

// MARK: - Your own prints, one at a time

/// Your own prints, one at a time, on the desk: the App Store app's photo pager, v2's way. Swipe
/// between them; Post puts one on your page with a line for its back and the people in it, Share
/// sends the print, Delete takes it out with Undo (the pager's own staged delete). The rarer
/// things (a profile photo, a shot that will not load) are under More, in the full viewer.
struct V2OwnPrintsView: View {
    let prints: [Photo]
    let start: Int
    var onDelete: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.v2Palette) private var palette
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed
    @Environment(PhotoService.self) private var photos

    @State private var index = 0
    @State private var composing: Photo?
    @State private var sharing: Photo?
    @State private var fullViewer = false
    @State private var note: String?

    private var current: Photo? { prints.indices.contains(index) ? prints[index] : nil }

    var body: some View {
        GeometryReader { proxy in
            let mode = V2LayoutMode.resolve(horizontalSizeClass: sizeClass, proxy: proxy)
            let width = min(340, V2PrintGeometry.width(fitting: CGSize(width: proxy.size.width - V2Metrics.margin * 2,
                                                                       height: proxy.size.height - 210)))
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, V2Metrics.margin)
                TabView(selection: $index) {
                    ForEach(prints.indices, id: \.self) { i in
                        V2Print(width: width, caption: prints[i].caption, date: prints[i].takenAt) {
                            V2Image(path: prints[i].viewPath, maxPixel: 1400)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .tag(i)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Print \(i + 1) of \(prints.count), \(prints[i].takenAt.formatted(.dateTime.weekday(.wide).month(.wide).day()))")
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                if let note {
                    Text(note)
                        .font(V2Type.serif(13, italic: true, relativeTo: .footnote))
                        .foregroundStyle(palette.ink2)
                        .transition(.opacity)
                }
                actions
                    .padding(.horizontal, V2Metrics.margin)
                    .padding(.bottom, 8)
            }
            .environment(\.v2LayoutMode, mode)
        }
        .background { V2Desktop(palette: palette) }
        .foregroundStyle(palette.ink)
        .onAppear { index = min(max(0, start), max(0, prints.count - 1)) }
        #if DEBUG
        // `-v2OpenPost`: the post sheet on the first print (`-v2OpenTag` goes on to Tag people).
        .task {
            guard ProcessInfo.processInfo.arguments.contains("-v2OpenPost") else { return }
            try? await Task.sleep(for: .seconds(0.8))
            composing = current
        }
        #endif
        .sheet(item: $composing) { photo in
            V2PostSheet(photo: photo) { posted in
                composing = nil
                if posted { showNote("On your page.") }
            }
            .modifier(V2DeskEnvironment())
            .presentationDetents([.medium, .large])
        }
        .fullScreenCover(item: $sharing) { photo in
            V2SharePrintView(print: V2ShareablePrint(path: photo.viewPath, takenAt: photo.takenAt, caption: photo.caption,
                                                     handle: auth.currentUser?.username ?? ""))
                .modifier(V2DeskEnvironment())
        }
        .fullScreenCover(isPresented: $fullViewer) {
            PhotoPagerView(photos: prints, startIndex: index, signedURLs: [:], onDelete: onDelete)
                .preferredColorScheme(.dark)
        }
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Text("Back").font(V2Type.control()).frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            if let current {
                Text(current.takenAt.formatted(.dateTime.weekday(.wide).day()))
                    .font(V2Type.serif(15, relativeTo: .subheadline))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text("\(index + 1) / \(prints.count)")
                .font(V2Type.data(12))
                .foregroundStyle(palette.ink3)
                .frame(minWidth: 44, alignment: .trailing)
        }
    }

    private var actions: some View {
        HStack {
            if let current, feed.myPostedPhotoIds.contains(current.id) {
                Text("On your page")
                    .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
                    .foregroundStyle(palette.ink3)
                    .frame(minHeight: 44)
            } else {
                control("Post") { composing = current }
            }
            Spacer(minLength: 8)
            control("Share") { sharing = current }
            Spacer(minLength: 8)
            // A roll's print is deleted from the roll, without Undo, in the full viewer.
            if current?.rollId == nil {
                control("Delete") { if let current { delete(current) } }
                Spacer(minLength: 8)
            }
            control("More", quiet: true) { fullViewer = true }
        }
        .disabled(current == nil)
    }

    private func control(_ title: String, quiet: Bool = false, action: @escaping () -> Void) -> some View {
        Button { Haptics.tap(); action() } label: {
            Text(title)
                .font(V2Type.control())
                .foregroundStyle(quiet ? palette.ink3 : palette.ink)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// As the pager's own delete: closes, then holds the delete for the Undo window.
    private func delete(_ photo: Photo) {
        Haptics.warning()
        let service = photos
        let feedService = feed
        let afterDelete = onDelete
        dismiss()
        UndoCenter.shared.stage(
            title: "Photo deleted",
            failureText: "Couldn't delete that. Check your connection.",
            commit: {
                guard await service.deletePhoto(photo) else { return false }
                feedService.dropPost(forDeletedPhotoId: photo.id)
                afterDelete()
                return true
            })
    }

    private func showNote(_ text: String) {
        withAnimation(.easeOut(duration: 0.2)) { note = text }
        Task {
            try? await Task.sleep(for: .seconds(3))
            if note == text { withAnimation(.easeOut(duration: 0.2)) { note = nil } }
        }
    }
}

/// Post to your page: the print, a line for its back, the people in it.
struct V2PostSheet: View {
    let photo: Photo
    var done: (Bool) -> Void

    @Environment(\.v2Palette) private var palette
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed

    @State private var caption = ""
    @State private var tags: [PendingTag] = []
    @State private var tagging = false
    @State private var working = false
    @State private var problem: String?
    @FocusState private var writing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Button { done(false) } label: { Text("Cancel").font(V2Type.control()).foregroundStyle(palette.ink2) }
                    .buttonStyle(.plain)
                Spacer()
                Text("Post to your page").font(V2Type.serif(15, relativeTo: .subheadline))
                Spacer()
                Button { post() } label: { Text("Post").font(V2Type.control()).underline() }
                    .buttonStyle(.plain)
                    .disabled(working)
            }
            .frame(minHeight: 44)
            HStack(alignment: .top, spacing: 14) {
                V2Print(width: 96, date: photo.takenAt) { V2Image(path: photo.viewPath, maxPixel: 300) }
                TextField("A line for the back", text: $caption, axis: .vertical)
                    .font(V2Type.serif(17, italic: true, relativeTo: .body))
                    .lineLimit(1...4)
                    .focused($writing)
                    .submitLabel(.done)
            }
            Button { tagging = true } label: {
                Text(tags.isEmpty ? "Tag people" : (tags.count == 1 ? "1 person tagged" : "\(tags.count) people tagged"))
                    .font(V2Type.control())
                    .underline()
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            if let problem {
                Text(problem).font(V2Type.serif(14, italic: true, relativeTo: .footnote)).foregroundStyle(.red)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, V2Metrics.margin)
        .padding(.top, 12)
        .background { V2Desktop(palette: palette) }
        .foregroundStyle(palette.ink)
        .onAppear { writing = true }
        #if DEBUG
        .task {
            guard ProcessInfo.processInfo.arguments.contains("-v2OpenTag") else { return }
            try? await Task.sleep(for: .seconds(1))
            writing = false
            tagging = true
        }
        #endif
        .sheet(isPresented: $tagging) {
            V2TagSheet(photo: photo, tags: $tags)
                .modifier(V2DeskEnvironment())
        }
    }

    private func post() {
        guard let uid = auth.currentUser?.id, !working else { return }
        working = true
        problem = nil
        let line = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        // Marked at once, as the pager does, so the Darkroom shows it on your page on the way back.
        feed.myPostedPhotoIds.insert(photo.id)
        Task {
            do {
                _ = try await feed.createPost(photo: photo, caption: line.isEmpty ? nil : line, userId: uid, tags: tags)
                Haptics.success()
                done(true)
            } catch {
                feed.myPostedPhotoIds.remove(photo.id)
                Haptics.error()
                problem = "Couldn't post that. Try again."
                working = false
            }
        }
    }
}

/// Tag people (replaces the App Store tag sheet in FLIM Beta): who is in this print, chosen from
/// the people you follow, friends first. The roll's other members (or, for your own print,
/// whoever you tagged lately) sit in a row on top, one tap each. The choosing rules are the App
/// Store sheet's own (`QuickTagChips`, `personMatches`), so the two can't disagree on who shows.
struct V2TagSheet: View {
    let photo: Photo
    @Binding var tags: [PendingTag]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.v2Palette) private var palette
    @Environment(\.v2Stamp) private var stamp
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed
    @Environment(RollService.self) private var rolls

    @State private var following: [UserProfile] = []
    @State private var friendIds: Set<UUID> = []
    @State private var quickHeader: String?
    @State private var quick: [UserProfile] = []
    @State private var query = ""
    @State private var loaded = false

    private var results: [UserProfile] {
        following.filter { personMatches($0, query: query) }.sorted { a, b in
            let af = friendIds.contains(a.id), bf = friendIds.contains(b.id)
            if af != bf { return af }
            return (a.username ?? "") < (b.username ?? "")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Tag people").font(V2Type.serif(22, relativeTo: .title2)).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button { dismiss() } label: {
                    Text("Done").font(V2Type.control()).underline().frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 12) {
                V2PrintCard(width: 46, showsShadow: false, borderFraction: 3.0 / 46, footFraction: 8.0 / 46) {
                    V2Image(path: photo.thumbPath ?? photo.viewPath, maxPixel: 160)
                } foot: { Color.clear }
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                .accessibilityHidden(true)
                Text(tagSummary(handles: tags.map(\.user.handle)))
                    .font(V2Type.serif(15, italic: true, relativeTo: .body))
                    .foregroundStyle(tags.isEmpty ? palette.ink3 : palette.ink2)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.top, 10)
            if let quickHeader, !quick.isEmpty {
                Text(quickHeader)
                    .font(V2Type.data(10)).tracking(1.5).textCase(.uppercase)
                    .foregroundStyle(palette.ink3)
                    .padding(.top, 20)
                ScrollView(.horizontal) {
                    HStack(spacing: 14) {
                        ForEach(quick) { person in chip(person) }
                    }
                }
                .scrollIndicators(.hidden)
                .padding(.top, 8)
            }
            TextField("", text: $query,
                      prompt: Text("Search people you follow")
                        .font(V2Type.serif(16, italic: true, relativeTo: .body))
                        .foregroundStyle(palette.ink3))
                .font(V2Type.serif(16, relativeTo: .body))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .frame(minHeight: 44)
                .overlay(alignment: .bottom) { Rectangle().fill(palette.rule).frame(height: 1) }
                .padding(.top, 18)
            if loaded, results.isEmpty {
                Text(query.isEmpty ? "Follow people to tag them." : "No matches.")
                    .font(V2Type.serif(15, italic: true, relativeTo: .body))
                    .foregroundStyle(palette.ink3)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(results) { person in row(person) }
                    }
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .padding(.horizontal, V2Metrics.margin)
        .padding(.top, 18)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .background { V2Desktop(palette: palette) }
        .foregroundStyle(palette.ink)
        .presentationDetents([.large])
        .task { await load() }
    }

    private func isTagged(_ person: UserProfile) -> Bool { tags.contains { $0.user.id == person.id } }

    private func row(_ person: UserProfile) -> some View {
        let on = isTagged(person)
        return Button { toggle(person) } label: {
            HStack(spacing: 12) {
                AvatarView(path: person.avatarPath, name: person.username, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(person.name).font(.system(.subheadline))
                    Text(person.handle).font(V2Type.control(.caption)).foregroundStyle(palette.ink3)
                }
                Spacer(minLength: 8)
                if friendIds.contains(person.id) {
                    Text("friend").font(V2Type.serif(13, italic: true, relativeTo: .footnote)).foregroundStyle(palette.ink3)
                }
                mark(on)
            }
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) { Rectangle().fill(palette.rule).frame(height: 1) }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(person.name)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func chip(_ person: UserProfile) -> some View {
        let on = isTagged(person)
        return Button { toggle(person) } label: {
            VStack(spacing: 6) {
                AvatarView(path: person.avatarPath, name: person.username, size: 46)
                    .overlay { Circle().stroke(on ? stamp.color(on: palette.desk) : .clear, lineWidth: 2).padding(-3) }
                Text(person.username ?? person.name)
                    .font(V2Type.control(.caption2))
                    .lineLimit(1)
            }
            .frame(width: 62)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(person.name)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// A ring, filled with the stamp colour once tagged.
    private func mark(_ on: Bool) -> some View {
        Circle()
            .strokeBorder(on ? Color.clear : palette.ink3, lineWidth: 1.5)
            .background(Circle().fill(on ? stamp.color(on: palette.desk) : .clear))
            .overlay {
                if on {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(V2Color.print)
                }
            }
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
    }

    private func toggle(_ person: UserProfile) {
        Haptics.tap()
        if let i = tags.firstIndex(where: { $0.user.id == person.id }) {
            tags.remove(at: i)
        } else {
            // Names are listed, not placed, so a tag's position is the centre (as on the App Store sheet).
            tags.append(PendingTag(user: person, x: 0.5, y: 0.5))
        }
    }

    private func load() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-v2DemoTag") {
            let people = ["nadia", "gem", "dev.k", "noor", "mari"].map {
                UserProfile(id: UUID(), username: $0, createdAt: .now)
            }
            following = people
            friendIds = Set(people.prefix(4).map(\.id))
            quick = Array(people.prefix(3))
            quickHeader = "From Lake weekend"
            if tags.isEmpty { tags = [PendingTag(user: people[0], x: 0.5, y: 0.5)] }
            loaded = true
            return
        }
        #endif
        guard let me = auth.currentUser?.id else { return }
        await feed.loadBlocked(userId: me)
        async let followingRead = feed.fetchFollowingProfiles(of: me)
        async let followerRead = feed.fetchFollowers(of: me)
        let list = await followingRead
        let followers = Set((await followerRead).map(\.id))
        following = list.filter { !feed.isBlocked($0.id) }
        friendIds = followers.intersection(Set(list.map(\.id)))
        loaded = true

        let memberIds: [UUID]? = if let rollId = photo.rollId {
            (try? await rolls.fetchMemberIds(for: rollId)) ?? []
        } else { nil }
        let recent = photo.rollId == nil ? await feed.recentlyTaggedUserIds(by: me) : []
        let picked = QuickTagChips.selectedIds(
            from: QuickTagChips.candidateIds(rollMemberIds: memberIds, recentlyTaggedIds: recent),
            selfId: me, blockedIds: feed.blockedIds)
        guard !picked.isEmpty else { return }
        let profiles = await feed.fetchProfiles(ids: picked)
        quick = picked.compactMap { profiles[$0] }
        if let rollId = photo.rollId {
            if rolls.rolls.isEmpty { try? await rolls.fetchRolls(for: me) }
            quickHeader = "From \(rolls.rolls.first { $0.id == rollId }?.name ?? "this roll")"
        } else {
            quickHeader = "Recently tagged"
        }
    }
}
