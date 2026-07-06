import SwiftUI

struct RollsView: View {
    var scrollToTop: Int = 0
    @Environment(AuthService.self) private var auth
    @Environment(RollService.self) private var rolls
    @Environment(PhotoService.self) private var photos
    @State private var showCreate = false
    @State private var showJoin = false
    @State private var coverURLs: [UUID: URL] = [:]
    @State private var loadError: String?
    @State private var rollToLeave: Roll?

    private func isCreator(_ roll: Roll) -> Bool { auth.currentUser?.id == roll.createdBy }

    var body: some View {
        ZStack {
            FlimTheme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                FlimNavTitle("Rolls")

                Group {
                    if rolls.isLoading && rolls.rolls.isEmpty {
                        ProgressView().tint(.white)
                    } else if let error = loadError, rolls.rolls.isEmpty {
                        ErrorState(message: error) { await load() }
                    } else if rolls.rolls.isEmpty {
                        emptyState
                    } else {
                        rollList
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 18) {
                    Button {
                        showJoin = true
                    } label: {
                        Image(systemName: "person.badge.plus")
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(FlimTheme.accent)
                            .frame(width: 26, height: 24)
                    }
                    .accessibilityLabel("Join a roll")
                    Button {
                        showCreate = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(FlimTheme.accent)
                            .frame(width: 26, height: 24)
                    }
                    .accessibilityLabel("New roll")
                }
            }
        }
        .sheet(isPresented: $showCreate) {
            CreateRollView()
        }
        .sheet(isPresented: $showJoin) {
            JoinRollView()
        }
        .onAppear { Task { await load() } }
        .onChange(of: rolls.coverPaths) {
            Task { await resolveCovers() }
        }
        .navigationDestination(for: Roll.self) { roll in
            RollDetailView(roll: roll)
        }
    }

    /// Fetches the user's rolls, surfacing a network error for the retry state.
    private func load() async {
        guard let userId = auth.currentUser?.id else { return }
        do {
            try await rolls.fetchRolls(for: userId)
            loadError = nil
            await resolveCovers()
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Mints signed URLs for each roll's cover path (skips ones already resolved).
    private func resolveCovers() async {
        for (rollId, path) in rolls.coverPaths where coverURLs[rollId] == nil {
            if let url = try? await photos.signedURL(for: path) {
                coverURLs[rollId] = url
            }
        }
    }

    private var rollList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(rolls.rolls) { roll in
                    NavigationLink(value: roll) {
                        RollRow(roll: roll,
                                memberCount: rolls.memberCounts[roll.id],
                                coverURL: coverURLs[roll.id])
                    }
                    .listRowBackground(Color(white: 0.08))
                    .listRowSeparatorTint(Color(white: 0.15))
                    .swipeActions(edge: .trailing) {
                        // Members leave via swipe; creators delete from inside the roll (too
                        // destructive for a swipe — it removes the roll for everyone).
                        if !isCreator(roll) {
                            Button(role: .destructive) { rollToLeave = roll } label: {
                                Label("Leave", systemImage: "rectangle.portrait.and.arrow.right")
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { await load() }
            .onChange(of: scrollToTop) {
                withAnimation(.snappy) { proxy.scrollTo(rolls.rolls.first?.id, anchor: .top) }
            }
        }
        .confirmationDialog("Leave this roll?", isPresented: Binding(get: { rollToLeave != nil }, set: { if !$0 { rollToLeave = nil } }), presenting: rollToLeave) { roll in
            Button("Leave Roll", role: .destructive) {
                guard let uid = auth.currentUser?.id else { return }
                Task { try? await rolls.leaveRoll(rollId: roll.id, userId: uid); await load() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { roll in
            Text("You'll leave “\(roll.name)” and need the code to rejoin.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "film.stack")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(FlimTheme.accent.opacity(0.8))
            Text("Better with friends.")
                .font(.system(size: 17, weight: .light))
                .foregroundStyle(FlimTheme.textSecondary)
            Text("Start a roll and share the code, or join one with a friend's code.")
                .font(.system(size: 13))
                .foregroundStyle(FlimTheme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

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
    var memberCount: Int?
    var coverURL: URL?

    var body: some View {
        HStack(spacing: 14) {
            RollCover(roll: roll, coverURL: coverURL)

            VStack(alignment: .leading, spacing: 6) {
                Text(roll.name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)

                HStack(spacing: 8) {
                    if let memberCount {
                        MetaChip(icon: "person.2.fill", text: "\(memberCount)")
                    }

                    HStack(spacing: 5) {
                        Image(systemName: "number")
                            .font(.system(size: 9, weight: .bold))
                        Text(roll.inviteCode)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .tracking(1)
                    }
                    .foregroundStyle(FlimTheme.accent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(FlimTheme.accentSoft, in: Capsule())
                }

                // Reveal status — the clock runs from when the roll was created.
                if roll.isDeveloped {
                    MetaChip(icon: "checkmark.seal.fill", text: "Developed",
                             color: FlimTheme.textTertiary, textSize: 11)
                } else {
                    TimelineView(.periodic(from: .now, by: 60)) { tl in
                        let remaining = max(0, Int(roll.revealAt.timeIntervalSince(tl.date)))
                        MetaChip(icon: "hourglass", text: "Reveals in \(Self.short(remaining))",
                                 color: FlimTheme.accent, textSize: 11)
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 8)
    }

    private static func short(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(seconds)s"
    }
}

/// A film-frame cover: the roll's latest photo when there is one, otherwise a stable
/// identity gradient + initial.
private struct RollCover: View {
    let roll: Roll
    var coverURL: URL?

    var body: some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(LinearGradient(colors: Self.gradient(for: roll),
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 54, height: 54)
            .overlay {
                if let coverURL {
                    AsyncImage(url: coverURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.clear
                    }
                } else {
                    Text(roll.name.prefix(1).uppercased())
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.white.opacity(0.95))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 1)
            )
    }

    /// Deterministic hue from the roll's UUID bytes — stable across launches.
    static func gradient(for roll: Roll) -> [Color] {
        let bytes = withUnsafeBytes(of: roll.id.uuid) { Array($0) }
        let sum = bytes.reduce(0) { $0 + Int($1) }
        let h = Double(sum % 360) / 360.0
        return [
            Color(hue: h, saturation: 0.52, brightness: 0.5),
            Color(hue: (h + 0.07).truncatingRemainder(dividingBy: 1), saturation: 0.62, brightness: 0.26)
        ]
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
