import SwiftUI

struct EmailAuthView: View {
    @Environment(AuthService.self) private var auth
    @State private var email = ""
    @State private var isSending = false
    @State private var error: String?
    @State private var showOTP = false
    @ScaledMetric private var subtitleSize = 15
    #if DEBUG
    @State private var debugPassword = ""
    #endif

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.04, blue: 0.04).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                Spacer()

                VStack(alignment: .leading, spacing: 8) {
                    Text("FLIM")
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

                #if DEBUG
                VStack(alignment: .leading, spacing: 6) {
                    SecureField("", text: $debugPassword, prompt: Text("password (DEBUG sign-in)").foregroundStyle(Color(white: 0.3)))
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .font(.system(size: 15))
                        .foregroundStyle(.white)
                        .tint(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 12))
                    Button("DEBUG sign in →") {
                        Task {
                            error = nil
                            do { try await auth.debugSignIn(email: email, password: debugPassword) }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(white: 0.5))
                }
                .padding(.top, 20)
                #endif

                Spacer()

                PrimaryButton(title: "Send Code", isLoading: isSending, disabled: !isValidEmail) {
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
    }

    private var isValidEmail: Bool {
        email.contains("@") && email.contains(".")
    }

    private func send() async {
        isSending = true
        error = nil
        do {
            try await auth.sendOTP(email: email)
            showOTP = true
        } catch {
            self.error = error.localizedDescription
        }
        isSending = false
    }
}
