import SwiftUI

struct RollsView: View {
    @Environment(\.flimAccent) private var accent
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
    /// Top-slot toast for a leave that failed server-side; a successful leave just needs the row
    /// gone, this is only for the failure the swipe action can't otherwise report.
    @State private var toastMessage: String?
    @State private var toastDismiss: Task<Void, Never>?

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
        .overlay(alignment: .top) {
            if let toastMessage {
                Label(toastMessage, systemImage: "exclamationmark.triangle.fill")
                    .flimFont(13, weight: .medium)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
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
                            .foregroundStyle(accent)
                            .frame(width: 26, height: 24)
                            // 9 is the most these two can take: the HStack spacing is 18, so at 9
                            // each their touch areas meet exactly and neither steals the other's.
                            .expandTapTarget(by: 9)
                    }
                    .accessibilityLabel("Join a roll")
                    Button {
                        showCreate = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(accent)
                            .frame(width: 26, height: 24)
                            .expandTapTarget(by: 9)
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
            ActivityView(items: [AppInfo.rollInviteMessage(rollName: roll.name, code: roll.inviteCode)],
                        onComplete: { Activation.log(.inviteSent) })
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
            await refreshLiveActivities(userId: userId)
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Re-requests the lock-screen countdown for the rolls closest to revealing.
    ///
    /// This is the whole fix for the reach problem. The system ends a Live Activity after about
    /// 8 hours, and a roll takes 12 to develop, so the card that was started at creation is gone
    /// for the last third of the wait. Nothing server-side can restart it, so the app does, every
    /// time this list loads, which is the most-visited screen in the app.
    ///
    /// This runs for every candidate, including rolls whose card is already live.
    ///
    /// It used to skip those, to avoid paying for a shot count that a running card supposedly did
    /// not need. That was wrong, and visibly so: a running card then never received anything new,
    /// so a changed accent or a shot taken since never reached the lock screen, and the only way
    /// to update one was to open that specific roll, which syncs unconditionally.
    ///
    /// The cost is bounded by `maxConcurrent`, so it is at most two count queries on a screen
    /// that already makes several round trips, and `sync` itself is a no-op when the state is
    /// unchanged.
    private func refreshLiveActivities(userId: UUID) async {
        // First the other half of the pass: end cards for rolls that are no longer ours. A roll
        // deleted by its creator, or left on another device, leaves a card counting down to a
        // reveal that is never coming — and this list is the one place that reliably knows the
        // current set.
        RollLiveActivity.reconcile(activeRollIds: rolls.rolls.map(\.id))
        let candidates = RollLiveActivity.rollsNeedingActivity(rolls.rolls, revealAt: \.revealAt)
        for roll in candidates {
            let shots = await photos.rollTotalShotCount(rollId: roll.id)
            RollLiveActivity.sync(rollId: roll.id, rollName: roll.name, revealAt: roll.revealAt,
                                  shotCount: shots, developFrom: roll.createdAt)
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
        Task {
            guard await photos.setRollMuted(muted, rollId: roll.id, userId: uid) else {
                // Put the bell back. A bell that says muted on a roll that still notifies is
                // worse than one that plainly didn't change.
                if muted { mutedRolls.remove(roll.id) } else { mutedRolls.insert(roll.id) }
                Haptics.error()
                return
            }
        }
    }

    /// A developed roll the user hasn't opened the reveal for yet, the "your photos are ready"
    /// state. `rollRevealSeen.<id>` is set in RollDetailView the first time the reveal plays.
    private func isReadyToReveal(_ roll: Roll) -> Bool {
        roll.isDeveloped && !UserDefaults.standard.bool(forKey: "rollRevealSeen.\(roll.id.uuidString)")
    }

    /// Ready to reveal, then still-open rolls by soonest reveal, then the archive. See
    /// `RollImminence.sorted`, which holds the reasoning and the tests.
    private var sortedRolls: [Roll] {
        RollImminence.sorted(rolls.rolls, now: .now, isReadyToReveal: isReadyToReveal)
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
        // The consequence sheet's copy is `RollConsequence.leave`, the same one every other
        // screen asks this question with: this screen, RollDetailView and RollMembersView
        // used to ship three different messages, two disagreeing about needing the code.
        .sheet(item: $rollToLeave) { roll in
            ConsequenceSheet(consequence: .leave(name: roll.name, myShots: nil)) {
                guard let uid = auth.currentUser?.id else { return }
                Task {
                    do {
                        try await rolls.leaveRoll(rollId: roll.id, userId: uid)
                        await load()
                    } catch {
                        // The leave never landed server-side; the row must stay put, not
                        // disappear as though it had, and reloading here would be reload-as-if-left.
                        Haptics.error()
                        withAnimation { toastMessage = "Couldn't leave the roll. Check your connection and try again." }
                        toastDismiss?.cancel()
                        toastDismiss = Task {
                            try? await Task.sleep(for: .seconds(2.4))
                            guard !Task.isCancelled else { return }
                            withAnimation { toastMessage = nil }
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "film.stack")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(accent.opacity(0.8))
            Text("Better with friends.")
                .flimFont(17, weight: .light, relativeTo: .body)
                .foregroundStyle(FlimTheme.textSecondary)
            Text("Start a roll and share the code, or join one with a friend's code.")
                .flimFont(13, relativeTo: .footnote)
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
    @Environment(\.flimAccent) private var accent
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
                        .flimFont(17, weight: .semibold, relativeTo: .body)
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
                            .flimFont(12, weight: .semibold, design: .monospaced, relativeTo: .caption)
                            .tracking(1)
                    }
                    .foregroundStyle(accent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(accent.opacity(0.16), in: Capsule())
                }

                // Reveal status, the clock runs from when the roll was created.
                if isReadyToReveal {
                    // Developed and NOT yet opened: the one thing that should pull you into the
                    // app, so it's loud (filled accent pill, not the muted grey "Developed" chip)
                    // and this row is sorted to the top of the list.
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles").font(.system(size: 10, weight: .bold))
                        Text("Ready to reveal").flimFont(11, weight: .semibold)
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(accent, in: Capsule())
                    .accessibilityLabel("Ready to reveal, tap to open")
                } else if roll.isDeveloped {
                    MetaChip(icon: "checkmark.seal.fill", text: "Developed",
                             color: FlimTheme.textTertiary, textSize: 11)
                } else {
                    TimelineView(.periodic(from: .now, by: 60)) { tl in
                        let remaining = max(0, Int(roll.revealAt.timeIntervalSince(tl.date)))
                        MetaChip(icon: "hourglass", text: "Reveals in \(Self.short(remaining))",
                                 color: accent, textSize: 11)
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
    @Environment(\.flimAccent) private var accent
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
                        .flimFont(22, weight: .light, relativeTo: .title3)
                        .foregroundStyle(.white.opacity(0.95))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 1)
            )
            .overlay { developProgressRing }
            // Padded so the ring's stroke has room outside the cover's own border instead of
            // sitting on top of it.
            .padding(2)
    }

    /// A ring tracing the cover's edge as the roll fills its develop window.
    ///
    /// Text alone wasn't enough: "Reveals in 20m" and "Reveals in 8h" were the same chip at the
    /// same weight, and nobody reads digits while scanning. A ring is readable at a glance with no
    /// text and, unlike a pulsing or colour-escalating chip, adds no motion to a list, which is
    /// the kind of noise the tooltips were removed for.
    @ViewBuilder
    private var developProgressRing: some View {
        if !roll.isDeveloped {
            // Once a minute is plenty for a 12-hour window and matches the countdown chip's tick.
            TimelineView(.periodic(from: .now, by: 60)) { tl in
                let progress = RollImminence.progress(roll: roll, now: tl.date)
                ZStack {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .inset(by: -2)
                        .stroke(.white.opacity(0.10), lineWidth: 2)
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .inset(by: -2)
                        .trim(from: 0, to: progress)
                        .stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        // Starts the fill at the top edge rather than mid-right, so a nearly-full
                        // ring reads as nearly-round rather than lopsided.
                        .rotationEffect(.degrees(-90))
                }
                .accessibilityHidden(true)   // the row's countdown chip already says this in words
            }
        }
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
    @Environment(\.flimAccent) private var accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .flimFont(14, weight: .semibold)
            .foregroundStyle(accent)
            .padding(.horizontal, 22)
            .padding(.vertical, 11)
            .glassCapsule(interactive: true)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
