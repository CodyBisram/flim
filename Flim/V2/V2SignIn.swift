import SwiftUI
import UIKit

// FLIM Beta's way in: the splash, email, code, username, waitlist and App Review screens, and the
// first-run camera intro, drawn on the desk. Every rule is the App Store screens' own
// (EmailAuthView, OTPView, UsernameView, WaitlistSheet, ReviewerSignInSheet, OnboardingView): the
// same server calls, the same invite and inviter handling, the same errors and the same keys, so
// the two can be read side by side. Only the look and the words about friends differ (friends in
// v2 are mutual: following someone asks them to add you back). The stamp is not picked here: the
// first run asks for it right after the desk (V2DeskChoice).

// MARK: - Shared pieces

/// A sign-in screen's frame. Phone and the closed Duo: one column, the action pinned above the
/// keyboard. The open Duo: the wordmark and a print on the left half, the column on the right.
struct V2AuthFrame<Content: View, Action: View>: View {
    /// Shows the wordmark at the top of the column (the open Duo has it on the left half).
    var showsWordmark = false
    @ViewBuilder var content: () -> Content
    @ViewBuilder var action: () -> Action

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.v2Palette) private var palette

    var body: some View {
        GeometryReader { proxy in
            let mode = V2LayoutMode.resolve(horizontalSizeClass: sizeClass, proxy: proxy)
            if mode == .inner {
                HStack(spacing: 0) {
                    V2AuthBrandPanel()
                        .frame(width: proxy.size.width / 2)
                    Rectangle().fill(palette.rule).frame(width: 1).ignoresSafeArea()
                    column(top: 36, wordmark: false)
                }
            } else {
                column(top: mode == .outer ? 28 : 64, wordmark: showsWordmark)
            }
        }
        .foregroundStyle(palette.ink)
        .tint(palette.ink)
        .background { V2Desktop(palette: palette).ignoresSafeArea() }
    }

    private func column(top: CGFloat, wordmark: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if wordmark {
                    V2Wordmark(size: 40)
                        .padding(.bottom, 14)
                }
                content()
            }
            .frame(maxWidth: 460, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, V2Metrics.margin)
            .padding(.top, top)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) { action() }
                .frame(maxWidth: 460, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, V2Metrics.margin)
                .padding(.top, 10)
                .padding(.bottom, 16)
                .background { V2Desktop(palette: palette).ignoresSafeArea(edges: .bottom) }
        }
    }
}

/// "FLIM", set in the display face, widely spaced.
struct V2Wordmark: View {
    var size: CGFloat = 40

    var body: some View {
        Text(AppInfo.appName)
            .font(V2Type.serif(size, relativeTo: .largeTitle))
            .tracking(size * 0.22)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The open Duo's left half on the sign-in screens: the wordmark over a print lying on the desk.
private struct V2AuthBrandPanel: View {
    @Environment(\.v2Palette) private var palette

    var body: some View {
        VStack(spacing: 30) {
            V2Wordmark(size: 36)
            V2SamplePrint(width: 170)
                .rotationEffect(.degrees(-3))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// A print with a warm gradient and today's burned-in date, for screens with no photo of their own.
struct V2SamplePrint: View {
    let width: CGFloat
    @Environment(\.v2Palette) private var palette

    var body: some View {
        V2PrintCard(width: width, showsShadow: false) {
            LinearGradient(colors: [V2Color.rgb(0xE9A05A), V2Color.rgb(0x3A2A22)], startPoint: .top, endPoint: .bottom)
                .overlay(alignment: .bottomTrailing) {
                    V2DateStamp(text: BrandedExport.dateText(.init(date: .now)), cellHeight: width * 0.045, stamp: .amber)
                        .padding(width * 0.05)
                }
        } foot: { Color.clear }
        .shadow(color: palette.shadowNear.color, radius: palette.shadowNear.radius, y: palette.shadowNear.y)
        .shadow(color: palette.shadowFar.color, radius: palette.shadowFar.radius, y: palette.shadowFar.y)
        .accessibilityHidden(true)
    }
}

/// The one strong control on a sign-in screen: a ruled box, the label in the system face.
struct V2AuthButton: View {
    let title: String
    var isLoading = false
    var disabled = false
    let action: () async -> Void

    @Environment(\.v2Palette) private var palette

    var body: some View {
        Button { Task { await action() } } label: {
            ZStack {
                if isLoading {
                    ProgressView().tint(palette.ink)
                } else {
                    Text(title).font(V2Type.control(.body))
                }
            }
            .foregroundStyle(disabled ? palette.ink3 : palette.ink)
            .frame(maxWidth: .infinity, minHeight: 50)
            .overlay {
                Rectangle().stroke(disabled ? palette.ink3.opacity(0.45) : palette.ink.opacity(0.75), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled || isLoading)
        .accessibilityLabel(title)
        .animation(.easeInOut(duration: 0.2), value: disabled)
    }
}

/// A quiet control: underlined text in the system face, a 44-point target.
struct V2TextAction: View {
    let title: String
    var dim = false
    let action: () -> Void
    @Environment(\.v2Palette) private var palette

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(V2Type.control())
                .foregroundStyle(dim ? palette.ink3 : palette.ink)
                .underline(!dim)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A field on the desk: a small label above, a ruled line below.
struct V2AuthField<Field: View>: View {
    let label: String
    var focused = false
    @ViewBuilder var field: () -> Field
    @Environment(\.v2Palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(V2Type.serif(13, italic: true, relativeTo: .footnote))
                .foregroundStyle(palette.ink3)
                .accessibilityHidden(true)
            field()
                .frame(minHeight: 44)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(focused ? palette.ink : palette.ink.opacity(0.45))
                        .frame(height: focused ? 1.5 : 1)
                }
                .animation(.easeInOut(duration: 0.15), value: focused)
        }
    }
}

/// Errors on the desk: a deep red on Paper (4.5:1), the bright one on Slate.
enum V2AuthInk {
    static func error(_ palette: V2Palette) -> Color {
        palette.isDark ? V2Color.rgb(0xF5738C) : V2Color.rgb(0xA3303F)
    }
}

private struct V2AuthMessage: View {
    let text: String
    var isError = true
    @Environment(\.v2Palette) private var palette

    var body: some View {
        Text(text)
            .font(V2Type.serif(14, italic: !isError, relativeTo: .subheadline))
            .foregroundStyle(isError ? V2AuthInk.error(palette) : palette.ink2)
            .fixedSize(horizontal: false, vertical: true)
            .transition(.opacity)
    }
}

// MARK: - Splash

/// While the session and the profile load. The wordmark fades up on the desk.
struct V2Splash: View {
    @Environment(\.v2Palette) private var palette
    @State private var shown = false

    var body: some View {
        V2Wordmark(size: 36)
            .foregroundStyle(palette.ink)
            .opacity(shown ? 1 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { V2Desktop(palette: palette).ignoresSafeArea() }
            .onAppear { withAnimation(.easeIn(duration: 0.6)) { shown = true } }
    }
}

/// Signed in, but the account could not be read (`AuthService.profileUnavailable`).
struct V2AccountUnreachable: View {
    let retry: () async -> Void
    @Environment(\.v2Palette) private var palette
    @State private var retrying = false

    var body: some View {
        V2AuthFrame {
            Text("Couldn't reach your account")
                .font(V2Type.serif(28, relativeTo: .title))
                .accessibilityAddTraits(.isHeader)
            Text("Check your connection and try again. You're still signed in.")
                .font(V2Type.serif(15, italic: true, relativeTo: .body))
                .foregroundStyle(palette.ink2)
                .padding(.top, 8)
        } action: {
            V2AuthButton(title: "Try again", isLoading: retrying) {
                retrying = true
                await retry()
                retrying = false
            }
        }
    }
}

// MARK: - Email

/// The email screen (`EmailAuthView`'s rules, see there for the reasons behind each).
struct V2EmailSignIn: View {
    @Environment(AuthService.self) private var auth
    @Environment(\.v2Palette) private var palette

    @State private var email = ""
    @State private var isSending = false
    @State private var error: String?
    @State private var showOTP = false
    @State private var showReviewerSignIn = false
    @State private var needsInvite = false
    @State private var inviteCode = ""
    @State private var inviteError: String?
    @FocusState private var focus: Field?
    @State private var inviter: AuthService.InvitePreview?
    @State private var previewTask: Task<Void, Never>?
    @State private var showWaitlist = false

    private enum Field { case email, code }

    var body: some View {
        V2AuthFrame(showsWordmark: true) {
            Text("Just your email to get started.")
                .font(V2Type.serif(16, italic: true, relativeTo: .body))
                .foregroundStyle(palette.ink2)

            V2AuthField(label: "Email", focused: focus == .email) {
                TextField("", text: $email, prompt: Text(verbatim: "you@example.com")
                    .font(V2Type.serif(19, italic: true, relativeTo: .title3))
                    .foregroundStyle(palette.ink3))
                    .font(V2Type.serif(19, relativeTo: .title3))
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.next)
                    .focused($focus, equals: .email)
                    .onSubmit { focus = .code }
                    .accessibilityLabel("Email")
            }
            .padding(.top, 36)

            if let error {
                V2AuthMessage(text: error).padding(.top, 8)
            }

            inviteSection
                .padding(.top, 34)
        } action: {
            V2AuthButton(title: "Send code", isLoading: isSending, disabled: !canSubmit) {
                await send()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: inviter)
        .animation(.easeInOut(duration: 0.2), value: needsInvite)
        .animation(.easeInOut(duration: 0.2), value: error)
        .animation(.easeInOut(duration: 0.2), value: inviteError)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showReviewerSignIn) {
            V2ReviewerSignIn(email: email)
                .modifier(V2DeskEnvironment())
        }
        .sheet(isPresented: $showWaitlist) {
            V2WaitlistSheet(prefilledEmail: email) { name, email in
                await auth.joinWaitlist(name: name, email: email)
            }
            .modifier(V2DeskEnvironment())
        }
        .navigationDestination(isPresented: $showOTP) {
            V2CodeEntry()
                .modifier(V2DeskEnvironment())
        }
        .task {
            adoptPendingInvite()
            #if DEBUG
            // `-v2DemoAuthInvite`: a typed code and the inviter it names, with no server.
            if ProcessInfo.processInfo.arguments.contains("-v2DemoAuthInvite") {
                email = "sam@example.com"
                previewTask?.cancel()
                inviteCode = "MAYA42"
                try? await Task.sleep(for: .milliseconds(200))
                previewTask?.cancel()
                inviter = AuthService.InvitePreview(inviterId: UUID(), username: "maya", displayName: "Maya")
            }
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPersonalInvite)) { _ in adoptPendingInvite() }
        .onReceive(NotificationCenter.default.publisher(for: .openRollInvite)) { _ in adoptPendingInvite() }
        .onChange(of: email) { _, _ in
            needsInvite = false
            inviteError = nil
            error = nil
        }
    }

    private var inviteSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(needsInvite ? "You'll need an invite code to join" : "Have an invite code?")
                .font(V2Type.serif(18, relativeTo: .headline))
            Text(needsInvite
                 ? "Enter the code a friend sent you and we'll get you straight in."
                 : "New here? Enter it now and you'll go straight in. Members can leave it blank.")
                .font(V2Type.serif(14, italic: true, relativeTo: .subheadline))
                .foregroundStyle(palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)

            V2AuthField(label: "Invite code", focused: focus == .code) {
                // Not the roll code's "ABC123": the two codes are different things.
                TextField("", text: $inviteCode, prompt: Text("six letters or numbers")
                    .font(V2Type.serif(17, italic: true, relativeTo: .body))
                    .foregroundStyle(palette.ink3))
                    .font(V2Type.data(22))
                    .tracking(inviteCode.isEmpty ? 0 : 6)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                    .focused($focus, equals: .code)
                    .accessibilityLabel("Invite code")
                    .onChange(of: inviteCode) { _, new in
                        let clean = String(new.uppercased().prefix(6))
                        if clean != new { inviteCode = clean }
                        inviteError = nil
                        resolveInviter()
                    }
            }
            .padding(.top, 18)

            if let inviteError {
                V2AuthMessage(text: inviteError).padding(.top, 8)
            } else if let hint = InviteCopy.codeLengthHint(for: inviteCode) {
                V2AuthMessage(text: hint, isError: false).padding(.top, 8)
            }

            if let inviter {
                inviterRow(inviter)
                    .padding(.top, 18)
                    .transition(.opacity)
            } else {
                noCodeRow
                    .padding(.top, 18)
                    .transition(.opacity)
            }
        }
    }

    /// Who brought you, the moment the code resolves. With friends mutual, the follow made for
    /// you is a request: they are asked to add you back.
    private func inviterRow(_ inviter: AuthService.InvitePreview) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(palette.ink.opacity(0.08))
                .frame(width: 34, height: 34)
                .overlay {
                    Text(String(inviter.shownName.trimmingCharacters(in: CharacterSet(charactersIn: "@")).prefix(1)).uppercased())
                        .font(V2Type.serif(16, relativeTo: .body))
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(V2SignInCopy.inviterTitle(name: inviter.shownName, rollName: inviter.rollName, isCampaign: inviter.isCampaign))
                    .font(V2Type.serif(16, relativeTo: .body))
                Text(V2SignInCopy.inviterDetail(rollName: inviter.rollName, isCampaign: inviter.isCampaign))
                    .font(V2Type.serif(13, italic: true, relativeTo: .footnote))
                    .foregroundStyle(palette.ink2)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var noCodeRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Waitlist.Copy.noCode)
                .font(V2Type.serif(14, italic: true, relativeTo: .subheadline))
                .foregroundStyle(palette.ink2)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 22) { noCodeActions }
                VStack(alignment: .leading, spacing: 0) { noCodeActions }
            }
        }
    }

    @ViewBuilder
    private var noCodeActions: some View {
        ShareLink(item: Waitlist.Copy.shareMessage) {
            Text(Waitlist.Copy.askFriend)
                .font(V2Type.control())
                .underline()
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .simultaneousGesture(TapGesture().onEnded { Haptics.tap() })
        .accessibilityLabel(Waitlist.Copy.askFriend)
        .accessibilityHint(Waitlist.Copy.askFriendHint)

        V2TextAction(title: Waitlist.Copy.joinWaitlist) {
            Haptics.tap()
            focus = nil
            showWaitlist = true
        }
        .accessibilityHint(Waitlist.Copy.joinWaitlistHint)
    }

    private func adoptPendingInvite() {
        guard inviteCode.isEmpty, let code = PendingInvite.take() ?? PendingRollInvite.peek() else { return }
        inviteCode = code
        Haptics.tap()
        resolveInviter()
    }

    private func resolveInviter() {
        previewTask?.cancel()
        inviter = nil
        guard inviteCode.count == 6 else { return }
        let code = inviteCode
        previewTask = Task {
            let preview = await auth.previewInvite(code: code)
            guard !Task.isCancelled, inviteCode == code else { return }
            inviter = preview
        }
    }

    private var isValidEmail: Bool { email.contains("@") && email.contains(".") }

    private var canSubmit: Bool {
        guard isValidEmail, !isSending else { return false }
        return inviteCode.isEmpty || inviteCode.count == 6
    }

    private func send() async {
        guard !isSending else { return }
        isSending = true
        error = nil
        inviteError = nil
        defer { isSending = false }

        if AuthService.isReviewerEmail(email) {
            showReviewerSignIn = true
            return
        }

        do {
            if !inviteCode.isEmpty, !PendingInviteRedeemed.isRedeemed(for: email) {
                if let inviter { PendingInviter.remember(inviterId: inviter.inviterId, name: inviter.shownName, isCampaign: inviter.isCampaign, for: email) }
                guard try await auth.redeemInvite(code: inviteCode, email: email) else {
                    Haptics.error()
                    inviteError = InviteCopy.redeemFailed
                    return
                }
                Haptics.success()
            }
            try await auth.sendOTP(email: email)
            focus = nil
            showOTP = true
        } catch AuthError.notInvited {
            needsInvite = true
            focus = .code
        } catch AuthError.rateLimited where !inviteCode.isEmpty {
            Haptics.error()
            inviteError = InviteCopy.redeemRateLimited
        } catch {
            self.error = (error as? AuthError)?.errorDescription ?? UserFacingError.messageIfNotCancelled(for: error)
        }
    }
}

/// The words that differ from the App Store screens. Pure, so they can be pinned.
enum V2SignInCopy {
    static func inviterTitle(name: String, rollName: String?, isCampaign: Bool) -> String {
        if let rollName { return "\(name) invited you to \(rollName)." }
        return isCampaign ? "You're in with \(name)'s code." : "\(name) invited you."
    }

    static func inviterDetail(rollName: String?, isCampaign: Bool) -> String {
        if isCampaign, rollName == nil { return "Once you're in, find the people you know." }
        return rollName == nil
            ? "Once you're in, they're asked to add you back."
            : "The roll is waiting once you're in, and they're asked to add you back."
    }
}

// MARK: - App Review

/// Password sign-in for the App Review address (`ReviewerSignInSheet`'s rules).
struct V2ReviewerSignIn: View {
    let email: String

    @Environment(AuthService.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @Environment(\.v2Palette) private var palette
    @State private var password = ""
    @State private var isSigningIn = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            V2TextAction(title: "Cancel", dim: true) { dismiss() }
            Text("App Review sign-in")
                .font(V2Type.serif(24, relativeTo: .title2))
                .padding(.top, 10)
                .accessibilityAddTraits(.isHeader)
            Text("Enter the password from App Review Information for \(email).")
                .font(V2Type.serif(14, italic: true, relativeTo: .subheadline))
                .foregroundStyle(palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            V2AuthField(label: "Password", focused: focused) {
                SecureField("Password", text: $password)
                    .font(V2Type.serif(19, relativeTo: .title3))
                    .textContentType(.password)
                    .submitLabel(.go)
                    .focused($focused)
                    .onSubmit { Task { await signIn() } }
            }
            .padding(.top, 26)
            if let error {
                V2AuthMessage(text: error).padding(.top, 8)
            }
            Spacer(minLength: 24)
            V2AuthButton(title: "Sign In", isLoading: isSigningIn, disabled: password.isEmpty) {
                await signIn()
            }
        }
        .padding(V2Metrics.margin)
        .padding(.top, 6)
        .foregroundStyle(palette.ink)
        .tint(palette.ink)
        .presentationBackground { V2Desktop(palette: palette) }
        .task { focused = true }
    }

    private func signIn() async {
        guard !isSigningIn, !password.isEmpty else { return }
        isSigningIn = true
        error = nil
        do {
            try await auth.signInWithPassword(email: email, password: password)
            Haptics.success()
            dismiss()
        } catch {
            self.error = "Couldn't sign in. Check the password and try again."
            Haptics.error()
        }
        isSigningIn = false
    }
}

// MARK: - Waitlist

/// The waitlist form (`WaitlistSheet`'s rules and copy).
struct V2WaitlistSheet: View {
    let join: (_ name: String, _ email: String) async -> Waitlist.Outcome
    private let store: UserDefaults

    @Environment(\.dismiss) private var dismiss
    @Environment(\.v2Palette) private var palette
    @State private var name = ""
    @State private var email: String
    @State private var isJoining = false
    @State private var emailError: String?
    @State private var error: String?
    @State private var joinedEmail: String?
    @FocusState private var focus: Field?

    private enum Field { case name, email }

    init(prefilledEmail: String, store: UserDefaults = .standard,
         join: @escaping (_ name: String, _ email: String) async -> Waitlist.Outcome) {
        let trimmed = prefilledEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        self.join = join
        self.store = store
        _email = State(initialValue: trimmed)
        _joinedEmail = State(initialValue: Waitlist.hasJoined(trimmed, in: store) ? trimmed.lowercased() : nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if joinedEmail == nil {
                        V2TextAction(title: "Cancel", dim: true) { dismiss() }
                    }
                    Group {
                        if let joinedEmail { joined(email: joinedEmail) } else { form }
                    }
                    .padding(.top, joinedEmail == nil ? 10 : 54)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, V2Metrics.margin)
                .padding(.top, 6)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)

            Group {
                if joinedEmail != nil {
                    V2AuthButton(title: Waitlist.Copy.done) { dismiss() }
                } else {
                    V2AuthButton(title: Waitlist.Copy.join, isLoading: isJoining,
                                 disabled: !Waitlist.canSubmit(name: name, email: email)) {
                        await submit()
                    }
                }
            }
            .padding(.horizontal, V2Metrics.margin)
            .padding(.top, 10)
            .padding(.bottom, 20)
        }
        .animation(.easeInOut(duration: 0.25), value: joinedEmail)
        .foregroundStyle(palette.ink)
        .tint(palette.ink)
        .presentationBackground { V2Desktop(palette: palette) }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Waitlist.Copy.title)
                .font(V2Type.serif(24, relativeTo: .title2))
                .accessibilityAddTraits(.isHeader)
            Text(Waitlist.Copy.body)
                .font(V2Type.serif(14, italic: true, relativeTo: .subheadline))
                .foregroundStyle(palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            V2AuthField(label: Waitlist.Copy.nameField, focused: focus == .name) {
                TextField("", text: $name)
                    .font(V2Type.serif(19, relativeTo: .title3))
                    .textContentType(.givenName)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focus, equals: .name)
                    .onSubmit { focus = .email }
                    .accessibilityLabel(Waitlist.Copy.nameField)
            }
            .padding(.top, 26)
            V2AuthField(label: Waitlist.Copy.emailField, focused: focus == .email) {
                TextField("", text: $email, prompt: Text(verbatim: "you@example.com")
                    .font(V2Type.serif(19, italic: true, relativeTo: .title3))
                    .foregroundStyle(palette.ink3))
                    .font(V2Type.serif(19, relativeTo: .title3))
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.join)
                    .focused($focus, equals: .email)
                    .onSubmit { Task { await submit() } }
                    .accessibilityLabel(Waitlist.Copy.emailField)
            }
            .padding(.top, 18)
            if let emailError { V2AuthMessage(text: emailError).padding(.top, 8) }
            if let error { V2AuthMessage(text: error).padding(.top, 8) }
        }
        .onChange(of: email) { _, _ in emailError = nil; error = nil }
        .onChange(of: name) { _, _ in error = nil }
        .task { if focus == nil { focus = .name } }
    }

    private func joined(email: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Waitlist.Copy.joinedTitle)
                .font(V2Type.serif(24, relativeTo: .title2))
                .accessibilityAddTraits(.isHeader)
            Text(Waitlist.Copy.joinedBody(email: email))
                .font(V2Type.serif(14, italic: true, relativeTo: .subheadline))
                .foregroundStyle(palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .transition(.opacity)
    }

    private func submit() async {
        guard !isJoining,
              let cleanName = Waitlist.normalizedName(name),
              let cleanEmail = Waitlist.normalizedEmail(email) else { return }
        isJoining = true
        emailError = nil
        error = nil
        defer { isJoining = false }
        let outcome = await join(cleanName, cleanEmail)
        if outcome == .joined {
            Waitlist.remember(cleanEmail, in: store)
            focus = nil
            Haptics.success()
            joinedEmail = cleanEmail
            AccessibilityNotification.Announcement(
                "\(Waitlist.Copy.joinedTitle) \(Waitlist.Copy.joinedBody(email: cleanEmail))"
            ).post()
            return
        }
        Haptics.error()
        let message = outcome.message ?? Waitlist.Copy.unreachable
        if outcome.isAboutEmail {
            emailError = message
            focus = .email
        } else {
            error = message
        }
        AccessibilityNotification.Announcement(message).post()
    }
}

// MARK: - Code

private let v2CodeLength = 6

/// The emailed code (`OTPView`'s rules: autofill-safe input, paste, resend with a cooldown).
struct V2CodeEntry: View {
    @Environment(AuthService.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @Environment(\.v2Palette) private var palette
    @State private var code = ""
    @State private var isVerifying = false
    @State private var error: String?
    @State private var isResending = false
    @State private var resendCountdown = 0
    @State private var sentNotice: String?

    var body: some View {
        V2AuthFrame {
            V2TextAction(title: "Back", dim: true) { dismiss() }
            Text("Check your email.")
                .font(V2Type.serif(30, relativeTo: .largeTitle))
                .padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
            Text(auth.pendingEmail.map { "We sent a \(v2CodeLength)-digit code to \($0)." }
                 ?? "Enter the \(v2CodeLength)-digit code we sent you.")
                .font(V2Type.serif(15, italic: true, relativeTo: .body))
                .foregroundStyle(palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            V2CodeField(code: $code, length: v2CodeLength)
                .padding(.top, 34)
                .onChange(of: code) { _, new in
                    if new.count == v2CodeLength { Task { await verify() } }
                }

            V2TextAction(title: "Paste code") {
                let digits = OTPView.sanitizeOTPInput(UIPasteboard.general.string ?? "", length: v2CodeLength)
                if !digits.isEmpty { code = digits }
            }
            .padding(.top, 10)

            if let sentNotice, error == nil {
                V2AuthMessage(text: sentNotice, isError: false).padding(.top, 4)
            }
            if let error {
                V2AuthMessage(text: error).padding(.top, 4)
            }

            Text("No code yet? Check your spam folder.")
                .font(V2Type.serif(14, italic: true, relativeTo: .subheadline))
                .foregroundStyle(palette.ink3)
                .padding(.top, 22)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 22) { recoveryActions }
                VStack(alignment: .leading, spacing: 0) { recoveryActions }
            }
        } action: {
            V2AuthButton(title: "Verify", isLoading: isVerifying, disabled: code.count < v2CodeLength) {
                await verify()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: error)
        .animation(.easeInOut(duration: 0.2), value: sentNotice)
        .toolbar(.hidden, for: .navigationBar)
    }

    @ViewBuilder
    private var recoveryActions: some View {
        V2TextAction(title: resendCountdown > 0 ? "Send a new code in \(resendCountdown)s"
                                                : (isResending ? "Sending…" : "Send a new code"),
                     dim: resendCountdown > 0 || isResending) {
            Task { await resend() }
        }
        .disabled(resendCountdown > 0 || isResending)
        V2TextAction(title: "Use a different email", dim: true) { dismiss() }
    }

    private func verify() async {
        guard code.count == v2CodeLength, !isVerifying else { return }
        isVerifying = true
        error = nil
        do {
            try await auth.verifyOTP(token: code)
        } catch {
            if NetworkFailure.isUnreachable(error) {
                self.error = UserFacingError.genericMessage
            } else {
                self.error = "That code didn't work. Check the newest email, or send a new code."
                code = ""
            }
        }
        isVerifying = false
    }

    private func resend() async {
        guard let email = auth.pendingEmail, !isResending, resendCountdown == 0 else { return }
        isResending = true
        error = nil
        do {
            try await auth.sendOTP(email: email)
            Haptics.success()
            sentNotice = "Sent. Check your email again."
            startResendCooldown()
        } catch {
            Haptics.error()
            self.error = (error as? AuthError)?.errorDescription ?? UserFacingError.messageIfNotCancelled(for: error)
        }
        isResending = false
    }

    private func startResendCooldown() {
        resendCountdown = 30
        Task {
            while resendCountdown > 0 {
                try? await Task.sleep(for: .seconds(1))
                resendCountdown -= 1
            }
        }
    }
}

/// Six ruled cells in the data face, with one full-width field laid over them so one-time-code
/// autofill and paste land (the App Store field's reasons, `OTPField`).
private struct V2CodeField: View {
    @Binding var code: String
    let length: Int
    @FocusState private var focused: Bool
    @Environment(\.v2Palette) private var palette

    private var sanitized: Binding<String> {
        Binding(get: { code }, set: { code = OTPView.sanitizeOTPInput($0, length: length) })
    }

    var body: some View {
        ZStack {
            HStack(spacing: 10) {
                ForEach(0..<length, id: \.self) { cell(at: $0) }
            }
            TextField("", text: sanitized)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($focused)
                .foregroundStyle(.clear)
                .tint(.clear)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .contentShape(Rectangle())
                .accessibilityLabel("Code")
        }
        .onAppear { focused = true }
    }

    private func cell(at index: Int) -> some View {
        let chars = Array(code)
        let char = index < chars.count ? String(chars[index]) : ""
        let active = index == chars.count && focused
        return Text(char)
            .font(V2Type.data(26))
            .frame(maxWidth: .infinity, minHeight: 52)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(active || !char.isEmpty ? palette.ink : palette.ink.opacity(0.35))
                    .frame(height: active ? 2 : 1)
            }
            .animation(.easeInOut(duration: 0.12), value: active)
            .accessibilityHidden(true)
    }
}

// MARK: - Username

/// A new account's name (`UsernameView`'s rules: the suggestion from the email, the live reason,
/// the escape, and the inviter's follow the moment the account's row exists).
struct V2UsernameEntry: View {
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed
    @Environment(\.v2Palette) private var palette
    @AppStorage("accentColor") private var accentColor = "amber"
    @State private var username = ""
    @State private var name = ""
    @State private var isSaving = false
    @State private var error: String?
    @FocusState private var focus: Field?

    private enum Field { case username, name }

    private var isValid: Bool { AuthService.isValidUsername(username) }

    var body: some View {
        V2AuthFrame {
            Text("Pick a username.")
                .font(V2Type.serif(30, relativeTo: .largeTitle))
                .accessibilityAddTraits(.isHeader)
            Text("3 to 20 characters. Letters, numbers and underscores.")
                .font(V2Type.serif(15, italic: true, relativeTo: .body))
                .foregroundStyle(palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            V2AuthField(label: "Username", focused: focus == .username) {
                HStack(spacing: 2) {
                    Text("@")
                        .font(V2Type.serif(19, relativeTo: .title3))
                        .foregroundStyle(palette.ink3)
                    TextField("", text: $username, prompt: Text("yourname")
                        .font(V2Type.serif(19, italic: true, relativeTo: .title3))
                        .foregroundStyle(palette.ink3))
                        .font(V2Type.serif(19, relativeTo: .title3))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.next)
                        .focused($focus, equals: .username)
                        .onSubmit { focus = .name }
                        .accessibilityLabel("Username")
                }
            }
            .padding(.top, 34)

            if let reason = AuthService.usernameRejection(username), error == nil {
                V2AuthMessage(text: reason, isError: false).padding(.top, 8)
            }
            if let error {
                V2AuthMessage(text: error).padding(.top, 8)
            }

            V2AuthField(label: "What should we call you? (optional)", focused: focus == .name) {
                TextField("", text: $name, prompt: Text("First name")
                    .font(V2Type.serif(19, italic: true, relativeTo: .title3))
                    .foregroundStyle(palette.ink3))
                    .font(V2Type.serif(19, relativeTo: .title3))
                    .textContentType(.givenName)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($focus, equals: .name)
                    .accessibilityLabel("What should we call you? Optional")
                    .onChange(of: name) { _, typed in
                        if typed.count > AuthService.displayNameMaxLength {
                            name = String(typed.prefix(AuthService.displayNameMaxLength))
                        }
                    }
            }
            .padding(.top, 22)
            if name.count >= AuthService.displayNameMaxLength - 10 {
                Text("\(name.count)/\(AuthService.displayNameMaxLength)")
                    .font(V2Type.data(11))
                    .foregroundStyle(palette.ink3)
                    .padding(.top, 6)
            }
        } action: {
            if let email = auth.currentUser?.email ?? auth.pendingEmail {
                HStack(spacing: 6) {
                    Text("Signed in as \(email).")
                        .font(V2Type.serif(13, italic: true, relativeTo: .footnote))
                        .foregroundStyle(palette.ink3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    V2TextAction(title: "Sign out") { Task { try? await auth.signOut() } }
                }
                .padding(.bottom, 4)
            }
            V2AuthButton(title: "Continue", isLoading: isSaving, disabled: !isValid) {
                await save()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: error)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            guard username.isEmpty, let email = auth.currentUser?.email ?? auth.pendingEmail else { return }
            username = UsernameSuggestion.from(email: email)
        }
    }

    private func save() async {
        isSaving = true
        error = nil
        do {
            try await auth.setUsername(username.lowercased(), displayName: name)
            try? await auth.setAccent(accentColor)
            if let uid = auth.currentUser?.id,
               let email = auth.currentUser?.email ?? auth.pendingEmail {
                let pending = PendingInviter.peek(for: email) ?? PendingInviter.Entry(id: nil, name: "")
                let answer = await auth.ownInviter(pending: pending)
                if answer.answered { PendingInviter.forget(for: email) }
                if let inviter = answer.inviter, inviter.id != uid {
                    if !inviter.name.isEmpty { NewAccountIntro.rememberInviter(inviter, userId: uid) }
                    _ = await feed.follow(inviter.id, from: uid)
                }
            }
        } catch {
            self.error = (error as? AuthError)?.errorDescription ?? UserFacingError.messageIfNotCancelled(for: error)
        }
        isSaving = false
    }
}

// MARK: - First run

/// The first run after the username, in one cover so nothing slides away and back: where your
/// prints lie and your stamp first (`V2DeskChoice`), then the camera's own screen, drawn on the
/// desk just chosen (`OnboardingView`'s rules: one sentence, one button, no Skip). "Take a shot"
/// ends onboarding and the camera appears; it asks for its permission in its own window first
/// (`V2CameraAsk`), so the system dialog still follows from the app's message. An account that
/// already chose a desk goes straight to the camera screen.
struct V2Onboarding: View {
    /// Set when replayed from Account: "Take a shot" calls this instead of ending onboarding.
    var onFinish: (() -> Void)? = nil

    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @AppStorage(V2DeskChoice.askedKey) private var deskAsked = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.v2Palette) private var palette
    @State private var isOpening = false
    @State private var choosingDesk: Bool?

    var body: some View {
        ZStack {
            if choosingDesk ?? !deskAsked {
                V2DeskChoice { withAnimation(.easeInOut(duration: 0.45)) { choosingDesk = false } }
                    .transition(.opacity)
            } else {
                camera
                    .transition(.opacity)
            }
        }
        // Decided once: the desk step marks the desk asked before its stamp step, which must not
        // cut the stamp short.
        .onAppear {
            guard choosingDesk == nil else { return }
            #if DEBUG
            // `-v2AskDesk`: the desk step even when a desk was chosen before.
            if ProcessInfo.processInfo.arguments.contains("-v2AskDesk") { choosingDesk = true; return }
            #endif
            choosingDesk = !deskAsked
        }
    }

    private var camera: some View {
        GeometryReader { proxy in
            let mode = V2LayoutMode.resolve(horizontalSizeClass: sizeClass, proxy: proxy)
            let width = min(proxy.size.width - V2Metrics.margin * 2, mode == .inner ? 300 : 300,
                            (proxy.size.height - 300) / 1.48)
            Group {
                if mode == .inner {
                    HStack(spacing: 56) {
                        viewfinder(width: width)
                        words(alignment: .leading)
                            .frame(maxWidth: 320, alignment: .leading)
                    }
                } else {
                    VStack(spacing: 30) {
                        viewfinder(width: width)
                        words(alignment: .center)
                            .padding(.horizontal, V2Metrics.margin)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(palette.ink)
        .background { V2Desktop(palette: palette).ignoresSafeArea() }
    }

    private func viewfinder(width: CGFloat) -> some View {
        V2PrintCard(width: width) {
            RadialGradient(colors: [Color(red: 0.055, green: 0.045, blue: 0.035), Color(red: 0.012, green: 0.012, blue: 0.012)],
                           center: UnitPoint(x: 0.5, y: 0.42), startRadius: 0, endRadius: width)
        } foot: { Color.clear }
        .accessibilityHidden(true)
    }

    private func words(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 0) {
            Text("\(AppInfo.appName) is a camera.")
                .font(V2Type.serif(28, relativeTo: .title))
                .accessibilityAddTraits(.isHeader)
            Text("Point and shoot. The frame comes back with the look already on it.")
                .font(V2Type.serif(15, italic: true, relativeTo: .body))
                .foregroundStyle(palette.ink2)
                .multilineTextAlignment(alignment == .center ? .center : .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            V2AuthButton(title: "Take a shot", disabled: isOpening) { openCamera() }
                .frame(maxWidth: 280)
                .padding(.top, 24)
                .accessibilityHint("Asks for camera access, then opens the camera")
        }
    }

    private func openCamera() {
        guard !isOpening else { return }
        isOpening = true
        Haptics.tap()
        if let onFinish {
            onFinish()
            return
        }
        hasOnboarded = true
        Activation.log(.onboardingFinished)
    }
}

#if DEBUG
/// `-v2DemoAuth <screen>`: one way-in screen on the chosen desk, for screenshots at every size
/// (`-v2DemoFrame`). `-v2DemoAuthInvite` fills a code and a stand-in inviter on the email screen.
struct V2AuthDemoHost: View {
    let screen: String

    var body: some View {
        Group {
            switch screen {
            case "code": NavigationStack { V2CodeEntry() }
            case "username": NavigationStack { V2UsernameEntry() }
            case "onboarding": V2Onboarding()
            case "unreachable": V2AccountUnreachable {}
            case "splash": V2Splash()
            case "reviewer", "waitlist":
                V2AuthDemoSheetHost(sheet: screen)
            default: NavigationStack { V2EmailSignIn() }
            }
        }
        .modifier(V2DemoFrame())
        .modifier(V2DeskEnvironment())
    }
}

/// The two sheets over the email screen, as they come up.
private struct V2AuthDemoSheetHost: View {
    let sheet: String
    @State private var shown = false

    var body: some View {
        NavigationStack { V2EmailSignIn() }
            .sheet(isPresented: $shown) {
                Group {
                    if sheet == "reviewer" {
                        V2ReviewerSignIn(email: "review@flim-app.com")
                    } else {
                        V2WaitlistSheet(prefilledEmail: "") { _, _ in .joined }
                    }
                }
                .modifier(V2DeskEnvironment())
            }
            .task { try? await Task.sleep(for: .milliseconds(400)); shown = true }
    }
}
#endif
