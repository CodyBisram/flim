import SwiftUI

/// Everything FLIM Beta shows in place of the tab bar: v2's frame, Personal's camera, and the
/// Darkroom and Friends the caller builds (they live in the caller's navigation stacks, which the
/// app's routes push onto). `MainTabView` hands over here, so v2's screens change without touching
/// the App Store app's files.
///
/// It drives the same tab selection the tab bar does (`V2Place.tab`), so every route that picks a
/// tab lands in the matching place. A route to a print or a page covers the frame (`V2Route`),
/// as every v2 screen past the places does.
struct V2Home<Darkroom: View, Friends: View>: View {
    @Binding var selection: Int
    @Binding var route: V2Route?
    var rollsHaveUnwatched: Bool
    var onReselect: (V2Place) -> Void = { _ in }
    var openRolls: () -> Void
    @ViewBuilder var darkroom: () -> Darkroom
    @ViewBuilder var friends: () -> Friends

    @Environment(AuthService.self) private var auth
    @Environment(PhotoService.self) private var photos
    @Environment(\.scenePhase) private var scenePhase

    @State private var camera = V2Camera()
    @State private var unsortedCount: Int?
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @AppStorage(V2DeskChoice.askedKey) private var deskAsked = false

    /// The desk question, once, after onboarding.
    private var asksDesk: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-v2AskDesk") { return !deskAskedThisRun }
        #endif
        return hasOnboarded && !deskAsked
    }
    @State private var deskAskedThisRun = false

    var body: some View {
        #if DEBUG
        root.modifier(V2DemoFrame())
        #else
        root
        #endif
    }

    private var root: some View {
        V2RootView(
            place: Binding(get: { V2Place.forTab(selection) }, set: { selection = $0.tab }),
            onReselect: onReselect,
            darkroomCount: unsortedCount,
            content: { place, isShowing in
                switch place {
                case .personal:
                    // Built only on screen: the pager mounts its neighbours early, and the
                    // camera starts its session (and asks for access) when it appears.
                    // Leaving Personal removes it, which stops the session.
                    if isShowing {
                        V2PersonalPlace(camera: camera, rollsHaveUnwatched: rollsHaveUnwatched, openRolls: openRolls)
                    } else {
                        Color.clear
                    }
                case .darkroom: darkroom()
                case .friends: friends()
                }
            },
            columnFoot: { place in
                // Closed, Personal's shutter is the last thing in the column, Rolls above it
                // (board 15a). The other places have no action there yet.
                if place == .personal {
                    VStack(alignment: .trailing, spacing: 10) {
                        V2RollsButton(hasUnwatched: rollsHaveUnwatched, open: openRolls)
                        V2Shutter(camera: camera, diameter: 64)
                    }
                }
            }
        )
        .task(id: auth.currentUser?.id) { await refreshUnsorted() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refreshUnsorted() } }
        }
        .onChange(of: photos.pendingCaptureCount) { old, new in
            if new < old { Task { await refreshUnsorted() } }
        }
        .onChange(of: selection) { _, _ in Task { await refreshUnsorted() } }
        .fullScreenCover(item: $route) { route in
            NavigationStack {
                switch route {
                case .print(let item, let onBack):
                    V2GroupView(groups: [V2FeedGroup(author: item.author, items: [item])], index: 0,
                                startsOnBack: onBack, pushed: true) { self.route = nil }
                case .page(let page):
                    V2PageView(userId: page.id, openInvite: page.openInvite, close: { self.route = nil })
                }
            }
            .modifier(V2DeskEnvironment())
            .undoCapsuleHost()
            #if DEBUG
            .modifier(V2DemoFrame())
            #endif
        }
        .fullScreenCover(isPresented: Binding(get: { asksDesk }, set: { _ in })) {
            V2DeskChoice { deskAskedThisRun = true }
                #if DEBUG
                .modifier(V2DemoFrame())
                #endif
        }
    }

    private func refreshUnsorted() async {
        guard let uid = auth.currentUser?.id else { return }
        let epoch = AccountEpoch.current
        // A dropped read keeps the last count rather than flashing it away.
        guard let count = await photos.unsortedPhotoCount(userId: uid), AccountEpoch.isCurrent(epoch) else { return }
        unsortedCount = count
    }
}

/// A route that covers v2's frame: a print (on its back when the route was about its thread) or
/// someone's page.
enum V2Route: Identifiable {
    case print(FeedItem, onBack: Bool)
    case page(ProfileRoute)

    var id: String {
        switch self {
        case .print(let item, _): "print-\(item.id)"
        case .page(let page): "page-\(page.id)-\(page.openInvite)"
        }
    }
}
