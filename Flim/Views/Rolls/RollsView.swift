import SwiftUI

struct RollsView: View {
    @Environment(AuthService.self) private var auth
    @Environment(RollService.self) private var rolls
    @State private var showCreate = false
    @State private var showJoin = false

    var body: some View {
        ZStack {
            FlimTheme.bg.ignoresSafeArea()

            Group {
                if rolls.isLoading && rolls.rolls.isEmpty {
                    ProgressView().tint(.white)
                } else if rolls.rolls.isEmpty {
                    emptyState
                } else {
                    rollList
                }
            }
        }
        .navigationTitle("Rolls")
        .navigationBarTitleDisplayMode(.large)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showJoin = true
                } label: {
                    Image(systemName: "person.badge.plus")
                        .foregroundStyle(FlimTheme.accent)
                }
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(FlimTheme.accent)
                }
            }
        }
        .sheet(isPresented: $showCreate) {
            CreateRollView()
        }
        .sheet(isPresented: $showJoin) {
            JoinRollView()
        }
        .onAppear {
            Task {
                guard let userId = auth.currentUser?.id else { return }
                try? await rolls.fetchRolls(for: userId)
            }
        }
        .navigationDestination(for: Roll.self) { roll in
            RollDetailView(roll: roll)
        }
    }

    private var rollList: some View {
        List {
            ForEach(rolls.rolls) { roll in
                NavigationLink(value: roll) {
                    RollRow(roll: roll)
                }
                .listRowBackground(Color(white: 0.08))
                .listRowSeparatorTint(Color(white: 0.15))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable {
            guard let userId = auth.currentUser?.id else { return }
            try? await rolls.fetchRolls(for: userId)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "film.stack")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(Color(white: 0.3))
            Text("No rolls yet.")
                .font(.system(size: 15, weight: .light))
                .foregroundStyle(Color(white: 0.4))
            Text("Create one or join a friend's.")
                .font(.system(size: 13))
                .foregroundStyle(Color(white: 0.3))

            HStack(spacing: 12) {
                Button("Create") { showCreate = true }
                    .buttonStyle(OutlineButtonStyle())
                Button("Join") { showJoin = true }
                    .buttonStyle(OutlineButtonStyle())
            }
            .padding(.top, 8)
        }
    }
}

private struct RollRow: View {
    let roll: Roll

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(roll.name)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
            Text("Code: \(roll.inviteCode)")
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(Color(white: 0.45))
        }
        .padding(.vertical, 6)
    }
}

struct OutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(FlimTheme.accent)
            .padding(.horizontal, 22)
            .padding(.vertical, 11)
            .glassCapsule(interactive: true)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
