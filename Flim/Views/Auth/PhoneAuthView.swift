import SwiftUI

struct EmailAuthView: View {
    @Environment(\.flimAccent) private var accent
    @Environment(AuthService.self) private var auth
    @State private var email = ""
    @State private var isSending = false
    @State private var error: String?
    @State private var showOTP = false
    /// App Review signs in with a password instead of a mailed code. See AuthService.
    @State private var showReviewerSignIn = false
    @ScaledMetric private var subtitleSize = 15

    // Invite-code redemption.
    //
    // The field is available from the START, not revealed by failure. It used to appear only
    // after the server rejected an email, so someone holding a perfectly good invite code was
    // told "this email isn't on the invite list yet, ask whoever invited you to add you" —
    // advice to go and get the thing they already had in their hand. Rejection before
    // opportunity, and the one screen where a new person forms their first impression.
    /// Whether the code field is showing. Opened by tapping the disclosure, or automatically when
    /// the server says this email needs an invite.
    @State private var inviteExpanded = false
    /// Set when the server has told us this email isn't allowlisted. Changes the invite section's
    /// wording from an offer into an instruction, without ever rendering a red rejection.
    @State private var needsInvite = false
    @State private var inviteCode = ""
    @State private var inviteError: String?
    @FocusState private var codeFocused: Bool

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.04, blue: 0.04).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                Spacer()

                VStack(alignment: .leading, spacing: 8) {
                    Text(AppInfo.appName)
                        .flimFont(34, weight: .thin, relativeTo: .title3)
                        .tracking(12)
                        .foregroundStyle(.white)
                    Text("Shoot now. See it later. Enter your email to get started.")
                        .font(.system(size: subtitleSize))
                        .foregroundStyle(Color(white: 0.5))
                }
                .padding(.bottom, 40)

                VStack(alignment: .leading, spacing: 6) {
                    Text("EMAIL")
                        .flimFont(11, weight: .medium, relativeTo: .caption)
                        .tracking(2)
                        .foregroundStyle(Color(white: 0.4))

                    TextField("", text: $email, prompt: Text("you@example.com").foregroundStyle(Color(white: 0.3)))
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .flimFont(17, relativeTo: .body)
                        .foregroundStyle(.white)
                        .tint(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 16)
                        .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 12))
                }

                if let error {
                    Text(error)
                        .flimFont(13, relativeTo: .subheadline)
                        .foregroundStyle(Color(red: 1, green: 0.4, blue: 0.4))
                        .padding(.top, 8)
                }

                inviteSection

                Spacer()

                PrimaryButton(title: "Send Code", isLoading: isSending, disabled: !canSubmit) {
                    await send()
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 40)
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $showReviewerSignIn) {
            ReviewerSignInSheet(email: email)
        }
        .navigationDestination(isPresented: $showOTP) {
            OTPView()
        }
        // A code that arrived by link fills itself in and opens the section, so the person only
        // has to type their email. Checked on appear as well as by notification because the link
        // can be handled while this view is still being built, before it could receive anything.
        .task { adoptPendingInvite() }
        .onReceive(NotificationCenter.default.publisher(for: .openPersonalInvite)) { _ in
            adoptPendingInvite()
        }
        // A corrected typo deserves a clean slate: the previous email's verdict shouldn't keep
        // insisting this one needs an invite.
        .onChange(of: email) { _, _ in
            needsInvite = false
            inviteError = nil
            error = nil
        }
    }

    @ViewBuilder
    private var inviteSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if inviteExpanded {
                Text(needsInvite ? "You'll need an invite code to join" : "Have an invite code?")
                    .flimFont(14, weight: .medium, relativeTo: .subheadline)
                    .foregroundStyle(.white)
                Text(needsInvite
                     ? "Enter the code a friend sent you and we'll get you straight in."
                     : "Enter it now and you'll go straight in.")
                    .flimFont(12, relativeTo: .caption)
                    .foregroundStyle(Color(white: 0.5))

                TextField("", text: $inviteCode, prompt: Text("ABC123").foregroundStyle(Color(white: 0.3)))
                    .flimFont(24, weight: .thin, design: .monospaced, relativeTo: .title2)
                    .tracking(6)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .tint(.white)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                    .focused($codeFocused)
                    .onChange(of: inviteCode) { _, new in
                        inviteCode = String(new.uppercased().prefix(6))
                        inviteError = nil
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.top, 6)

                if let inviteError {
                    Text(inviteError)
                        .flimFont(13, relativeTo: .subheadline)
                        .foregroundStyle(Color(red: 1, green: 0.4, blue: 0.4))
                        .padding(.top, 4)
                }
            } else {
                // Collapsed by default so the screen still reads as "enter your email", with the
                // code one tap away for the people who arrived holding one.
                Button {
                    withAnimation(.snappy(duration: 0.2)) { inviteExpanded = true }
                    codeFocused = true
                } label: {
                    Text("Have an invite code?")
                        .flimFont(14, weight: .medium, relativeTo: .subheadline)
                        .foregroundStyle(accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 16)
        .animation(.snappy(duration: 0.2), value: inviteExpanded)
        .animation(.snappy(duration: 0.2), value: needsInvite)
    }

    /// Fills in an invite code that arrived by link.
    ///
    /// Never overwrites something already typed: someone mid-way through entering a code by hand
    /// should not have it swapped underneath them by a stale link.
    private func adoptPendingInvite() {
        guard inviteCode.isEmpty, let code = PendingInvite.take() else { return }
        inviteCode = code
        withAnimation(.snappy(duration: 0.2)) { inviteExpanded = true }
        Haptics.tap()
    }

    private var isValidEmail: Bool {
        email.contains("@") && email.contains(".")
    }

    /// A half-typed code would fail redemption for no reason, so it blocks submission the same
    /// way a half-typed email does.
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

        // The App Review account signs in with a password rather than an emailed code: a reviewer
        // has no inbox for this address and no invite, so the normal flow dead-ends for them.
        // Checked before anything else so the invite gate is never even consulted.
        if AuthService.isReviewerEmail(email) {
            showReviewerSignIn = true
            return
        }

        do {
            // A code entered up front is redeemed as part of the SAME tap. This is the path that
            // removes the old two-round-trip dance: previously you were rejected, then shown the
            // field, then had to redeem, then send again.
            // Skip a redemption that already succeeded for THIS email.
            //
            // redeem_invite is idempotent server-side, so a repeat costs the inviter nothing.
            // What is not free is the shape underneath: redemption succeeds, the sendOTP right
            // after it fails on a network blip, and the person retries. Re-asking is pointless
            // work on the app's own front door, and it puts a second call through a globally
            // rate-gated RPC for a person who is already allowlisted. `redeemedEmails` is the
            // record the sign-up flow already keeps for exactly this address.
            if !inviteCode.isEmpty, !PendingInviteRedeemed.isRedeemed(for: email) {
                guard try await auth.redeemInvite(code: inviteCode, email: email) else {
                    Haptics.error()
                    // Says BOTH things that can be true, because the server cannot tell you
                    // which, and must not.
                    //
                    // Since invites became finite (2026-08-29) a `false` here means one of two
                    // things: the code does not exist, or it exists and its owner has spent all
                    // theirs. `redeem_invite` deliberately returns the same answer for both, so a
                    // stranger cannot probe which codes are real. That is the right call and is
                    // not changing.
                    //
                    // What WAS wrong is the copy. "Check it and try again" asserts a typo, which
                    // is only one of the two cases: someone handed a genuinely correct code by a
                    // real friend, typed correctly, was told to go re-check a code that is not
                    // wrong, and re-typing it would never work. With three invites a head, that
                    // case is not an edge, it is what scarcity is FOR. This wording accuses
                    // nobody, leaks nothing (it is one string either way), and gives a next step
                    // that can actually succeed.
                    inviteError = InviteCopy.redeemFailed
                    return
                }
                Haptics.success()
            }
            try await auth.sendOTP(email: email)
            showOTP = true
        } catch AuthError.notInvited {
            // Deliberately NOT surfaced as an error. Needing an invite is the expected state for
            // every new person, not a mistake they made, so it opens the field and says what to
            // do next instead of colouring the screen red.
            withAnimation(.snappy(duration: 0.2)) {
                needsInvite = true
                inviteExpanded = true
            }
            codeFocused = true
        } catch AuthError.rateLimited where !inviteCode.isEmpty {
            // Shown against the CODE field, not the email field. The person was acting on the
            // code; putting the reason next to an input they did not touch reads as the email
            // being at fault. The global gate is 30/hour across everyone, so this is rare, and
            // rarer still is the person who sees it understanding why without being told.
            Haptics.error()
            inviteError = InviteCopy.redeemRateLimited
        } catch {
            self.error = error.localizedDescription
        }
    }

}
