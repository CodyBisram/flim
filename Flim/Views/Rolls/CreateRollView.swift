import SwiftUI
import UIKit

struct CreateRollView: View {
    @Environment(\.flimAccent) private var accent
    @Environment(AuthService.self) private var auth
    @Environment(RollService.self) private var rolls
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var isCreating = false
    @State private var createdRoll: Roll?
    @State private var error: String?
    @State private var copied = false
    /// The form fits a medium sheet; the success state (code card + promise note + two button
    /// rows) does not, so it grows to large on create rather than overflowing the detent.
    @State private var detent: PresentationDetent = .medium

    var body: some View {
        NavigationStack {
            ZStack {
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
        .flimSheetSurface()
        .presentationDetents([.medium, .large], selection: $detent)
    }

    private var formView: some View {
        VStack(alignment: .leading, spacing: 24) {
            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                Text("ROLL NAME")
                    .flimFont(11, weight: .medium, relativeTo: .caption)
                    .tracking(2)
                    .foregroundStyle(Color(white: 0.4))

                TextField("", text: $name, prompt: Text("Summer Road Trip").foregroundStyle(Color(white: 0.3)))
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
            }

            Spacer()

            PrimaryButton(title: "Create Roll", isLoading: isCreating, disabled: name.trimmingCharacters(in: .whitespaces).isEmpty) {
                await create()
            }
        }
    }

    private func successView(roll: Roll) -> some View {
        // Everything above Done scrolls, so a short device (or Dynamic Type) shrinks the
        // scrollable middle instead of pushing the checkmark into the nav bar and Done off
        // the bottom edge — the failure mode when this was a plain Spacer-padded VStack.
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 48, weight: .ultraLight))
                        .foregroundStyle(accent)

                    VStack(spacing: 8) {
                        Text(roll.name)
                            .flimFont(22, weight: .thin, relativeTo: .title3)
                            .foregroundStyle(.white)
                        Text("Share this code with friends")
                            .flimFont(14, relativeTo: .subheadline)
                            .foregroundStyle(Color(white: 0.5))
                    }

                    Text(roll.inviteCode)
                        .flimFont(36, weight: .thin, design: .monospaced, relativeTo: .title)
                        .tracking(8)
                        .foregroundStyle(.white)
                        .padding(.vertical, 20)
                        .padding(.horizontal, 28)
                        .glassCard(cornerRadius: 16)

                    // The hook, said the moment the roll exists: everyone's shots come back together.
                    RevealPromiseNote()

                    // Copy the code, or share the invite (a tappable https link) straight to friends.
                    HStack(spacing: 12) {
                        Button {
                            UIPasteboard.general.string = roll.inviteCode
                            Haptics.tap()
                            withAnimation(.snappy(duration: 0.2)) { copied = true }
                        } label: {
                            Label(copied ? "Copied" : "Copy code",
                                  systemImage: copied ? "checkmark" : "doc.on.doc")
                                .flimFont(14, weight: .semibold)
                                .foregroundStyle(copied ? accent : .white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .glassCapsule(interactive: true)
                                .contentTransition(.symbolEffect(.replace))
                        }

                        ShareLink(item: AppInfo.rollInviteMessage(rollName: roll.name, code: roll.inviteCode)) {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .flimFont(14, weight: .semibold)
                                .foregroundStyle(.black)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(accent, in: Capsule())
                        }
                        .simultaneousGesture(TapGesture().onEnded { Haptics.tap() })
                    }
                    .padding(.horizontal, 4)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 20)
                .padding(.bottom, 24)
            }
            // No rubber-banding when the content already fits the large detent.
            .scrollBounceBehavior(.basedOnSize)

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
            let roll = try await rolls.createRoll(name: name.trimmingCharacters(in: .whitespaces), createdBy: userId)
            Activation.log(.rollCreated)
            withAnimation(.snappy(duration: 0.3)) {
                createdRoll = roll
                detent = .large
            }
            RollLiveActivity.sync(rollId: roll.id, rollName: roll.name, revealAt: roll.revealAt,
                                  shotCount: 0, developFrom: roll.createdAt)
            // The camera should default to shooting into a roll you just made until you
            // deliberately switch away from it.
            CameraRollSelection.select(roll, for: userId)
            Haptics.success()
        } catch {
            self.error = error.localizedDescription
        }
        isCreating = false
    }
}

/// The roll's core hook, stated in one line: everyone shoots into it, and it all reveals
/// together after the develop delay. Shown at create + join so the promise lands before someone
/// is already inside a roll. The delay text is derived from `Roll.developDelay`, so it reads "12
/// hours" on release and the shortened debug value automatically.
struct RevealPromiseNote: View {
    @Environment(\.flimAccent) private var accent
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "hourglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(accent)
            Text("Everyone shoots into it. All the shots reveal together, \(Self.delayText) after the roll starts.")
                .flimFont(13, relativeTo: .subheadline)
                .foregroundStyle(FlimTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
    }

    /// A human phrase for the develop delay, so the copy tracks the constant rather than
    /// hardcoding "12 hours" (which would read wrong in a DEBUG build's 2-minute delay).
    private static var delayText: String {
        let hours = Int(Roll.developDelay / 3600)
        if hours >= 1 { return hours == 1 ? "1 hour" : "\(hours) hours" }
        let minutes = max(1, Int(Roll.developDelay / 60))
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
}
