import SwiftUI

struct ContentView: View {
    @Environment(AuthService.self) private var auth

    var body: some View {
        Group {
            if auth.isLoading {
                SplashView()
            } else if !auth.isAuthenticated {
                NavigationStack {
                    EmailAuthView()
                }
                .transition(.opacity)
            } else if auth.currentUser?.username == nil {
                NavigationStack {
                    UsernameView()
                }
                .transition(.opacity)
            } else {
                MainTabView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: auth.currentUser?.id)
        .animation(.easeInOut(duration: 0.35), value: auth.currentUser?.username)
        .animation(.easeInOut(duration: 0.35), value: auth.isLoading)
    }
}
