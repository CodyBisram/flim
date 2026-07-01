import SwiftUI
import UIKit

// Supabase generates 8-digit email OTP codes by default
private let otpLength = 8

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
                if UIPasteboard.general.hasStrings {
                    Button {
                        let digits = String((UIPasteboard.general.string ?? "").filter(\.isNumber).prefix(otpLength))
                        if !digits.isEmpty { code = digits }
                    } label: {
                        Label("Paste code", systemImage: "doc.on.clipboard")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color(white: 0.6))
                    }
                    .padding(.top, 16)
                }

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

    var body: some View {
        ZStack {
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($isFocused)
                .frame(width: 1, height: 1)
                .opacity(0.001)
                .onChange(of: code) { _, new in
                    code = String(new.filter(\.isNumber).prefix(length))
                }

            HStack(spacing: 6) {
                ForEach(0..<length, id: \.self) { index in
                    digitBox(at: index)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { isFocused = true }
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
