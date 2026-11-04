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
    @State private var tagURL: URL?
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
            Button {
                Task {
                    if tagURL == nil { tagURL = await feed.signedURL(for: photo.viewPath) }
                    tagging = true
                }
            } label: {
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
        .sheet(isPresented: $tagging) {
            TagPhotoSheet(url: tagURL, cacheKey: photo.viewPath, tags: $tags, rollId: photo.rollId)
                .preferredColorScheme(.dark)
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
