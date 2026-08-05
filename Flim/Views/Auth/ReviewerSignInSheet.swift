import SwiftUI

/// Password sign-in for the App Review account.
///
/// Deliberately a separate view rather than a mode bolted onto the email screen: it appears only
/// for `AuthService.reviewerEmail`, it is the only place in the app that accepts a password, and
/// keeping it apart means nothing about the normal invite-only flow has to grow a branch for it.
///
/// Not hidden behind a gesture or a build flag. It has to work in the shipped App Store binary,
/// because that is the binary a reviewer installs, and a hidden path a reviewer cannot find is the
/// same as no path at all.
struct ReviewerSignInSheet: View {
    @Environment(\.flimAccent) private var accent
    let email: String
    /// Called after a successful sign-in so the caller can dismiss its own flow.
    var onSignedIn: () -> Void = {}

    @Environment(AuthService.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var isSigningIn = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                FlimTheme.bg.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 18) {
                    Text("App Review sign-in")
                        .flimFont(22, weight: .light, relativeTo: .title3)
                        .foregroundStyle(.white)
                    Text("Enter the password from App Review Information for \(email).")
                        .flimFont(14, relativeTo: .subheadline)
                        .foregroundStyle(FlimTheme.textSecondary)

                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .focused($focused)
                        .flimFont(16, relativeTo: .body)
                        .foregroundStyle(.white)
                        .tint(accent)
                        .padding(.horizontal, 16).padding(.vertical, 14)
                        .background(FlimTheme.bgElevated, in: RoundedRectangle(cornerRadius: 12))
                        .onSubmit { Task { await signIn() } }

                    if let error {
                        Text(error)
                            .flimFont(13, relativeTo: .subheadline)
                            .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.42))
                    }

                    Spacer()

                    PrimaryButton(title: "Sign In", isLoading: isSigningIn,
                                  disabled: password.isEmpty) {
                        await signIn()
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 40)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(.white)
                }
            }
            .task { focused = true }
        }
        .presentationBackground(FlimTheme.bg)
    }

    private func signIn() async {
        guard !isSigningIn, !password.isEmpty else { return }
        isSigningIn = true
        error = nil
        do {
            try await auth.signInWithPassword(email: email, password: password)
            Haptics.success()
            onSignedIn()
            dismiss()
        } catch {
            // Deliberately generic. This screen is reachable by anyone who types the review
            // address, so distinguishing "wrong password" from "no such account" would confirm
            // the account exists to someone probing it.
            self.error = "Couldn't sign in. Check the password and try again."
            Haptics.error()
        }
        isSigningIn = false
    }
}
