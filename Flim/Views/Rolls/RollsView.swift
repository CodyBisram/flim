import SwiftUI

struct RollsView: View {
    var scrollToTop: Int = 0
    @Environment(AuthService.self) private var auth
    @Environment(RollService.self) private var rolls
    @Environment(PhotoService.self) private var photos
    @State private var showCreate = false
    @State private var showJoin = false
    /// Signed cover URLs keyed by STORAGE PATH, not by roll id.
    ///
    /// Keyed by roll id, changing a roll's cover left the old URL in place forever: the resolve
    /// below skips anything that already has an entry, and that roll did, pointing at the
    /// PREVIOUS cover. The new cover only appeared after a relaunch, when this started empty
    /// again. A signed URL belongs to a path, so keying it by path means a new cover is a new key
    /// and resolves on sight, while an unchanged one still costs nothing.
    @State private var coverURLs: [String: URL] = [:]
    @State private var loadError: String?
    @State private var rollToLeave: Roll?
    @State private var mutedRolls: Set<UUID> = []
    @State private var inviteShareRoll: Roll?

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
        .sheet(item: $inviteShareRoll) { roll in
            ActivityView(items: [AppInfo.rollInviteMessage(rollName: roll.name, code: roll.inviteCode)])
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
            mutedRolls = await photos.fetchMutedRolls(userId: userId)
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Signs every not-yet-resolved cover PATH in one batched call. This used to sign them one at a time in
    /// a loop, so on a cold cache the list's covers appeared one per round-trip, top to bottom,
    /// instead of together.
    private func resolveCovers() async {
        let pending = Set(rolls.coverPaths.values).filter { coverURLs[$0] == nil }
        guard !pending.isEmpty else { return }
        let urls = await photos.signedURLs(for: Array(pending))
        for (path, url) in urls { coverURLs[path] = url }
    }

    /// Long-press actions on a roll row. Muting was previously reachable only from inside the
    /// roll's own ••• menu, even though this row is where the muted bell is actually shown, and
    /// inviting meant opening the roll first. Leaving stays a swipe action too; both paths run
    /// through the same confirmation.
    @ViewBuilder
    private func rollMenu(_ roll: Roll) -> some View {
        Button { inviteShareRoll = roll } label: { Label("Share invite", systemImage: "square.and.arrow.up") }
        Button { toggleMute(roll) } label: {
            let muted = mutedRolls.contains(roll.id)
            Label(muted ? "Unmute notifications" : "Mute notifications",
                  systemImage: muted ? "bell.slash" : "bell")
        }
        if !isCreator(roll) {
            Divider()
            Button(role: .destructive) { rollToLeave = roll } label: {
                Label("Leave roll", systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
    }

    private func toggleMute(_ roll: Roll) {
        guard let uid = auth.currentUser?.id else { return }
        let muted = !mutedRolls.contains(roll.id)
        Haptics.tap()
        if muted { mutedRolls.insert(roll.id) } else { mutedRolls.remove(roll.id) }   // optimistic
        Task { await photos.setRollMuted(muted, rollId: roll.id, userId: uid) }
    }

    /// A developed roll the user hasn't opened the reveal for yet, the "your photos are ready"
    /// state. `rollRevealSeen.<id>` is set in RollDetailView the first time the reveal plays.
    private func isReadyToReveal(_ roll: Roll) -> Bool {
        roll.isDeveloped && !UserDefaults.standard.bool(forKey: "rollRevealSeen.\(roll.id.uuidString)")
    }

    /// Ready-to-reveal rolls first (the whole reason to open the app), then everything else in its
    /// existing newest-first order. Explicit partition so the ordering is obviously stable.
    private var sortedRolls: [Roll] {
        let ready = rolls.rolls.filter(isReadyToReveal)
        let rest = rolls.rolls.filter { !isReadyToReveal($0) }
        return ready + rest
    }

    private var rollList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(sortedRolls) { roll in
                    NavigationLink(value: roll) {
                        RollRow(roll: roll,
                                memberCount: rolls.memberCounts[roll.id],
                                coverURL: rolls.coverPaths[roll.id].flatMap { coverURLs[$0] },
                                coverPath: rolls.coverPaths[roll.id],
                                isMuted: mutedRolls.contains(roll.id),
                                isReadyToReveal: isReadyToReveal(roll))
                    }
                    .listRowBackground(Color(white: 0.08))
                    .listRowSeparatorTint(Color(white: 0.15))
                    .swipeActions(edge: .trailing) {
                        // Members leave via swipe; creators delete from inside the roll (too
                        // destructive for a swipe, it removes the roll for everyone).
                        if !isCreator(roll) {
                            Button(role: .destructive) { rollToLeave = roll } label: {
                                Label("Leave", systemImage: "rectangle.portrait.and.arrow.right")
                            }
                        }
                    }
                    .contextMenu { rollMenu(roll) }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { await load() }
            .onChange(of: scrollToTop) {
                withAnimation(.snappy) { proxy.scrollTo(sortedRolls.first?.id, anchor: .top) }
            }
        }
        .confirmationDialog("Leave this roll?", isPresented: Binding(get: { rollToLeave != nil }, set: { if !$0 { rollToLeave = nil } }), presenting: rollToLeave) { roll in
            Button("Leave Roll", role: .destructive) {
                Haptics.warning()
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
    var coverPath: String?
    var isMuted: Bool = false
    var isReadyToReveal: Bool = false

    var body: some View {
        HStack(spacing: 14) {
            RollCover(roll: roll, coverURL: coverURL, coverPath: coverPath)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(roll.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                    if isMuted {
                        Image(systemName: "bell.slash.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(FlimTheme.textTertiary)
                            .accessibilityLabel("Muted")
                    }
                }

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

                // Reveal status, the clock runs from when the roll was created.
                if isReadyToReveal {
                    // Developed and NOT yet opened: the one thing that should pull you into the
                    // app, so it's loud (filled accent pill, not the muted grey "Developed" chip)
                    // and this row is sorted to the top of the list.
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles").font(.system(size: 10, weight: .bold))
                        Text("Ready to reveal").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(FlimTheme.accent, in: Capsule())
                    .accessibilityLabel("Ready to reveal, tap to open")
                } else if roll.isDeveloped {
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
    var coverPath: String?

    var body: some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(LinearGradient(colors: Self.gradient(for: roll),
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 54, height: 54)
            .overlay {
                if let coverURL {
                    // CachedImage (not AsyncImage): downsamples the decode to the 54pt box and
                    // caches to memory + disk, so revisiting the Rolls tab or scrolling a row
                    // back doesn't re-download and re-decode the image every time. cacheKey is
                    // the path (token-independent) so a rotated signed URL still hits the cache.
                    CachedImage(url: coverURL, maxPixel: 120, cacheKey: coverPath) { image in
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

    /// Deterministic hue from the roll's UUID bytes, stable across launches.
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
