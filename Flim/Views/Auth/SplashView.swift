import SwiftUI

struct SplashView: View {
    @State private var opacity = 0.0

    var body: some View {
        ZStack {
            FlimTheme.bg.ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "camera.aperture")
                    .font(.system(size: 48, weight: .ultraLight))
                    .foregroundStyle(FlimTheme.accent)
                Text("FLIM")
                    .font(.system(size: 30, weight: .thin, design: .default))
                    .tracking(12)
                    .foregroundStyle(.white)
            }
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeIn(duration: 0.6)) { opacity = 1 }
            }
        }
    }
}
