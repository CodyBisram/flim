import Photos
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
    @Environment(\.flimAccent) private var accent
    @Environment(AuthService.self) private var auth
    @Environment(PhotoService.self) private var photos
    @Environment(NotificationService.self) private var notifications
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @State private var showDeletePage = false
    @State private var showWipePage = false
    @State private var showBlockedUsers = false
    @State private var showFeedbackSheet = false
    /// Guards `requestAuthorizationIfNeeded()` against a double tap while the OS's one-shot
    /// prompt (or the settings read backing it) is still in flight.
    @State private var isRequestingNotifAuth = false

    /// Mirrors `CameraRollAutoSave.isEnabled(for:)`. Re-read in `onAppear` and on foreground
    /// (same precedent as the notification status row below), never bound straight to the store:
    /// turning it ON has to wait on an async Photos permission request first, and a plain
    /// `Binding` would flip the switch before that answer comes back.
    @State private var cameraRollAutoSaveEnabled = false
    /// Guards the toggle against a double tap while `PHPhotoLibrary.requestAuthorization` is in
    /// flight, same shape as `isRequestingNotifAuth`.
    @State private var isRequestingPhotosAuth = false
    /// True after iOS refused (or has revoked) add-only Photos access while the save toggle
    /// was being turned on: the toggle row explains itself inline with Open Settings beside
    /// it, instead of a modal (confirmations redesign rule 4). Cleared the moment a refresh
    /// sees access granted again.
    @State private var photosAccessBlocked = false

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
                    // `developNotificationsEnabled` is a preference layered ON TOP of the OS's own
                    // permission, not a substitute for it: the toggle only means anything once
                    // notifications are actually authorized, so this row surfaces that authorization
                    // as its own thing rather than letting the toggle silently lie about working.
                    switch notifications.authorizationState {
                    case .notDetermined:
                        notificationStatusRow(
                            title: "Notifications are off",
                            subtitle: "Turn them on to get develop reminders and reactions.",
                            icon: "bell.slash"
                        ) {
                            guard !isRequestingNotifAuth else { return }
                            isRequestingNotifAuth = true
                            Task {
                                await notifications.requestAuthorizationIfNeeded()
                                isRequestingNotifAuth = false
                            }
                        }
                        .disabled(isRequestingNotifAuth)
                    case .denied:
                        notificationStatusRow(
                            title: "Notifications are off in Settings",
                            subtitle: "Turn them on in iOS Settings to get develop reminders and reactions.",
                            icon: "bell.slash"
                        ) {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                    case .authorized:
                        EmptyView()
                    }
                    Toggle("Develop reminders", isOn: $notificationsEnabled)
                        .tint(accent)
                        .disabled(notifications.authorizationState != .authorized)
                    Toggle("Sound effects", isOn: $soundEffects)
                        .tint(accent)
                } header: { sectionHeader("Notifications & Sound") }
                .listRowBackground(FlimTheme.sheetRow)

                Section {
                    Toggle("Save developed shots", isOn: Binding(
                        get: { cameraRollAutoSaveEnabled },
                        set: { handleCameraRollAutoSaveToggle($0) }
                    ))
                    .tint(accent)
                    .disabled(auth.currentUser?.id == nil || isRequestingPhotosAuth)
                    if photosAccessBlocked {
                        HStack(spacing: 11) {
                            Text("iOS is holding this one. Photos access is off for \(AppInfo.appName).")
                                .flimFont(12, relativeTo: .caption)
                                .foregroundStyle(FlimTheme.textSecondary)
                            Spacer(minLength: 6)
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                            }
                            .flimFont(12.5, weight: .semibold, relativeTo: .caption)
                            .foregroundStyle(accent)
                        }
                    }
                } header: {
                    sectionHeader("Camera Roll")
                } footer: {
                    Text("Shots you keep are saved to your photo library. Shots from a roll save once you watch the reveal. Applies to shots you take from now on.")
                }
                .listRowBackground(FlimTheme.sheetRow)

                Section {
                    accentRow
                } header: { sectionHeader("Appearance") }

                Section {
                    linkRow("Blocked users", icon: "hand.raised.slash") { showBlockedUsers = true }
                    linkRow("Replay intro", icon: "play.circle") { hasOnboarded = false; dismiss() }
                } header: { sectionHeader("Account") }

                Section {
                    // Primary path: posts straight to the database, so a report is captured the
                    // moment Send is tapped. The mailto link below stays too, for people who'd
                    // rather write to a person, and because Apple expects a support contact.
                    linkRow("Send feedback", icon: "envelope") { showFeedbackSheet = true }
                    linkRow("Email us directly", icon: "paperplane") {
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
                                    .flimFont(11, relativeTo: .caption).foregroundStyle(FlimTheme.textTertiary)
                            }
                        }
                        .tint(accent)
                    } header: { sectionHeader("Film Lab") }
                    .listRowBackground(FlimTheme.sheetRow)
                }

                // Test-only data reset. DEBUG builds only, so App Review never sees it.
                #if DEBUG
                Section {
                    Button(role: .destructive) { showWipePage = true } label: {
                        Label("Wipe my test data", systemImage: "trash")
                    }
                }
                .listRowBackground(FlimTheme.sheetRow)
                #endif

                Section {
                    Button {
                        Task { try? await auth.signOut(); dismiss() }
                    } label: {
                        Text("Sign Out")
                            .flimFont(15, weight: .medium, relativeTo: .body)
                            .foregroundStyle(Color(red: 1, green: 0.35, blue: 0.35))
                            .frame(maxWidth: .infinity)
                    }
                    Button { showDeletePage = true } label: {
                        Text("Delete Account")
                            .flimFont(13, relativeTo: .subheadline)
                            .foregroundStyle(FlimTheme.textTertiary)
                            .frame(maxWidth: .infinity)
                    }
                } footer: {
                    // The build, then the signature under it. Smaller and fainter than the
                    // version on purpose: the version is the line you come here to read when
                    // something is wrong, and the signature is the one you find by accident.
                    VStack(spacing: 4) {
                        Text("\(AppInfo.appName) \(AppInfo.versionString)")
                            .flimFont(11, relativeTo: .caption)
                            .foregroundStyle(FlimTheme.textTertiary.opacity(0.7))
                        Text(AppInfo.colophon)
                            .flimFont(9.5, relativeTo: .caption2)
                            .foregroundStyle(FlimTheme.textTertiary.opacity(0.5))
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 8)
                }
                .listRowBackground(FlimTheme.sheetRow)
                // Sign Out and Delete Account are centered, different-weight actions. The
                // default inset row separator between them reads as a stray hairline rather than
                // a divider, so drop it and let the two sit as one danger block.
                .listRowSeparator(.hidden)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
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
            .sheet(isPresented: $showFeedbackSheet) {
                FeedbackSheet()
            }
            // Rule 3 (confirmations redesign): the irreversible-forever action gets a page
            // with a real inventory and a held confirm, never a sheet with a yes/no. The
            // debug wipe shares the page's shape; see `AccountDeleteView`.
            .navigationDestination(isPresented: $showDeletePage) {
                AccountDeleteView(mode: .deleteAccount)
            }
            .navigationDestination(isPresented: $showWipePage) {
                AccountDeleteView(mode: .wipeData)
            }
        }
        .task { await notifications.refreshAuthorizationState() }
        // Someone who leaves for iOS Settings to flip notifications on (or off) and comes back
        // must see the change here without relaunching; a settings READ never shows a system
        // dialog, so this is safe to run every time the app returns to the foreground.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await notifications.refreshAuthorizationState() }
            refreshCameraRollAutoSaveState()
        }
        .onAppear { refreshCameraRollAutoSaveState() }
        .flimSheetSurface()
        .presentationDetents([.large])
    }

    /// The toggle shows ON only when the preference is on AND Photos access is still granted:
    /// a revoke in iOS Settings otherwise leaves the switch lying ON forever over a sweep that
    /// silently no-ops. Rendering it OFF is the honest state, and tapping it back ON walks the
    /// normal request path, whose instant `.denied` answer re-offers the Open Settings alert;
    /// once access is restored the stored preference (never cleared by the revoke) shows through
    /// again on the next refresh without needing a re-tap.
    private func refreshCameraRollAutoSaveState() {
        guard let uid = auth.currentUser?.id else { cameraRollAutoSaveEnabled = false; return }
        let authorized = PHPhotoLibrary.authorizationStatus(for: .addOnly) == .authorized
        cameraRollAutoSaveEnabled = CameraRollAutoSave.shared.isEnabled(for: uid) && authorized
        // Access came back (someone went to Settings and returned): the inline explainer's
        // job is done.
        if authorized { photosAccessBlocked = false }
    }

    /// Turning the toggle OFF is immediate, no prompt. Turning it ON first asks iOS for
    /// add-only Photos permission (never granted implicitly), since the toggle means nothing
    /// without it; a denial reverts the switch and offers Settings instead of leaving it ON with
    /// nothing actually able to save.
    private func handleCameraRollAutoSaveToggle(_ newValue: Bool) {
        guard let uid = auth.currentUser?.id else { return }
        guard !isRequestingPhotosAuth else { return }

        guard newValue else {
            cameraRollAutoSaveEnabled = false
            CameraRollAutoSave.shared.setEnabled(false, for: uid)
            return
        }

        isRequestingPhotosAuth = true
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            isRequestingPhotosAuth = false
            switch status {
            case .authorized:
                cameraRollAutoSaveEnabled = true
                CameraRollAutoSave.shared.setEnabled(true, for: uid)
            default:
                cameraRollAutoSaveEnabled = false
                Haptics.error()
                withAnimation { photosAccessBlocked = true }
            }
        }
    }

    // MARK: - Rows

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .flimFont(11, weight: .medium, relativeTo: .caption).tracking(2)
            .foregroundStyle(FlimTheme.textTertiary)
    }

    /// A two-line explanatory row for the "not authorized yet" and "denied" notification states,
    /// each with its own recovery action (asking iOS, or opening Settings).
    private func notificationStatusRow(title: String, subtitle: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).flimFont(15, relativeTo: .body).foregroundStyle(.white)
                    Text(subtitle).flimFont(11, relativeTo: .caption).foregroundStyle(FlimTheme.textTertiary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FlimTheme.textTertiary)
            }
        }
    }

    private func linkRow(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(accent)
                    .frame(width: 22)
                Text(title).flimFont(15, relativeTo: .body).foregroundStyle(.white)
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
    @Environment(\.flimAccent) private var accent
    @Environment(AuthService.self) private var auth
    @Environment(PhotoService.self) private var photos
    @Environment(\.dismiss) private var dismiss

    @State private var avatarURL: URL?
    /// Surfaced when an avatar or cover change fails. Those calls return Bool precisely so this
    /// can be reported, and for a while nothing read the result.
    @State private var photoError: String?
    @State private var showEditName = false
    @State private var showEditUsername = false
    @State private var showEditBio = false
    @State private var showAvatarPicker = false
    @State private var showCoverPicker = false
    @State private var showBadgePicker = false

    private var displayName: String? {
        let n = auth.currentUser?.displayName
        return (n?.isEmpty == false) ? n : nil
    }
    private var bio: String? {
        let b = auth.currentUser?.bio
        return (b?.isEmpty == false) ? b : nil
    }

    /// Honest current-state copy for the badges row, mirroring the three states
    /// `displayed_badges` can actually be: see `AppUser.displayedBadges`.
    private var badgesSummary: String {
        switch auth.currentUser?.displayedBadges {
        case nil: return "Automatic"
        case .some(let ids) where ids.isEmpty: return "None shown"
        case .some(let ids): return "\(ids.count) chosen"
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
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
                            divider
                            editRow("Badges", value: badgesSummary,
                                    isPlaceholder: auth.currentUser?.displayedBadges == nil) { showBadgePicker = true }
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
                // Both sources go through the 1:1 cropper, so the user picks WHICH square of the
                // photo becomes their avatar. Without it the downscaler centre-cropped, and a
                // face that wasn't dead centre came out as a shoulder.
                PhotoPickerSheet(title: "Profile Photo") { _ in } onPickCropped: { data in
                    Task {
                        // The picker dismisses either way, so silence here looks exactly like
                        // success: you pick a new photo, the sheet closes, and your old one is
                        // still there with no explanation.
                        if await !auth.setAvatar(fromImageData: data) {
                            photoError = "Couldn't update your profile photo. Check your connection and try again."
                        }
                    }
                }
            }
            .sheet(isPresented: $showBadgePicker) {
                BadgePickerSheet()
            }
            .sheet(isPresented: $showCoverPicker) {
                PhotoPickerSheet(title: "Cover Photo") { path in
                    Task {
                        if await !auth.setCover(fromPhotoPath: path) {
                            photoError = "Couldn't update your cover photo. Check your connection and try again."
                        }
                    }
                } onPickLibraryImage: { data in
                    Task {
                        if await !auth.setCover(fromImageData: data) {
                            photoError = "Couldn't update your cover photo. Check your connection and try again."
                        }
                    }
                }
            }
            // Rule 4 (confirmations redesign): a failed avatar/cover save is a banner over
            // the screen where retrying is one tap away (the picker is right there), never a
            // modal whose only button admits it.
            .overlay(alignment: .top) {
                if let photoError {
                    Label(photoError, systemImage: "exclamationmark.triangle.fill")
                        .flimFont(13, weight: .medium).foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 6).padding(.horizontal, 16)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.25), value: photoError)
            .onChange(of: photoError) { _, error in
                guard error != nil else { return }
                Task {
                    try? await Task.sleep(for: .seconds(2.6))
                    withAnimation { photoError = nil }
                }
            }
            .task { await refreshAvatar() }
            .onChange(of: auth.currentUser?.avatarPath) { Task { await refreshAvatar() } }
        }
        .flimSheetSurface()
        .presentationDetents([.large])
    }

    private var avatarButton: some View {
        Button { showAvatarPicker = true } label: {
            Circle()
                .fill(accent.opacity(0.18))
                .frame(width: 96, height: 96)
                .overlay {
                    if let avatarURL {
                        CachedImage(url: avatarURL, maxPixel: 220, cacheKey: auth.currentUser?.avatarPath) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.clear
                        }
                    } else {
                        Text(String((auth.currentUser?.username ?? "?").prefix(1)).uppercased())
                            .flimFont(34, weight: .thin, relativeTo: .title3)
                            .foregroundStyle(accent)
                    }
                }
                .clipShape(Circle())
                .overlay(Circle().stroke(accent.opacity(0.5), lineWidth: 1))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 12)).foregroundStyle(.black)
                        .padding(7).background(accent, in: Circle())
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
                Text(title).flimFont(15, relativeTo: .body).foregroundStyle(.white)
                Spacer()
                Text(value)
                    .flimFont(15, relativeTo: .body)
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
    @Environment(\.flimAccent) private var accent
    @Environment(AuthService.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var codeCopied = false
    /// Starts `.unknown`, which renders no count at all. See `AuthService.ownInviteQuota`.
    @State private var quota: AuthService.InviteQuota = .unknown

    /// Whether the code can still let anyone in. `.unknown` and `.unlimited` both count as yes:
    /// never hide a working code because a lookup failed.
    private var codeStillWorks: Bool {
        if case .remaining(0) = quota { return false }
        return true
    }

    /// The scarcity, said plainly and only when it is actually known.
    ///
    /// Never says "roll". FLIM already ships a Share invite on the Rolls screen that means invite
    /// someone to a ROLL, so "invites left on this roll" would name a different, real feature.
    ///
    /// Nothing here promises more invites arrive later. Earning one back is a separate piece that
    /// is not built, and copy that implies a refill nobody has written would be a lie with a
    /// delivery date.
    @ViewBuilder
    private var quotaLine: some View {
        switch quota {
        case .remaining(let left) where left > 0:
            Text(left == 1 ? "1 invite left" : "\(left) invites left")
                .flimFont(13, weight: .semibold, relativeTo: .footnote)
                .foregroundStyle(accent)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(accent.opacity(0.12), in: Capsule())
        case .remaining:
            Text("No invites left")
                .flimFont(13, weight: .semibold, relativeTo: .footnote)
                .foregroundStyle(FlimTheme.textTertiary)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Color.white.opacity(0.08), in: Capsule())
        // Unlimited says nothing rather than boasting, and unknown must never render a number:
        // "0 invites left" for someone whose lookup merely failed is a lie in the worst direction.
        case .unlimited, .unknown:
            EmptyView()
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                VStack(spacing: 20) {
                    Text(codeStillWorks
                         ? "Share this code so friends can add you on \(AppInfo.appName)."
                         : "Your code will not let anyone else in.")
                        .flimFont(14, relativeTo: .subheadline)
                        .foregroundStyle(FlimTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                        .padding(.top, 12)

                    quotaLine

                    if codeStillWorks {
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
                                    .flimFont(32, weight: .thin, design: .monospaced, relativeTo: .title)
                                    .tracking(8)
                                    .foregroundStyle(.white)
                                Image(systemName: codeCopied ? "checkmark.circle.fill" : "doc.on.doc")
                                    .font(.system(size: 18))
                                    .foregroundStyle(codeCopied ? accent : FlimTheme.textSecondary)
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
                    }
                    Spacer()
                }
                .padding(.horizontal, 24)
                .task { quota = await auth.ownInviteQuota() }
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
        .flimSheetSurface()
        .presentationDetents([.medium])
    }
}

// MARK: - Edit bio

private struct EditBioSheet: View {
    @Environment(\.flimAccent) private var accent
    @State private var saveError: String?
    @Environment(AuthService.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var bio: String
    @State private var isSaving = false

    init(current: String) { _bio = State(initialValue: current) }

    var body: some View {
        NavigationStack {
            ZStack {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("A little about you…", text: $bio, axis: .vertical)
                        .lineLimit(1...4)
                        .flimFont(17, relativeTo: .body)
                        .foregroundStyle(.white)
                        .tint(.white)
                        .padding(16)
                        .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 12))
                    Text("\(bio.count)/140")
                        .flimFont(12, relativeTo: .caption)
                        .foregroundStyle(FlimTheme.textTertiary)
                    if let saveError {
                        Text(saveError)
                            .flimFont(13, relativeTo: .subheadline)
                            .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.42))
                    }
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
                        Task {
                            do {
                                try await auth.setBio(String(bio.prefix(140)))
                                dismiss()
                            } catch {
                                // Dismissing on failure told people the edit saved when it had not.
                                saveError = "Couldn't save that. Check your connection and try again."
                                isSaving = false
                            }
                        }
                    }
                    .foregroundStyle(accent)
                    .disabled(isSaving)
                }
            }
        }
        .presentationDetents([.medium])
        .flimSheetSurface()
    }
}

// MARK: - Edit name

private struct EditNameSheet: View {
    @Environment(\.flimAccent) private var accent
    @State private var saveError: String?
    @Environment(AuthService.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var isSaving = false

    init(current: String) { _name = State(initialValue: current) }

    var body: some View {
        NavigationStack {
            ZStack {
                VStack(alignment: .leading, spacing: 12) {
                    Text("What should we call you?")
                        .flimFont(13, relativeTo: .subheadline).foregroundStyle(FlimTheme.textTertiary)
                    TextField("First name", text: $name)
                        .textContentType(.givenName)
                        .autocorrectionDisabled()
                        .flimFont(17, relativeTo: .body)
                        .foregroundStyle(.white)
                        .tint(.white)
                        .padding(16)
                        .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 12))
                    if let saveError {
                        Text(saveError)
                            .flimFont(13, relativeTo: .subheadline)
                            .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.42))
                    }
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
                        Task {
                            do {
                                try await auth.setDisplayName(String(name.prefix(40)))
                                dismiss()
                            } catch {
                                // Dismissing on failure told people the edit saved when it had not.
                                saveError = "Couldn't save that. Check your connection and try again."
                                isSaving = false
                            }
                        }
                    }
                    .foregroundStyle(accent)
                    .disabled(isSaving)
                }
            }
        }
        .presentationDetents([.medium])
        .flimSheetSurface()
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
                VStack(alignment: .leading, spacing: 20) {
                    Text("USERNAME")
                        .flimFont(11, weight: .medium, relativeTo: .caption)
                        .tracking(2)
                        .foregroundStyle(FlimTheme.textTertiary)
                        .padding(.top, 24)

                    HStack {
                        Text("@").foregroundStyle(FlimTheme.textTertiary)
                        TextField("", text: $username, prompt: Text("yourname").foregroundStyle(Color(white: 0.3)))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .flimFont(17, relativeTo: .body)
                            .foregroundStyle(.white)
                            .tint(.white)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 12))

                    // Same live reason the SIGN-UP screen gives. That fix never made it here, so
                    // changing your username later left Save greyed out saying nothing, which is
                    // the exact defect ("apple-review" disabled Continue in silence) that
                    // usernameRejection was written for.
                    if let reason = AuthService.usernameRejection(username), error == nil {
                        Text(reason)
                            .flimFont(13, relativeTo: .subheadline)
                            .foregroundStyle(FlimTheme.textSecondary)
                    }

                    if let error {
                        Text(error)
                            .flimFont(13, relativeTo: .subheadline)
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
        .flimSheetSurface()
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
