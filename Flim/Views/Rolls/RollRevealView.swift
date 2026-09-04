import SwiftUI

/// The roll reveal, as an event: the first time you open a roll after it develops, everyone's
/// shots are yours to page through, and each print DEVELOPS in front of you (blurred + washed
/// → sharp) the first time you reach it, once, never again.
///
/// The Rolls redesign (2026-08-27) deleted the timer, not the ceremony. Gone: the auto-advance,
/// the story progress bar and its 30Hz repaint, Skip, and the tap-zone/hold machinery. Kept and
/// moved onto the thumb: the develop beat, which is what stops a once-ever reveal from looking
/// exactly like browsing the same roll's grid five minutes later. Gained: paging at your own
/// speed, a rack scrubber that shows the whole roll at a glance, and comments on a frame.
///
/// Deck loading, the develop ledger and the save-all export live in `RollRevealViewModel`.
/// What stays here is genuinely view-local: the pinch-zoom, sheet routing, and the pager.
struct RollRevealView: View {
    @Environment(\.flimAccent) private var accent
    let rollId: UUID
    let rollName: String
    /// Chronological, developed, as of the moment the caller last fetched. Re-verified against
    /// the server on appear (see `RollRevealViewModel.loadDeck`) so a shot deleted after that
    /// fetch (but before this member opened the reveal) never enters the deck.
    let photos: [Photo]
    let memberNames: [UUID: String]

    @State private var viewModel: RollRevealViewModel

    init(rollId: UUID, rollName: String, photos: [Photo], memberNames: [UUID: String],
         onCompleted: (() -> Void)? = nil) {
        self.rollId = rollId
        self.rollName = rollName
        self.photos = photos
        self.memberNames = memberNames
        self.onCompleted = onCompleted
        _viewModel = State(initialValue: RollRevealViewModel(rollId: rollId, photos: photos))
    }

    @Environment(PhotoService.self) private var photoService
    @Environment(AuthService.self) private var auth
    @Environment(RollService.self) private var rollService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var profileRoute: ProfileRoute?
    /// Read once, on appear, purely for the summary's own invite prompt. Fails soft to `.unknown`
    /// like every other reader of this call: the offer still shows, it just says nothing about a
    /// count until the read lands.
    @State private var inviteQuota: AuthService.InviteQuota = .unknown
    /// The frame on screen, driven by the pager. Mirrored into the view model's `index` (which
    /// the rack, the credit line and prefetching all read) through `moved(to:)`.
    @State private var selection = 0
    /// The rack's visible width, which decides whether its edges need fading at all.
    @State private var rackViewportWidth: CGFloat = 0
    /// The frame whose comments are open, if any.
    @State private var commentsPhoto: Photo?
    /// Reported ids, so the flag control disables the moment a report lands.
    @State private var reportedIds: Set<UUID> = []
    /// Called when the reveal is genuinely finished, so the caller can burn its one-shot flag.
    /// Nothing else may write it: an abandoned reveal has to stay replayable.
    var onCompleted: (() -> Void)?
    /// Pinch-to-look on the current slide. Transient, so a zoom can never be left behind on a
    /// slideshow that keeps moving. Reset whenever the photo on screen changes, see the
    /// `onChange` below.
    @State private var revealZoom: CGFloat = 1
    @State private var zoomAnchor: UnitPoint = .center
    @State private var pinchStart: CGFloat?

    /// The photo currently on screen, read through a bounds-safe subscript: `skipDeadFrame`
    /// mutates the deck during playback, and an unguarded index would trap. From `playedDeck`,
    /// not `deck`: bursts are skipped down to their sharpest frame, so `index` names a position in
    /// the played list, never a raw offset into the full roll.
    private var currentPhoto: Photo? { viewModel.playedDeck[safe: viewModel.index] }

    var body: some View {
        // Its own stack, so a handle tapped during a reveal pushes the profile with a back
        // button instead of presenting it as a sheet that has no way out.
        NavigationStack {
            revealBody
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(item: $profileRoute) { UserPageView(userId: $0.id) }
        }
    }

    private var revealBody: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if viewModel.showCover {
                coverCard
            } else if viewModel.isEmpty {
                emptyState
            } else if viewModel.showSummary {
                summary
            } else if !viewModel.playedDeck.isEmpty {
                revealPager
            } else {
                // Still loading the deck. Much shorter now that playback starts on the cached
                // thumbnail rather than waiting for the full rendition, but a bare black screen
                // for even that wait read as a hang.
                ProgressView().tint(.white)
            }
        }
        .statusBarHidden()
        .onChange(of: currentPhoto?.id) { _, _ in
            // Per-photo: a zoom left over from the previous frame would be applied to a shot
            // nobody pinched.
            revealZoom = 1
            zoomAnchor = .center
            pinchStart = nil
        }
        .sheet(item: $commentsPhoto) { photo in
            PhotoCommentsSheet(photoId: photo.id, memberNames: memberNames) {
                profileRoute = ProfileRoute(id: $0)
            }
        }
        .task {
            viewModel.reduceMotion = reduceMotion
            viewModel.displayScale = displayScale
            await viewModel.loadDeck(photoService: photoService, auth: auth, rollService: rollService)
        }
        // Its own task, independent of the deck: the summary can render long before this
        // answers, and a slow quota read must never hold up the reveal itself.
        .task {
            inviteQuota = await auth.ownInviteQuota()
        }
        .onChange(of: reduceMotion) { _, newValue in
            viewModel.reduceMotion = newValue
        }
        // The one-shot flag burns HERE and nowhere else: reaching the end, by paging past the
        // last frame or tapping Done. An abandoned reveal (swipe-down, close, backgrounding)
        // leaves it unset, so the Ready band stays up and the roll replays from the cover.
        .onChange(of: viewModel.completed) { _, done in
            if done { onCompleted?() }
        }
    }

    // MARK: - The pager (3f)

    /// Header, photograph, rack scrubber, credit, reactions, thread. Structurally stable at
    /// every index, per the app's ratified swipe pattern: one always-mounted page per frame,
    /// nothing swapped in and out as the pager settles.
    private var revealPager: some View {
        VStack(spacing: 0) {
            revealHeader
            Spacer(minLength: 0)

            TabView(selection: $selection) {
                ForEach(Array(viewModel.playedDeck.enumerated()), id: \.element.id) { index, photo in
                    frame(photo)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(maxHeight: .infinity)
            .onChange(of: selection) { _, newValue in
                // Paging past the last frame is how the reveal ends; the pager itself cannot
                // scroll past its own last page, so the footer's own Done handles that side.
                viewModel.moved(to: newValue)
            }
            // The other direction, and it is NOT redundant. `selection` is a positional tag, so
            // when `skipDeadFrame` removes a frame from behind the reader the tag silently comes
            // to mean the next photograph. The model corrects its own index for that; without
            // this the pager would not follow, and the two would disagree about which frame is
            // on screen. `moved(to:)` already no-ops when the value matches, so the pair cannot
            // loop.
            .onChange(of: viewModel.index) { _, newValue in
                guard selection != newValue else { return }
                selection = newValue
            }

            rackScrubber
                .padding(.horizontal, 16)
                .padding(.top, 10)

            credit
                .padding(.top, 12)

            if let photo = currentPhoto {
                reactionBar(for: photo)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                commentRow(for: photo)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 44)
    }

    private var revealHeader: some View {
        HStack(spacing: 12) {
            Button { Haptics.tap(); dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(FlimTheme.textPrimary)
            }
            .accessibilityLabel("Close")
            Text(rollName)
                .flimFont(17, weight: .semibold, relativeTo: .body)
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 8)
            // Done is a COMPLETION, same as paging off the end: this is the reader saying
            // they are finished, which is the only thing allowed to burn the one-shot flag.
            Button { Haptics.tap(); viewModel.finish() } label: {
                Text("Done")
                    .flimFont(15, weight: .medium, relativeTo: .body)
                    .foregroundStyle(Color(white: 0.7))
            }
        }
        .padding(.horizontal, 16)
        // The design's 62 is measured from the top of a prototype phone with no safe area.
        // This VStack already starts below the Dynamic Island, so adding 62 on top of that
        // inset double-counts it and drops the header a third of the way down the notch gap.
        .padding(.top, 12)
    }

    /// One frame: the photograph, developing in place the first time it is reached.
    ///
    /// The print sits in a 3:4 box, the capture aspect and the same geometry `FeedUnitCard` gives
    /// a photograph, and it earns its place twice. It rounds the corners the way every other photo
    /// surface in the app rounds them, and it gives the develop beat AN EDGE TO STOP AT: `.blur`
    /// renders outside the bounds of the view it is applied to, so the unclipped radius-26 opening
    /// washed a blurred copy of the photograph up under the close button, the roll name and Done.
    /// The box was also full-bleed tight before (524pt of photograph in 526pt of room), which is
    /// what put the frame against the header even once the bleed is cut.
    @ViewBuilder
    private func frame(_ photo: Photo) -> some View {
        Group {
            if let url = viewModel.urls[photo.viewPath] {
                // Two layers, sharing one set of develop modifiers.
                //
                // The thumbnail underneath is what lets the reveal start immediately. It is
                // ~30KB and is almost always already in cache from the roll grid you just came
                // from, and at the develop animation's opening blur radius of 26 it is
                // indistinguishable from the full rendition. The reveal used to sit on a
                // spinner through three network round trips before its first frame; a spinner
                // is the one thing that cannot develop into anything.
                ZStack {
                    // Opaque backing, and the reason the blur below can be `opaque: true`: a
                    // blur over transparent pixels samples the clear space at the boundary and
                    // fades out, which under a hard clip reads as a dark rim around the print.
                    Color.black
                    if let thumbPath = photo.thumbPath, let thumbURL = viewModel.urls[thumbPath] {
                        CachedImage(url: thumbURL, maxPixel: 400, cacheKey: thumbPath) { $0.resizable().scaledToFit() }
                            placeholder: { Color.clear }
                    }
                    // maxPixel 1400, matching the warm in loadDeck and the prefetch window in
                    // prefetchAhead exactly: warm and view must agree on key+size, or a frame
                    // re-downloads bytes the reveal already fetched for itself.
                    CachedImage(url: url, maxPixel: 1400, cacheKey: photo.viewPath,
                               onFailure: { viewModel.skipDeadFrame(photo.id) },
                               // Reveal only: the photograph arrives under a clearing blur here,
                               // so it lands and settles rather than rushing in at the end.
                               fadeIn: .easeOut(duration: 0.45)) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        // Clear, not a spinner: the thumbnail below is already showing the
                        // photograph, and a spinner on top of it would be a lie.
                        Color.clear
                    }
                }
                .compositingGroup()
                // NO BLUR. It was tried at 1.4s, 0.8s, 0.5s and 0.35s and the note was the same
                // every time: it is in the way. What survives is the part of the first reveal
                // that people actually liked, a photograph fading in, which the reveal's own
                // `fadeIn` curve does on the layer above. Everything else about the ceremony is
                // untouched: the cover card, the rack, the wells ahead of you, the one-shot flag.
            } else {
                ProgressView().tint(.white)
            }
        }
        // The box, then the clip. Order matters: `aspectRatio` is what sizes the stack the blur
        // is applied to, and `clipShape` outside it is what cuts the bleed off at the print's
        // own edge. Rounding here rather than on the image itself keeps the corners while the
        // pinch below scales the frame.
        .aspectRatio(RevealPacing.frameAspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: RevealPacing.frameCornerRadius))
        .scaleEffect(photo.id == currentPhoto?.id ? revealZoom : 1, anchor: zoomAnchor)
        .padding(.horizontal, RevealPacing.frameHorizontalInset)
        .padding(.vertical, RevealPacing.frameVerticalInset)
        // The pinch rides the photograph itself here (no tap-zone layer left to steal it).
        .simultaneousGesture(TransientPinch(scale: $revealZoom, anchor: $zoomAnchor,
                                            restingScale: $pinchStart))
    }

    /// The rack: the whole roll at a glance, and the design made visible. Three states, and the
    /// third is the point — frames you have not reached yet are still WELLS, so the strip fills
    /// in behind you as you page.
    private var rackScrubber: some View {
        VStack(spacing: 0) {
            DarkroomPerforationLine().frame(height: 3)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: RevealPacing.rackFrameGap) {
                        ForEach(Array(viewModel.playedDeck.enumerated()), id: \.element.id) { index, photo in
                            rackFrame(photo, index: index)
                                .id(photo.id)
                        }
                    }
                    .padding(.vertical, 2)
                }
                // Centred on the current frame: 47 frames do not fit, and the ones off screen
                // must not read as though the visible eleven are all there is.
                .onChange(of: selection) { _, _ in
                    guard let id = currentPhoto?.id else { return }
                    withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
                }
                .task {
                    guard let id = currentPhoto?.id else { return }
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { rackViewportWidth = $0 }
            .mask(rackFadeMask)
            DarkroomPerforationLine().frame(height: 3)
        }
        // The road stops where the film does. A four-frame roll used to draw four frames and then
        // most of a screen width of empty perforated stock, because the strip took every point it
        // was offered; `maxWidth` caps it at its own content instead and, since that modifier
        // centres by default, parks a short strip under the middle of the photograph rather than
        // against the leading edge. A roll long enough to overflow is simply offered less than
        // this, so it fills the row and scrolls exactly as it did before.
        .frame(maxWidth: rackContentWidth)
    }

    private var rackContentWidth: CGFloat {
        RevealPacing.rackWidth(frameCount: viewModel.playedDeck.count)
    }

    /// Softens the two edges where the strip runs off the viewport, so the eleven frames you can
    /// see do not read as the whole roll. A strip that fits has nothing running off either edge,
    /// and fading it there would dim real frames for no reason, so it gets no mask at all.
    private var rackFadeMask: some View {
        let overflows = rackViewportWidth > 0 && rackContentWidth > rackViewportWidth + 0.5
        let fade = overflows ? min(0.4, 26 / rackViewportWidth) : 0
        return LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: fade),
            .init(color: .black, location: 1 - fade),
            .init(color: .clear, location: 1)
        ], startPoint: .leading, endPoint: .trailing)
    }

    private func rackFrame(_ photo: Photo, index: Int) -> some View {
        let isCurrent = index == selection
        let developed = viewModel.hasDeveloped(photo)
        return Group {
            if developed, let thumbPath = photo.thumbPath, let url = viewModel.urls[thumbPath] {
                CachedImage(url: url, maxPixel: 120, cacheKey: thumbPath) { image in
                    image.resizable().scaledToFill()
                } placeholder: { Color.white.opacity(0.06) }
            } else if developed, let url = viewModel.urls[photo.viewPath] {
                CachedImage(url: url, maxPixel: 120, cacheKey: photo.viewPath) { image in
                    image.resizable().scaledToFill()
                } placeholder: { Color.white.opacity(0.06) }
            } else {
                // Not yet reached: the compact developing well, verbatim from the Darkroom's
                // own rack.
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(white: 0.063))
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(FlimTheme.stroke, lineWidth: 1))
                    .overlay {
                        Circle()
                            .strokeBorder(accent.opacity(0.7), lineWidth: 1.5)
                            .frame(width: 9, height: 9)
                    }
            }
        }
        .frame(width: RevealPacing.rackFrameWidth, height: RevealPacing.rackFrameHeight)
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .overlay {
            if isCurrent {
                RoundedRectangle(cornerRadius: 2).stroke(accent, lineWidth: 1.5)
            }
        }
        .opacity(isCurrent ? 1 : 0.45)
        .contentShape(Rectangle())
        .onTapGesture {
            guard index != selection else { return }
            selection = index
        }
        .accessibilityElement()
        .accessibilityLabel(developed ? "Frame \(index + 1)" : "Frame \(index + 1), not yet reached")
        .accessibilityAddTraits(.isButton)
    }

    private var credit: some View {
        VStack(spacing: 2) {
            if let photo = currentPhoto, let name = memberNames[photo.userId] {
                Button {
                    profileRoute = ProfileRoute(id: photo.userId)
                } label: {
                    Text("@\(name)")
                        .flimFont(15, weight: .semibold, relativeTo: .body)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens @\(name)'s profile")
            }
            if let photo = currentPhoto {
                let timeLabel = FrameCredit.timeLabel(
                    for: photo.takenAt, index: viewModel.index,
                    in: viewModel.playedDeck.map(\.takenAt))
                // "N of M" counts the frames actually PLAYED, never the roll's raw shot count: a
                // burst plays once, as its sharpest frame, so M is `playedDeck.count`.
                Text("\(viewModel.index + 1) of \(viewModel.playedDeck.count) · \(timeLabel)")
                    .flimFont(12.5, relativeTo: .footnote)
                    .foregroundStyle(Color(white: 0.6))
                // This frame stands in for a burst: say so, singular phrasing at one, so the
                // credit reads honestly rather than always pluralizing.
                if let extra = viewModel.burstExtraCount[photo.id], extra > 0 {
                    Text(extra == 1 ? "and 1 more like it" : "and \(extra) more like it")
                        .flimFont(11.5, relativeTo: .caption)
                        .foregroundStyle(Color(white: 0.45))
                }
            }
        }
    }

    /// The thread row. A real gain from paging at your own speed: a timed slideshow could never
    /// have offered this, because opening a sheet over a moving deck means coming back to a
    /// different photograph than the one you were reading about.
    private func commentRow(for photo: Photo) -> some View {
        HStack(spacing: 12) {
            Button { commentsPhoto = photo } label: {
                HStack(spacing: 7) {
                    Image(systemName: "bubble.left").font(.system(size: 14))
                    Text("Comments")
                        .flimFont(12.5, relativeTo: .footnote)
                }
                .foregroundStyle(Color(white: 0.6))
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            // Mixed-author deck, so a report branch belongs here, exactly as it does anywhere
            // else someone else's photograph is shown full screen.
            if photo.userId != auth.currentUser?.id {
                let reported = reportedIds.contains(photo.id)
                Button {
                    Haptics.tap()
                    reportedIds.insert(photo.id)
                    let service = photoService
                    UndoCenter.shared.stage(
                        title: "Reported. We'll look into it.",
                        failureText: "Couldn't send that report",
                        revert: { reportedIds.remove(photo.id) },
                        commit: { await service.reportPhoto(photo) })
                } label: {
                    Image(systemName: reported ? "flag.fill" : "flag")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(white: 0.5))
                }
                .buttonStyle(.plain)
                .disabled(reported)
                .accessibilityLabel("Report photo")
            }
        }
    }

    /// The reaction bar for a shot, wired to the deck-wide reaction cache. React to each print as
    /// it develops, and see what others already left.
    private func reactionBar(for photo: Photo) -> some View {
        let reactions = viewModel.reactionsByPhoto[photo.id] ?? []
        return ReactionBar(
            defaults: photoService.reactionDefaults(for: photo.id),
            counts: Dictionary(grouping: reactions, by: \.emoji).mapValues(\.count),
            mine: Set(reactions.filter { $0.userId == auth.currentUser?.id }.map(\.emoji))
        ) { emoji in
            viewModel.toggleReaction(emoji, on: photo, auth: auth, photoService: photoService)
        }
        .id(photo.id)   // fresh bar per photo as the reveal pages
    }

    // The vertical swipe-to-dismiss that used to live here as its own root-level gesture is now
    // handled inside `playbackGesture`, which resolves it alongside tap and hold. Two independent
    // DragGestures on the same view would have raced: the root one could claim a swipe that the
    // playback layer needed to see in order to cancel a pending hold.

    /// Copy for the group-progress line. Being first is its own little reward; after that it's
    /// framed as the group ("N of M have opened it") so the roll reads as shared.
    private func presenceText(_ p: RollService.RevealPresence) -> String {
        if p.position == 1 { return "You're first to open this roll" }
        return "\(p.position) of \(p.total) have opened this roll"
    }

    private var summary: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack")
                .font(.system(size: 44, weight: .ultraLight))
                .foregroundStyle(accent)
            Text(rollName)
                .flimFont(26, weight: .light, relativeTo: .title3).foregroundStyle(.white)
            Text("\(viewModel.deck.count) shot\(viewModel.deck.count == 1 ? "" : "s") · developed together")
                .flimFont(12.5, relativeTo: .footnote).foregroundStyle(Color(white: 0.6))

            // The communal signal: where you land in the group's reveal, so it feels shared even
            // though everyone opens at their own time.
            if let presence = viewModel.presence {
                Label(presenceText(presence), systemImage: presence.position == 1 ? "sparkles" : "person.2.fill")
                    .flimFont(13.5, weight: .medium, relativeTo: .subheadline)
                    .foregroundStyle(accent)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(accent.opacity(0.16), in: Capsule())
                    .padding(.top, 2)
            }

            Button {
                Haptics.tap()
                dismiss()
            } label: {
                // Outlined, matching the Rolls screen's own primary: a filled accent capsule
                // with black text was the only one of its kind left in this flow.
                Text("View the roll")
                    .flimFont(15, weight: .medium, relativeTo: .body)
                    .foregroundStyle(accent)
                    .padding(.horizontal, 36)
                    .frame(height: 46)
                    .overlay(Capsule().strokeBorder(accent, lineWidth: 1))
            }
            .padding(.top, 12)

            // The one thing people actually want at this moment, offered at this moment.
            //
            // It already existed, buried in the roll's ⋯ menu two screens away, which is a fine
            // place for a utility and the wrong place for an impulse. You have just watched the
            // whole roll; "keep these" is the feeling, and making someone go find it is how the
            // feeling gets lost. Nearly free here: every frame was fetched to be shown, so this
            // is reading the cache the slideshow just filled.
            if !viewModel.deck.isEmpty {
                Button {
                    viewModel.saveAll()
                } label: {
                    HStack(spacing: 7) {
                        if viewModel.savingAll {
                            ProgressView().tint(Color(white: 0.7)).controlSize(.small)
                        } else {
                            Image(systemName: "square.and.arrow.down").font(.system(size: 13))
                        }
                        Text(viewModel.savingAll ? "Getting them ready" : "Save all to Camera Roll")
                            .flimFont(15, weight: .medium, relativeTo: .body)
                    }
                    .foregroundStyle(Color(white: 0.7))
                }
                .disabled(viewModel.savingAll)
                .padding(.top, 4)

                // Rule 4 (confirmations redesign): a failed Save all lands right here, under
                // the button that caused it, with the retry in place. A partial result says
                // how many made it in the same quiet spot; the share sheet still opens.
                if let error = viewModel.saveAllError {
                    HStack(spacing: 10) {
                        Text(error)
                            .flimFont(12.5, relativeTo: .footnote)
                            .foregroundStyle(Color(white: 0.55))
                        Button("Retry") { viewModel.saveAll() }
                            .flimFont(12.5, weight: .semibold, relativeTo: .footnote)
                            .foregroundStyle(accent)
                    }
                    .padding(.top, 6)
                    .transition(.opacity)
                } else if let notice = viewModel.partialNotice {
                    Text(notice)
                        .flimFont(12.5, relativeTo: .footnote)
                        .foregroundStyle(Color(white: 0.55))
                        .padding(.top, 6)
                        .transition(.opacity)
                }
            }

            // The invite, at the one moment someone would actually want a friend in the next
            // one: after they have watched the whole roll come back, not two taps into the
            // profile where this otherwise lives alone. Quiet on purpose, same weight as Save
            // all above it rather than the accent-filled primary above that: this is the end of
            // a calm beat, not a growth-hack CTA, and it must never delay View the roll or Done.
            if InviteCopy.revealOfferVisible(for: inviteQuota), let code = auth.currentUser?.inviteCode {
                ShareLink(item: AppInfo.personalInviteMessage(code: code)) {
                    VStack(spacing: 2) {
                        HStack(spacing: 7) {
                            Image(systemName: "person.badge.plus").font(.system(size: 13))
                            Text(InviteCopy.revealPrompt)
                                .flimFont(15, weight: .medium, relativeTo: .body)
                        }
                        .foregroundStyle(Color(white: 0.7))
                        if let quotaLine = InviteCopy.revealQuotaLine(for: inviteQuota) {
                            Text(quotaLine)
                                .flimFont(12, relativeTo: .footnote)
                                .foregroundStyle(Color(white: 0.5))
                        }
                    }
                }
                // Same growth-funnel milestone as the profile and feed shares. Firing it here too
                // is what lets the invite funnel see that this reveal-close surface converts at all,
                // which is the whole point of putting an invite on the reveal.
                .simultaneousGesture(TapGesture().onEnded {
                    Haptics.tap()
                    Activation.log(.inviteSent)
                    Usage.log(.inviteSharedReveal)
                })
                .padding(.top, 14)
            }
        }
        .transition(.opacity)
        .sheet(isPresented: Binding(get: { viewModel.showShareAll },
                                    set: {
                                        viewModel.showShareAll = $0
                                        // The some-of-them line has done its job once the
                                        // sheet closes; a stale count must not linger.
                                        if !$0 { viewModel.partialNotice = nil }
                                    })) {
            ActivityView(items: viewModel.shareImages)
        }
    }

    /// Shown when every shot in the deck was deleted (either before this member opened the
    /// reveal, or one by one as each dead frame was skipped during playback).
    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(accent.opacity(0.8))
            Text("The shots in this roll were deleted.")
                .flimFont(20, weight: .light, relativeTo: .title3)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                Haptics.tap()
                dismiss()
            } label: {
                Text("Close")
                    .flimFont(15, weight: .semibold, relativeTo: .body).foregroundStyle(.black)
                    .padding(.horizontal, 36).padding(.vertical, 13)
                    .background(accent, in: Capsule())
            }
            .padding(.top, 12)
        }
        .transition(.opacity)
    }

    // MARK: - Opening card

    /// The beat before the first frame. Also the loading state, deliberately.
    private var coverCard: some View {
        VStack(spacing: 0) {
            Spacer()

            // An eyebrow, because the card has to answer "why am I looking at this" before it
            // answers "what is it". Without it the title reads as a splash screen.
            Text("DEVELOPED")
                .flimFont(11, weight: .semibold, relativeTo: .caption2)
                .tracking(3.5)
                .foregroundStyle(accent)

            Text(rollName)
                .flimFont(34, weight: .ultraLight, relativeTo: .largeTitle)
                .tracking(2)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 32)
                .padding(.top, 14)

            // A rule under the title, the width of the text above it. Gives the block an edge to
            // sit on, so the type is composed rather than floating in the middle of black.
            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 44, height: 1)
                .padding(.top, 20)

            Text(viewModel.cover.metaLine)
                .flimFont(15, weight: .medium, relativeTo: .body)
                .foregroundStyle(Color(white: 0.82))
                .padding(.top, 20)

            if let dateLine = viewModel.cover.dateLine() {
                Text(dateLine)
                    .flimFont(12.5, relativeTo: .footnote)
                    .foregroundStyle(Color(white: 0.45))
                    .padding(.top, 5)
            }

            Spacer()

            // Honest about the wait: it fills over the beat, and if the deck is slow it sits at
            // the end rather than completing, so the card never promises a show it cannot start.
            coverProgress
                .padding(.bottom, 92)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.tapCover()
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(rollName). \(viewModel.cover.metaLine). \(viewModel.cover.dateLine() ?? "") Tap to begin.")
        .task {
            await viewModel.startCoverBeat()
        }
    }

    @ViewBuilder
    private var coverProgress: some View {
        let width: CGFloat = 120
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.16)).frame(width: width, height: 2)
            TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { tl in
                Capsule()
                    .fill(accent)
                    .frame(width: width * coverFill(at: tl.date), height: 2)
            }
        }
        .accessibilityHidden(true)
    }

    private func coverFill(at date: Date) -> CGFloat {
        guard let started = viewModel.coverAppearedAt else { return 0 }
        let elapsed = date.timeIntervalSince(started)
        return min(1, max(0, elapsed / RevealCover.holdDuration))
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
