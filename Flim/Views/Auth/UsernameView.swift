import SwiftUI

struct UsernameView: View {
    @Environment(AuthService.self) private var auth
    @State private var username = ""
    @State private var isSaving = false
    @State private var error: String?

    var isValid: Bool { AuthService.isValidUsername(username) }

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.04, blue: 0.04).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                Spacer()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Pick a username.")
                        .font(.system(size: 28, weight: .thin))
                        .foregroundStyle(.white)
                    Text("3–20 characters, letters and numbers only.")
                        .font(.system(size: 15))
                        .foregroundStyle(Color(white: 0.5))
                }
                .padding(.bottom, 40)

                VStack(alignment: .leading, spacing: 6) {
                    Text("USERNAME")
                        .font(.system(size: 11, weight: .medium))
                        .tracking(2)
                        .foregroundStyle(Color(white: 0.4))

                    HStack {
                        Text("@")
                            .foregroundStyle(Color(white: 0.4))
                        TextField("", text: $username, prompt: Text("yourname").foregroundStyle(Color(white: 0.3)))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.system(size: 17))
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

                if let error {
                    Text(error)
                        .font(.system(size: 13))
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
            try await auth.setUsername(username.lowercased())
        } catch {
            self.error = error.localizedDescription
        }
        isSaving = false
    }
}
