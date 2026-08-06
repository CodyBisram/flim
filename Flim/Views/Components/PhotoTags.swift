import SwiftUI

/// How tall the "In this photo" sheet should be for `count` people.
///
/// Sized to its contents up to a cap, so one tagged friend gets a sheet the height of one row
/// instead of half the screen, and a group shot scrolls inside a sheet that still leaves the
/// photograph visible above it.
func taggedPeopleSheetHeight(count: Int, rowHeight: CGFloat = 60, headerHeight: CGFloat = 54,
                             maxRows: CGFloat = 4.5, padding: CGFloat = 16) -> CGFloat {
    let list = min(CGFloat(max(0, count)) * rowHeight, rowHeight * maxRows)
    return headerHeight + list + padding
}

/// Whether the "In this photo" sheet offers a Follow for someone.
///
/// One-directional by design: there is no "Following" state to tap. This sheet is opened to find
/// out who is in a photo, and a one-tap unfollow sitting under a name you just tapped to read is
/// a trap. Unfollowing lives on the profile, which the row opens.
func offersFollow(person: UUID, viewer: UUID?, isFollowing: Bool) -> Bool {
    person != viewer && !isFollowing
}

/// Overlay for a shared photo: a small tag indicator that opens an "In this photo" sheet listing
/// everyone tagged. Apply via `.overlay { }` on the photo.
///
/// The names used to be pinned as capsules at each person's (x, y) on the photograph itself. A
/// sheet replaced that for two reasons: a capsule sits on top of the thing you tapped the photo to
/// look at, and a photo with five people in it turns into a wall of overlapping labels with no
/// order to read them in. A list has room for a face and a real name next to each handle, and it
/// cannot cover the picture. Positions are still recorded when tagging, they just no longer decide
/// how the names are shown.
///
/// The indicator lives in the BOTTOM-left and never moves. It also fades out on its own after a
/// few seconds, so a photo worth looking at isn't permanently wearing a badge.
///
/// The full cycle, since it is easy to break one half while fixing the other: the indicator rests
/// for `fadeAfter`, fades over `fadeDuration`, and once faded a tap anywhere on the photo brings
/// it back over `returnDuration` and restarts the clock. Nothing about it is ever permanently gone.
struct PhotoTags: View {
    let tags: [PostTag]
    let profiles: [UUID: UserProfile]
    let onProfile: (UUID) -> Void

    @State private var showSheet = false
    /// The resting indicator fades itself out; any tap on the photo brings it back.
    @State private var indicatorVisible = true
    @State private var fadeTask: Task<Void, Never>?
    /// Set by a row tap and consumed once the sheet has closed. Opening a profile straight from
    /// the row would push it behind the sheet that is still on screen.
    @State private var pendingProfile: UUID?

    /// How long the indicator sits there before fading. Long enough to notice, short enough that
    /// it isn't part of the photo.
    private static let fadeAfter: Duration = .seconds(5)

    /// How long the fade itself takes.
    ///
    /// 1.6s, up from 0.5s. Half a second on a small element in a corner is below the threshold at
    /// which the eye reads a fade at all: it registers as the badge blinking out. A slow fade is
    /// legible as a deliberate retreat, and it also gives someone who was about to reach for it a
    /// moment to notice it going.
    private static let fadeDuration: TimeInterval = 1.6

    /// How long it takes to come back. Deliberately much faster than it leaves: a response to a
    /// tap has to feel immediate, while a self-initiated retreat should not.
    private static let returnDuration: TimeInterval = 0.28

    /// Tagged people we can actually name, in tag order. A tag whose profile hasn't loaded is
    /// dropped rather than shown as a blank row.
    private var people: [UserProfile] {
        tags.compactMap { profiles[$0.taggedUserId] }
    }

    var body: some View {
        if !tags.isEmpty {
            ZStack {
                // Indicator, tap to open the list.
                Button { openSheet() } label: {
                    Image(systemName: "person.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
                        // 26 + 9 either side = 44. The badge stays small on the photograph; only
                        // the touch area grows, into padding that was already empty.
                        .expandTapTarget(by: 9)
                }
                .opacity(indicatorVisible ? 1 : 0)
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .accessibilityLabel("Show tagged people")
                .accessibilityHidden(!indicatorVisible)

                // Once the indicator has faded, a tap ANYWHERE on the photo brings it back.
                //
                // It was technically still tappable in its own corner while invisible, which is
                // not a real affordance: nobody hunts for a 26pt target they cannot see, so in
                // practice a faded indicator was gone for good and the tags with it.
                //
                // Present only while faded, so it costs exactly one tap and only in the state
                // where the photo had nothing else to offer. Note the trade: in a host that opens
                // something on tap (post detail opens the viewer), that first tap revives the
                // indicator instead. That is the intended exchange, not an oversight, and it is
                // why this layer removes itself the moment it fires.
                if !indicatorVisible {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { scheduleFade() }
                        .accessibilityHidden(true)
                }
            }
            .onAppear { scheduleFade() }
            .onDisappear { fadeTask?.cancel() }
            .sheet(isPresented: $showSheet, onDismiss: {
                guard let id = pendingProfile else { return }
                pendingProfile = nil
                onProfile(id)
            }) {
                TaggedPeopleSheet(people: people) { id in
                    pendingProfile = id
                    showSheet = false
                }
            }
        }
    }

    private func openSheet() {
        fadeTask?.cancel()
        Haptics.tap()
        indicatorVisible = true      // so it's already there when the sheet closes again
        showSheet = true
        scheduleFade()
    }

    /// Fades the resting indicator out after a few seconds so it stops sitting on the photo.
    /// Cancelled and restarted rather than stacked, so re-showing never leaves an older timer
    /// running that would fade it early.
    private func scheduleFade() {
        fadeTask?.cancel()
        // Animated on the way back in too. This used to be a bare assignment, so an indicator
        // returning from a tap popped in while the one leaving faded, which read as two different
        // controls rather than one coming and going.
        if !indicatorVisible {
            Haptics.tap()
            withAnimation(.easeOut(duration: Self.returnDuration)) { indicatorVisible = true }
        } else {
            indicatorVisible = true
        }
        fadeTask = Task {
            try? await Task.sleep(for: Self.fadeAfter)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: Self.fadeDuration)) { indicatorVisible = false }
        }
    }
}

/// The list of people tagged in a photo, as a short sheet over the photo rather than a full screen
/// away from it.
///
/// It is sized to its contents up to a cap, so one tagged friend gets a sheet the height of one
/// row instead of half the screen, and a group shot scrolls inside a sheet that still leaves the
/// photograph visible above it.
private struct TaggedPeopleSheet: View {
    let people: [UserProfile]
    let onPick: (UUID) -> Void

    @Environment(\.flimAccent) private var accent
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed

    private static let rowHeight: CGFloat = 60
    private static let headerHeight: CGFloat = 54

    private var detentHeight: CGFloat {
        taggedPeopleSheetHeight(count: people.count,
                                rowHeight: Self.rowHeight, headerHeight: Self.headerHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("In this photo")
                .flimFont(16, weight: .semibold, relativeTo: .headline)
                .foregroundStyle(.white)
                .frame(height: Self.headerHeight)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(people) { person in
                        Button { onPick(person.id) } label: { row(person) }
                            .buttonStyle(.plain)
                    }
                }
            }
            // Bounce off when everything already fits, so a two-person sheet isn't springy for
            // no reason.
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(detentHeight)])
        .presentationDragIndicator(.visible)
        .presentationBackground(FlimTheme.bg)
        // `isFollowing` reads a set that only Activity and the profile screens populate, so
        // without this someone who opened the app straight to the feed would be offered Follow
        // for people they already follow. Same guard those screens use.
        .task {
            if feed.followingIds.isEmpty, let uid = auth.currentUser?.id {
                await feed.loadFollowing(userId: uid)
            }
        }
    }

    private func canFollow(_ person: UserProfile) -> Bool {
        offersFollow(person: person.id, viewer: auth.currentUser?.id,
                     isFollowing: feed.isFollowing(person.id))
    }

    /// The row is two controls, not one inside another: the name area opens the profile, the
    /// Follow button follows. A button nested in a button is a coin toss over which one a tap
    /// lands on.
    private func row(_ person: UserProfile) -> some View {
        HStack(spacing: 12) {
            Button { onPick(person.id) } label: {
                HStack(spacing: 12) {
                    AvatarView(path: person.avatarPath, name: person.username, size: 40)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(person.name)
                            .flimFont(15, weight: .semibold, relativeTo: .subheadline)
                            .foregroundStyle(.white)
                        Text(person.handle)
                            .flimFont(13, relativeTo: .footnote)
                            .foregroundStyle(FlimTheme.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens \(person.handle)'s profile")

            if canFollow(person) {
                followButton(person)
            } else {
                // Nothing, deliberately. The alternative is a "Following" button, and this sheet
                // is opened to find out who someone is, not to manage a relationship: a one-tap
                // unfollow sitting under a name you just tapped to read is a trap. Unfollowing
                // lives on the profile, which the row opens.
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FlimTheme.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: Self.rowHeight)
    }

    private func followButton(_ person: UserProfile) -> some View {
        Button {
            guard let uid = auth.currentUser?.id else { return }
            Haptics.tap()
            // The button disappears rather than changing state, because `isFollowing` flips
            // optimistically inside `follow` and this row re-reads it.
            Task { await feed.follow(person.id, from: uid) }
        } label: {
            Text("Follow")
                .flimFont(13, weight: .semibold, relativeTo: .subheadline)
                .foregroundStyle(.black)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(accent, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Follow \(person.handle)")
    }
}
