import SwiftUI

/// The in-app feedback form: primary path to `submit_feedback`, reached from Settings alongside
/// the mailto fallback (kept for people who'd rather write to a person, and because Apple
/// expects a support contact). A failed send leaves the message on screen rather than clearing
/// it, the whole point of this form is not losing a report the way the mail draft could.
struct FeedbackSheet: View {
    @Environment(\.flimAccent) private var accent
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var message = ""
    @State private var sendError: String?
    @State private var sent = false

    private var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("What's going on?", text: $message, axis: .vertical)
                        .lineLimit(6...12)
                        .flimFont(16, relativeTo: .body)
                        .foregroundStyle(.white)
                        .tint(.white)
                        .padding(16)
                        .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 12))
                        .disabled(sent)

                    Text("Your app version and device model are attached automatically, so we don't have to ask.")
                        .flimFont(12, relativeTo: .caption)
                        .foregroundStyle(FlimTheme.textTertiary)

                    if let sendError {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(sendError)
                                .flimFont(13, relativeTo: .subheadline)
                                .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.42))
                            if let url = AppInfo.feedbackMailURL {
                                Button("Email us instead") { openURL(url) }
                                    .flimFont(13, weight: .medium, relativeTo: .subheadline)
                                    .foregroundStyle(accent)
                            }
                        }
                    }

                    Spacer(minLength: 12)

                    PrimaryButton(title: sent ? "Sent" : "Send", disabled: trimmedMessage.isEmpty || sent) {
                        await send()
                    }
                }
                .padding(20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .flimInlineTitle("Send feedback")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(.white)
                }
            }
        }
        .presentationDetents([.medium])
        .flimSheetSurface()
    }

    private func send() async {
        sendError = nil
        do {
            let accepted = try await FeedbackService.submit(trimmedMessage)
            guard accepted else {
                // The server's own empty-message check. Client-side the Send button is already
                // disabled for an empty field, so this is the server disagreeing after trimming
                // its own way, not the normal path.
                Haptics.error()
                sendError = "That message looks empty. Add a few words and try again."
                return
            }
            Haptics.success()
            sent = true
            // A brief confirmation before the sheet closes, rather than vanishing the instant
            // Send is tapped, so the tap visibly landed before the screen it was on goes away.
            try? await Task.sleep(for: .milliseconds(700))
            dismiss()
        } catch {
            // Left on screen deliberately: a mailto draft this replaces could silently go
            // nowhere if the person never pressed send in Mail, so a failure here has to be
            // loud, and nothing typed can disappear with it.
            Haptics.error()
            sendError = "Couldn't send. Check your connection and try again, or email us instead."
        }
    }
}
