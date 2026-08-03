import SwiftUI

struct PrimaryButton: View {
    let title: String
    var isLoading: Bool = false
    var disabled: Bool = false
    let action: () async -> Void

    @State private var isRunning = false
    /// Label and height scale TOGETHER. Scaling the label alone would push the text out of a
    /// hard-coded 54pt pill at large sizes; scaling the pill alone would leave a tiny label
    /// floating in a tall button. This is the app's primary action control, used on sign-in, the
    /// OTP screen, username selection, roll creation, roll joining and settings, so it was the
    /// single most-seen thing the type pass missed.
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 54

    var body: some View {
        Button {
            guard !isRunning && !disabled else { return }
            isRunning = true
            Task {
                await action()
                isRunning = false
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(.white)
                    .frame(height: height)

                if isLoading || isRunning {
                    ProgressView()
                        .tint(.black)
                        .controlSize(.regular)
                } else {
                    Text(title)
                        .flimFont(16, weight: .medium, relativeTo: .body)
                        .foregroundStyle(.black)
                        // A long title at an accessibility size would otherwise force the pill
                        // wider than the screen; shrink a little before wrapping.
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                }
            }
        }
        .disabled(disabled || isLoading || isRunning)
        .opacity(disabled ? 0.35 : 1)
        .animation(.easeInOut(duration: 0.15), value: disabled)
    }
}
