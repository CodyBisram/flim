import SwiftUI
import UIKit

// Supabase mailer OTP length (server-configured, currently 6 digits)
private let otpLength = 6

struct OTPView: View {
    @Environment(AuthService.self) private var auth
    @State private var code = ""
    @State private var isVerifying = false
    @State private var error: String?

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.04, blue: 0.04).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                Spacer()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Check your email.")
                        .font(.system(size: 28, weight: .thin))
                        .foregroundStyle(.white)
                    Text("Enter the \(otpLength)-digit code we sent you.")
                        .font(.system(size: 15))
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
                    let digits = String((UIPasteboard.general.string ?? "").filter(\.isNumber).prefix(otpLength))
                    if !digits.isEmpty { code = digits }
                } label: {
                    Label("Paste code", systemImage: "doc.on.clipboard")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color(white: 0.6))
                }
                .padding(.top, 16)

                if let error {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(Color(red: 1, green: 0.4, blue: 0.4))
                        .padding(.top, 12)
                }

                Spacer()

                PrimaryButton(title: "Verify", isLoading: isVerifying) {
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
            self.error = error.localizedDescription
            code = ""
        }
        isVerifying = false
    }
}

// MARK: - OTP digit field

private struct OTPField: View {
    @Binding var code: String
    let length: Int
    @FocusState private var isFocused: Bool

    // Sanitizes on the same write that delivers autofill/paste/typed input, rather than
    // correcting after the fact in a separate onChange — a follow-up onChange that rewrites
    // the bound value can race with the system's one-time-code autofill transaction and drop
    // the insertion. Strips non-digits (autofill sometimes appends a trailing space) and clamps
    // to `length` instead of rejecting the whole string.
    private var sanitizedCode: Binding<String> {
        Binding(
            get: { code },
            set: { code = String($0.filter(\.isNumber).prefix(length)) }
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

            // A real, full-size text field laid over the boxes — its text and cursor are invisible,
            // so the boxes show the code, but because it's a proper full-size field, one-time-code
            // autofill (tap the keyboard suggestion) and paste land reliably. It must actually span
            // the full width (not just its own intrinsic, near-zero width for an empty string) —
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
                    .font(.system(size: 20, weight: .light, design: .monospaced))
                    .foregroundStyle(.white)
            )
            .frame(height: 52)
            .animation(.easeInOut(duration: 0.1), value: isActive)
    }
}
