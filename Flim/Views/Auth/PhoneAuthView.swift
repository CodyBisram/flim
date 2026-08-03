import SwiftUI

struct EmailAuthView: View {
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
                    .font(.system(size: 24, weight: .thin, design: .monospaced))
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
                        .foregroundStyle(FlimTheme.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 16)
        .animation(.snappy(duration: 0.2), value: inviteExpanded)
        .animation(.snappy(duration: 0.2), value: needsInvite)
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
            if !inviteCode.isEmpty {
                guard try await auth.redeemInvite(code: inviteCode, email: email) else {
                    Haptics.error()
                    inviteError = "That code didn't work. Check it and try again."
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
        } catch {
            self.error = error.localizedDescription
        }
    }

}
