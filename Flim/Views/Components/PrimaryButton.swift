import SwiftUI

struct PrimaryButton: View {
    let title: String
    var isLoading: Bool = false
    var disabled: Bool = false
    let action: () async -> Void

    @State private var isRunning = false

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
                    .frame(height: 54)

                if isLoading || isRunning {
                    ProgressView()
                        .tint(.black)
                        .controlSize(.regular)
                } else {
                    Text(title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.black)
                }
            }
        }
        .disabled(disabled || isLoading || isRunning)
        .opacity(disabled ? 0.35 : 1)
        .animation(.easeInOut(duration: 0.15), value: disabled)
    }
}
