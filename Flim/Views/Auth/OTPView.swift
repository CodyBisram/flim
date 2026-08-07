import SwiftUI
import UIKit

// Supabase mailer OTP length (server-configured, currently 6 digits)
private let otpLength = 6

struct OTPView: View {
    @Environment(\.flimAccent) private var accent
    @Environment(AuthService.self) private var auth
    @State private var code = ""
    @State private var isVerifying = false
    @State private var error: String?
    @State private var isResending = false
    @State private var resendCountdown = 0
    @State private var sentNotice: String?
    @Environment(\.dismiss) private var dismiss

    // Sanitizes on the same write that delivers autofill/paste/typed input, rather than
    // correcting after the fact in a separate onChange, a follow-up onChange that rewrites
    // the bound value can race with the system's one-time-code autofill transaction and drop
    // the insertion. Strips non-digits (autofill sometimes appends a trailing space) and clamps
    // to `length` instead of rejecting the whole string. Shared by the digit field's binding and
    // the paste button so both behave identically.
    static func sanitizeOTPInput(_ raw: String, length: Int) -> String {
        String(raw.filter(\.isNumber).prefix(length))
    }

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.04, blue: 0.04).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                Spacer()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Check your email.")
                        .flimFont(28, weight: .thin, relativeTo: .title3)
                        .foregroundStyle(.white)
                    // The address is echoed because a typo is otherwise invisible: someone who
                    // typed gmial.com waits for mail that will never arrive, with nothing on
                    // screen to tell them why.
                    Text(auth.pendingEmail.map { "We sent a \(otpLength)-digit code to \($0)." }
                         ?? "Enter the \(otpLength)-digit code we sent you.")
                        .flimFont(15, relativeTo: .body)
                        .foregroundStyle(Color(white: 0.5))
                }
                .padding(.bottom, 40)

                OTPField(code: $code, length: otpLength)
                    .onChange(of: code) { _, new in
                        if new.count == otpLength { Task { await verify() } }
                    }

                // The hidden field can't surface the system paste menu, so offer paste directly.
                // Always shown (clipboard state isn't re-checked on appear/return-to-app).
                Button {
                    let digits = OTPView.sanitizeOTPInput(UIPasteboard.general.string ?? "", length: otpLength)
                    if !digits.isEmpty { code = digits }
                } label: {
                    Label("Paste code", systemImage: "doc.on.clipboard")
                        .flimFont(13, weight: .medium)
                        .foregroundStyle(Color(white: 0.6))
                }
                .padding(.top, 16)

                if let sentNotice, error == nil {
                    Text(sentNotice)
                        .flimFont(13, relativeTo: .subheadline)
                        .foregroundStyle(accent)
                        .padding(.top, 8)
                }

                if let error {
                    Text(error)
                        .flimFont(13, relativeTo: .subheadline)
                        .foregroundStyle(Color(red: 1, green: 0.4, blue: 0.4))
                        .padding(.top, 12)
                }

                // Recovery. There was previously none at all: no resend anywhere in the app, and
                // the only way back was the system chevron, which nothing pointed at. Codes
                // expire and mail lands in spam, so this was the highest-traffic dead end in the
                // product, sitting between an invite and a first photo.
                VStack(alignment: .leading, spacing: 10) {
                    Text("No code yet? Check your spam folder.")
                        .flimFont(13, relativeTo: .subheadline)
                        .foregroundStyle(Color(white: 0.45))

                    HStack(spacing: 16) {
                        Button {
                            Task { await resend() }
                        } label: {
                            Text(resendCountdown > 0
                                 ? "Send a new code in \(resendCountdown)s"
                                 : (isResending ? "Sending…" : "Send a new code"))
                                .flimFont(13, weight: .medium, relativeTo: .subheadline)
                                .foregroundStyle(resendCountdown > 0 ? Color(white: 0.4) : accent)
                        }
                        .disabled(resendCountdown > 0 || isResending)

                        Button("Use a different email") { dismiss() }
                            .flimFont(13, weight: .medium, relativeTo: .subheadline)
                            .foregroundStyle(Color(white: 0.55))
                    }
                }
                .padding(.top, 20)

                Spacer()

                PrimaryButton(title: "Verify", isLoading: isVerifying,
                              disabled: code.count < otpLength) {
                    await verify()
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 40)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    private func verify() async {
        guard code.count == otpLength else { return }
        isVerifying = true
        error = nil
        do {
            try await auth.verifyOTP(token: code)
        } catch {
            // Raw server prose told people nothing they could act on. Name the two things that
            // actually go wrong: they read an older email, or the code expired.
            self.error = "That code didn't work. Check the newest email, or send a new code."
            code = ""
        }
        isVerifying = false
    }

    /// Sends a fresh code to the same address, then starts a cooldown so the button cannot be
    /// hammered into a rate limit.
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
            self.error = error.localizedDescription
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

// MARK: - OTP digit field

private struct OTPField: View {
    @Binding var code: String
    let length: Int
    @FocusState private var isFocused: Bool

    private var sanitizedCode: Binding<String> {
        Binding(
            get: { code },
            set: { code = OTPView.sanitizeOTPInput($0, length: length) }
        )
    }

    var body: some View {
        ZStack {
            // The visible digit boxes.
            HStack(spacing: 6) {
                ForEach(0..<length, id: \.self) { index in
                    digitBox(at: index)
                }
            }

            // A real, full-size text field laid over the boxes, its text and cursor are invisible,
            // so the boxes show the code, but because it's a proper full-size field, one-time-code
            // autofill (tap the keyboard suggestion) and paste land reliably. It must actually span
            // the full width (not just its own intrinsic, near-zero width for an empty string), 
            // a narrow/undersized field is unreliable as an autofill insertion target.
            TextField("", text: sanitizedCode)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($isFocused)
                .foregroundStyle(.clear)
                .tint(.clear)
                .frame(maxWidth: .infinity, minHeight: 52)
                .contentShape(Rectangle())
        }
        .onAppear { isFocused = true }
    }

    private func digitBox(at index: Int) -> some View {
        let chars = Array(code)
        let char = index < chars.count ? String(chars[index]) : ""
        let isActive = index == chars.count && isFocused

        return RoundedRectangle(cornerRadius: 8)
            .fill(Color(white: 0.1))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isActive ? Color.white.opacity(0.7) :
                        !char.isEmpty ? Color.white.opacity(0.3) :
                        Color(white: 0.2),
                        lineWidth: isActive ? 1.5 : 1
                    )
            )
            .overlay(
                Text(char)
                    .flimFont(20, weight: .light, design: .monospaced, relativeTo: .title3)
                    .foregroundStyle(.white)
            )
            .frame(height: 52)
            .animation(.easeInOut(duration: 0.1), value: isActive)
    }
}
