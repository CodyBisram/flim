import SwiftUI
import UIKit

struct RollDetailView: View {
    @Environment(\.flimAccent) private var accent
    let roll: Roll
    @Environment(PhotoService.self) private var photoService
    @Environment(RollService.self) private var rollService
    @Environment(AuthService.self) private var auth
    @Environment(NotificationService.self) private var notifications
    @Environment(FeedService.self) private var feed
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dismiss) private var dismiss
    @AppStorage("developNotificationsEnabled") private var notificationsEnabled = true
    @State private var vm = DarkroomViewModel()
    @State private var showMembers = false
    @Namespace private var photoNS
    @State private var selectedPhoto: Photo?
    @State private var memberNames: [UUID: String] = [:]   // userId → username, for attribution
    @State private var showRename = false
    @State private var renameDraft = ""
    @State private var showDeleteRoll = false
    @State private var savingAll = false
    @State private var saveAllError: String?
    /// Set when the alert is a warning rather than a failure, so the share sheet opens after it
    /// is dismissed. Presenting both at once means SwiftUI shows one and drops the other.
    @State private var shareAfterAlert = false
    /// File URLs, not UIImages: see PhotoExport for why the roll is not held in memory.
    @State private var shareImages: [URL] = []
    @State private var showShareAll = false
    @State private var displayName = ""
    @State private var showInviteShare = false
    @State private var coverToast = false
    @State private var showLeaveRoll = false
    @State private var showCarousel = false
    @State private var shareItem: ShareImage?
    @State private var isMuted = false
    @State private var showReveal = false
    /// Flips true once a developed roll's pagination has been fully drained (see `onAppear`).
    /// Gates the "Play through the roll" button so it appears once, already showing the true
    /// count, without this, the button popped in after page 1 (30) and its own count label
    /// visibly ticked upward (30 → 60 → 75) as each further page streamed in behind it.
    @State private var rollFullyPaged = false

    private var revealSeenKey: String { "rollRevealSeen.\(roll.id.uuidString)" }

    private var isCreator: Bool { auth.currentUser?.id == roll.createdBy }
    /// Developed shots oldest → newest, for the flip-through carousel, cached on the view model
    /// (recomputed only when the roll's photos change) rather than sorted on every access.
    private var chronologicalDeveloped: [Photo] { vm.chronologicalDeveloped }
    private var isFullyDeveloped: Bool {
        roll.isDeveloped && rollFullyPaged && !vm.developedPhotos.isEmpty
    }

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    var body: some View {
        ZStack {
            FlimTheme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                FlimNavTitle(displayName.isEmpty ? roll.name : displayName)

                if let count = rollService.memberCounts[roll.id] {
                    Label("\(count) member\(count == 1 ? "" : "s")", systemImage: "person.2.fill")
                        .font(.system(size: 13, weight: .medium))
                        .imageScale(.small)
                        .foregroundStyle(FlimTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                }

                // Countdown to the shared reveal, runs from the moment the roll was created,
                // so it shows even before anyone has taken a shot.
                if !roll.isDeveloped {
                    // nil (not 0) while pagination is still draining, 0 legitimately means "no
                    // shots yet", a different message from "still counting". See rollFullyPaged.
                    revealBanner(revealAt: roll.revealAt,
                                 shots: rollFullyPaged ? vm.developingPhotos.count : nil,
                                 people: Set(vm.developingPhotos.map(\.userId)).count)
                }

                // Flip through the whole developed roll, in order.
                if isFullyDeveloped {
                    Button {
                        showCarousel = true
                    } label: {
                        Label("Play through the roll · \(vm.developedPhotos.count)", systemImage: "play.circle.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(accent, in: Capsule())
                    }
                    .padding(.horizontal, 16).padding(.bottom, 6)
                }

                Group {
                    if vm.isLoading && vm.photos.isEmpty {
                        ProgressView().tint(.white)
                    } else if let error = vm.error, vm.photos.isEmpty {
                        // The view model has always tracked this; the roll grid just never showed
                        // it, so a failed load looked like an empty roll.
                        ErrorState(message: error) {
                            await vm.loadRoll(photoService: photoService, rollId: roll.id, blockedIds: feed.blockedIds)
                        }
                    } else if vm.photos.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 36, weight: .ultraLight))
                                .foregroundStyle(accent.opacity(0.8))
                            Text("No photos in this roll yet.")
                                .flimFont(15, weight: .light, relativeTo: .body)
                                .foregroundStyle(FlimTheme.textSecondary)
                            Text("Take a photo and send it to \"\(roll.name)\".")
                                .flimFont(13, relativeTo: .subheadline)
                                .foregroundStyle(FlimTheme.textTertiary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)
                        }
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                if !vm.developingPhotos.isEmpty {
                                    // Same reasoning as the reveal banner: no count in the
                                    // header until it's the true total, not a page-1 fragment.
                                    sectionHeader(rollFullyPaged ? "\(vm.developingPhotos.count) DEVELOPING" : "DEVELOPING")
                                    photoGrid(vm.developingPhotos, triggersLoadMore: false)
                                }
                                if !vm.developedPhotos.isEmpty {
                                    sectionHeader("DEVELOPED")
                                    photoGrid(vm.developedPhotos, triggersLoadMore: true)
                                }
                            }
                        }
                        .refreshable {
                            await vm.loadRoll(photoService: photoService, rollId: roll.id, blockedIds: feed.blockedIds)
                            warmGridThumbnails()   // no-op for anything already cached
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .top) {
            if coverToast {
                Label("Roll cover updated", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showMembers = true } label: {
                    Image(systemName: "person.2")
                        .foregroundStyle(accent)
                }
                .accessibilityLabel("Members")
                Button {
                    Haptics.tap()
                    showInviteShare = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(accent)
                }
                .accessibilityLabel("Share invite")

                Menu {
                    // The reveal is the best thing this app does and it was strictly one-shot:
                    // seen once, gone forever, because the flag that stops it replaying on every
                    // visit never clears. So the moment a roll exists to be remembered by could
                    // never be watched again, which is backwards for something built to be
                    // rewatched with the people who were there.
                    if roll.isDeveloped, !vm.developedPhotos.isEmpty {
                        Button {
                            Haptics.tap()
                            replayReveal()
                        } label: { Label("Play reveal again", systemImage: "play.circle") }
                    }

                    // Disabled with no reason reads as a broken menu item. A menu can hold a
                    // plain Text, so it says which of the two reasons applies instead.
                    if vm.developedPhotos.isEmpty {
                        Text("Nothing to save until the roll develops")
                    } else {
                        Button {
                            saveAll()
                        } label: { Label(savingAll ? "Saving…" : "Save all to Camera Roll", systemImage: "square.and.arrow.down.on.square") }
                            .disabled(savingAll)
                    }

                    // Silence this roll's comment/reaction notifications without leaving it.
                    Button {
                        guard let uid = auth.currentUser?.id else { return }
                        let wanted = !isMuted
                        isMuted = wanted   // optimistic
                        Task {
                            if await !photoService.setRollMuted(wanted, rollId: roll.id, userId: uid) {
                                isMuted = !wanted   // the write never landed; don't claim it did
                                Haptics.error()
                            }
                        }
                    } label: {
                        Label(isMuted ? "Unmute notifications" : "Mute notifications",
                              systemImage: isMuted ? "bell.slash" : "bell")
                    }

                    if isCreator {
                        Button {
                            renameDraft = roll.name
                            showRename = true
                        } label: { Label("Rename roll", systemImage: "pencil") }
                        Button(role: .destructive) {
                            showDeleteRoll = true
                        } label: { Label("Delete roll", systemImage: "trash") }
                    } else {
                        Button(role: .destructive) {
                            showLeaveRoll = true
                        } label: { Label("Leave roll", systemImage: "rectangle.portrait.and.arrow.right") }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(accent)
                }
                .accessibilityLabel("More")
            }
        }
        .onAppear {
            Task {
                if let uid = auth.currentUser?.id { await feed.loadBlocked(userId: uid) }
                await vm.loadRoll(photoService: photoService, rollId: roll.id, blockedIds: feed.blockedIds)
                // A roll's photo set is small (a friend group's shots), not the endless, ever-
                // growing personal Darkroom feed, where lazy, scroll-triggered pagination
                // genuinely protects performance, so it's safe to finish paging eagerly here
                // regardless of develop state. Without this, EVERY roll-count label read
                // PhotoService's first-30-photo page instead of the true total: the developing
                // banner's "N shots waiting" (the single most commonly seen roll screen, since a
                // roll spends most of its life developing), "Play through the roll · N", the
                // carousel, the reveal, and the develop-reminder notification's own shot count
                // below all draw from `vm.photos` / `vm.developingPhotos` / `vm.developedPhotos`.
                // If this roll is about to play its reveal, start pulling the first print NOW,
                // in parallel with the paging below rather than after it. The reveal waits for
                // that image before it starts (otherwise the develop animation plays over an
                // empty frame), so every second of the drain that isn't also spent downloading
                // is a second the user spends looking at a spinner.
                if roll.isDeveloped, !UserDefaults.standard.bool(forKey: revealSeenKey) {
                    warmFirstRevealPrint()
                }

                while photoService.hasMore {
                    await vm.loadMoreRoll(photoService: photoService, rollId: roll.id, blockedIds: feed.blockedIds)
                }
                rollFullyPaged = true
                // Only loadRoll batches signed URLs; loadMoreRoll doesn't, so every photo past
                // the first page used to mint its own URL round-trip as it scrolled into view.
                // One batched call for the whole (now fully paged) roll instead, then warm the
                // thumbnails those URLs point at.
                await vm.prefetchURLs(photoService: photoService)
                warmGridThumbnails()
                // The reveal, as an event: play everyone's shots once, the first time the
                // roll is opened after it has developed.
                if roll.isDeveloped, !vm.developedPhotos.isEmpty,
                   !UserDefaults.standard.bool(forKey: revealSeenKey) {
                    UserDefaults.standard.set(true, forKey: revealSeenKey)
                    showReveal = true
                }
                // Ensure EVERY member gets a develop reminder, even those who didn't shoot.
                // The reveal is fixed at the roll's creation, so this works with zero photos too.
                if notificationsEnabled, !roll.isDeveloped {
                    let myCount = vm.photos.filter { $0.userId == auth.currentUser?.id }.count
                    await notifications.requestAuthorizationIfNeeded()
                    notifications.scheduleRollDevelopNotification(
                        rollId: roll.id, rollName: displayName.isEmpty ? roll.name : displayName,
                        developsAt: roll.revealAt, photoCount: myCount
                    )
                }
                // Keeps the countdown Live Activity going for anyone who opens the roll while it's
                // still developing, not just whoever created it, since sync() starts one fresh if
                // nothing's running yet. Ends it once developed; there's no push-driven lifecycle,
                // so this only fires the next time the roll is opened after reveal, not the instant
                // it happens.
                if roll.isDeveloped {
                    RollLiveActivity.end(rollId: roll.id)
                } else {
                    RollLiveActivity.sync(rollId: roll.id, rollName: displayName.isEmpty ? roll.name : displayName,
                                          revealAt: roll.revealAt, shotCount: vm.developingPhotos.count,
                                          developFrom: roll.createdAt)
                }
            }
            Task {
                if let members = try? await rollService.fetchMembers(for: roll.id) {
                    memberNames = Dictionary(members.map { ($0.id, $0.username ?? "unknown") },
                                             uniquingKeysWith: { first, _ in first })
                }
            }
            Task {
                if let uid = auth.currentUser?.id {
                    isMuted = await photoService.fetchMutedRolls(userId: uid).contains(roll.id)
                }
            }
        }
        .fullScreenCover(item: $selectedPhoto) { photo in
            PhotoPagerView(
                photos: vm.developedPhotos,
                startIndex: vm.developedPhotos.firstIndex(where: { $0.id == photo.id }) ?? 0,
                signedURLs: vm.signedURLCache,
                showsReactions: true,
                showsComments: true,
                showsAttribution: true,
                memberNames: memberNames,
                // Every photo here belongs to this roll, so the delete-confirmation name is
                // always this roll's, regardless of the (all-identical) rollId.
                rollName: { _ in displayName.isEmpty ? roll.name : displayName },
                onDelete: { Task { await vm.loadRoll(photoService: photoService, rollId: roll.id, blockedIds: feed.blockedIds) } }
            )
            .navigationTransition(.zoom(sourceID: photo.id, in: photoNS))
        }
        .fullScreenCover(isPresented: $showCarousel) {
            RollCarouselView(photos: chronologicalDeveloped, memberNames: memberNames)
        }
        .fullScreenCover(isPresented: $showReveal) {
            RollRevealView(rollId: roll.id, rollName: displayName.isEmpty ? roll.name : displayName,
                           photos: chronologicalDeveloped, memberNames: memberNames)
        }
        .sheet(isPresented: $showMembers) {
            RollMembersView(roll: roll)
        }
        .sheet(item: $shareItem) { SharePreviewSheet(photo: $0.image) }
        .sheet(isPresented: $showShareAll) {
            ActivityView(items: shareImages)
        }
        .alert("Save all", isPresented: Binding(get: { saveAllError != nil },
                                                set: { if !$0 { saveAllError = nil } })) {
            Button("OK", role: .cancel) {
                if shareAfterAlert {
                    shareAfterAlert = false
                    showShareAll = true
                }
            }
        } message: {
            Text(saveAllError ?? "")
        }
        .sheet(isPresented: $showInviteShare) {
            ActivityView(items: [AppInfo.rollInviteMessage(rollName: displayName.isEmpty ? roll.name : displayName,
                                                           code: roll.inviteCode)])
        }
        .confirmationDialog("Delete this roll?", isPresented: $showDeleteRoll, titleVisibility: .visible) {
            Button("Delete Roll", role: .destructive) {
                Haptics.warning()
                notifications.cancelRollDevelopNotification(rollId: roll.id)
                Task {
                    try? await rollService.deleteRoll(rollId: roll.id)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The roll is removed for everyone. Each person keeps their own photos.")
        }
        .confirmationDialog("Leave this roll?", isPresented: $showLeaveRoll, titleVisibility: .visible) {
            Button("Leave Roll", role: .destructive) {
                guard let uid = auth.currentUser?.id else { return }
                Haptics.warning()
                notifications.cancelRollDevelopNotification(rollId: roll.id)
                Task {
                    try? await rollService.leaveRoll(rollId: roll.id, userId: uid)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll stop seeing this roll. Your own photos stay in your Darkroom.")
        }
        .alert("Rename roll", isPresented: $showRename) {
            TextField("Roll name", text: $renameDraft)
            Button("Save") {
                let name = renameDraft.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                displayName = name
                Task { try? await rollService.renameRoll(rollId: roll.id, name: name) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Replays the reveal for this roll.
    ///
    /// Clears the seen flag as well as presenting, so the roll is left in the same state a
    /// first-time viewer would leave it in: watched. Without the clear, a replay would present
    /// once and then the flag would still read "seen", which is the same thing, but leaving a
    /// stale flag around invites the next reader to wonder which one is authoritative.
    private func replayReveal() {
        UserDefaults.standard.set(true, forKey: revealSeenKey)
        showReveal = true
    }

    private func saveAll() {
        saveAllError = nil
        shareAfterAlert = false
        guard !savingAll else { return }
        savingAll = true
        Task {
            // Streamed to disk one at a time. Holding a 75-shot roll in memory as UIImages was a
            // jetsam kill waiting for someone with a big roll to tap this. See PhotoExport.
            // Its own directory: this Task outlives the view, so a second export started from
            // another roll must not be able to touch these files. See PhotoExport.
            let exportDir = PhotoExport.begin()
            let deck = vm.developedPhotos
            // Signed in one batched, parallel call rather than one sequential round trip each.
            let signed = await photoService.signedURLs(for: deck.map(\.storagePath))
            var images: [URL] = []
            for (i, photo) in deck.enumerated() {
                guard let url = signed[photo.storagePath] else { continue }
                if let file = await PhotoExport.download(url, into: exportDir, index: i, total: deck.count) {
                    images.append(file)
                }
            }
            shareImages = images
            savingAll = false
            if images.isEmpty {
                // Every fetch failed, so no share sheet is coming. Silence here looks exactly
                // like the menu item doing nothing at all.
                Haptics.error()
                saveAllError = "Couldn't load the photos. Check your connection and try again."
            } else {
                if images.count < vm.developedPhotos.count {
                    // A partial result still reaches the sheet, because some photos IS better
                    // than none, but claiming "all" when it was 4 of 9 would be a lie the person
                    // only discovers later, in their camera roll, with no way to tell which four.
                    saveAllError = "Only \(images.count) of \(vm.developedPhotos.count) photos could be loaded. Saving those now."
                    shareAfterAlert = true
                } else {
                    showShareAll = true
                }
            }
        }
    }

    /// Long-press actions on a roll photo. Setting the cover used to be a bare long-press with
    /// nothing on screen announcing it existed, so only whoever wrote it knew it was there; it's
    /// a named menu item now, next to the actions that previously meant opening the shot first.
    @ViewBuilder
    private func photoMenu(_ photo: Photo) -> some View {
        if photo.isReady {
            if isCreator {
                Button { setCover(photo) } label: { Label("Use as roll cover", systemImage: "rectangle.on.rectangle") }
            }
            Button { share(photo) } label: { Label("Share", systemImage: "square.and.arrow.up") }
        } else {
            // Nothing to act on until the roll develops, but an empty menu would just flash a
            // blank card, so say why instead.
            Text("Develops with the roll")
        }
    }

    /// Pulls the roll's earliest developed print into cache, at the size and cache key the reveal
    /// will ask for, so the slideshow can start on an image that's already there.
    ///
    /// Fire-and-forget: if it doesn't finish in time the reveal waits for it itself, exactly as
    /// before. This only removes dead time, it isn't load-bearing.
    private func warmFirstRevealPrint() {
        guard let first = vm.chronologicalDeveloped.first else { return }
        Task {
            guard let url = try? await photoService.signedURL(for: first.viewPath) else { return }
            // `cacheKey: nil` and maxPixel 1600 match what RollRevealView requests; a different
            // key or size would warm an entry the reveal never looks for.
            _ = await ImageLoader.fetch(url: url, maxPixel: 1600, scale: displayScale)
        }
    }

    /// Warms the grid's thumbnails so cells don't pop in on a fast scroll, mirroring what the
    /// Darkroom grid already does at the same size.
    ///
    /// Deliberately the ~30KB `displayPath` thumbnail at 400pt, NOT the full 2048px image: a
    /// 75-shot roll costs roughly 2MB warmed this way, and most of it isn't even extra egress,
    /// since anything scrolled past would be downloaded anyway, just later and with a visible
    /// gap. The carousel is intentionally left alone for the same reason inverted, it shows full
    /// images, so warming a whole roll there would be tens of megabytes; its TabView already
    /// keeps the neighbouring pages loaded.
    ///
    /// Developed shots only. A developing one has no viewable image and no resolved URL.
    private func warmGridThumbnails() {
        let items = vm.developedPhotos.compactMap { photo -> (url: URL, cacheKey: String?)? in
            vm.signedURLCache[photo.id].map { ($0, photo.displayPath) }
        }
        guard !items.isEmpty else { return }
        ImageLoader.prefetch(items, maxPixel: 400, scale: displayScale)
    }

    private func setCover(_ photo: Photo) {
        Haptics.select()
        Task { await rollService.setRollCover(rollId: roll.id, path: photo.storagePath) }
        withAnimation { coverToast = true }
        Task { try? await Task.sleep(for: .seconds(1.6)); withAnimation { coverToast = false } }
    }

    /// Pulls the full-res file down and hands it to the share composer.
    private func share(_ photo: Photo) {
        Haptics.tap()
        Task {
            guard let url = try? await photoService.signedURL(for: photo.storagePath),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else {
                Haptics.error()
                return
            }
            shareItem = ShareImage(image: image)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .flimFont(11, weight: .medium, relativeTo: .caption).tracking(2)
                .foregroundStyle(Color(white: 0.4))
            Spacer()
        }
        .padding(.horizontal, 6).padding(.top, 18).padding(.bottom, 8)
    }

    private func photoGrid(_ list: [Photo], triggersLoadMore: Bool) -> some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(list) { photo in
                // The reveal banner above already shows "Develops in Xh Xm" for the whole roll
                // (every shot in it develops together), so developing tiles here don't repeat it.
                PhotoGridCell(photo: photo, signedURL: vm.signedURLCache[photo.id], showsCountdown: false)
                    .matchedTransitionSource(id: photo.id, in: photoNS)
                    .onTapGesture {
                        // Can't peek before it develops, only open ready shots.
                        guard photo.isReady else { return }
                        selectedPhoto = photo
                    }
                    .contextMenu { photoMenu(photo) }
                    .task {
                        if photo.isReady, vm.signedURLCache[photo.id] == nil {
                            _ = await vm.signedURL(for: photo, photoService: photoService)
                        }
                        if triggersLoadMore, photo.id == list.last?.id {
                            await vm.loadMoreRoll(photoService: photoService, rollId: roll.id, blockedIds: feed.blockedIds)
                        }
                    }
            }
        }
        .padding(.horizontal, 2)
    }

    private func revealBanner(revealAt: Date, shots: Int?, people: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let remaining = max(0, Int(revealAt.timeIntervalSince(timeline.date)))
                Label("Develops in \(Self.countdown(remaining))", systemImage: "hourglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(accent)
            }
            Group {
                if let shots {
                    Text(shots == 0
                         ? "No shots yet. Be the first to add one"
                         : "\(shots) shot\(shots == 1 ? "" : "s") waiting" + (people > 1 ? " from \(people) people" : ""))
                } else {
                    Text("Counting shots…")
                }
            }
            .flimFont(12, relativeTo: .caption)
            .foregroundStyle(FlimTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16).padding(.bottom, 4)
    }

    private static func countdown(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }
}
