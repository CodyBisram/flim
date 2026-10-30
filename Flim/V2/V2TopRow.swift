import SwiftUI

/// You, Find and Activity: the top row on the phone and the open display, the top of the trailing
/// column on the closed one. Find and Activity are words, not glyphs ("text is the control");
/// Activity carries the red dot when something is new (owner, 2026-10-02: every "new" dot is red).
/// Open, the place names sit in the middle of the same line (`middle`, board 15d).
///
/// Activity shares its watermark with the Feed's bell (`ActivitySeenMark`), so reading it in
/// either place clears both.
struct V2TopRow<Middle: View>: View {
    @ViewBuilder var middle: () -> Middle

    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed
    @Environment(\.v2Palette) private var palette
    @Environment(\.v2LayoutMode) private var mode
    @Environment(\.scenePhase) private var scenePhase

    @State private var showPage = false
    @State private var showFind = false
    @State private var showActivity = false
    @State private var unreadActivity = 0
    /// The watermark before this visit, so Activity can put what is newer under "New".
    @State private var activitySeenBefore: Date?

    var body: some View {
        Group {
            switch mode {
            case .outer:
                VStack(alignment: .trailing, spacing: 0) {
                    you
                    find
                    activity
                }
            case .phone:
                HStack(spacing: 16) {
                    you
                    Spacer(minLength: 8)
                    find
                    activity
                }
            case .inner:
                HStack(spacing: 16) {
                    you
                    Spacer(minLength: 8)
                    middle()
                    Spacer(minLength: 8)
                    find
                    activity
                }
            }
        }
        .fullScreenCover(isPresented: $showPage) {
            if let uid = pageUserId {
                NavigationStack { V2PageView(userId: uid) }
                    .modifier(V2DeskEnvironment())
                    .undoCapsuleHost()
                    #if DEBUG
                    .modifier(V2DemoFrame())
                    #endif
            }
        }
        .fullScreenCover(isPresented: $showFind) {
            V2FindView { showFind = false }
                .modifier(V2DeskEnvironment())
                .undoCapsuleHost()
                #if DEBUG
                .modifier(V2DemoFrame())
                #endif
        }
        .fullScreenCover(isPresented: $showActivity) {
            V2ActivityView(seenBefore: activitySeenBefore, onLoaded: { queriedAt in
                // Never backwards, the same rule as the Feed's bell.
                let uid = auth.currentUser?.id
                ActivitySeenMark.set(max(ActivitySeenMark.value(userId: uid), queriedAt.timeIntervalSince1970),
                                     userId: uid)
                unreadActivity = 0
            }, close: { showActivity = false })
                .modifier(V2DeskEnvironment())
                .undoCapsuleHost()
                #if DEBUG
                .modifier(V2DemoFrame())
                #endif
        }
        #if DEBUG
        // `-v2OpenActivity` / `-v2OpenFind` / `-v2OpenPage`: opens one at launch, for screenshots.
        .task {
            let args = ProcessInfo.processInfo.arguments
            guard args.contains("-v2OpenActivity") || args.contains("-v2OpenFind") || args.contains("-v2OpenPage") || args.contains("-v2OpenAppearance") else { return }
            try? await Task.sleep(for: .seconds(1.2))
            if args.contains("-v2OpenActivity") { showActivity = true }
            else if args.contains("-v2OpenPage") || args.contains("-v2OpenAppearance") { showPage = true }
            else { showFind = true }
        }
        #endif
        .task(id: auth.currentUser?.id) { await refreshUnread() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refreshUnread() } }
        }
        .onChange(of: showActivity) { _, open in
            if !open { Task { await refreshUnread() } }
        }
    }

    /// Whose page "You" opens: yours. With `-v2DemoPage` and no account, a stand-in, for screenshots.
    private var pageUserId: UUID? {
        #if DEBUG
        if auth.currentUser == nil, ProcessInfo.processInfo.arguments.contains("-v2DemoPage") {
            return UUID(uuidString: "00000000-0000-0000-0000-00000000C0DE")
        }
        #endif
        return auth.currentUser?.id
    }

    private var you: some View {
        Button { showPage = true } label: {
            HStack(spacing: 8) {
                AvatarView(path: auth.currentUser?.avatarPath, name: auth.currentUser?.username, size: 26)
                    .accessibilityHidden(true)
                Text(auth.currentUser?.username ?? "You")
                    .font(V2Type.serif(14, relativeTo: .subheadline))
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(minHeight: mode == .outer ? 36 : 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Your page")
    }

    private var find: some View {
        Button { showFind = true } label: {
            word("Find")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Find friends")
    }

    private var activity: some View {
        Button {
            let mark = ActivitySeenMark.value(userId: auth.currentUser?.id)
            activitySeenBefore = mark > 0 ? Date(timeIntervalSince1970: mark) : nil
            showActivity = true
        } label: {
            word("Activity")
                .overlay(alignment: .topTrailing) {
                    if unreadActivity > 0 {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 6, height: 6)
                            .offset(x: 8, y: 11)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Activity")
        .accessibilityValue(unreadActivity > 0 ? "\(unreadActivity) new" : "")
        .animation(V2Motion.setDown, value: unreadActivity > 0)
    }

    /// 12/600 on the phone (prototype), 13 in the column, ink 2.
    private func word(_ text: String) -> some View {
        Text(text)
            .font(V2Type.control(mode == .phone ? .caption : .footnote))
            .foregroundStyle(palette.ink2)
            .frame(minHeight: mode == .outer ? 32 : 44)
            .contentShape(Rectangle())
    }

    private func refreshUnread() async {
        guard let uid = auth.currentUser?.id else { return }
        let epoch = AccountEpoch.current
        let mark = ActivitySeenMark.value(userId: uid)
        let count = await feed.unreadActivityCount(userId: uid, since: Date(timeIntervalSince1970: mark))
        // Activity opened during the round trip moved the mark; this answer is older than that.
        guard AccountEpoch.isCurrent(epoch), ActivitySeenMark.value(userId: uid) == mark else { return }
        unreadActivity = count
    }
}

extension V2TopRow where Middle == EmptyView {
    init() { self.init(middle: { EmptyView() }) }
}
