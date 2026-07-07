import SwiftUI
import UIKit

struct CreateRollView: View {
    @Environment(AuthService.self) private var auth
    @Environment(RollService.self) private var rolls
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var isCreating = false
    @State private var createdRoll: Roll?
    @State private var error: String?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ZStack {
                FlimTheme.bg.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 0) {
                    if let roll = createdRoll {
                        successView(roll: roll)
                    } else {
                        formView
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 40)
            }
            .navigationBarTitleDisplayMode(.inline)
            .flimInlineTitle("New Roll")
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
    }

    private var formView: some View {
        VStack(alignment: .leading, spacing: 24) {
            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                Text("ROLL NAME")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(2)
                    .foregroundStyle(Color(white: 0.4))

                TextField("", text: $name, prompt: Text("Summer Road Trip").foregroundStyle(Color(white: 0.3)))
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
            }

            Spacer()

            PrimaryButton(title: "Create Roll", isLoading: isCreating, disabled: name.trimmingCharacters(in: .whitespaces).isEmpty) {
                await create()
            }
        }
    }

    private func successView(roll: Roll) -> some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.circle")
                .font(.system(size: 48, weight: .ultraLight))
                .foregroundStyle(FlimTheme.accent)

            VStack(spacing: 8) {
                Text(roll.name)
                    .font(.system(size: 22, weight: .thin))
                    .foregroundStyle(.white)
                Text("Share this code with friends")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(white: 0.5))
            }

            Text(roll.inviteCode)
                .font(.system(size: 36, weight: .thin, design: .monospaced))
                .tracking(8)
                .foregroundStyle(.white)
                .padding(.vertical, 20)
                .padding(.horizontal, 28)
                .glassCard(cornerRadius: 16)

            // Copy the code, or share the invite (a tappable https link) straight to friends.
            HStack(spacing: 12) {
                Button {
                    UIPasteboard.general.string = roll.inviteCode
                    Haptics.tap()
                    withAnimation(.snappy(duration: 0.2)) { copied = true }
                } label: {
                    Label(copied ? "Copied" : "Copy code",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(copied ? FlimTheme.accent : .white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .glassCapsule(interactive: true)
                        .contentTransition(.symbolEffect(.replace))
                }

                ShareLink(item: AppInfo.rollInviteMessage(rollName: roll.name, code: roll.inviteCode)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(FlimTheme.accent, in: Capsule())
                }
                .simultaneousGesture(TapGesture().onEnded { Haptics.tap() })
            }
            .padding(.horizontal, 4)

            Spacer()

            PrimaryButton(title: "Done") {
                dismiss()
            }
        }
    }

    private func create() async {
        guard let userId = auth.currentUser?.id else { return }
        isCreating = true
        error = nil
        do {
            createdRoll = try await rolls.createRoll(name: name.trimmingCharacters(in: .whitespaces), createdBy: userId)
            Haptics.reveal()
        } catch {
            self.error = error.localizedDescription
        }
        isCreating = false
    }
}
