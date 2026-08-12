import SwiftUI

/// The line under the thumbnail in the tag editor, naming who is on the photo so far.
///
/// Named handles up to two, then a count, because past two the names stop being scannable and the
/// number is the useful fact. Not em dashes anywhere, per the copy rule.
func tagSummary(handles: [String]) -> String {
    switch handles.count {
    case 0: "Nobody tagged yet"
    case 1: handles[0]
    case 2: "\(handles[0]) and \(handles[1])"
    default: "\(handles[0]), \(handles[1]) and \(handles.count - 2) more"
    }
}

/// "Tag People": pick anyone you follow, in one searchable list. Returns the tags via a binding.
///
/// This used to be the photo at a fixed 3:4 frame, where you tapped a spot to drop a tag and a
/// second sheet opened on top to choose the person. That was built when names were drawn as
/// capsules pinned at each tag's (x, y) on the photograph. Names are shown in a list now (see
/// `PhotoTags`), so placing them cost two taps and a nested sheet to record a position nothing
/// reads back. What is left is the actual question, which is who is in the photo.
///
/// The photo stays as a thumbnail: knowing which shot you are tagging is the one thing the old
/// screen gave you that a bare list would not.
struct TagPhotoSheet: View {
    @Environment(\.flimAccent) private var accent
    let url: URL?
    @Binding var tags: [PendingTag]
    /// The roll this photo belongs to, when known: drives the quick-tag row toward that roll's
    /// OTHER members instead of the personal-photo fallback. Nil for a personal photo, or for a
    /// caller (editing an already-shared photo's tags) that doesn't have this in hand, in which
    /// case the row falls back to recently-tagged people.
    var rollId: UUID? = nil
    /// Called when Done is tapped. The share composer leaves this empty (it persists the tags as
    /// part of creating the post); editing an already-shared photo uses it to save the changes.
    var onDone: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed
    @Environment(RollService.self) private var rollService

    /// Nil until `loadQuickTags` decides there's anything to show. Kept separate from
    /// `quickTagPeople.isEmpty` so "still loading" and "loaded, nobody to offer" both render
    /// nothing, rather than a header with no chips under it or a flash of an empty row.
    @State private var quickTagHeader: String?
    @State private var quickTagPeople: [UserProfile] = []

    /// Tags still carry a position because the column and the model still do, and a tag has to go
    /// somewhere. The centre is the honest value for "unplaced": nothing renders it, and if
    /// positional labels ever come back, a stack of tags in the middle is visibly unplaced rather
    /// than quietly wrong.
    private static let unplaced = (x: 0.5, y: 0.5)

    var body: some View {
        NavigationStack {
            ZStack {
                FlimTheme.bg.ignoresSafeArea()
                VStack(spacing: 0) {
                    photoHeader
                    if let quickTagHeader, !quickTagPeople.isEmpty {
                        quickTagRow(header: quickTagHeader)
                    }
                    FollowingList(emptyMessage: "Follow people to tag them.") { profile in
                        checkmark(for: profile)
                    } onSelect: { toggle($0) }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .flimInlineTitle("Tag People")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { onDone(); dismiss() }
                        .foregroundStyle(accent).fontWeight(.semibold)
                }
            }
        }
        .task { await loadQuickTags() }
    }

    /// Likely-next-tag chips, one tap each: a roll photo's OTHER members (regardless of the
    /// follow graph, since `FollowingList` below already covers that path), or, for a personal
    /// photo, whoever was tagged most recently on the caller's own posts. Horizontal scroll
    /// rather than wrap, so this stays one scannable line above the full list.
    private func quickTagRow(header: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(header.uppercased())
                .flimFont(11, weight: .medium, relativeTo: .caption)
                .tracking(1)
                .foregroundStyle(FlimTheme.textTertiary)
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(quickTagPeople) { profile in
                        quickTagChip(profile)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private func quickTagChip(_ profile: UserProfile) -> some View {
        let selected = tags.contains { $0.user.id == profile.id }
        return Button { toggle(profile) } label: {
            VStack(spacing: 6) {
                ZStack(alignment: .bottomTrailing) {
                    AvatarView(path: profile.avatarPath, name: profile.username, size: 50)
                        .overlay(Circle().stroke(selected ? accent : .clear, lineWidth: 2))
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(accent)
                            .background(Circle().fill(FlimTheme.bg))
                    }
                }
                Text(profile.username.map { "@\($0)" } ?? profile.name)
                    .flimFont(11, relativeTo: .caption2)
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .frame(width: 62)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(profile.name)\(selected ? ", tagged" : "")")
    }

    /// Picks the quick-tag row's source and resolves it to profiles. Renders nothing if it comes
    /// up empty, whether that's a personal photo nobody's ever been tagged on, or a roll with no
    /// one else in it: an empty header with no chips under it would read as broken furniture.
    private func loadQuickTags() async {
        guard let selfId = auth.currentUser?.id else { return }
        await feed.loadBlocked(userId: selfId)   // so a blocked party never shows up as a chip

        let rollMemberIds: [UUID]?
        if let rollId {
            rollMemberIds = (try? await rollService.fetchMemberIds(for: rollId)) ?? []
        } else {
            rollMemberIds = nil
        }
        let recentIds = rollId == nil ? await feed.recentlyTaggedUserIds(by: selfId) : []

        let candidates = QuickTagChips.candidateIds(rollMemberIds: rollMemberIds, recentlyTaggedIds: recentIds)
        let picked = QuickTagChips.selectedIds(from: candidates, selfId: selfId, blockedIds: feed.blockedIds)
        guard !picked.isEmpty else { return }

        let profiles = await feed.fetchProfiles(ids: picked)
        quickTagPeople = picked.compactMap { profiles[$0] }
        guard !quickTagPeople.isEmpty else { return }

        if let rollId {
            if rollService.rolls.isEmpty { try? await rollService.fetchRolls(for: selfId) }
            let name = rollService.rolls.first { $0.id == rollId }?.name
            quickTagHeader = "From \(name ?? "this roll")"
        } else {
            quickTagHeader = "Recently tagged"
        }
    }

    /// The shot being tagged, plus who is on it so far. Small enough to leave the list the whole
    /// screen, big enough to tell two shots from the same roll apart.
    private var photoHeader: some View {
        HStack(spacing: 12) {
            Group {
                if let url {
                    CachedImage(url: url, maxPixel: 200) { $0.resizable().scaledToFill() }
                        placeholder: { ShimmerPlaceholder(cornerRadius: 8) }
                } else {
                    ShimmerPlaceholder(cornerRadius: 8)
                }
            }
            .frame(width: 44, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(summary)
                .flimFont(14, relativeTo: .subheadline)
                .foregroundStyle(tags.isEmpty ? FlimTheme.textTertiary : .white)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.top, 12)
    }

    private var summary: String { tagSummary(handles: tags.map(\.user.handle)) }

    @ViewBuilder
    private func checkmark(for profile: UserProfile) -> some View {
        Image(systemName: tags.contains { $0.user.id == profile.id }
              ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 20))
            .foregroundStyle(tags.contains { $0.user.id == profile.id }
                             ? accent : FlimTheme.textTertiary)
    }

    private func toggle(_ profile: UserProfile) {
        Haptics.tap()
        if let existing = tags.firstIndex(where: { $0.user.id == profile.id }) {
            tags.remove(at: existing)
        } else {
            tags.append(PendingTag(user: profile, x: Self.unplaced.x, y: Self.unplaced.y))
        }
    }
}
