import SwiftUI

struct RollMembersView: View {
    @Environment(\.flimAccent) private var accent
    @State private var profileRoute: ProfileRoute?
    let roll: Roll
    @Environment(RollService.self) private var rollService
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed
    @Environment(NotificationService.self) private var notifications
    @Environment(\.dismiss) private var dismiss

    @State private var members: [AppUser] = []
    @State private var isLoading = false
    @State private var codeCopied = false
    @State private var loadError: String?
    /// Staged rather than immediate. Every other leave-a-roll path in the app confirms first
    /// (RollsView and RollDetailView both use a confirmationDialog that states what is lost);
    /// this screen removed people on a single swipe and tap, with no warning and no statement of
    /// the consequence. Worse for Remove, where the person being removed is not the one tapping.
    @State private var memberToRemove: AppUser?
    @State private var confirmLeave = false
    /// The sheet's one top-slot toast, same shape as RollsView/RollDetailView's: a failed leave
    /// or remove must say so and leave the row retryable, not just close as if it worked.
    @State private var toastMessage: String?
    @State private var toastDismiss: Task<Void, Never>?

    private var isCreator: Bool { auth.currentUser?.id == roll.createdBy }

    private func showToast(_ message: String) {
        withAnimation { toastMessage = message }
        toastDismiss?.cancel()
        toastDismiss = Task {
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            withAnimation { toastMessage = nil }
        }
    }

    /// The current user leaving the roll. Goes through `RollService.leaveRoll` (not a bare
    /// `removeMember`) so a success also drops the roll from `rolls`/`memberCounts`/`coverPaths`,
    /// ends its Live Activity and refreshes the widget the way every other leave path does.
    /// Dismisses this sheet only once the server confirms it: a failed leave must not read as a
    /// successful one.
    private func leave(_ member: AppUser) {
        guard let uid = auth.currentUser?.id else { return }
        Task {
            do {
                try await rollService.leaveRoll(rollId: roll.id, userId: uid)
                notifications.cancelRollDevelopNotification(rollId: roll.id)
                dismiss()
            } catch {
                Haptics.error()
                showToast("Couldn't leave the roll. Check your connection and try again.")
            }
        }
    }

    /// Creator-initiated removal of someone else. Removed from the list optimistically so the
    /// swipe reads as immediate, restored on failure so a rejected removal doesn't silently show
    /// the person gone while the server still lists them.
    private func removeMember(_ member: AppUser) {
        guard let index = members.firstIndex(where: { $0.id == member.id }) else { return }
        let removed = members.remove(at: index)
        Task {
            do {
                try await rollService.removeMember(rollId: roll.id, userId: member.id)
                rollService.recordMemberRemoved(rollId: roll.id)
            } catch {
                members.insert(removed, at: min(index, members.count))
                Haptics.error()
                showToast("Couldn't remove @\(member.username ?? "this person"). Check your connection and try again.")
            }
        }
    }

    private var inviteCodeBanner: some View {
        VStack(spacing: 6) {
            Text("INVITE CODE")
                .flimFont(11, weight: .medium, relativeTo: .caption)
                .tracking(2)
                .foregroundStyle(Color(white: 0.4))
            Button {
                UIPasteboard.general.string = roll.inviteCode
                withAnimation { codeCopied = true }
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation { codeCopied = false }
                }
            } label: {
                HStack(spacing: 10) {
                    Text(roll.inviteCode)
                        .flimFont(28, weight: .thin, design: .monospaced, relativeTo: .title2)
                        .tracking(6)
                        .foregroundStyle(.white)
                    Image(systemName: codeCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 14))
                        .foregroundStyle(codeCopied ? accent : Color(white: 0.5))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(FlimTheme.sheetRow)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                VStack(spacing: 0) {
                    // Invite code banner. Gone once the roll develops, same rule as the roll
                    // screen's share-invite button (owner decision, 2026-08-26): invites are
                    // for a group still forming, not a finished roll.
                    if !roll.isDeveloped {
                        inviteCodeBanner
                    }

                    if isLoading {
                        Spacer()
                        ProgressView().tint(.white)
                        Spacer()
                    } else if let error = loadError {
                        Spacer()
                        ErrorState(message: error) { await load() }
                        Spacer()
                    } else {
                        List {
                            ForEach(members) { member in
                                // roll_members stays fully readable server-side (so the "x/cap"
                                // count is accurate), but a blocked co-member's identity is
                                // omitted from the roster, no name, no avatar initial.
                                let isBlocked = feed.isBlocked(member.id)
                                HStack(spacing: 12) {
                                    if isBlocked {
                                        // A blocked co-member's identity stays omitted: no name,
                                        // no avatar, just the blocked glyph.
                                        Circle()
                                            .fill(Color(white: 0.15))
                                            .frame(width: 36, height: 36)
                                            .overlay(Image(systemName: "hand.raised.slash")
                                                .font(.system(size: 13))
                                                .foregroundStyle(Color(white: 0.4)))
                                    } else {
                                        AvatarView(path: member.avatarPath, name: member.username, size: 36)
                                    }

                                    VStack(alignment: .leading, spacing: 2) {
                                        // Tappable, like the other eight surfaces that render a
                                        // handle. This was the only one that refused, and it is
                                        // the screen where someone joining a friend's roll looks
                                        // up the strangers in it. A blocked row stays inert.
                                        Button {
                                            guard !isBlocked else { return }
                                            profileRoute = ProfileRoute(id: member.id)
                                        } label: {
                                            Text(isBlocked ? "Blocked user" : "@\(member.username ?? "unknown")")
                                                .flimFont(15, weight: .medium, relativeTo: .body)
                                                .foregroundStyle(isBlocked ? Color(white: 0.45) : .white)
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(isBlocked)
                                        if member.id == roll.createdBy {
                                            Text("Creator")
                                                .flimFont(11, relativeTo: .caption)
                                                .foregroundStyle(Color(white: 0.4))
                                        }
                                    }

                                    Spacer()

                                    if member.id == auth.currentUser?.id {
                                        Text("You")
                                            .flimFont(12, relativeTo: .caption)
                                            .foregroundStyle(Color(white: 0.4))
                                    }
                                }
                                .padding(.vertical, 4)
                                .listRowBackground(FlimTheme.sheetRow)
                                .listRowSeparatorTint(Color(white: 0.12))
                                .swipeActions(edge: .trailing) {
                                    // Creator can remove anyone but themselves; anyone else
                                    // can leave their own roll.
                                    if isCreator, member.id != roll.createdBy {
                                        Button(role: .destructive) {
                                            memberToRemove = member
                                        } label: { Label("Remove", systemImage: "person.fill.xmark") }
                                    } else if member.id == auth.currentUser?.id, member.id != roll.createdBy {
                                        Button(role: .destructive) {
                                            confirmLeave = true
                                        } label: { Label("Leave", systemImage: "rectangle.portrait.and.arrow.right") }
                                    }
                                }
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        // Both consequence sheets share `RollConsequence`'s copy with every
                        // other screen that asks (see that type: three screens used to ship
                        // three different leave messages).
                        .sheet(item: $memberToRemove) { member in
                            ConsequenceSheet(consequence: .removeMember(
                                handle: "@\(member.username ?? "this person")",
                                rollName: roll.name, theirShots: nil)) {
                                removeMember(member)
                            }
                        }
                        .sheet(isPresented: $confirmLeave) {
                            ConsequenceSheet(consequence: .leave(name: roll.name, myShots: nil)) {
                                // Resolved from the loaded list rather than captured at swipe
                                // time, so this cannot act on a stale row.
                                if let me = members.first(where: { $0.id == auth.currentUser?.id }) {
                                    leave(me)
                                }
                            }
                        }
                    }
                }
                .overlay(alignment: .top) {
                    if let toastMessage {
                        Label(toastMessage, systemImage: "exclamationmark.triangle.fill")
                            .flimFont(13.5, weight: .medium, relativeTo: .subheadline)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: Capsule())
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
            }
            // Pushed into this sheet's own stack, so it arrives with a back button. Presenting it
            // as a further sheet made UserPageView the root of a new stack, and a root generates
            // no back button, which left the ••• menu as the only control on the screen.
            .navigationDestination(item: $profileRoute) { UserPageView(userId: $0.id) }
        .navigationBarTitleDisplayMode(.inline)
            .flimInlineTitle("Members (\(members.count)/\(Roll.memberCap))")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(.white)
                }
            }
        }
        .flimSheetSurface()
        .task { await load() }
    }

    /// Fetches the roster, surfacing a real error + retry instead of a silently-empty list
    /// when the fetch fails (network, RLS, etc.), matches RollsView's load pattern.
    private func load() async {
        isLoading = true
        loadError = nil
        if let uid = auth.currentUser?.id { await feed.loadBlocked(userId: uid) }
        do {
            members = try await rollService.fetchMembers(for: roll.id)
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}
