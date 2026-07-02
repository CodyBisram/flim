import SwiftUI

struct ProfileView: View {
    @Environment(AuthService.self) private var auth
    @Environment(RollService.self) private var rolls
    @Environment(PhotoService.self) private var photos
    @Environment(\.dismiss) private var dismiss

    @State private var photoCount = 0
    @State private var avatarURL: URL?
    @State private var showEditBio = false
    @State private var codeCopied = false
    @State private var showSignOutConfirm = false
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    @State private var deleteError: String?
    @State private var showEditUsername = false
    @AppStorage("developNotificationsEnabled") private var notificationsEnabled = true
    @AppStorage("hasOnboarded") private var hasOnboarded = false

    var body: some View {
        NavigationStack {
            ZStack {
                FlimTheme.bg.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Avatar + username + stats + bio
                    VStack(spacing: 12) {
                        Circle()
                            .fill(FlimTheme.accent.opacity(0.18))
                            .frame(width: 84, height: 84)
                            .overlay {
                                if let avatarURL {
                                    CachedImage(url: avatarURL, maxPixel: 200) { image in
                                        image.resizable().scaledToFill()
                                    } placeholder: {
                                        Color.clear
                                    }
                                } else {
                                    Text(String((auth.currentUser?.username ?? "?").prefix(1)).uppercased())
                                        .font(.system(size: 30, weight: .thin))
                                        .foregroundStyle(FlimTheme.accent)
                                }
                            }
                            .clipShape(Circle())
                            .overlay(Circle().stroke(FlimTheme.accent.opacity(0.5), lineWidth: 1))

                        Button {
                            showEditUsername = true
                        } label: {
                            HStack(spacing: 6) {
                                Text("@\(auth.currentUser?.username ?? "")")
                                    .font(.system(size: 20, weight: .thin))
                                    .foregroundStyle(.white)
                                Image(systemName: "pencil")
                                    .font(.system(size: 12))
                                    .foregroundStyle(FlimTheme.textTertiary)
                            }
                        }
                        .accessibilityLabel("Edit username")

                        statsRow

                        // Bio (tap to add/edit)
                        Button {
                            showEditBio = true
                        } label: {
                            Text((auth.currentUser?.bio?.isEmpty == false) ? auth.currentUser!.bio! : "Add a bio…")
                                .font(.system(size: 14))
                                .foregroundStyle((auth.currentUser?.bio?.isEmpty == false) ? FlimTheme.textSecondary : FlimTheme.textTertiary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)
                        }

                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)

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

                    // Develop reminders toggle
                    Toggle(isOn: $notificationsEnabled) {
                        Text("Develop reminders")
                            .font(.system(size: 15))
                            .foregroundStyle(.white)
                    }
                    .tint(FlimTheme.accent)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                    .background(FlimTheme.bgElevated)

                    // Replay the intro
                    Button {
                        hasOnboarded = false
                        dismiss()
                    } label: {
                        HStack {
                            Text("Replay intro").font(.system(size: 15)).foregroundStyle(.white)
                            Spacer()
                            Image(systemName: "play.circle").foregroundStyle(FlimTheme.textTertiary)
                        }
                        .padding(.horizontal, 28).padding(.vertical, 14)
                        .background(FlimTheme.bgElevated)
                    }

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
            .sheet(isPresented: $showEditUsername) {
                EditUsernameSheet(current: auth.currentUser?.username ?? "")
            }
            .sheet(isPresented: $showEditBio) {
                EditBioSheet(current: auth.currentUser?.bio ?? "")
            }
            .task {
                if let uid = auth.currentUser?.id {
                    photoCount = await photos.photoCount(userId: uid)
                    try? await rolls.fetchRolls(for: uid)
                }
                if let path = auth.currentUser?.avatarPath {
                    avatarURL = try? await photos.signedURL(for: path)
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

    private var statsRow: some View {
        HStack(spacing: 24) {
            stat("\(photoCount)", photoCount == 1 ? "shot" : "shots")
            stat("\(rolls.rolls.count)", rolls.rolls.count == 1 ? "roll" : "rolls")
            if let joined = auth.currentUser?.createdAt {
                stat(joined.formatted(.dateTime.month(.abbreviated).year()), "joined")
            }
        }
        .padding(.top, 4)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(FlimTheme.textTertiary)
        }
    }
}

// MARK: - Edit bio

private struct EditBioSheet: View {
    @Environment(AuthService.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var bio: String
    @State private var isSaving = false

    init(current: String) { _bio = State(initialValue: current) }

    var body: some View {
        NavigationStack {
            ZStack {
                FlimTheme.bg.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 12) {
                    TextField("A little about you…", text: $bio, axis: .vertical)
                        .lineLimit(1...4)
                        .font(.system(size: 17))
                        .foregroundStyle(.white)
                        .tint(.white)
                        .padding(16)
                        .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 12))
                    Text("\(bio.count)/140")
                        .font(.system(size: 12))
                        .foregroundStyle(FlimTheme.textTertiary)
                    Spacer()
                }
                .padding(20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .flimInlineTitle("Bio")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(.white)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        isSaving = true
                        Task { try? await auth.setBio(String(bio.prefix(140))); dismiss() }
                    }
                    .foregroundStyle(FlimTheme.accent)
                    .disabled(isSaving)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationBackground(FlimTheme.bg)
    }
}

// MARK: - Edit username

private struct EditUsernameSheet: View {
    @Environment(AuthService.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var username: String
    @State private var isSaving = false
    @State private var error: String?

    init(current: String) { _username = State(initialValue: current) }

    var body: some View {
        NavigationStack {
            ZStack {
                FlimTheme.bg.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 20) {
                    Text("USERNAME")
                        .font(.system(size: 11, weight: .medium))
                        .tracking(2)
                        .foregroundStyle(FlimTheme.textTertiary)
                        .padding(.top, 24)

                    HStack {
                        Text("@").foregroundStyle(FlimTheme.textTertiary)
                        TextField("", text: $username, prompt: Text("yourname").foregroundStyle(Color(white: 0.3)))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.system(size: 17))
                            .foregroundStyle(.white)
                            .tint(.white)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 12))

                    if let error {
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundStyle(Color(red: 1, green: 0.4, blue: 0.4))
                    }

                    Spacer()

                    PrimaryButton(title: "Save", isLoading: isSaving,
                                  disabled: !AuthService.isValidUsername(username)) {
                        await save()
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 32)
            }
            .navigationBarTitleDisplayMode(.inline)
            .flimInlineTitle("Edit username")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(.white)
                }
            }
        }
        .presentationBackground(FlimTheme.bg)
        .presentationDetents([.medium])
    }

    private func save() async {
        isSaving = true
        error = nil
        do {
            try await auth.setUsername(username.lowercased())
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        isSaving = false
    }
}
