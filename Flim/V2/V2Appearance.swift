import Photos
import SwiftUI

/// What Appearance writes. The stamp is the App Store app's accent (`accentColor`): the same six
/// names with the same bright values, so the date burned into exports, the widget and every stamp
/// in v2 follow one choice.
enum V2Settings {
    static let stampKey = "accentColor"
    static let grainKey = "v2Grain"
    static let leakKey = "v2Leak"
    static let developKey = "v2Develop"
}

/// How long a print takes to develop the first time it is seen (handoff 2, "Develop").
enum V2DevelopMode: String, CaseIterable {
    case follow, always, quick

    var title: String {
        switch self {
        case .follow: "Follows Reduce Motion"
        case .always: "Always"
        case .quick: "Quick"
        }
    }

    func seconds(reduceMotion: Bool) -> Double {
        switch self {
        case .always: V2Motion.developSeconds
        case .quick: V2Motion.developSecondsReduced
        case .follow: reduceMotion ? V2Motion.developSecondsReduced : V2Motion.developSeconds
        }
    }
}

/// Appearance (board 4c, 16-1l, 16-1m; prototype): the desk, the stamp colour, the grain and the
/// camera's light leak, and how prints develop. Account and the rest of the settings sit under it.
struct V2AppearanceView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.v2Palette) private var palette
    @Environment(AuthService.self) private var auth
    @AppStorage(V2Desk.storageKey) private var deskRaw = V2Desk.system.rawValue
    @AppStorage(V2Settings.stampKey) private var stampRaw = V2Stamp.amber.rawValue
    @AppStorage(V2Settings.grainKey) private var grain = true
    @AppStorage(V2Settings.leakKey) private var leak = true
    @AppStorage(V2Settings.developKey) private var developRaw = V2DevelopMode.follow.rawValue
    @State private var showAccount = false

    private var stamp: V2Stamp { V2Stamp(rawValue: stampRaw) ?? .amber }

    var body: some View {
        GeometryReader { proxy in
            let mode = V2LayoutMode.resolve(horizontalSizeClass: sizeClass, proxy: proxy)
            Group {
                switch mode {
                case .phone:
                    VStack(spacing: 0) {
                        header.padding(.horizontal, V2Metrics.margin)
                        ScrollView { settings.padding(.horizontal, V2Metrics.margin) }
                        footnote.padding(.bottom, 16)
                    }
                case .outer:
                    // Settings have no main action, so the column holds Back alone (16-1l).
                    HStack(spacing: 0) {
                        ScrollView {
                            VStack(alignment: .leading) {
                                settings
                                footnote.padding(.top, 30)
                            }
                            .padding(.horizontal, V2Metrics.margin)
                            .padding(.vertical, 12)
                        }
                        VStack { backButton; Spacer() }
                            .padding(.vertical, 12)
                            .padding(.trailing, 14)
                            .frame(width: V2RootMetrics.columnWidth, alignment: .trailing)
                    }
                case .inner:
                    // Settings on the left, a live desk on the right (16-1m).
                    VStack(spacing: 0) {
                        header.padding(.horizontal, V2Metrics.margin)
                        HStack(spacing: 0) {
                            ScrollView {
                                VStack(alignment: .leading) {
                                    settings
                                    footnote.padding(.top, 30)
                                }
                                .padding(V2Metrics.margin)
                            }
                            .frame(maxWidth: .infinity)
                            preview
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            }
            .environment(\.v2LayoutMode, mode)
        }
        .background { V2Desktop(palette: palette) }
        .foregroundStyle(palette.ink)
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $showAccount) { V2AccountView() }
        #if DEBUG
        // `-v2OpenAccount` (with `-v2OpenAppearance`): on to Account, for screenshots.
        .task {
            guard ProcessInfo.processInfo.arguments.contains("-v2OpenAccount") else { return }
            try? await Task.sleep(for: .seconds(0.6))
            showAccount = true
        }
        #endif
    }

    private var header: some View {
        HStack {
            backButton
            Spacer(minLength: 8)
            Text("Appearance").font(V2Type.serif(15, relativeTo: .subheadline))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            backButton.hidden()
        }
    }

    private var backButton: some View {
        Button { dismiss() } label: {
            Text("Back").font(V2Type.control()).frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footnote: some View {
        Text("Prints are always cream. That part isn't a setting.")
            .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
            .foregroundStyle(palette.ink3)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    // MARK: Settings

    private var settings: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Desk").padding(.top, 14)
            HStack(spacing: 12) {
                deskSwatch(.paper)
                deskSwatch(.slate)
                deskSwatch(.system)
            }
            .padding(.top, 14)

            title("Stamp colour").padding(.top, 34)
            HStack(spacing: 14) {
                ForEach(V2Stamp.allCases, id: \.self) { option in
                    Button {
                        stampRaw = option.rawValue
                        Haptics.tap()
                        // The row too: a profile load lets the server's stamp win (`AccentSync`),
                        // so a choice kept only on the phone would come back as the old one.
                        Task { try? await auth.setAccent(option.rawValue) }
                    } label: {
                        Circle()
                            .fill(palette.isDark ? option.bright : option.paperColor)
                            .frame(width: 34, height: 34)
                            .overlay {
                                if option == stamp {
                                    Circle().stroke(palette.ink, lineWidth: 1.5).padding(-5)
                                }
                            }
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option.rawValue.capitalized)
                    .accessibilityAddTraits(option == stamp ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 8)
            HStack {
                Text("Burned into every print you take. Friends see it too.")
                    .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
                    .foregroundStyle(palette.ink3)
                Spacer(minLength: 8)
                V2DateStamp(text: BrandedExport.dateText(.init(date: .now)), cellHeight: 9, stamp: stamp)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(V2Color.rgb(0x151210))
                    .accessibilityHidden(true)
            }
            .padding(.top, 6)

            title("Dust and light").padding(.top, 34)
            VStack(spacing: 14) {
                toggleRow("Grain on the desk", value: grain) { grain.toggle() }
                toggleRow("Light leak in the camera", value: leak) { leak.toggle() }
                row("Develop animation", value: (V2DevelopMode(rawValue: developRaw) ?? .follow).title) {
                    let all = V2DevelopMode.allCases
                    let current = all.firstIndex(of: V2DevelopMode(rawValue: developRaw) ?? .follow) ?? 0
                    developRaw = all[(current + 1) % all.count].rawValue
                    Haptics.tap()
                }
                row("Account", value: "") { showAccount = true }
            }
            .padding(.top, 14)
        }
    }

    private func title(_ text: String) -> some View {
        Text(text).font(V2Type.serif(22, relativeTo: .title2)).accessibilityAddTraits(.isHeader)
    }

    private func deskSwatch(_ desk: V2Desk) -> some View {
        let selected = (V2Desk(rawValue: deskRaw) ?? .system) == desk
        return Button { deskRaw = desk.rawValue; Haptics.tap() } label: {
            ZStack(alignment: .bottom) {
                switch desk {
                case .paper: V2Color.rgb(0xF3E7DC)
                case .slate: V2Color.rgb(0x1C1917)
                case .system:
                    LinearGradient(stops: [.init(color: V2Color.rgb(0xF3E7DC), location: 0.5),
                                           .init(color: V2Color.rgb(0x1C1917), location: 0.5)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
                if desk != .system {
                    V2PrintCard(width: 52, showsShadow: false, borderFraction: 4.0 / 52, footFraction: 16.0 / 52) {
                        LinearGradient(colors: [V2Color.rgb(0xE9A05A), V2Color.rgb(0x5E3A2A)], startPoint: .top, endPoint: .bottom)
                    } foot: { Color.clear }
                    .shadow(color: .black.opacity(desk == .slate ? 0.5 : 0.16), radius: 3, y: 2)
                    .rotationEffect(.degrees(desk == .paper ? -3 : 3))
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 16)
                }
                Text(desk == .paper ? "Paper" : desk == .slate ? "Slate" : "System")
                    .font(V2Type.control(.caption))
                    .foregroundStyle(desk == .paper ? V2Color.printInk : V2Color.rgb(0xF3E7DC))
                    .shadow(color: desk == .system ? V2Color.rgb(0x1C1917) : .clear, radius: 3)
                    .padding(.bottom, 10)
            }
            .frame(height: 130)
            .frame(maxWidth: .infinity)
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            .overlay { if selected { Rectangle().stroke(palette.ink, lineWidth: 1.5).padding(-3) } }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(desk == .paper ? "Paper" : desk == .slate ? "Slate" : "System")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func toggleRow(_ label: String, value: Bool, toggle: @escaping () -> Void) -> some View {
        row(label, value: value ? "On" : "Off") { toggle(); Haptics.tap() }
            .accessibilityValue(value ? "On" : "Off")
    }

    private func row(_ label: String, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label).font(.system(.subheadline))
                Spacer()
                Text(value).font(V2Type.control(.subheadline)).foregroundStyle(palette.ink2)
            }
            .padding(.bottom, 12)
            .overlay(alignment: .bottom) { Rectangle().fill(palette.rule).frame(height: 1) }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Open: two loose prints on the chosen desk, with the chosen stamp (16-1m).
    private var preview: some View {
        ZStack {
            V2Desktop(palette: palette)
            ZStack {
                V2PrintCard(width: 150, tilt: .degrees(-4)) {
                    LinearGradient(colors: [V2Color.rgb(0x2E2620), V2Color.rgb(0x151210)], startPoint: .top, endPoint: .bottom)
                        .overlay(alignment: .bottomTrailing) {
                            V2DateStamp(text: BrandedExport.dateText(.init(date: .now)), cellHeight: 6, stamp: stamp)
                                .padding(8)
                        }
                } foot: { Color.clear }
                .offset(x: -40, y: -20)
                V2PrintCard(width: 150, tilt: .degrees(6)) {
                    LinearGradient(colors: [V2Color.rgb(0xE9A05A), V2Color.rgb(0x5E3A2A)], startPoint: .top, endPoint: .bottom)
                } foot: { Color.clear }
                .offset(x: 50, y: 30)
            }
            Text("Your desk, as it will look")
                .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
                .foregroundStyle(palette.ink2)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 24)
        }
        .accessibilityHidden(true)
    }
}

/// Develop (handoff 2): the first time a print is seen it comes up from blank cream through
/// sepia to the image. Seen prints show at once, this session and after.
struct V2Develop: ViewModifier {
    let key: String?

    @AppStorage(V2Settings.developKey) private var developRaw = V2DevelopMode.follow.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: Double = 1

    func body(content: Content) -> some View {
        content
            .sepia(1 - progress)
            .brightness((1 - progress) * 0.45)
            .contrast(0.2 + 0.8 * progress)
            .opacity(0.15 + 0.85 * progress)
            .onAppear {
                guard let key, !V2DevelopLedger.isDeveloped(key) else { return }
                V2DevelopLedger.markDeveloped(key)
                progress = 0
                let seconds = (V2DevelopMode(rawValue: developRaw) ?? .follow).seconds(reduceMotion: reduceMotion)
                withAnimation(.easeOut(duration: seconds)) { progress = 1 }
            }
    }
}

private extension View {
    /// Sepia as a hue-held colour shift, since SwiftUI has no sepia filter: desaturate, then warm.
    func sepia(_ amount: Double) -> some View {
        self.saturation(1 - amount * 0.8)
            .colorMultiply(Color(red: 1, green: 1 - 0.08 * amount, blue: 1 - 0.25 * amount))
    }
}

/// Which prints have developed on this device. Kept in memory and written in batches, so a feed
/// full of prints is one small write, not one per print.
@MainActor
enum V2DevelopLedger {
    private static let key = "v2Developed"
    private static let limit = 4_000
    private static var seen: Set<String> = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    private static var pendingWrite = false

    static func isDeveloped(_ id: String) -> Bool { seen.contains(id) }

    static func markDeveloped(_ id: String) {
        seen.insert(id)
        guard !pendingWrite else { return }
        pendingWrite = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            pendingWrite = false
            UserDefaults.standard.set(Array(seen.suffix(limit)), forKey: key)
        }
    }
}

/// Account (replaces the App Store Settings sheet in FLIM Beta), under Appearance: notifications
/// and sound, saving developed shots to the camera roll, blocked people, help and the legal pages,
/// then Sign out and Delete account. Every switch writes what the App Store sheet writes and asks
/// iOS the same way; Sign out still warns about shots that haven't uploaded. Blocked people,
/// feedback and the delete page are the App Store app's own screens.
struct V2AccountView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.v2Palette) private var palette
    @Environment(AuthService.self) private var auth
    @Environment(PhotoService.self) private var photos
    @Environment(NotificationService.self) private var notifications

    @AppStorage(InstantFilmProcessor.neutralCaptureKey) private var neutralCapture = false
    @AppStorage("developNotificationsEnabled") private var developReminders = true
    @AppStorage("soundEffects") private var soundEffects = true
    @AppStorage("hasOnboarded") private var hasOnboarded = false

    @State private var askingNotifications = false
    @State private var savesShots = false
    @State private var askingPhotos = false
    @State private var photosBlocked = false
    @State private var unsentAtSignOut: Int?
    @State private var showBlocked = false
    @State private var showFeedback = false
    @State private var showDelete = false
    @State private var showWipe = false

    private var showsFilmLab: Bool {
        !AppInfo.isAppStore && isOwnerAccount(email: auth.currentUser?.email, username: auth.currentUser?.username)
    }

    var body: some View {
        V2Screen(title: "Account", onBack: { dismiss() }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    title("Notifications").padding(.top, 14)
                    VStack(spacing: 14) {
                        notificationState
                        toggleRow("Develop reminders", value: developReminders) { developReminders.toggle() }
                            .disabled(notifications.authorizationState != .authorized)
                            .opacity(notifications.authorizationState == .authorized ? 1 : 0.5)
                        toggleRow("Sound effects", value: soundEffects) { soundEffects.toggle() }
                    }
                    .padding(.top, 14)

                    title("Camera roll").padding(.top, 34)
                    VStack(alignment: .leading, spacing: 10) {
                        toggleRow("Save developed shots", value: savesShots) { setSavesShots(!savesShots) }
                            .disabled(auth.currentUser == nil || askingPhotos)
                        if photosBlocked {
                            HStack(alignment: .firstTextBaseline) {
                                note("iOS is holding this one. Photos access is off for \(AppInfo.appName).")
                                Spacer(minLength: 8)
                                Button { openSettings() } label: {
                                    Text("Open Settings").font(V2Type.control()).underline().frame(minHeight: 44)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        note("Shots you keep are saved to your photo library. Shots from a roll save once you watch the reveal. Applies to shots you take from now on.")
                    }
                    .padding(.top, 14)

                    title("Account").padding(.top, 34)
                    VStack(spacing: 14) {
                        row("Blocked users") { showBlocked = true }
                        row("Replay intro") { hasOnboarded = false; dismiss() }
                    }
                    .padding(.top, 14)

                    title("Support and legal").padding(.top, 34)
                    VStack(spacing: 14) {
                        row("Send feedback") { showFeedback = true }
                        row("Email us directly") { if let url = AppInfo.feedbackMailURL { openURL(url) } }
                        row("Privacy Policy") { openURL(AppInfo.privacyPolicyURL) }
                        row("Terms of Service") { openURL(AppInfo.termsURL) }
                    }
                    .padding(.top, 14)

                    if showsFilmLab {
                        title("Film Lab").padding(.top, 34)
                        VStack(alignment: .leading, spacing: 10) {
                            toggleRow("Neutral capture", value: neutralCapture) { neutralCapture.toggle() }
                            note("Shots skip the FLIM look (LUT calibration)")
                        }
                        .padding(.top, 14)
                    }

                    #if DEBUG
                    VStack(spacing: 14) {
                        row("Wipe my test data", tint: .red) { showWipe = true }
                    }
                    .padding(.top, 34)
                    #endif

                    VStack(spacing: 6) {
                        Button { signOutTapped() } label: {
                            Text("Sign out")
                                .font(V2Type.control(.body))
                                .foregroundStyle(Color.red)
                                .frame(maxWidth: .infinity, minHeight: 50)
                                .overlay { Rectangle().stroke(Color.red.opacity(0.5), lineWidth: 1) }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button { showDelete = true } label: {
                            Text("Delete account")
                                .font(V2Type.control())
                                .foregroundStyle(palette.ink3)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 40)

                    VStack(spacing: 4) {
                        Text("\(AppInfo.appName) \(AppInfo.versionString)")
                            .font(V2Type.data(10))
                            .foregroundStyle(palette.ink3)
                        Text(AppInfo.colophon)
                            .font(V2Type.serif(12, italic: true, relativeTo: .caption))
                            .foregroundStyle(palette.ink3)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 18)
                }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(.horizontal, V2Metrics.margin)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
        }
        .sheet(isPresented: $showBlocked) { BlockedUsersSheet().preferredColorScheme(.dark) }
        .sheet(isPresented: $showFeedback) { FeedbackSheet().preferredColorScheme(.dark) }
        // The page with the real inventory and the held confirm (confirmations rule 3), as in
        // the App Store app.
        .navigationDestination(isPresented: $showDelete) {
            AccountDeleteView(mode: .deleteAccount).preferredColorScheme(.dark)
        }
        .navigationDestination(isPresented: $showWipe) {
            AccountDeleteView(mode: .wipeData).preferredColorScheme(.dark)
        }
        .confirmationDialog(
            unsentAtSignOut == 1 ? "1 shot hasn't uploaded yet" : "\(unsentAtSignOut ?? 0) shots haven't uploaded yet",
            isPresented: Binding(get: { unsentAtSignOut != nil }, set: { if !$0 { unsentAtSignOut = nil } }),
            titleVisibility: .visible
        ) {
            Button("Wait and upload") { Task { await photos.retryFailedUploads() } }
            Button("Sign out anyway", role: .destructive) { signOut() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They stay on this phone and send when you sign back in here.")
        }
        .task { await notifications.refreshAuthorizationState() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await notifications.refreshAuthorizationState() }
            refreshSavesShots()
        }
        .onAppear { refreshSavesShots() }
    }

    // MARK: Notifications

    /// The switches mean nothing until iOS allows notifications, so that comes first, with its
    /// own way forward: asking, or iOS Settings once it has been refused.
    @ViewBuilder private var notificationState: some View {
        switch notifications.authorizationState {
        case .notDetermined:
            permissionRow("Notifications are off",
                          detail: "Turn them on to get develop reminders and reactions.") {
                guard !askingNotifications else { return }
                askingNotifications = true
                Task {
                    await notifications.requestAuthorizationIfNeeded()
                    askingNotifications = false
                }
            }
            .disabled(askingNotifications)
        case .denied:
            permissionRow("Notifications are off in Settings",
                          detail: "Turn them on in iOS Settings to get develop reminders and reactions.") {
                openSettings()
            }
        case .authorized:
            EmptyView()
        }
    }

    // MARK: Camera roll

    /// On only while the choice is on AND Photos access still stands, so a revoke in iOS Settings
    /// never leaves the switch saying On over saves that can't happen.
    private func refreshSavesShots() {
        guard let uid = auth.currentUser?.id else { savesShots = false; return }
        let allowed = PHPhotoLibrary.authorizationStatus(for: .addOnly) == .authorized
        savesShots = CameraRollAutoSave.shared.isEnabled(for: uid) && allowed
        if allowed { photosBlocked = false }
    }

    /// Off is immediate. On asks iOS for add-only access first; a refusal leaves it off and says why.
    private func setSavesShots(_ on: Bool) {
        guard let uid = auth.currentUser?.id, !askingPhotos else { return }
        guard on else {
            savesShots = false
            CameraRollAutoSave.shared.setEnabled(false, for: uid)
            return
        }
        askingPhotos = true
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            askingPhotos = false
            if status == .authorized {
                savesShots = true
                CameraRollAutoSave.shared.setEnabled(true, for: uid)
            } else {
                savesShots = false
                Haptics.error()
                withAnimation { photosBlocked = true }
            }
        }
    }

    // MARK: Sign out

    /// Unsent shots wait on this phone under the account and send at its next sign-in here, but
    /// they stop sending, so signing out with some still waiting says so first.
    private func signOutTapped() {
        let unsent = photos.unsentShotCount
        if unsent > 0 { unsentAtSignOut = unsent } else { signOut() }
    }

    private func signOut() {
        Task { try? await auth.signOut() }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }

    // MARK: Rows

    private func title(_ text: String) -> some View {
        Text(text).font(V2Type.serif(22, relativeTo: .title2)).accessibilityAddTraits(.isHeader)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
            .foregroundStyle(palette.ink3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ label: String, value: String = "", tint: Color? = nil,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label).font(.system(.subheadline)).foregroundStyle(tint ?? palette.ink)
                Spacer()
                Text(value).font(V2Type.control(.subheadline)).foregroundStyle(palette.ink2)
            }
            .padding(.bottom, 12)
            .overlay(alignment: .bottom) { Rectangle().fill(palette.rule).frame(height: 1) }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleRow(_ label: String, value: Bool, toggle: @escaping () -> Void) -> some View {
        row(label, value: value ? "On" : "Off") { toggle(); Haptics.tap() }
            .accessibilityValue(value ? "On" : "Off")
    }

    private func permissionRow(_ label: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.system(.subheadline))
                Text(detail)
                    .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
                    .foregroundStyle(palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 12)
            .overlay(alignment: .bottom) { Rectangle().fill(palette.rule).frame(height: 1) }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
