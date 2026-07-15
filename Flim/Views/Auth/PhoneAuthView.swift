import SwiftUI

struct EmailAuthView: View {
    @Environment(AuthService.self) private var auth
    @State private var email = ""
    @State private var isSending = false
    @State private var error: String?
    @State private var showOTP = false
    @ScaledMetric private var subtitleSize = 15

    // Invite-code redemption, revealed inline when `email` fails the invite gate.
    @State private var showInviteSection = false
    @State private var inviteEmailContext = ""
    @State private var inviteCode = ""
    @State private var isRedeeming = false
    @State private var inviteError: String?

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.04, blue: 0.04).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                Spacer()

                VStack(alignment: .leading, spacing: 8) {
                    Text(AppInfo.appName)
                        .font(.system(size: 34, weight: .thin))
                        .tracking(12)
                        .foregroundStyle(.white)
                    Text("Shoot now. See it later. Enter your email to get started.")
                        .font(.system(size: subtitleSize))
                        .foregroundStyle(Color(white: 0.5))
                }
                .padding(.bottom, 40)

                VStack(alignment: .leading, spacing: 6) {
                    Text("EMAIL")
                        .font(.system(size: 11, weight: .medium))
                        .tracking(2)
                        .foregroundStyle(Color(white: 0.4))

                    TextField("", text: $email, prompt: Text("you@example.com").foregroundStyle(Color(white: 0.3)))
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(size: 17))
                        .foregroundStyle(.white)
                        .tint(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 16)
                        .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 12))
                }

                if let error {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(Color(red: 1, green: 0.4, blue: 0.4))
                        .padding(.top, 8)
                }

                if showInviteSection {
                    inviteSection
                }

                Spacer()

                PrimaryButton(title: "Send Code", isLoading: isSending, disabled: !isValidEmail || isRedeeming) {
                    await send()
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 40)
        }
        .navigationBarHidden(true)
        .navigationDestination(isPresented: $showOTP) {
            OTPView()
        }
        .onChange(of: email) { _, newValue in
            if newValue != inviteEmailContext {
                showInviteSection = false
                inviteError = nil
            }
        }
    }

    private var inviteSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Have an invite code?")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
            Text("Enter it below and we'll get you straight in.")
                .font(.system(size: 12))
                .foregroundStyle(Color(white: 0.5))

            TextField("", text: $inviteCode, prompt: Text("ABC123").foregroundStyle(Color(white: 0.3)))
                .font(.system(size: 24, weight: .thin, design: .monospaced))
                .tracking(6)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .tint(.white)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
                .onChange(of: inviteCode) { _, new in
                    inviteCode = String(new.uppercased().prefix(6))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 12))
                .padding(.top, 6)

            if let inviteError {
                Text(inviteError)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(red: 1, green: 0.4, blue: 0.4))
                    .padding(.top, 4)
            }

            PrimaryButton(title: "Redeem Code", isLoading: isRedeeming, disabled: inviteCode.count < 6) {
                await redeemCode()
            }
            .padding(.top, 6)
        }
        .padding(.top, 16)
    }

    private var isValidEmail: Bool {
        email.contains("@") && email.contains(".")
    }

    private func send() async {
        guard !isSending else { return }
        isSending = true
        error = nil
        do {
            try await auth.sendOTP(email: email)
            showOTP = true
        } catch AuthError.notInvited {
            error = AuthError.notInvited.localizedDescription
            inviteEmailContext = email
            showInviteSection = true
        } catch {
            self.error = error.localizedDescription
        }
        isSending = false
    }

    private func redeemCode() async {
        guard !isRedeeming else { return }
        isRedeeming = true
        inviteError = nil
        do {
            let valid = try await auth.redeemInvite(code: inviteCode, email: email)
            if valid {
                Haptics.reveal()
                showInviteSection = false
                inviteCode = ""
                await send()
            } else {
                Haptics.error()
                inviteError = "That code didn’t work. Check it and try again."
            }
        } catch {
            Haptics.error()
            inviteError = error.localizedDescription
        }
        isRedeeming = false
    }
}
