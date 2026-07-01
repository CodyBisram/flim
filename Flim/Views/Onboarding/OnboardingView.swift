import SwiftUI

struct OnboardingView: View {
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @State private var page = 0

    private struct Card: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let body: String
    }

    private let cards = [
        Card(icon: "camera.aperture",
             title: "Shoot now.",
             body: "Snap like a disposable camera — no filters to fuss over. Just point and shoot."),
        Card(icon: "hourglass",
             title: "See it later.",
             body: "Your shots develop over time. Personal instants take a minute; shared rolls reveal together at the 12-hour mark. The wait is the fun."),
        Card(icon: "sparkles",
             title: "Share the moment.",
             body: "Post your favorites to your page, follow friends, and react to theirs. FLIM is invite-only — it's just your people.")
    ]

    var body: some View {
        ZStack {
            FlimTheme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                TabView(selection: $page) {
                    ForEach(Array(cards.enumerated()), id: \.offset) { index, card in
                        VStack(spacing: 22) {
                            Spacer()
                            Image(systemName: card.icon)
                                .font(.system(size: 52, weight: .ultraLight))
                                .foregroundStyle(FlimTheme.accent)
                            Text(card.title)
                                .font(.system(size: 30, weight: .thin))
                                .foregroundStyle(.white)
                            Text(card.body)
                                .font(.system(size: 15))
                                .foregroundStyle(FlimTheme.textSecondary)
                                .multilineTextAlignment(.center)
                                .lineSpacing(3)
                                .padding(.horizontal, 44)
                            Spacer()
                            Spacer()
                        }
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                Button {
                    if page < cards.count - 1 {
                        withAnimation { page += 1 }
                    } else {
                        Haptics.tap()
                        hasOnboarded = true
                    }
                } label: {
                    Text(page < cards.count - 1 ? "Next" : "Get started")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(FlimTheme.accent, in: Capsule())
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 20)

                Button("Skip") { hasOnboarded = true }
                    .font(.system(size: 13))
                    .foregroundStyle(FlimTheme.textTertiary)
                    .padding(.bottom, 24)
            }
        }
    }
}
