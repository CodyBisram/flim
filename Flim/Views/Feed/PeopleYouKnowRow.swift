import SwiftUI

/// Three people you know but do not follow, with the reason and a Follow button, for a feed
/// that is thin because you follow almost nobody.
///
/// Fourteen of the fifty people who opened FLIM in the week of 2026-09-10 followed fewer than
/// three accounts, and posts have been readable by followers since the 13th, so their feed is
/// one or two people's days. This is not a strangers rail: it draws from the same signals as
/// Find friends (follows you, in your rolls, invited you, invited by the same person, friends of
/// friends), never from "newest accounts", and it disappears the moment you follow three
/// people. The rule that decides whether it shows is `shouldShow`, pure and tested.
struct PeopleYouKnowRow: View {
    @Environment(\.flimAccent) private var accent
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed
    /// Opens Find friends, for "See all".
    let onSeeAll: () -> Void

    @State private var people: [(profile: UserProfile, reason: String)] = []
    @State private var loaded = false

    static let followThreshold = 3
    static let shownCount = 3

    /// Show only for a thin feed, and only with people who carry a reason.
    static func shouldShow(followingCount: Int, candidates: Int) -> Bool {
        followingCount < followThreshold && candidates > 0
    }

    /// The first `shownCount` people across the sections that say why, skipping "New on FLIM":
    /// a newcomer with no signal is not someone you know.
    static func pick(_ sections: [FeedService.DiscoverSection], limit: Int = shownCount) -> [(profile: UserProfile, reason: String)] {
        var out: [(profile: UserProfile, reason: String)] = []
        for section in sections where section.title != "New on FLIM" {
            for profile in section.profiles where !out.contains(where: { $0.profile.id == profile.id }) {
                out.append((profile, section.title))
                if out.count == limit { return out }
            }
        }
        return out
    }

    private var visible: Bool {
        Self.shouldShow(followingCount: feed.followingIds.count, candidates: people.count)
    }

    var body: some View {
        Group {
            if loaded, visible {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("People you know")
                            .flimFont(13, weight: .semibold, relativeTo: .footnote)
                            .foregroundStyle(FlimTheme.textSecondary)
                        Spacer()
                        Button("See all", action: onSeeAll)
                            .flimFont(13, relativeTo: .footnote)
                            .foregroundStyle(accent)
                            .frame(minHeight: 44)
                    }
                    ForEach(people, id: \.profile.id) { entry in
                        HStack(spacing: 12) {
                            AvatarView(path: entry.profile.avatarPath, name: entry.profile.username, size: 36)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.profile.displayName?.isEmpty == false ? entry.profile.displayName! : entry.profile.handle)
                                    .flimFont(14, weight: .medium, relativeTo: .subheadline)
                                    .foregroundStyle(FlimTheme.textPrimary)
                                    .lineLimit(1)
                                Text(entry.reason)
                                    .flimFont(12, relativeTo: .caption)
                                    .foregroundStyle(FlimTheme.textTertiary)
                            }
                            Spacer(minLength: 8)
                            FollowButton(userId: entry.profile.id)
                        }
                        .frame(minHeight: 44)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .transition(.opacity)
            }
        }
        .task {
            guard let uid = auth.currentUser?.id, feed.followingIds.count < Self.followThreshold else { loaded = true; return }
            await feed.loadFollowers(userId: uid)
            let sections = await feed.discoverSections(excluding: uid)
            people = Self.pick(sections)
            loaded = true
        }
        .animation(.easeOut(duration: 0.3), value: visible)
    }
}
