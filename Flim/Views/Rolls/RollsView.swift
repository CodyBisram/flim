import SwiftUI

/// The Rolls tab, rebuilt around one idea (Rolls redesign, 2026-08-26): the screen should do
/// the thing its clocks are asking for. The roll closing soonest is a header with a primary
/// action (Shoot into this roll); the other open rolls are a picker, not a list; Ready to
/// reveal stays a loud transient band; developed rolls become an album grid. The visual
/// anatomy is the Darkroom's: band, meta line, film rack between dashed perforations.
///
/// One periodic redraw on the whole screen: a single TimelineView drives the active roll's
/// clock and every develop arc. Its tick is ADAPTIVE: 60s normally, 1s only when the closing
/// label is in its seconds form, because a seconds label on a minute tick is stale the moment
/// it draws. The archive is static; the Ready band is static (its arc is complete).
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
    /// gone, this is only for the failure the menu action can't otherwise report.
    @State private var toastMessage: String?
    @State private var toastDismiss: Task<Void, Never>?
    /// The roll in the header. Persisted per scene so returning from Camera does not reset the
    /// choice; `activeRoll` falls back to the soonest-closing roll when this develops, is left,
    /// or is deleted.
    @SceneStorage("rollsActiveRollId") private var activeRollIdRaw = ""
    /// Per-roll TOTAL shot counts for the racks and meta lines. Server-side counts, never a
    /// page length: `PhotoService`'s pagination doc and `RollDetailView.rollFullyPaged` both
    /// record undercounting bugs from exactly that.
    @State private var frameCounts: [UUID: Int] = [:]
    /// The signed-in member's own counts, for "you shot 4". Same server-side rule.
    @State private var myFrameCounts: [UUID: Int] = [:]
    /// The screen's width, measured once, for `DarkroomDayUnit.stripCapacity`.
    @State private var containerWidth: CGFloat = 0
    /// Bumped at the instant the active roll develops, purely to re-derive the bands; see
    /// the `.task(id:)` on the body.
    @State private var developTick = 0

    private func isCreator(_ roll: Roll) -> Bool { auth.currentUser?.id == roll.createdBy }

    // MARK: - The three bands

    /// Open rolls, soonest closing first. A developed roll is not shootable, so it is not
    /// a choice in the picker.
    private var openRolls: [Roll] {
        rolls.rolls.filter { !$0.isDeveloped }.sorted { $0.revealAt < $1.revealAt }
    }

    private var readyRolls: [Roll] {
        rolls.rolls.filter { isReadyToReveal($0) }
    }

    /// Developed and seen, newest reveal first.
    private var developedRolls: [Roll] {
        rolls.rolls.filter { $0.isDeveloped && !isReadyToReveal($0) }
            .sorted { $0.revealAt > $1.revealAt }
    }

    private var activeRoll: Roll? {
        openRolls.first { $0.id.uuidString == activeRollIdRaw } ?? openRolls.first
    }

    var body: some View {
        ZStack {
            FlimTheme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                Group {
                    if rolls.isLoading && rolls.rolls.isEmpty {
                        ProgressView().tint(.white)
                    } else if let error = loadError, rolls.rolls.isEmpty {
                        ErrorState(message: error) { await load() }
                    } else if rolls.rolls.isEmpty {
                        emptyState
                    } else {
                        rollsScroll
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { containerWidth = $0 }
        // The bands (open / ready / developed) are derived in BODY, which TimelineView ticks
        // do not re-evaluate: without this, the moment the active roll develops the header
        // would sit on "0s left to shoot" with a dead verb until some other state changed.
        // Sleeping until the active roll's own reveal instant and bumping state re-derives
        // the bands right as the roll crosses over; `task(id:)` re-arms when the active roll
        // changes and cancels when the view goes away.
        .task(id: activeRoll?.revealAt) {
            guard let revealAt = activeRoll?.revealAt else { return }
            let wait = revealAt.timeIntervalSinceNow + 0.5
            guard wait > 0 else { return }
            try? await Task.sleep(for: .seconds(wait))
            developTick += 1
        }
        .overlay(alignment: .top) {
            if let toastMessage {
                Label(toastMessage, systemImage: "exclamationmark.triangle.fill")
                    .flimFont(13.5, weight: .medium, relativeTo: .subheadline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .navigationBarHidden(true)
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
        // The consequence sheet's copy is `RollConsequence.leave`, the same one every other
        // screen asks this question with.
        .sheet(item: $rollToLeave) { roll in
            ConsequenceSheet(consequence: .leave(name: roll.name, myShots: myFrameCounts[roll.id])) {
                guard let uid = auth.currentUser?.id else { return }
                Task {
                    do {
                        try await rolls.leaveRoll(rollId: roll.id, userId: uid)
                        await load()
                    } catch {
                        // The leave never landed server-side; the roll must stay put, not
                        // disappear as though it had.
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
        .onAppear { Task { await load() } }
        .onChange(of: rolls.coverPaths) {
            Task { await resolveCovers() }
        }
        .navigationDestination(for: Roll.self) { roll in
            RollDetailView(roll: roll)
        }
    }

    // MARK: - Header

    /// The compact bar every tab shares: the screen's own name at the far left, controls at
    /// the right, one row (Feed and Darkroom set the pattern). One glyph, two actions: the
    /// redesign collapses the old create/join pair, since both start a roll's life here.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Rolls")
                .flimFont(17, weight: .light, relativeTo: .body)
                .tracking(0.5)
                .foregroundStyle(FlimTheme.textSecondary)
            // The ledger, taken whole from Feed's and Darkroom's bars: the urgent fact in
            // accent with the glow (a sealed roll is exactly what that treatment is reserved
            // for), the calm fact in tertiary, and never a zero. `fetchRolls` is unpaginated
            // (every membership row in one query), so counting the loaded set IS the
            // server-side truth; no extra count query needed.
            if !readyRolls.isEmpty {
                Text("·")
                    .flimFont(12.5, relativeTo: .footnote)
                    .foregroundStyle(FlimTheme.textTertiary)
                Text("\(readyRolls.count) ready")
                    .flimFont(12.5, relativeTo: .footnote)
                    .foregroundStyle(accent)
                    .shadow(color: accent.opacity(0.55), radius: 6)
            } else if !openRolls.isEmpty {
                Text("·")
                    .flimFont(12.5, relativeTo: .footnote)
                    .foregroundStyle(FlimTheme.textTertiary)
                Text("\(openRolls.count) open")
                    .flimFont(12.5, relativeTo: .footnote)
                    .foregroundStyle(FlimTheme.textTertiary)
            }
            Spacer(minLength: 8)
            Menu {
                Button { showCreate = true } label: { Label("New roll", systemImage: "plus") }
                Button { showJoin = true } label: { Label("Join with a code", systemImage: "person.badge.plus") }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(accent)
                    .frame(width: 38, height: 38)
                    .glassCapsule(interactive: true)
            }
            .accessibilityLabel("New roll or join with a code")
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }

    // MARK: - The scroll

    private var rollsScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    Color.clear.frame(height: 0).id("rollsTop")

                    // The whole open-roll region shares ONE clock. The cadence is decided
                    // from the active roll: 1s only near the closing window's seconds form,
                    // 60s the rest of a roll's life, so the fast tick is reachable only in
                    // the last minutes and costs nothing in practice.
                    if let active = activeRoll {
                        TimelineView(.periodic(from: .now, by: clockCadence(for: active))) { tl in
                            VStack(spacing: 0) {
                                // A picker with one choice is an echo of the header right
                                // below it (owner's call, on device, 2026-08-27): it only
                                // appears once there is genuinely something to switch to.
                                // Long-press actions for a solo roll live on the header's
                                // own menu paths.
                                if openRolls.count > 1 {
                                    openRollPicker(now: tl.date)
                                }
                                activeRollBlock(active, now: tl.date)
                            }
                        }
                    } else {
                        nothingOpenBlock
                    }

                    DarkroomUnitSeparator()
                        .padding(.top, 9)   // the separator brings its own 11; the design wants 20 here

                    ForEach(readyRolls) { roll in
                        readyBand(roll)
                    }

                    if !developedRolls.isEmpty {
                        developedSection
                    }
                }
                .padding(.bottom, 24)
            }
            .refreshable { await load() }
            .onChange(of: scrollToTop) {
                withAnimation(.snappy) { proxy.scrollTo("rollsTop", anchor: .top) }
            }
        }
    }

    /// 1s only while the closing label is (or is about to be) counting seconds; 60s otherwise.
    /// The 120s threshold catches the minutes-to-seconds transition on a coarse tick.
    private func clockCadence(for roll: Roll) -> TimeInterval {
        RollImminence.secondsRemaining(roll: roll, now: .now) < 120 ? 1 : 60
    }

    // MARK: - Picker

    private func openRollPicker(now: Date) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                ForEach(openRolls) { roll in
                    pickerItem(roll, now: now)
                }
            }
            .padding(.horizontal, 16)
        }
        // The trailing fade says "there is more" without a scroll indicator.
        .mask(
            HStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 26)
            }
        )
    }

    private func pickerItem(_ roll: Roll, now: Date) -> some View {
        let selected = roll.id == activeRoll?.id
        return Button {
            Haptics.tap()
            activeRollIdRaw = roll.id.uuidString
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(roll.name)
                        .flimFont(13.5, weight: .medium, relativeTo: .subheadline)
                        .foregroundStyle(selected ? FlimTheme.textPrimary : FlimTheme.textSecondary)
                    Text(pickerTime(roll, now: now))
                        .flimFont(11, relativeTo: .caption2)
                        .foregroundStyle(selected ? accent : FlimTheme.textSecondary)
                }
                .lineLimit(1)
                // Selection is carried by the accent mark, never by contrast: unselected
                // items must stay readable (that regression has been caught three times).
                RoundedRectangle(cornerRadius: 1)
                    .fill(selected ? accent : .clear)
                    .frame(height: 2)
            }
        }
        .buttonStyle(.plain)
        .contextMenu { rollMenu(roll) }
        .accessibilityLabel("\(roll.name), \(pickerTime(roll, now: now))\(selected ? ", selected" : "")")
    }

    private func pickerTime(_ roll: Roll, now: Date) -> String {
        if let closing = RollImminence.closingLabel(roll: roll, now: now) {
            // "24m left" / "40s left"; the picker only has room for the number.
            return closing.replacingOccurrences(of: " left", with: "")
        }
        return Self.longRemaining(RollImminence.secondsRemaining(roll: roll, now: now))
    }

    // MARK: - Active roll

    private func activeRollBlock(_ roll: Roll, now: Date) -> some View {
        let closing = RollImminence.closingLabel(roll: roll, now: now) != nil
        return VStack(alignment: .leading, spacing: 0) {
            NavigationLink(value: roll) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(roll.name)
                        .flimFont(26, weight: .light, relativeTo: .title3)
                        .tracking(0.3)
                        .foregroundStyle(FlimTheme.textPrimary)
                        .padding(.bottom, 5)
                    clockLine(roll, now: now, closing: closing)
                    Text(activeMeta(roll))
                        .flimFont(12.5, relativeTo: .footnote)
                        .foregroundStyle(FlimTheme.textSecondary)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)

            NavigationLink(value: roll) {
                rack(frames: frameCounts[roll.id] ?? 0,
                     fraction: RollImminence.progress(roll: roll, now: now),
                     sealed: false)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .accessibilityLabel("\(frameCounts[roll.id] ?? 0) frames, developing. Opens the roll.")

            Button {
                Haptics.tap()
                // The Camera already accepts a pre-selected roll; reuse that path, then
                // switch tabs. Two notifications because they already exist separately.
                NotificationCenter.default.post(name: .selectCameraRoll, object: roll)
                NotificationCenter.default.post(name: .openCamera, object: nil)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "camera.aperture").font(.system(size: 18))
                    Text(closing ? "Last frames. Shoot now" : "Shoot into this roll")
                        .flimFont(15, weight: .medium, relativeTo: .body)
                }
                .foregroundStyle(accent)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .overlay(Capsule().strokeBorder(accent, lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 14)
        }
        .padding(.top, 16)
    }

    private func clockLine(_ roll: Roll, now: Date, closing: Bool) -> some View {
        let closesAt = roll.revealAt.formatted(date: .omitted, time: .shortened)
        let remaining: String
        if let label = RollImminence.closingLabel(roll: roll, now: now) {
            remaining = label.replacingOccurrences(of: " left", with: "") + " left to shoot"
        } else {
            remaining = Self.longRemaining(RollImminence.secondsRemaining(roll: roll, now: now)) + " left to shoot"
        }
        // Inside the last hour the WHOLE line goes accent; the deadline is the message.
        return (
            Text("Closes \(closesAt) · ").foregroundStyle(closing ? accent : FlimTheme.textSecondary)
            + Text(remaining).foregroundStyle(accent)
        )
        .flimFont(12.5, relativeTo: .footnote)
    }

    private func activeMeta(_ roll: Roll) -> String {
        let people = rolls.memberCounts[roll.id].map { "\($0) \($0 == 1 ? "person" : "people")" } ?? "Your roll"
        guard let frames = frameCounts[roll.id], frames > 0 else {
            return "\(people) · no frames yet"
        }
        let mine = myFrameCounts[roll.id] ?? 0
        let yours = mine > 0 ? "you shot \(mine)" : "none of them yours"
        return "\(people) · \(frames) frame\(frames == 1 ? "" : "s") · \(yours)"
    }

    // MARK: - Film rack

    /// One strip, never wrapped, and only as long as its film: existing frames render as
    /// wells (sealed wells for a Ready roll) and when the roll holds more than fit, the last
    /// slot becomes a `+N` overflow well. No pad slots and NOTHING at zero frames, per
    /// `DarkroomFrameSlot.empty`'s own rule ("a three-shot day is a short piece of film, not
    /// a strip nine-tenths empty"): the meta line already says "no frames yet", and a
    /// full-width blank strip read as a loading skeleton (the same reason 3c's was cut).
    @ViewBuilder
    private func rack(frames: Int, fraction: Double, sealed: Bool) -> some View {
        let capacity = DarkroomDayUnit.stripCapacity(availableWidth: max(0, containerWidth - 32))
        let overflow = frames > capacity ? frames - (capacity - 1) : 0
        let wells = overflow > 0 ? capacity - 1 : min(frames, capacity)
        let slotCount = wells + (overflow > 0 ? 1 : 0)
        if slotCount > 0 {
            VStack(alignment: .leading, spacing: 0) {
                perforation(slotCount: slotCount)
                HStack(spacing: DarkroomDayUnit.frameGap) {
                    ForEach(0..<wells, id: \.self) { _ in
                        rackWell(sealed: sealed) {
                            DarkroomDevelopArc(accent: accent, fraction: sealed ? 1 : fraction)
                                .frame(width: 16, height: 16)
                        }
                    }
                    if overflow > 0 {
                        rackWell(sealed: sealed) {
                            Text("+\(overflow)")
                                .flimFont(11, weight: .medium, relativeTo: .caption2)
                                .foregroundStyle(accent)
                        }
                    }
                }
                .padding(.vertical, 2)
                perforation(slotCount: slotCount)
            }
            .accessibilityHidden(true)
        }
    }

    /// The Darkroom's developing well, verbatim geometry; `sealed` is the Ready band's
    /// accent-tinted variant. Sealed frames are never real photographs: the reveal is the
    /// first time anyone sees them.
    private func rackWell(sealed: Bool, @ViewBuilder content: () -> some View) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(sealed ? accent.opacity(0.16) : Color(white: 0.063))
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(sealed ? accent.opacity(0.35) : FlimTheme.stroke, lineWidth: 1)
            )
            .overlay { content() }
            .frame(width: DarkroomDayUnit.framePitch - DarkroomDayUnit.frameGap, height: 59)
    }

    private func perforation(slotCount: Int) -> some View {
        DarkroomPerforationLine()
            .frame(width: DarkroomDayUnit.perforationWidth(slotCount: slotCount), height: 3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Ready band

    private func readyBand(_ roll: Roll) -> some View {
        NavigationLink(value: roll) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text(roll.name)
                        .flimFont(17, weight: .light, relativeTo: .body)
                        .tracking(0.4)
                        .foregroundStyle(FlimTheme.textPrimary)
                    Spacer(minLength: 8)
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles").font(.system(size: 10, weight: .bold))
                        Text(frameCounts[roll.id].map { "Reveal · \($0)" } ?? "Reveal")
                            .flimFont(11, weight: .medium, relativeTo: .caption2)
                    }
                    .foregroundStyle(accent)
                    .padding(.vertical, 4).padding(.horizontal, 9)
                    .background(accent.opacity(0.16), in: Capsule())
                    .overlay(Capsule().strokeBorder(accent, lineWidth: 1))
                }
                .padding(.top, 10).padding(.leading, 16).padding(.trailing, 12).padding(.bottom, 5)

                Text(readyMeta(roll))
                    .flimFont(12.5, relativeTo: .footnote)
                    .foregroundStyle(FlimTheme.textTertiary)
                    .padding(.horizontal, 16).padding(.bottom, 5)

                rack(frames: frameCounts[roll.id] ?? 0, fraction: 1, sealed: true)
                    .padding(.horizontal, 16)
                    .padding(.top, 5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Developed, so no Share invite here: invites end when a roll develops.
        .contextMenu {
            Button { toggleMute(roll) } label: {
                let muted = mutedRolls.contains(roll.id)
                Label(muted ? "Unmute notifications" : "Mute notifications",
                      systemImage: muted ? "bell.slash" : "bell")
            }
            if !isCreator(roll) {
                Button(role: .destructive) { rollToLeave = roll } label: {
                    Label("Leave roll", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        }
        .accessibilityLabel("\(roll.name), ready to reveal, \(frameCounts[roll.id] ?? 0) sealed shots")
    }

    private func readyMeta(_ roll: Roll) -> String {
        let members = rolls.memberCounts[roll.id] ?? 1
        return members > 1
            ? "\(members) people · sealed until you open it"
            : "Just you · sealed until you open it"
    }

    // MARK: - Nothing open (3c)

    private var nothingOpenBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("No roll is open")
                .flimFont(26, weight: .light, relativeTo: .title3)
                .foregroundStyle(FlimTheme.textPrimary)
                .padding(.horizontal, 16)
            // The duration must come from the constant: a literal "12 hours" is false in
            // every DEBUG build, and `Roll`'s own doc records exactly that bug.
            Text("A roll closes \(Roll.developDelayPhrase) after it starts. Nobody sees a frame until then.")
                .flimFont(12.5, relativeTo: .footnote)
                .foregroundStyle(FlimTheme.textSecondary)
                .lineSpacing(4)
                .padding(.horizontal, 16)
                .padding(.top, 6)

            // No rack here (cut in revision 3): a strip of empty slots carried no state and
            // read as a loading skeleton. The whitespace is correct; the photographs begin
            // one section down.
            HStack(spacing: 8) {
                Button { showCreate = true } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "plus").font(.system(size: 14))
                        Text("Start a roll").flimFont(15, weight: .medium, relativeTo: .body)
                    }
                    .foregroundStyle(accent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .overlay(Capsule().strokeBorder(accent, lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                Button { showJoin = true } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "person.badge.plus").font(.system(size: 14))
                        Text("Join with a code").flimFont(15, weight: .medium, relativeTo: .body)
                    }
                    .foregroundStyle(FlimTheme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .overlay(Capsule().strokeBorder(FlimTheme.stroke, lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
        }
        .padding(.top, 16)
    }

    // MARK: - Developed (the archive)

    private var developedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Developed · \(developedRolls.count)")
                    .flimFont(11, weight: .semibold, relativeTo: .caption2)
                    .tracking(1.4)
                    .textCase(.uppercase)
                    .foregroundStyle(FlimTheme.textSecondary)
                LinearGradient(colors: [FlimTheme.stroke, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(height: 1)
            }
            .padding(.top, 18).padding(.horizontal, 16).padding(.bottom, 12)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                      spacing: 10) {
                ForEach(developedRolls) { roll in
                    archiveTile(roll)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func archiveTile(_ roll: Roll) -> some View {
        NavigationLink(value: roll) {
            VStack(alignment: .leading, spacing: 5) {
                // The cover takes its size from the COLUMN (Color.clear + fit), never from
                // the image: a scaledToFill photo in a bare container inflates past its grid
                // cell and paints over the header, the gutters, and its own caption row.
                Color.clear
                    .aspectRatio(FlimTheme.frameAspect, contentMode: .fit)
                    .overlay {
                        ZStack {
                            LinearGradient(colors: Self.gradient(for: roll),
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                            // The URL is passed in OPTIONALLY, and the initial is the
                            // placeholder rather than a sibling branch. That distinction is the
                            // whole fix for the cover flashing a coloured letter on every launch.
                            //
                            // The bytes are almost always already on this device: `CachedImage`
                            // keys its disk cache on the STORAGE PATH, not the signed URL, and
                            // tries that cache before it looks at the URL at all. Gating the view's
                            // very existence on `coverURLs[path]` meant that fast path was never
                            // reached: the tile sat on a gradient through a roll fetch, a cover
                            // fetch and a sign round trip, then swapped to a photo it had all
                            // along. Handing `CachedImage` the path the moment it is known lets a
                            // warm cover paint immediately and a cold one fall through to the
                            // placeholder while the network catches up.
                            if let path = rolls.coverPaths[roll.id] {
                                CachedImage(url: coverURLs[path], maxPixel: 400, cacheKey: path) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    Text(roll.name.prefix(1).uppercased())
                                        .flimFont(26, weight: .light, relativeTo: .title3)
                                        .foregroundStyle(.white.opacity(0.95))
                                }
                            } else {
                                Text(roll.name.prefix(1).uppercased())
                                    .flimFont(26, weight: .light, relativeTo: .title3)
                                    .foregroundStyle(.white.opacity(0.95))
                            }
                        }
                    }
                    // 12, the app's photograph radius (the feed hero, the reveal's print, the
                    // pager's box). These tiles had the rack well's 2, which they inherited
                    // rather than chose: a well is a small sealed film frame and 2 is right
                    // for it, while this is a ~180pt photograph with the roll's name underneath. The
                    // wells keep their 2, so the film language is intact where it belongs.
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(FlimTheme.stroke, lineWidth: 1))

                HStack(spacing: 5) {
                    Text(roll.name)
                        .flimFont(13.5, relativeTo: .subheadline)
                        .foregroundStyle(FlimTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if mutedRolls.contains(roll.id) {
                        Image(systemName: "bell.slash.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(FlimTheme.textTertiary)
                            .accessibilityLabel("Muted")
                    }
                }
                Text(archiveMeta(roll))
                    .flimFont(12.5, relativeTo: .footnote)
                    .foregroundStyle(FlimTheme.textTertiary)
                    .padding(.top, -3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // No Share invite on an archive tile: invites end when a roll develops, and
        // offering one here would resurrect a dead action.
        .contextMenu {
            Button { toggleMute(roll) } label: {
                let muted = mutedRolls.contains(roll.id)
                Label(muted ? "Unmute notifications" : "Mute notifications",
                      systemImage: muted ? "bell.slash" : "bell")
            }
            if !isCreator(roll) {
                Button(role: .destructive) { rollToLeave = roll } label: {
                    Label("Leave roll", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        }
        .accessibilityLabel("\(roll.name), developed \(roll.revealAt.formatted(date: .abbreviated, time: .omitted))")
    }

    private func archiveMeta(_ roll: Roll) -> String {
        let date = roll.revealAt.formatted(.dateTime.month(.abbreviated).day())
        if let members = rolls.memberCounts[roll.id], members > 1 {
            return "\(members) people · \(date)"
        }
        return date
    }

    // MARK: - Shared menu (open rolls only; developed surfaces build their own without invite)

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
    /// state. `rollRevealSeen.<id>` is set in RollDetailView when the reveal completes.
    private func isReadyToReveal(_ roll: Roll) -> Bool {
        roll.isDeveloped && !UserDefaults.standard.bool(forKey: "rollRevealSeen.\(roll.id.uuidString)")
    }

    // MARK: - Loading

    /// Fetches the user's rolls, surfacing a network error for the retry state.
    private func load() async {
        guard let userId = auth.currentUser?.id else { return }
        do {
            try await rolls.fetchRolls(for: userId)
            loadError = nil
            await resolveCovers()
            mutedRolls = await photos.fetchMutedRolls(userId: userId)
            await refreshFrameCounts(userId: userId)
            await refreshLiveActivities(userId: userId)
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Server-side counts for every roll the racks and meta lines describe: the open set and
    /// the Ready set. The archive shows no counts, so it costs nothing here.
    private func refreshFrameCounts(userId: UUID) async {
        for roll in openRolls + readyRolls {
            frameCounts[roll.id] = await photos.rollTotalShotCount(rollId: roll.id)
            if !roll.isDeveloped {
                myFrameCounts[roll.id] = await photos.rollPhotoCount(rollId: roll.id, userId: userId)
            }
        }
    }

    /// Re-requests the lock-screen countdown for the rolls closest to revealing.
    ///
    /// This is the whole fix for the reach problem. The system ends a Live Activity after about
    /// 8 hours, and a roll takes 12 to develop, so the card that was started at creation is gone
    /// for the last third of the wait. Nothing server-side can restart it, so the app does, every
    /// time this list loads, which is the most-visited screen in the app.
    ///
    /// This runs for every candidate, including rolls whose card is already live: a running card
    /// never receives anything new otherwise (see the doc this preserved from the list era).
    private func refreshLiveActivities(userId: UUID) async {
        // End cards for rolls that are no longer ours first. A roll deleted by its creator, or
        // left on another device, leaves a card counting down to a reveal that is never coming,
        // and this screen is the one place that reliably knows the current set.
        RollLiveActivity.reconcile(activeRollIds: rolls.rolls.map(\.id))
        let candidates = RollLiveActivity.rollsNeedingActivity(rolls.rolls, revealAt: \.revealAt)
        for roll in candidates {
            let shots: Int
            if let cached = frameCounts[roll.id] {
                shots = cached
            } else {
                shots = await photos.rollTotalShotCount(rollId: roll.id)
            }
            RollLiveActivity.sync(rollId: roll.id, rollName: roll.name, revealAt: roll.revealAt,
                                  shotCount: shots, developFrom: roll.createdAt)
        }
    }

    /// Signs every not-yet-resolved cover PATH in one batched call, so on a cold cache the
    /// covers appear together instead of one per round trip.
    private func resolveCovers() async {
        let pending = Set(rolls.coverPaths.values).filter { coverURLs[$0] == nil }
        guard !pending.isEmpty else { return }
        let urls = await photos.signedURLs(for: Array(pending))
        for (path, url) in urls { coverURLs[path] = url }
    }

    // MARK: - Formatting

    /// "3h 12m", "24m", "40s": the long-form remainder for the clock line and picker.
    static func longRemaining(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(total)s"
    }

    /// Deterministic hue from the roll's UUID bytes, stable across launches; the coverless
    /// tile's identity.
    static func gradient(for roll: Roll) -> [Color] {
        let bytes = withUnsafeBytes(of: roll.id.uuid) { Array($0) }
        let sum = bytes.reduce(0) { $0 + Int($1) }
        let h = Double(sum % 360) / 360.0
        return [
            Color(hue: h, saturation: 0.52, brightness: 0.5),
            Color(hue: (h + 0.07).truncatingRemainder(dividingBy: 1), saturation: 0.62, brightness: 0.26)
        ]
    }

    // MARK: - First run (3d, verbatim from the list era: it is already the product's voice)

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "film.stack")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(accent.opacity(0.8))
            Text("Better with friends.")
                .flimFont(17, weight: .light, relativeTo: .body)
                .foregroundStyle(FlimTheme.textSecondary)
            Text("Start a roll and share the code, or join one with a friend's code.")
                .flimFont(13.5, relativeTo: .subheadline)
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
