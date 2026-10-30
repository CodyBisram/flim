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
        .fullScreenCover(item: $viewing) { viewing in
            PhotoPagerView(photos: kept, startIndex: viewing.index, signedURLs: [:], onDelete: {
                Task { await reload() }
            })
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
