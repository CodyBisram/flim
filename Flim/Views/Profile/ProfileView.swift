import SwiftUI

struct ProfileView: View {
    @Environment(AuthService.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var codeCopied = false
    @State private var showSignOutConfirm = false
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    @State private var deleteError: String?

    var body: some View {
        NavigationStack {
            ZStack {
                FlimTheme.bg.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Avatar + username
                    VStack(spacing: 12) {
                        Circle()
                            .fill(FlimTheme.accent.opacity(0.18))
                            .frame(width: 72, height: 72)
                            .overlay(Circle().stroke(FlimTheme.accent.opacity(0.5), lineWidth: 1))
                            .overlay(
                                Text(String((auth.currentUser?.username ?? "?").prefix(1)).uppercased())
                                    .font(.system(size: 28, weight: .thin))
                                    .foregroundStyle(FlimTheme.accent)
                            )

                        Text("@\(auth.currentUser?.username ?? "")")
                            .font(.system(size: 20, weight: .thin))
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)

                    Divider().background(FlimTheme.stroke)

                    // Personal invite code
                    VStack(spacing: 8) {
                        Text("YOUR INVITE CODE")
                            .font(.system(size: 11, weight: .medium))
                            .tracking(2)
                            .foregroundStyle(FlimTheme.textTertiary)

                        Button {
                            UIPasteboard.general.string = auth.currentUser?.inviteCode
                            withAnimation { codeCopied = true }
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                withAnimation { codeCopied = false }
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Text(auth.currentUser?.inviteCode ?? "------")
                                    .font(.system(size: 32, weight: .thin, design: .monospaced))
                                    .tracking(8)
                                    .foregroundStyle(.white)

                                Image(systemName: codeCopied ? "checkmark.circle.fill" : "doc.on.doc")
                                    .font(.system(size: 18))
                                    .foregroundStyle(codeCopied ? FlimTheme.accent : FlimTheme.textSecondary)
                            }
                            .padding(.vertical, 20)
                            .padding(.horizontal, 24)
                            .glassCard(cornerRadius: 14, interactive: true)
                        }

                        Text("Share this code so friends can add you on FLIM.")
                            .font(.system(size: 12))
                            .foregroundStyle(FlimTheme.textTertiary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 28)

                    Spacer()

                    VStack(spacing: 12) {
                        // Sign out
                        Button(role: .destructive) {
                            showSignOutConfirm = true
                        } label: {
                            Text("Sign Out")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Color(red: 1, green: 0.35, blue: 0.35))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .glassCard(cornerRadius: 12, interactive: true)
                        }

                        // Delete account (App Store requirement)
                        Button {
                            showDeleteConfirm = true
                        } label: {
                            Group {
                                if isDeleting {
                                    ProgressView().tint(FlimTheme.textSecondary)
                                } else {
                                    Text("Delete Account")
                                        .font(.system(size: 13))
                                        .foregroundStyle(FlimTheme.textTertiary)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                        }
                        .disabled(isDeleting)
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 36)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .flimInlineTitle("Profile")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(.white)
                }
            }
            .confirmationDialog("Sign out?", isPresented: $showSignOutConfirm, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) {
                    Task {
                        try? await auth.signOut()
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Delete your account?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete Everything", role: .destructive) {
                    isDeleting = true
                    Task {
                        do {
                            try await auth.deleteAccount()
                            dismiss()
                        } catch {
                            deleteError = error.localizedDescription
                            isDeleting = false
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently deletes your account, photos, and rolls. This can't be undone.")
            }
            .alert("Couldn't delete account", isPresented: .constant(deleteError != nil)) {
                Button("OK") { deleteError = nil }
            } message: {
                Text(deleteError ?? "")
            }
        }
        .presentationBackground(FlimTheme.bg)
        .presentationDetents([.large])
    }
}
