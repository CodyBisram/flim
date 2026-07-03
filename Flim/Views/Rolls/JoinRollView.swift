import SwiftUI

struct JoinRollView: View {
    /// Pre-filled from a `…//join/CODE` deep link; auto-joins when present.
    var initialCode: String = ""

    @Environment(AuthService.self) private var auth
    @Environment(RollService.self) private var rolls
    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var isJoining = false
    @State private var joinedRoll: Roll?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                FlimTheme.bg.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 0) {
                    if let roll = joinedRoll {
                        successView(roll: roll)
                    } else {
                        formView
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 40)
            }
            .navigationBarTitleDisplayMode(.inline)
            .flimInlineTitle("Join a Roll")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
        }
        .presentationBackground(FlimTheme.bg)
        .presentationDetents([.medium])
        .task {
            // Deep-link arrival: fill the code and join automatically.
            if !initialCode.isEmpty, code.isEmpty {
                code = initialCode.uppercased()
                await join()
            }
        }
    }

    private var formView: some View {
        VStack(alignment: .leading, spacing: 24) {
            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                Text("INVITE CODE")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(2)
                    .foregroundStyle(Color(white: 0.4))

                TextField("", text: $code, prompt: Text("ABC123").foregroundStyle(Color(white: 0.3)))
                    .font(.system(size: 28, weight: .thin, design: .monospaced))
                    .tracking(6)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .tint(.white)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                    .onChange(of: code) { _, new in
                        code = String(new.uppercased().prefix(6))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 20)
                    .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 12))
            }

            if let error {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(red: 1, green: 0.4, blue: 0.4))
            }

            Spacer()

            PrimaryButton(title: "Join Roll", isLoading: isJoining, disabled: code.count < 6) {
                await join()
            }
        }
    }

    private func successView(roll: Roll) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "film.stack")
                .font(.system(size: 48, weight: .ultraLight))
                .foregroundStyle(FlimTheme.accent)
            VStack(spacing: 8) {
                Text("You joined")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(white: 0.5))
                Text(roll.name)
                    .font(.system(size: 26, weight: .thin))
                    .foregroundStyle(.white)
            }
            Spacer()
            PrimaryButton(title: "Done") { dismiss() }
        }
    }

    private func join() async {
        guard let userId = auth.currentUser?.id else { return }
        isJoining = true
        error = nil
        do {
            joinedRoll = try await rolls.joinRoll(inviteCode: code, userId: userId)
            Haptics.reveal()
        } catch {
            self.error = error.localizedDescription
        }
        isJoining = false
    }
}
