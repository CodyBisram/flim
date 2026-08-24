import SwiftUI

struct RollMembersView: View {
    @Environment(\.flimAccent) private var accent
    @State private var profileRoute: ProfileRoute?
    let roll: Roll
    @Environment(RollService.self) private var rollService
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed
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

    private var isCreator: Bool { auth.currentUser?.id == roll.createdBy }

    private func remove(_ member: AppUser, leaving: Bool = false) {
        Task {
            try? await rollService.removeMember(rollId: roll.id, userId: member.id)
            if leaving {
                dismiss()
            } else {
                members.removeAll { $0.id == member.id }
            }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                VStack(spacing: 0) {
                    // Invite code banner
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
                        .confirmationDialog("Remove @\(memberToRemove?.username ?? "this person")?",
                                            isPresented: Binding(get: { memberToRemove != nil },
                                                                 set: { if !$0 { memberToRemove = nil } }),
                                            titleVisibility: .visible) {
                            Button("Remove", role: .destructive) {
                                if let member = memberToRemove { remove(member) }
                                memberToRemove = nil
                            }
                            Button("Cancel", role: .cancel) { memberToRemove = nil }
                        } message: {
                            Text("They'll lose access to this roll. Their own photos stay in their Darkroom.")
                        }
                        .confirmationDialog("Leave this roll?", isPresented: $confirmLeave,
                                            titleVisibility: .visible) {
                            Button("Leave Roll", role: .destructive) {
                                // Resolved from the loaded list rather than captured at swipe
                                // time, so this cannot act on a stale row.
                                if let me = members.first(where: { $0.id == auth.currentUser?.id }) {
                                    remove(me, leaving: true)
                                }
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("You'll stop seeing this roll. Your own photos stay in your Darkroom.")
                        }
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
