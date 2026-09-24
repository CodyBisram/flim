import SwiftUI

struct UsernameView: View {
    @Environment(\.flimAccent) private var accent
    @Environment(AuthService.self) private var auth
    @State private var username = ""
    @State private var name = ""
    @State private var isSaving = false
    @State private var error: String?
    @Environment(FeedService.self) private var feed
    @AppStorage("accentColor") private var accentColor = "amber"

    var isValid: Bool { AuthService.isValidUsername(username) }

    var body: some View {
        ZStack {
            FlimTheme.bg.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                Spacer()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Pick a username.")
                        .flimFont(28, weight: .thin, relativeTo: .title3)
                        .foregroundStyle(.white)
                    Text("3 to 20 characters. Letters, numbers and underscores.")
                        .flimFont(15, relativeTo: .body)
                        .foregroundStyle(FlimTheme.textSecondary)
                }
                .padding(.bottom, 40)

                VStack(alignment: .leading, spacing: 6) {
                    Text("USERNAME")
                        .flimFont(11, weight: .medium, relativeTo: .caption)
                        .tracking(2)
                        .foregroundStyle(FlimTheme.textTertiary)

                    HStack {
                        Text("@")
                            .foregroundStyle(FlimTheme.textTertiary)
                        TextField("", text: $username, prompt: Text("yourname").foregroundStyle(FlimTheme.placeholder))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .flimFont(17, relativeTo: .body)
                            .foregroundStyle(.white)
                            .tint(.white)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isValid ? Color.white.opacity(0.2) : Color.clear, lineWidth: 1)
                    )
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("WHAT SHOULD WE CALL YOU? (OPTIONAL)")
                        .flimFont(11, weight: .medium, relativeTo: .caption)
                        .tracking(2)
                        .foregroundStyle(FlimTheme.textTertiary)

                    TextField("", text: $name, prompt: Text("First name").foregroundStyle(FlimTheme.placeholder))
                        .textContentType(.givenName)
                        .autocorrectionDisabled()
                        .flimFont(17, relativeTo: .body)
                        .foregroundStyle(.white)
                        .tint(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 16)
                        .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 12))
                        // The same limit the profile's Name sheet keeps. This field took any
                        // length, so a long name got in here and was cut the first time it was
                        // edited. Stops as you type; the count appears only once it is near,
                        // because the field is optional and a "0/40" under it would be noise.
                        .onChange(of: name) { _, typed in
                            if typed.count > AuthService.displayNameMaxLength {
                                name = String(typed.prefix(AuthService.displayNameMaxLength))
                            }
                        }
                    if name.count >= AuthService.displayNameMaxLength - 10 {
                        Text("\(name.count)/\(AuthService.displayNameMaxLength)")
                            .flimFont(12, relativeTo: .caption)
                            .foregroundStyle(FlimTheme.textTertiary)
                    }
                }
                .padding(.top, 18)

                VStack(alignment: .leading, spacing: 10) {
                    Text("PICK YOUR COLOR")
                        .flimFont(11, weight: .medium, relativeTo: .caption).tracking(2)
                        .foregroundStyle(FlimTheme.textTertiary)
                    HStack(spacing: 14) {
                        ForEach(FlimAccent.allCases) { swatch in
                            let selected = accentColor == swatch.rawValue
                            Button { accentColor = swatch.rawValue; Haptics.tap() } label: {
                                Circle().fill(swatch.color).frame(width: 30, height: 30)
                                    .overlay(Circle().strokeBorder(.white, lineWidth: selected ? 2.5 : 0))
                                    .frame(width: 44, height: 44)   // the target; the swatch itself stays 30
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(swatch.label)
                            .accessibilityValue(selected ? "Selected" : "")
                            .accessibilityAddTraits(selected ? [.isSelected] : [])
                        }
                        Spacer()
                    }
                }
                .padding(.top, 18)

                // A live reason, so the disabled button is never a mystery. The server-side
                // error (a taken username) still takes precedence when there is one.
                if let reason = AuthService.usernameRejection(username), error == nil {
                    Text(reason)
                        .flimFont(13, relativeTo: .subheadline)
                        .foregroundStyle(FlimTheme.textSecondary)
                        .padding(.top, 8)
                }

                if let error {
                    Text(error)
                        .flimFont(13, relativeTo: .subheadline)
                        .foregroundStyle(FlimTheme.error)
                        .padding(.top, 8)
                }

                Spacer()

                // An escape, always. This screen is otherwise a dead end: no back, no sign-out,
                // and nothing else to tap. Anyone who reaches it by mistake, or with the wrong
                // account, could previously only force-quit.
                if let email = auth.currentUser?.email ?? auth.pendingEmail {
                    HStack(spacing: 4) {
                        Text("Signed in as \(email).")
                            .foregroundStyle(FlimTheme.textTertiary)
                        Button("Sign out") {
                            Task { try? await auth.signOut() }
                        }
                        .foregroundStyle(accent)
                    }
                    .flimFont(12, relativeTo: .caption)
                    .padding(.bottom, 4)
                }

                PrimaryButton(title: "Continue", isLoading: isSaving, disabled: !isValid) {
                    await save()
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 40)
        }
        .navigationBarHidden(true)
        // Arrives filled in from the email's local part, so the common case is one glance and
        // Continue rather than inventing a handle on the spot. Still fully editable; the server
        // still decides uniqueness at save exactly as before.
        .onAppear {
            guard username.isEmpty, let email = auth.currentUser?.email ?? auth.pendingEmail else { return }
            username = UsernameSuggestion.from(email: email)
        }
    }

    private func save() async {
        isSaving = true
        error = nil
        do {
            try await auth.setUsername(username.lowercased(), displayName: name)
            try? await auth.setAccent(accentColor)
            // The one-way follow of whoever's code let this account in, the first moment the
            // account's own row exists. Best effort and silent: a failure here costs nothing the
            // person can see, and the follow can be made by hand from the inviter's page.
            if let uid = auth.currentUser?.id,
               let email = auth.currentUser?.email ?? auth.pendingEmail,
               let inviter = PendingInviter.take(for: email), inviter.id != uid {
                NewAccountIntro.rememberInviter(inviter, userId: uid)
                _ = await feed.follow(inviter.id, from: uid)
            }
        } catch {
            self.error = error.localizedDescription
        }
        isSaving = false
    }
}
