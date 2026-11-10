import SwiftUI

struct SplashView: View {
    @Environment(\.flimAccent) private var accent
    @State private var opacity = 0.0

    var body: some View {
        ZStack {
            DeskGround()
            VStack(spacing: 14) {
                Image(systemName: "camera.aperture")
                    .font(.system(size: 48, weight: .ultraLight))
                    .foregroundStyle(accent)
                if AppInfo.is17 {
                    Text(AppInfo.appName)
                        .font(DeskType.serif(44, relativeTo: .largeTitle))
                        .foregroundStyle(FlimTheme.textPrimary)
                } else {
                    Text(AppInfo.appName)
                        .flimFont(30, weight: .thin, design: .default, relativeTo: .title)
                        .tracking(12)
                        .foregroundStyle(.white)
                }
            }
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeIn(duration: 0.6)) { opacity = 1 }
            }
        }
    }
}
