import SwiftUI

struct JoinRollView: View {
    @Environment(\.flimAccent) private var accent
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
        .flimSheetSurface()
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
                Text("ROLL CODE")
                    .flimFont(11, weight: .medium, relativeTo: .caption)
                    .tracking(2)
                    .foregroundStyle(Color(white: 0.4))

                TextField("", text: $code, prompt: Text("ABC123").foregroundStyle(Color(white: 0.3)))
                    .flimFont(28, weight: .thin, design: .monospaced, relativeTo: .title2)
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
                    .flimFont(13, relativeTo: .subheadline)
                    .foregroundStyle(Color(red: 1, green: 0.4, blue: 0.4))
            }

            // Say what joining a roll actually means before they commit.
            RevealPromiseNote()

            Spacer()

            // The placeholder was the only hint, and it vanishes the moment they type. A
            // disabled button with no stated reason is the pattern this release is removing.
            if (1...5).contains(code.count) {
                Text("Roll codes are 6 characters.")
                    .flimFont(13, relativeTo: .subheadline)
                    .foregroundStyle(FlimTheme.textTertiary)
                    .padding(.bottom, 4)
            }

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
                .foregroundStyle(accent)
            VStack(spacing: 8) {
                Text("You joined")
                    .flimFont(14, relativeTo: .subheadline)
                    .foregroundStyle(Color(white: 0.5))
                Text(roll.name)
                    .flimFont(26, weight: .thin, relativeTo: .title3)
                    .foregroundStyle(.white)
            }
            RevealPromiseNote()
                .padding(.horizontal, 4)
            Spacer()
            PrimaryButton(title: "Done") { dismiss() }
        }
    }

    private func join() async {
        guard let userId = auth.currentUser?.id else { return }
        isJoining = true
        error = nil
        do {
            let roll = try await rolls.joinRoll(inviteCode: code, userId: userId)
            Activation.log(.rollJoined)
            joinedRoll = roll
            // Joining is the same commitment as creating, so it earns the same countdown. It
            // used to start only for the CREATOR, so everyone who came in by link had no card at
            // all: invited to a roll, then given nothing to wait with.
            RollLiveActivity.sync(rollId: roll.id, rollName: roll.name, revealAt: roll.revealAt,
                                  shotCount: 0, developFrom: roll.createdAt)
            // Point the camera at the roll you just joined, the same as creating one does. This
            // was missing entirely: only CreateRollView ever selected a roll, so joining one and
            // going to shoot put you into Personal with no indication anything was wrong.
            CameraRollSelection.select(roll, for: userId)
            Haptics.success()
        } catch {
            self.error = error.localizedDescription
        }
        isJoining = false
    }
}
