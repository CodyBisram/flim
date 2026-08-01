import SwiftUI

/// Whether an account is the FLIM owner's: the one account Film Lab (neutral capture, for LUT
/// calibration) stays visible to among TestFlight testers. Matches either the owner's email or
/// their username, case-insensitively, since a client could plausibly store either with
/// different casing than what's hardcoded here.
func isOwnerAccount(email: String?, username: String?) -> Bool {
    email?.lowercased() == "codyysb@gmail.com" || username?.lowercased() == "cody"
}

/// Settings, grouped into labeled sections. Deliberately NO profile-identity editing here:
/// that lives in `EditProfileView`, reached from the public profile itself (UserPageView), so you
/// edit your profile where you see it instead of inside a settings sheet layered on top of it.
/// The invite code likewise moved out to `InviteSheet` (surfaced on the profile). It's the
/// growth affordance, not a preference, and it doesn't belong buried between two toggles.
struct ProfileView: View {
    @Environment(AuthService.self) private var auth
    @Environment(PhotoService.self) private var photos
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    @State private var deleteError: String?
    @State private var showWipeConfirm = false
    @State private var showBlockedUsers = false

    @AppStorage(InstantFilmProcessor.neutralCaptureKey) private var neutralCapture = false
    @AppStorage("developNotificationsEnabled") private var notificationsEnabled = true
    @AppStorage("soundEffects") private var soundEffects = true
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @AppStorage("accentColor") private var accentColor = "amber"

    /// Film Lab is already TestFlight-only; restricted further to the owner's account
    /// specifically. An unexplained "skip the FLIM look" toggle in a beta tester's own Settings
    /// would just be confusing, not useful, and it exists purely for LUT calibration pairs.
    private var showsFilmLab: Bool {
        isOwnerAccount(email: auth.currentUser?.email, username: auth.currentUser?.username)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Develop reminders", isOn: $notificationsEnabled)
                        .tint(FlimTheme.accent)
                    Toggle("Sound effects", isOn: $soundEffects)
                        .tint(FlimTheme.accent)
                } header: { sectionHeader("Notifications & Sound") }
                .listRowBackground(FlimTheme.bgElevated)

                Section {
                    accentRow
                } header: { sectionHeader("Appearance") }

                Section {
                    linkRow("Blocked users", icon: "hand.raised.slash") { showBlockedUsers = true }
                    linkRow("Replay intro", icon: "play.circle") { hasOnboarded = false; dismiss() }
                } header: { sectionHeader("Account") }

                Section {
                    linkRow("Send feedback", icon: "envelope") {
                        if let url = AppInfo.feedbackMailURL { openURL(url) }
                    }
                    linkRow("Privacy Policy", icon: "hand.raised") { openURL(AppInfo.privacyPolicyURL) }
                    linkRow("Terms of Service", icon: "doc.text") { openURL(AppInfo.termsURL) }
                } header: { sectionHeader("Support & Legal") }

                // Film Lab: TestFlight-only (hidden on the public App Store), owner's account only.
                if !AppInfo.isAppStore && showsFilmLab {
                    Section {
                        Toggle(isOn: $neutralCapture) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Neutral capture").foregroundStyle(.white)
                                Text("Shots skip the FLIM look (LUT calibration)")
                                    .font(.system(size: 11)).foregroundStyle(FlimTheme.textTertiary)
                            }
                        }
                        .tint(FlimTheme.accent)
                    } header: { sectionHeader("Film Lab") }
                    .listRowBackground(FlimTheme.bgElevated)
                }

                // Test-only data reset. DEBUG builds only, so App Review never sees it.
                #if DEBUG
                Section {
                    Button(role: .destructive) { showWipeConfirm = true } label: {
                        Label("Wipe my test data", systemImage: "trash")
                    }
                }
                .listRowBackground(FlimTheme.bgElevated)
                #endif

                Section {
                    Button {
                        Task { try? await auth.signOut(); dismiss() }
                    } label: {
                        Text("Sign Out")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color(red: 1, green: 0.35, blue: 0.35))
                            .frame(maxWidth: .infinity)
                    }
                    Button { showDeleteConfirm = true } label: {
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
                    }
                    .disabled(isDeleting)
                } footer: {
                    Text("\(AppInfo.appName) \(AppInfo.versionString)")
                        .font(.system(size: 11))
                        .foregroundStyle(FlimTheme.textTertiary.opacity(0.7))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 8)
                }
                .listRowBackground(FlimTheme.bgElevated)
                // Sign Out and Delete Account are centered, different-weight actions. The
                // default inset row separator between them reads as a stray hairline rather than
                // a divider, so drop it and let the two sit as one danger block.
                .listRowSeparator(.hidden)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(FlimTheme.bg)
            .navigationBarTitleDisplayMode(.inline)
            .flimInlineTitle("Settings")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(.white)
                }
            }
            .sheet(isPresented: $showBlockedUsers) {
                BlockedUsersSheet()
            }
            .confirmationDialog("Delete your account?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete Everything", role: .destructive) {
                    Haptics.warning()
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
            .confirmationDialog("Wipe all your test data?", isPresented: $showWipeConfirm, titleVisibility: .visible) {
                Button("Wipe Everything", role: .destructive) {
                    guard let uid = auth.currentUser?.id else { return }
                    Haptics.warning()
                    Task { await photos.deleteAllMyData(userId: uid) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Deletes all your photos, thumbnails, avatar/cover, and posts from storage. Resets your egress baseline. Your account stays.")
            }
        }
        .presentationBackground(FlimTheme.bg)
        .presentationDetents([.large])
    }

    // MARK: - Rows

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .medium)).tracking(2)
            .foregroundStyle(FlimTheme.textTertiary)
    }

    private func linkRow(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(FlimTheme.accent)
                    .frame(width: 22)
                Text(title).font(.system(size: 15)).foregroundStyle(.white)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FlimTheme.textTertiary)
            }
        }
        .listRowBackground(FlimTheme.bgElevated)
    }

    private var accentRow: some View {
        HStack(spacing: 14) {
            ForEach(FlimAccent.allCases) { swatch in
                Button {
                    accentColor = swatch.rawValue
                    Haptics.tap()
                } label: {
                    Circle()
                        .fill(swatch.color)
                        .frame(width: 30, height: 30)
                        .overlay(Circle().strokeBorder(.white, lineWidth: accentColor == swatch.rawValue ? 2.5 : 0))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(swatch.label)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .listRowBackground(FlimTheme.bgElevated)
    }
}

// MARK: - Edit profile (identity)

/// Everything about your public identity, edited in one place, reached from your own profile
/// page (UserPageView) rather than from a settings sheet layered on top of it. Each field opens
/// its existing, validated editor sheet; avatar and cover use the shared photo picker.
struct EditProfileView: View {
    @Environment(AuthService.self) private var auth
    @Environment(PhotoService.self) private var photos
    @Environment(\.dismiss) private var dismiss

    @State private var avatarURL: URL?
    @State private var showEditName = false
    @State private var showEditUsername = false
    @State private var showEditBio = false
    @State private var showAvatarPicker = false
    @State private var showCoverPicker = false

    private var displayName: String? {
        let n = auth.currentUser?.displayName
        return (n?.isEmpty == false) ? n : nil
    }
    private var bio: String? {
        let b = auth.currentUser?.bio
        return (b?.isEmpty == false) ? b : nil
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FlimTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 24) {
                        avatarButton
                            .padding(.top, 12)

                        VStack(spacing: 0) {
                            editRow("Name", value: displayName ?? "Add your name",
                                    isPlaceholder: displayName == nil) { showEditName = true }
                            divider
                            editRow("Username", value: "@\(auth.currentUser?.username ?? "")",
                                    isPlaceholder: false) { showEditUsername = true }
                            divider
                            editRow("Bio", value: bio ?? "Add a bio…",
                                    isPlaceholder: bio == nil) { showEditBio = true }
                            divider
                            editRow("Cover photo", value: "Change", isPlaceholder: true) { showCoverPicker = true }
                        }
                        .background(FlimTheme.bgElevated, in: RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 20)

                        Spacer(minLength: 20)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .flimInlineTitle("Edit profile")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(.white)
                }
            }
            .sheet(isPresented: $showEditName) {
                EditNameSheet(current: auth.currentUser?.displayName ?? "")
            }
            .sheet(isPresented: $showEditUsername) {
                EditUsernameSheet(current: auth.currentUser?.username ?? "")
            }
            .sheet(isPresented: $showEditBio) {
                EditBioSheet(current: auth.currentUser?.bio ?? "")
            }
            .sheet(isPresented: $showAvatarPicker) {
                PhotoPickerSheet(title: "Profile Photo") { path in
                    Task { await auth.setAvatar(fromPhotoPath: path) }
                }
            }
            .sheet(isPresented: $showCoverPicker) {
                PhotoPickerSheet(title: "Cover Photo") { path in
                    Task { await auth.setCover(fromPhotoPath: path) }
                }
            }
            .task { await refreshAvatar() }
            .onChange(of: auth.currentUser?.avatarPath) { Task { await refreshAvatar() } }
        }
        .presentationBackground(FlimTheme.bg)
        .presentationDetents([.large])
    }

    private var avatarButton: some View {
        Button { showAvatarPicker = true } label: {
            Circle()
                .fill(FlimTheme.accent.opacity(0.18))
                .frame(width: 96, height: 96)
                .overlay {
                    if let avatarURL {
                        CachedImage(url: avatarURL, maxPixel: 220) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.clear
                        }
                    } else {
                        Text(String((auth.currentUser?.username ?? "?").prefix(1)).uppercased())
                            .font(.system(size: 34, weight: .thin))
                            .foregroundStyle(FlimTheme.accent)
                    }
                }
                .clipShape(Circle())
                .overlay(Circle().stroke(FlimTheme.accent.opacity(0.5), lineWidth: 1))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 12)).foregroundStyle(.black)
                        .padding(7).background(FlimTheme.accent, in: Circle())
                        .overlay(Circle().stroke(FlimTheme.bg, lineWidth: 2))
                }
        }
        .accessibilityLabel("Change profile photo")
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.leading, 20)
    }

    private func editRow(_ title: String, value: String, isPlaceholder: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 15)).foregroundStyle(.white)
                Spacer()
                Text(value)
                    .font(.system(size: 15))
                    .foregroundStyle(isPlaceholder ? FlimTheme.textTertiary : FlimTheme.textSecondary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FlimTheme.textTertiary)
            }
            .padding(.horizontal, 20).padding(.vertical, 15)
        }
        .buttonStyle(.plain)
    }

    private func refreshAvatar() async {
        if let path = auth.currentUser?.avatarPath {
            avatarURL = try? await photos.signedURL(for: path)
        } else {
            avatarURL = nil
        }
    }
}

// MARK: - Invite friends

/// The personal invite code: the growth affordance, surfaced from the profile rather than
/// buried in settings. Big code, copy, and a share sheet.
struct InviteSheet: View {
    @Environment(AuthService.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var codeCopied = false

    var body: some View {
        NavigationStack {
            ZStack {
                FlimTheme.bg.ignoresSafeArea()
                VStack(spacing: 20) {
                    Text("Share this code so friends can add you on \(AppInfo.appName).")
                        .font(.system(size: 14))
                        .foregroundStyle(FlimTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                        .padding(.top, 12)

                    HStack(spacing: 12) {
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

                        if let code = auth.currentUser?.inviteCode {
                            ShareLink(item: AppInfo.personalInviteMessage(code: code)) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundStyle(FlimTheme.textSecondary)
                                    .frame(width: 56, height: 56)
                                    .glassCard(cornerRadius: 14, interactive: true)
                            }
                            .simultaneousGesture(TapGesture().onEnded { Haptics.tap() })
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 24)
            }
            .navigationBarTitleDisplayMode(.inline)
            .flimInlineTitle("Invite friends")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(.white)
                }
            }
        }
        .presentationBackground(FlimTheme.bg)
        .presentationDetents([.medium])
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

// MARK: - Edit name

private struct EditNameSheet: View {
    @Environment(AuthService.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var isSaving = false

    init(current: String) { _name = State(initialValue: current) }

    var body: some View {
        NavigationStack {
            ZStack {
                FlimTheme.bg.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 12) {
                    Text("What should we call you?")
                        .font(.system(size: 13)).foregroundStyle(FlimTheme.textTertiary)
                    TextField("First name", text: $name)
                        .textContentType(.givenName)
                        .autocorrectionDisabled()
                        .font(.system(size: 17))
                        .foregroundStyle(.white)
                        .tint(.white)
                        .padding(16)
                        .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 12))
                    Spacer()
                }
                .padding(20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .flimInlineTitle("Name")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(.white)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        isSaving = true
                        Task { try? await auth.setDisplayName(String(name.prefix(40))); dismiss() }
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
