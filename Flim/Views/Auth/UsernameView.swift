import SwiftUI

struct UsernameView: View {
    @Environment(AuthService.self) private var auth
    @State private var username = ""
    @State private var name = ""
    @State private var isSaving = false
    @State private var error: String?
    @AppStorage("accentColor") private var accentColor = "amber"

    var isValid: Bool { AuthService.isValidUsername(username) }

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.04, blue: 0.04).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                Spacer()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Pick a username.")
                        .flimFont(28, weight: .thin, relativeTo: .title3)
                        .foregroundStyle(.white)
                    Text("3 to 20 characters. Letters, numbers and underscores.")
                        .flimFont(15, relativeTo: .body)
                        .foregroundStyle(Color(white: 0.5))
                }
                .padding(.bottom, 40)

                VStack(alignment: .leading, spacing: 6) {
                    Text("USERNAME")
                        .flimFont(11, weight: .medium, relativeTo: .caption)
                        .tracking(2)
                        .foregroundStyle(Color(white: 0.4))

                    HStack {
                        Text("@")
                            .foregroundStyle(Color(white: 0.4))
                        TextField("", text: $username, prompt: Text("yourname").foregroundStyle(Color(white: 0.3)))
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
                        .foregroundStyle(Color(white: 0.4))

                    TextField("", text: $name, prompt: Text("First name").foregroundStyle(Color(white: 0.3)))
                        .textContentType(.givenName)
                        .autocorrectionDisabled()
                        .flimFont(17, relativeTo: .body)
                        .foregroundStyle(.white)
                        .tint(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 16)
                        .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 12))
                }
                .padding(.top, 18)

                VStack(alignment: .leading, spacing: 10) {
                    Text("PICK YOUR COLOR")
                        .flimFont(11, weight: .medium, relativeTo: .caption).tracking(2)
                        .foregroundStyle(Color(white: 0.4))
                    HStack(spacing: 14) {
                        ForEach(FlimAccent.allCases) { swatch in
                            Button { accentColor = swatch.rawValue; Haptics.tap() } label: {
                                Circle().fill(swatch.color).frame(width: 30, height: 30)
                                    .overlay(Circle().strokeBorder(.white, lineWidth: accentColor == swatch.rawValue ? 2.5 : 0))
                            }
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
                        .foregroundStyle(Color(red: 1, green: 0.4, blue: 0.4))
                        .padding(.top, 8)
                }

                Spacer()

                PrimaryButton(title: "Continue", isLoading: isSaving, disabled: !isValid) {
                    await save()
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 40)
        }
        .navigationBarHidden(true)
    }

    private func save() async {
        isSaving = true
        error = nil
        do {
            try await auth.setUsername(username.lowercased(), displayName: name)
        } catch {
            self.error = error.localizedDescription
        }
        isSaving = false
    }
}
