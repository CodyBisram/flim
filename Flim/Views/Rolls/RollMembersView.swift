import SwiftUI

struct RollMembersView: View {
    let roll: Roll
    @Environment(RollService.self) private var rollService
    @Environment(AuthService.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var members: [AppUser] = []
    @State private var isLoading = false
    @State private var codeCopied = false

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
                FlimTheme.bg.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Invite code banner
                    VStack(spacing: 6) {
                        Text("INVITE CODE")
                            .font(.system(size: 11, weight: .medium))
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
                                    .font(.system(size: 28, weight: .thin, design: .monospaced))
                                    .tracking(6)
                                    .foregroundStyle(.white)
                                Image(systemName: codeCopied ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 14))
                                    .foregroundStyle(codeCopied ? FlimTheme.accent : Color(white: 0.5))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .background(Color(white: 0.08))

                    if isLoading {
                        Spacer()
                        ProgressView().tint(.white)
                        Spacer()
                    } else {
                        List {
                            ForEach(members) { member in
                                HStack(spacing: 12) {
                                    Circle()
                                        .fill(Color(white: 0.15))
                                        .frame(width: 36, height: 36)
                                        .overlay(
                                            Text(String((member.username ?? "?").prefix(1)).uppercased())
                                                .font(.system(size: 14, weight: .medium))
                                                .foregroundStyle(Color(white: 0.7))
                                        )

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("@\(member.username ?? "unknown")")
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundStyle(.white)
                                        if member.id == roll.createdBy {
                                            Text("Creator")
                                                .font(.system(size: 11))
                                                .foregroundStyle(Color(white: 0.4))
                                        }
                                    }

                                    Spacer()

                                    if member.id == auth.currentUser?.id {
                                        Text("You")
                                            .font(.system(size: 12))
                                            .foregroundStyle(Color(white: 0.4))
                                    }
                                }
                                .padding(.vertical, 4)
                                .listRowBackground(Color(white: 0.08))
                                .listRowSeparatorTint(Color(white: 0.12))
                                .swipeActions(edge: .trailing) {
                                    // Creator can remove anyone but themselves; anyone else
                                    // can leave their own roll.
                                    if isCreator, member.id != roll.createdBy {
                                        Button(role: .destructive) {
                                            remove(member)
                                        } label: { Label("Remove", systemImage: "person.fill.xmark") }
                                    } else if member.id == auth.currentUser?.id, member.id != roll.createdBy {
                                        Button(role: .destructive) {
                                            remove(member, leaving: true)
                                        } label: { Label("Leave", systemImage: "rectangle.portrait.and.arrow.right") }
                                    }
                                }
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .flimInlineTitle("Members (\(members.count)/\(Roll.memberCap))")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(.white)
                }
            }
        }
        .presentationBackground(FlimTheme.bg)
        .task {
            isLoading = true
            members = (try? await rollService.fetchMembers(for: roll.id)) ?? []
            isLoading = false
        }
    }
}
