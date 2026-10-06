import SwiftUI

/// The waitlist form, opened from the sign-in screen's "No code yet?" row.
///
/// Thin on purpose: what counts as valid, what the server's reply means and which emails already
/// joined all live in `Waitlist`. `join` is passed in rather than read from `AuthService` so the
/// DEBUG preview host can stand in for the server.
struct WaitlistSheet: View {
    @Environment(\.flimAccent) private var accent
    @Environment(\.dismiss) private var dismiss

    let join: (_ name: String, _ email: String) async -> Waitlist.Outcome
    private let store: UserDefaults

    @State private var name = ""
    @State private var email: String
    @State private var isJoining = false
    /// `invalid` from the server, shown under the email field.
    @State private var emailError: String?
    /// Rate limited or unreachable, shown above the button. The form stays as typed.
    @State private var error: String?
    /// Set once the server said `joined`, or when the sheet opens for an email that already did.
    @State private var joinedEmail: String?
    @FocusState private var focus: Field?

    private enum Field { case name, email }

    /// `prefilledEmail` is whatever the sign-in screen's email field holds, so nobody types it
    /// twice. An email that already joined on this phone opens straight to the joined state.
    init(prefilledEmail: String, store: UserDefaults = .standard,
         join: @escaping (_ name: String, _ email: String) async -> Waitlist.Outcome) {
        let trimmed = prefilledEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        self.join = join
        self.store = store
        _email = State(initialValue: trimmed)
        _joinedEmail = State(initialValue: Waitlist.hasJoined(trimmed, in: store) ? trimmed.lowercased() : nil)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // One column: the scroll region gives way to the keyboard and to large type, and
                // the button stays pinned above both.
                ScrollView {
                    Group {
                        if let joinedEmail {
                            joined(email: joinedEmail)
                        } else {
                            form
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.top, 24)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollDismissesKeyboard(.interactively)

                Group {
                    if joinedEmail != nil {
                        PrimaryButton(title: Waitlist.Copy.done) { dismiss() }
                    } else {
                        PrimaryButton(title: Waitlist.Copy.join, isLoading: isJoining,
                                      disabled: !Waitlist.canSubmit(name: name, email: email)) {
                            await submit()
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .animation(.snappy(duration: 0.2), value: joinedEmail)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                if joinedEmail == nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { dismiss() }.foregroundStyle(.white)
                    }
                }
            }
        }
        .flimSheetSurface()
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(Waitlist.Copy.title)
                    .flimFont(22, weight: .light, relativeTo: .title3)
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)
                Text(Waitlist.Copy.body)
                    .flimFont(14, relativeTo: .subheadline)
                    .foregroundStyle(FlimTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            field(label: Waitlist.Copy.nameField) {
                TextField("", text: $name)
                    .textContentType(.givenName)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focus, equals: .name)
                    .onSubmit { focus = .email }
                    .accessibilityLabel(Waitlist.Copy.nameField)
            }

            VStack(alignment: .leading, spacing: 6) {
                field(label: Waitlist.Copy.emailField) {
                    TextField("", text: $email, prompt: Text(verbatim: "you@example.com").foregroundStyle(FlimTheme.placeholder))
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.join)
                        .focused($focus, equals: .email)
                        .onSubmit { Task { await submit() } }
                        .accessibilityLabel(Waitlist.Copy.emailField)
                }
                if let emailError {
                    Text(emailError)
                        .flimFont(13, relativeTo: .subheadline)
                        .foregroundStyle(FlimTheme.error)
                }
            }

            if let error {
                Text(error)
                    .flimFont(13, relativeTo: .subheadline)
                    .foregroundStyle(FlimTheme.error)
            }
        }
        // A corrected address deserves a clean slate, the same as on the sign-in screen.
        .onChange(of: email) { _, _ in
            emailError = nil
            error = nil
        }
        .onChange(of: name) { _, _ in error = nil }
        .task {
            // The name is the one thing never prefilled, so start there.
            if focus == nil { focus = .name }
        }
    }

    private func field(label: String, @ViewBuilder input: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .flimFont(13, weight: .medium, relativeTo: .subheadline)
                .foregroundStyle(FlimTheme.textTertiary)
                .accessibilityHidden(true)
            input()
                .flimFont(17, relativeTo: .body)
                .foregroundStyle(.white)
                .tint(accent)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(FlimTheme.bgElevated, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func joined(email: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Waitlist.Copy.joinedTitle)
                .flimFont(22, weight: .light, relativeTo: .title3)
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)
            Text(Waitlist.Copy.joinedBody(email: email))
                .flimFont(14, relativeTo: .subheadline)
                .foregroundStyle(FlimTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .transition(.opacity)
    }

    private func submit() async {
        guard !isJoining,
              let cleanName = Waitlist.normalizedName(name),
              let cleanEmail = Waitlist.normalizedEmail(email) else { return }
        isJoining = true
        emailError = nil
        error = nil
        defer { isJoining = false }

        let outcome = await join(cleanName, cleanEmail)
        if outcome == .joined {
            // Remembered only after the server said so, never optimistically.
            Waitlist.remember(cleanEmail, in: store)
            focus = nil
            Haptics.success()
            joinedEmail = cleanEmail
            AccessibilityNotification.Announcement(
                "\(Waitlist.Copy.joinedTitle) \(Waitlist.Copy.joinedBody(email: cleanEmail))"
            ).post()
            return
        }
        // Everything typed stays where it was, so a retry is one tap.
        Haptics.error()
        let message = outcome.message ?? Waitlist.Copy.unreachable
        if outcome.isAboutEmail {
            emailError = message
            focus = .email
        } else {
            error = message
        }
        AccessibilityNotification.Announcement(message).post()
    }
}
