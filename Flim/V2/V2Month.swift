import SwiftUI

/// A boxed month, opened (prototype "September's box"; board 8b): the month by day, Play for its
/// screening, and on your own, Edit and "See it as friends do". Editing is the boxing card's two
/// gestures (product rule 4): tap a print to make it the cover, hold one to put it away (hold
/// again to bring it out). Nothing is deleted; put-away prints stay yours.
struct V2MonthView: View {
    let profileId: UUID
    let chapter: ChapterSummary
    let isSelf: Bool
    var close: () -> Void

    @Environment(\.v2Palette) private var palette
    @Environment(ChapterService.self) private var chapters

    @State private var photos: [ChapterPhoto] = []
    @State private var putAway: Set<UUID> = []
    @State private var cover: UUID?
    @State private var editing = false
    @State private var asFriends = false
    @State private var playing = false
    @State private var problem: String?
    @State private var loaded = false

    private var monthName: String { chapter.monthStart.formatted(.dateTime.month(.wide)) }

    /// What shows: everything to you, the out prints to friends (and to you, seeing it as they do).
    private var shown: [ChapterPhoto] {
        asFriends ? photos.filter { !isAway($0) } : photos
    }

    private func isAway(_ photo: ChapterPhoto) -> Bool { photo.postId.map(putAway.contains) ?? false }

    private var days: [(day: Date, photos: [ChapterPhoto])] {
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: shown) { calendar.startOfDay(for: $0.takenAt) }
        return byDay.keys.sorted(by: >).map { ($0, (byDay[$0] ?? []).sorted { $0.takenAt > $1.takenAt }) }
    }

    /// The chosen cover; without one, the first print still out (rule 4's default).
    private var coverId: UUID? {
        if let cover, photos.contains(where: { $0.id == cover && !isAway($0) }) { return cover }
        return photos.first { !isAway($0) }?.id
    }

    var body: some View {
        V2Screen(title: "\(monthName)'s box", onBack: close) {
            if isSelf {
                Button { withAnimation(V2Motion.setDown) { editing.toggle() } } label: {
                    Text(editing ? "Done" : "Edit").font(V2Type.control()).frame(minHeight: 44)
                }
                .buttonStyle(.plain)
            }
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(monthName)
                                .font(V2Type.serif(28, relativeTo: .largeTitle))
                            Text(summary)
                                .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
                                .foregroundStyle(palette.ink2)
                        }
                        Spacer(minLength: 8)
                        Button { playing = true } label: {
                            Text("Play \(monthName)")
                                .font(V2Type.control())
                                .foregroundStyle(palette.background)
                                .padding(.horizontal, 18)
                                .frame(minHeight: 40)
                                .background(palette.ink, in: RoundedRectangle(cornerRadius: V2Metrics.radius))
                        }
                        .buttonStyle(.plain)
                        .disabled(shown.isEmpty)
                    }
                    .padding(.top, 12)
                    if editing {
                        Text("Tap a print to make it the cover. Hold one to put it away; hold again to bring it out.")
                            .font(V2Type.serif(13, italic: true, relativeTo: .footnote))
                            .foregroundStyle(palette.ink3)
                            .padding(.top, 14)
                    }
                    if let problem {
                        Text(problem)
                            .font(V2Type.serif(13, italic: true, relativeTo: .footnote))
                            .foregroundStyle(Color.red)
                            .padding(.top, 10)
                    }
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(days, id: \.day) { day in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(day.day.formatted(.dateTime.weekday(.wide).day()))
                                    .font(V2Type.serif(13, italic: true, relativeTo: .footnote))
                                    .foregroundStyle(palette.ink3)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 112), spacing: 10, alignment: .leading)],
                                          alignment: .leading, spacing: 10) {
                                    ForEach(day.photos) { photo in print(photo) }
                                }
                            }
                        }
                    }
                    .padding(.top, 22)
                    if isSelf, loaded {
                        Text(asFriends ? "Friends see \(photos.count - awayCount) of \(photos.count). Put-away prints stay yours."
                                       : (awayCount == 0 ? "" : "\(awayCount) put away; only you see \(awayCount == 1 ? "it" : "them")."))
                            .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
                            .foregroundStyle(palette.ink2)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 30)
                        Button { withAnimation { asFriends.toggle() } } label: {
                            Text(asFriends ? "See it as you do" : "See it as friends do")
                                .font(V2Type.control()).underline().frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, V2Metrics.margin)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
        }
        .fullScreenCover(isPresented: $playing) {
            V2ScreeningView(source: .month(profileId: profileId, chapter: chapter), close: { playing = false })
        }
        .task { await load() }
    }

    private var awayCount: Int { photos.filter(isAway).count }

    private var summary: String {
        let n = shown.count
        let d = days.count
        return "\(n) \(n == 1 ? "print" : "prints") · \(d) \(d == 1 ? "day" : "days")"
    }

    private func print(_ photo: ChapterPhoto) -> some View {
        let away = isAway(photo)
        let isCover = photo.id == coverId
        return V2PrintCard(width: 104, borderFraction: 6.0 / 104, footFraction: 18.0 / 104) {
            V2Image(path: photo.displayPath, maxPixel: 240)
                .overlay {
                    if away {
                        V2Color.box.opacity(0.84)
                            .overlay {
                                Text("put away")
                                    .font(V2Type.serif(12, italic: true, relativeTo: .caption))
                                    .foregroundStyle(V2Color.printInk2)
                            }
                    }
                }
        } foot: {
            HStack {
                if isCover {
                    Text("cover")
                        .font(V2Type.data(7))
                        .tracking(1)
                        .foregroundStyle(V2Stamp.amber.paperColor)
                }
                Spacer(minLength: 0)
            }
        }
        .scaleEffect(editing && isCover ? 1.04 : 1)
        .onTapGesture { if editing { makeCover(photo) } }
        .onLongPressGesture(minimumDuration: 0.4) { if editing { toggleAway(photo) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Print from \(photo.takenAt.formatted(date: .abbreviated, time: .omitted))\(isCover ? ", cover" : "")\(away ? ", put away" : "")")
        .accessibilityActions {
            if editing {
                Button("Make it the cover") { makeCover(photo) }
                Button(away ? "Bring it out" : "Put it away") { toggleAway(photo) }
            }
        }
    }

    // MARK: Actions

    private func makeCover(_ photo: ChapterPhoto) {
        guard !isAway(photo), photo.id != coverId else { return }
        Haptics.tap()
        let before = cover
        withAnimation(V2Motion.setDown) { cover = photo.id }
        problem = nil
        Task {
            if !(await V2Server.setMonthCover(photo.id, user: profileId, monthStart: chapter.monthStart)) {
                withAnimation { cover = before }
                problem = "Couldn't save the cover. It's as it was."
            }
        }
    }

    /// Putting the cover away moves the cover to the next print that is out (rule 4), which
    /// `coverId` does by itself.
    private func toggleAway(_ photo: ChapterPhoto) {
        guard let postId = photo.postId else { return }
        Haptics.warning()
        let nowAway = !putAway.contains(postId)
        withAnimation(V2Motion.setDown) {
            if nowAway { putAway.insert(postId) } else { putAway.remove(postId) }
        }
        problem = nil
        Task {
            if !(await V2Server.setPutAway(nowAway, postId: postId)) {
                withAnimation {
                    if nowAway { putAway.remove(postId) } else { putAway.insert(postId) }
                }
                problem = "Couldn't save that. The print is as it was."
            }
        }
    }

    private func load() async {
        #if DEBUG
        // `-v2DemoMonthEdit`: opens in Edit with one print put away, for screenshots.
        if ProcessInfo.processInfo.arguments.contains("-v2DemoMonthEdit") { editing = true }
        #endif
        photos = await chapters.photos(for: profileId, monthStart: chapter.monthStart).sorted { $0.takenAt < $1.takenAt }
        #if DEBUG
        // The chapters fixture carries no posts; real chapter prints always do.
        if ProcessInfo.processInfo.arguments.contains("-v2DemoPage") {
            photos = photos.map { var p = $0; if p.postId == nil { p.postId = UUID() }; return p }
        }
        #endif
        if isSelf {
            async let away = V2Server.putAwayPostIds(photos.compactMap(\.postId))
            async let chosen = V2Server.monthCover(user: profileId, monthStart: chapter.monthStart)
            let (a, c) = await (away, chosen)
            if let a { putAway = a }
            cover = c
        }
        loaded = true
    }
}
