import SwiftUI
import UIKit

/// Whether a `landOnAnchorMonth` anchored fetch, captured at `capturedToken`, is still the live
/// jump by the time it resolves. Free function so the compare itself is testable without a
/// `DarkroomView`, a live `PhotoService`, or a `Task` to race against; see `DarkroomView
/// .jumpToken`'s own doc for the specific race this closes (a cancelled-but-already-past-its-
/// await anchored fetch landing an old month's rows under a newer crumb).
func jumpTokenIsCurrent(_ capturedToken: Int, latest: Int) -> Bool {
    capturedToken == latest
}

/// Manual `Equatable`, added here rather than on `Photo` itself (a model file this pass doesn't
/// own): every stored field participates, which is what `.onChange(of: vm.photos)` below needs to
/// tell "a real reassignment happened" from "the array is the same photos it was a moment ago".
/// Swift can only auto-synthesize a conformance declared in the SAME FILE as the type, so this has
/// to be written out by hand rather than left to the compiler.
extension Photo: Equatable {
    static func == (lhs: Photo, rhs: Photo) -> Bool {
        lhs.id == rhs.id && lhs.userId == rhs.userId && lhs.rollId == rhs.rollId
            && lhs.storagePath == rhs.storagePath && lhs.thumbPath == rhs.thumbPath
            && lhs.feedPath == rhs.feedPath && lhs.takenAt == rhs.takenAt
            && lhs.developsAt == rhs.developsAt && lhs.isDeveloped == rhs.isDeveloped
            && lhs.caption == rhs.caption && lhs.isSorted == rhs.isSorted
    }
}

struct DarkroomView: View {
    @Environment(\.flimAccent) private var accent
    var scrollToTop: Int = 0
    /// A counter the tab bumps to open the sort deck from outside — a widget tap, today. A signal
    /// rather than a Bool for the same reason `scrollToTop` is one: the deck can be asked for
    /// twice in a row, and an already-true Bool is not a second request.
    var openSortDeckSignal: Int = 0
    /// A frame a widget tap asked to open. A binding so it can be cleared once consumed, which is
    /// what stops the same frame reopening every time the Darkroom reappears.
    var openPhotoId: Binding<UUID?> = .constant(nil)
    @Environment(AuthService.self) private var auth
    @Environment(PhotoService.self) private var photoService
    @Environment(RollService.self) private var rolls
    @Environment(FeedService.self) private var feed
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Namespace private var photoNS
    @State private var vm = DarkroomViewModel()
    @State private var selectedPhoto: Photo?
    @State private var selectedURL: URL?
    @State private var isSelecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var pendingDelete: [Photo] = []
    @State private var showUndoToast = false
    @State private var undoTask: Task<Void, Never>?
    /// A failure that must not fail silently, e.g. "Set as profile photo" not sticking.
    @State private var errorToast: String?
    @AppStorage("lastRevealCheck") private var lastRevealCheck: Double = 0
    @State private var showReveal = false
    @State private var revealAnim = false
    @State private var revealCount = 0
    /// The unsorted photos themselves, not just a count: the sort row needs three of them for
    /// its preview thumbnails.
    @State private var unsortedPhotos: [Photo] = []
    /// Signed URLs for `unsortedPhotos`' preview thumbnails, resolved in one batched call
    /// alongside `reload()`, never per cell.
    @State private var unsortedURLCache: [UUID: URL] = [:]
    @State private var showSortDeck = false
    /// `darkroom_month_summary_v2`'s rows, `nil` until `reload()`'s dedicated fetch resolves or
    /// the RPC isn't reachable yet (see `PhotoService.darkroomMonthSummaryV2`'s own doc). Every
    /// reader treats `nil` as "no server summary yet", never as zero; every count the zoom bar
    /// and the Year/All-time rungs show comes from this, never from a loaded page.
    @State private var monthSummaries: [DarkroomMonthSummaryV2]?
    /// Whether the `darkroom_month_summary_v2` fetch is currently in flight, distinct from
    /// `monthSummaries == nil`: the two together are what let the Year/All-time rungs tell "still
    /// loading, be quiet about it" from "genuinely failed/unreachable, say so" (see
    /// `yearContent`/`allTimeContent`/`rungUnavailableState`'s own docs). Starts `true` so the
    /// very first frame — including a warm relaunch that lands directly on Year or All-time
    /// before `reload()` has even started — never flashes the failure copy.
    @State private var isLoadingSummaries = true
    /// Set once the current rung's scroll view exists, so the tab-retap handler can call
    /// `scrollTo` from outside the `ScrollViewReader` closure that owns it. Reassigned by
    /// whichever rung is currently mounted (see `monthContent`/`yearContent`/`allTimeContent`).
    /// NOT used for landing on a selected month any more — see `pendingMonthLanding`'s own doc for
    /// why that used to race this exact property and how it's avoided now.
    @State private var scrollProxy: ScrollViewProxy?
    /// The current rung's approximate vertical scroll offset, tracked so the tab-retap handler can
    /// tell "already at the top" (zoom out one rung) from "scrolled down" (scroll to top). A
    /// threshold, not an exact zero check: `.onScrollGeometryChange` can report a hair off zero at
    /// rest.
    @State private var scrollOffsetY: CGFloat = 0
    /// A month `selectMonth`/`zoomIn` asked the `.month` rung to land on, consumed by
    /// `monthContent` itself once ITS OWN `ScrollViewReader` exists (see `monthContent`'s
    /// `.task(id:)`).
    ///
    /// Setting `zoom = .month` and then immediately calling the paging/scroll helper in the SAME
    /// call stack was the original bug: at that point the `.year`/`.allTime` rung's content is
    /// still what's mounted (the `Group { switch zoom { ... } }` hasn't re-rendered yet), so
    /// `scrollProxy` still belongs to the OUTGOING rung and `scrollTo` silently no-ops. Worse,
    /// `monthContent` then mounts at the top (offset 0) a moment later, and the mounted-night
    /// anchor tracker (`updateMonthAnchorFromScroll`) immediately overwrote the anchor right back
    /// to the newest month, undoing the very selection that was just made. Storing the request as
    /// state instead and letting `monthContent`'s own `ScrollViewReader` consume it once it
    /// actually exists fixes both: the anchor tracker also checks this and stays quiet while a
    /// landing is pending, so the two can't fight over the anchor.
    @State private var pendingMonthLanding: DarkroomYearMonth?
    /// `landOnAnchorMonth`'s current in-flight anchored-fetch target, `nil` when nothing is in
    /// flight. A second target arriving while one is already in flight REPLACES it (cancels the
    /// old task, starts a new one) rather than being dropped or queued — a global "refuse while
    /// anything is running" guard would silently swallow a second tap and let the first target's
    /// scroll land under the second target's crumb once it (eventually) finished.
    ///
    /// PR 5 of the zoom redesign, revision 2, replaced this pair's predecessor
    /// (`jumpPagingTarget`/`jumpPagingTask`) entirely along with the `while` loop it guarded: that
    /// loop called `vm.loadMore` repeatedly with no guaranteed progress per iteration (`loadMore`'s
    /// own `!photoService.isLoading` guard can return synchronously, doing nothing, if another
    /// fetch is already in flight), which could spin the main actor with no suspension point.
    /// `landOnAnchorMonth` now awaits exactly ONE fetch (`PhotoService.fetchPersonalPhotos(userId:
    /// anchoredBefore:)`) per target; this pair only exists to let a SECOND target still in
    /// flight retarget the one outstanding call rather than compete with it.
    @State private var anchoredJumpTarget: DarkroomYearMonth?
    @State private var anchoredJumpTask: Task<Void, Never>?
    /// Monotonically increasing "which jump is the live one" token, bumped by `landOnAnchorMonth`
    /// itself whenever it lands (fast path) or starts a NEW anchored fetch (never when it merely
    /// joins one already running for the same target). `anchoredJumpTask?.cancel()` alone cannot
    /// stop a fetch that's already past its own last `await` when the cancel happens, so a
    /// cancelled-but-effectively-still-running anchored fetch used to complete and assign an old
    /// month's rows into `vm.photos` AFTER a retap-home had already taken the fast path back to
    /// the present, leaving `vm.photos` holding the old month under the current month's crumb
    /// (found 2026-08-25, second audit). `landOnAnchorMonth` captures this token before it starts
    /// (or joins) a fetch and hands `DarkroomViewModel.loadAnchored` a closure that re-checks it,
    /// which is what actually stops the stale assignment, not merely the scroll that would have
    /// followed it. See `jumpTokenIsCurrent`.
    @State private var jumpToken = 0

    // MARK: - Zoom ladder (PR 3 of the zoom redesign, revision 2)

    /// `@SceneStorage` has no optional-`Int` initializer: `-1` is the "never set" sentinel, see
    /// `DarkroomZoom.resolveEntry`'s own doc. Mirrored, not authoritative — `zoom` below is what
    /// every view reads; this only exists to survive relaunch.
    @SceneStorage("darkroom.rung") private var storedRung = -1
    /// The anchor's `"yyyy-MM"` mirror, see `DarkroomAnchorCoding`'s own doc.
    @SceneStorage("darkroom.anchor") private var storedAnchor = ""
    @State private var zoom: DarkroomZoom = .month
    @State private var anchor = DarkroomYearMonth(date: .now)
    /// The set of nights currently mounted in `nightList`'s `LazyVStack`, kept only while
    /// `zoom == .month`: the coarse "topmost mounted unit" the zoom bar's crumb follows while
    /// scrolling. See `updateMonthAnchorFromScroll`'s own doc.
    @State private var mountedNightDayKeys: Set<Date> = []
    @State private var shareItem: ShareImage?
    /// The scroll content's measured width, so the contact sheet's strip capacity is derived
    /// from the real available width rather than a hard-coded frame count. 393 is the design's
    /// own reference width, a reasonable first-paint guess before the geometry read lands.
    @State private var scrollWidth: CGFloat = 393

    /// Cached `DarkroomDayUnit` groupings over `vm.photos`, the fix for the Darkroom's own scroll
    /// hitch (perf audit finding 1+2): `dayUnits`/`monthScopedUnits` used to be computed
    /// properties re-running `Dictionary(grouping:)` + a sort over the WHOLE loaded photo list on
    /// every access, and `nightList`'s own `ForEach` read `lastMonthScopedUnitId` (which chains
    /// through `monthScopedUnits`) once PER MOUNTED ROW per body evaluation — so a month of thirty
    /// nights regrouped its own thirty-plus photos thirty separate times every scroll frame.
    ///
    /// Recomputed ONLY when an input changes (`vm.photos` or `anchor`, see `recomputeDayUnits`),
    /// never inside a row. Mirrors `DarkroomViewModel.recomputeSplits`'s own cache-on-`didSet`
    /// pattern one layer up (that type's own doc names the exact crash on record for touching
    /// `@Observable` state off the main actor); this cache is `@State`, so it is main-actor-only
    /// the same way every other piece of this view's state already is, and every write below
    /// happens synchronously inline with the mutation that invalidates it, never off-actor.
    ///
    /// ANTI-PATTERN, do not reintroduce: a computed grouping property (or anything that calls
    /// `DarkroomDayUnit.units`) read from inside a `ForEach` row, or from any per-row closure.
    /// `lastMonthScopedUnitId`/`closingRowInfo` below are free by-products of this cache: they
    /// already only ever read `dayUnits`/`monthScopedUnits`, so caching THOSE is what makes both
    /// of them cheap too, with no separate cache of their own needed.
    @State private var cachedDayUnits: [DarkroomDayUnit] = []
    @State private var cachedMonthScopedUnits: [DarkroomDayUnit] = []

    /// Three across, always, the same count the profile, roll and feed grids use. Not measured:
    /// the COUNT is the fixed thing now and the frame width is what falls out of the screen, which
    /// is the reverse of the well geometry below and the reason a full row ends flush on the
    /// margin instead of somewhere short of it.
    private var stripCapacity: Int { DarkroomDayUnit.photoColumns }

    /// One frame's width against the rack's own 16pt-a-side padding. `scrollWidth` starts at a
    /// sensible 393 and is corrected by `onGeometryChange` before anything is on screen, so this
    /// is never asked for a width of zero in practice, and returns zero rather than a negative
    /// frame if it ever is.
    private var photoFrameWidth: CGFloat {
        DarkroomDayUnit.photoFrameWidth(availableWidth: scrollWidth - 32)
    }

    /// `DarkroomYearRow`'s own per-row frame capacity, on the SMALL 46pt pitch its sample strip
    /// still draws at, against the Year row's own 16pt-a-side padding (`scrollWidth - 32`,
    /// identical to the rack's). Never a hard-coded frame count: a Pro Max's extra width earns
    /// the Year rung an eighth frame the same way it earns the rack one.
    ///
    /// This deliberately no longer matches `stripCapacity` above. They agreed while both racks
    /// drew 44x59; the day rack has since gone to three across for legibility, and a summary row
    /// that grew with it would show three big photographs for a seventy-eight shot month, which
    /// reads as a gallery of three rather than a taste of the month.
    ///
    /// `scrollWidth` is shared with the `.month` rung's own measurement (`yearScrollList`'s
    /// `.onGeometryChange` keeps it current while `.year` is the mounted rung, same as the night
    /// list's own `ScrollView` does for `.month`), so whichever rung was measured last is what
    /// this reads.
    private var yearRowCapacity: Int {
        max(1, DarkroomDayUnit.stripCapacity(availableWidth: scrollWidth - 32))
    }

    /// One unit per night, newest first, this render's single source of truth for both the
    /// contact sheet and the pager's flattened order. A cached read (see `cachedDayUnits`'s own
    /// doc), not a recomputation: this used to run `Dictionary(grouping:)` + a sort over the whole
    /// loaded photo list on every access.
    private var dayUnits: [DarkroomDayUnit] { cachedDayUnits }

    /// PR 5 of the zoom redesign, revision 2: what `nightList` actually renders at `.month` —
    /// `dayUnits` restricted to `anchor`'s own calendar month. Anything older the last fetched
    /// page's boundary dragged in stays loaded in `vm.photos`/`dayUnits`, just not shown here:
    /// SPILLOVER, warming the client-side cache for whichever OLDER month gets anchored next
    /// (a closing-row tap, most commonly), rather than being thrown away. A cached read, same as
    /// `dayUnits` above.
    private var monthScopedUnits: [DarkroomDayUnit] { cachedMonthScopedUnits }

    private var lastMonthScopedUnitId: Date? { monthScopedUnits.last?.id }

    /// The single choke point for both caches above: reruns `DarkroomDayUnit.units` over the
    /// current `vm.photos`, once unscoped and once scoped to the current `anchor`. Called
    /// explicitly from `.onAppear` (after `resolveInitialZoomAndAnchor` has set the real anchor,
    /// so the very first cache isn't built against the placeholder default) and from
    /// `.onChange(of:)` on both `vm.photos` and `anchor` below, the same two inputs
    /// `DarkroomDayUnit.units(from:anchor:)` itself takes.
    private func recomputeDayUnits() {
        cachedDayUnits = DarkroomDayUnit.units(from: vm.photos)
        cachedMonthScopedUnits = DarkroomDayUnit.units(from: vm.photos, anchor: anchor)
    }

    /// Every distinct calendar month currently loaded OTHER than `anchor` itself: the spillover
    /// fallback `DarkroomMonthPaging.nextOlderMonth` reads when the server summary hasn't
    /// resolved yet. Not pre-filtered to "older than anchor" here — `nextOlderMonth` does that
    /// itself, defensively, since an anchored fetch should never load anything newer than its own
    /// anchor in practice, but nothing here enforces that as an invariant worth trusting blindly.
    private var spilloverMonths: [DarkroomYearMonth] {
        Array(Set(dayUnits.map { DarkroomYearMonth(date: $0.dayKey) })).filter { $0 != anchor }
    }

    /// Whether within-month pagination should still be trying for another page. `loadMoreSentinel`,
    /// the geometry backstop, AND the closing row all read this ONE property (see
    /// `DarkroomMonthPaging.shouldContinuePaging`'s own doc for the rule itself), so none of the
    /// three can disagree about whether pagination for the current anchor is still live.
    private var monthPagingActive: Bool {
        DarkroomMonthPaging.shouldContinuePaging(
            oldestLoadedMonth: dayUnits.last.map { DarkroomYearMonth(date: $0.dayKey) },
            anchor: anchor,
            hasMore: photoService.hasMore
        )
    }

    /// The closing row's target + count, `nil` while pagination might still be live (never shown
    /// while a page may still arrive, see `DarkroomMonthClosingRow`'s own doc) or when neither the
    /// summary nor loaded spillover knows of anything older than `anchor`.
    private var closingRowInfo: (month: DarkroomYearMonth, shotCount: Int?)? {
        guard !monthPagingActive else { return nil }
        return DarkroomMonthPaging.nextOlderMonth(anchor: anchor, summaries: monthSummaries, spilloverMonths: spilloverMonths)
    }

    /// Distinct calendar months among currently-loaded photos, for the Year/All-time rungs' quiet
    /// loading treatment (see `yearContent`/`allTimeContent`'s own docs) before the server summary
    /// resolves. A LOWER BOUND only, never trusted as "the whole library" — the same trap
    /// `PhotoService`'s own pagination doc warns about: a month can gain a cell here and later gain
    /// a real count once the summary lands, but a month absent here is never asserted empty.
    private var loadedYearMonths: Set<DarkroomYearMonth> {
        Set(dayUnits.map { DarkroomYearMonth(date: $0.dayKey) })
    }

    /// The flattened archive in render order, developing shots included in their true
    /// chronological place: what `PhotoPagerView`'s night-rack pages through, so swiping (or a
    /// rack tap) can land on a still-developing shot's develops-at state instead of skipping it.
    private var renderOrderPhotos: [Photo] {
        dayUnits.flatMap(\.photos)
    }

    private var sortPreviewPhotos: [Photo] {
        DarkroomDayUnit.pickPreview(from: unsortedPhotos)
    }

    /// Distinct nights among `unsortedPhotos`, for the sort banner's second line. See
    /// `DarkroomDayUnit.distinctNightCount`'s own doc.
    private var unsortedNightCount: Int {
        DarkroomDayUnit.distinctNightCount(in: unsortedPhotos)
    }

    // MARK: - Header

    /// The one-row 44pt header the approved Darkroom design replaces the old big-title +
    /// toolbar arrangement with. Two mutually exclusive rows, not one row with conditional
    /// pieces bolted on: normal mode and select mode read as different intents (browse vs.
    /// batch action) and the approved design lays them out differently enough (title-left vs.
    /// centered count) that sharing one HStack would mean fighting its own alignment rules for
    /// both cases at once.
    @ViewBuilder
    private var darkroomHeader: some View {
        if isSelecting {
            selectionHeaderRow
        } else {
            normalHeaderRow
        }
    }

    private var normalHeaderRow: some View {
        HStack(spacing: 6) {
            // Chrome, not content. This sat at `textPrimary` and 17pt light, identical to the
            // unit titles below it (the night title, the feed handle, a ready roll's name), so
            // the top of the hierarchy was set exactly like its third rung and read as one more
            // row heading. The colour moved rather than the size: growing it to 22 was tried on
            // paper and put chrome in competition with the 26pt hero on Rolls, and grew the one
            // piece of chrome that was deliberately shrunk. Every other chrome label in the app
            // is already secondary (the zoom crumb, the DEVELOPED rule, the closing-month row);
            // this was the lone outlier dressed as content. Orientation is carried by the tab
            // bar, which is always on screen and marks the selected tab in the accent, so the
            // screen name is reinforcement and reinforcement should be quiet.
Text("Darkroom")
                .flimFont(17, weight: .light, relativeTo: .body)
                .tracking(0.5)
                .foregroundStyle(FlimTheme.textSecondary)

            // The ledger: server-counted, never the loaded page count (see PhotoService's own
            // pagination trap doc). Omitted with its dot at zero, same as the old toolbar total.
            if let total = vm.totalCount, total > 0 {
                Text("·")
                    .flimFont(12.5, relativeTo: .footnote)
                    .foregroundStyle(FlimTheme.textTertiary)
                Text("\(total) shot\(total == 1 ? "" : "s")")
                    .flimFont(12.5, relativeTo: .footnote)
                    .foregroundStyle(FlimTheme.textTertiary)
            }

            Spacer()

            #if DEBUG
            Button {
                Task {
                    if let uid = auth.currentUser?.id {
                        await photoService.seedUnsortedPhotos(userId: uid)
                        await reload()
                    }
                }
            } label: {
                Image(systemName: "ladybug").foregroundStyle(FlimTheme.textTertiary)
            }
            .accessibilityLabel("Seed unsorted (DEBUG)")
            #endif

            // Select only exists at the deepest rung: there is nothing to select at the Year or
            // All-time rungs, which render summary rows, not photo frames.
            if !vm.photos.isEmpty, zoom == .month {
                Button("Select") {
                    isSelecting = true
                    selectedIDs = []
                }
                .flimFont(15)
                .foregroundStyle(accent)
            }
        }
        .frame(height: 44)
        .padding(.horizontal, 20)
    }

    /// Cancel leading, the running count centered, laid out with a `ZStack` rather than a
    /// three-way `HStack` split so the count is exactly centered regardless of how wide "Cancel"
    /// renders at a given Dynamic Type size.
    private var selectionHeaderRow: some View {
        ZStack {
            Text("\(selectedIDs.count) selected")
                .flimFont(15)
                .foregroundStyle(FlimTheme.textPrimary)

            HStack {
                Button("Cancel") {
                    isSelecting = false
                    selectedIDs = []
                }
                .flimFont(15)
                .foregroundStyle(accent)

                Spacer()
            }
        }
        .frame(height: 44)
        .padding(.horizontal, 20)
    }

    var body: some View {
        ZStack {
            FlimTheme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                darkroomHeader

                // Pinned under the header, outside the scroll (PR 2 of the zoom redesign,
                // 2026-08-25): visible at every scroll offset instead of scrolling out of view
                // the moment a scan reaches night two. Same hide rules as before the move, plus
                // select mode and the zoom bar hide it together: the sort row is a .month-only
                // destination the same way the zoom control is a .month-only tool.
                if !isSelecting, zoom == .month, !unsortedPhotos.isEmpty {
                    DarkroomSortBanner(
                        accent: accent,
                        count: unsortedPhotos.count,
                        nightCount: unsortedNightCount,
                        previewPhotos: sortPreviewPhotos,
                        previewURLs: unsortedURLCache,
                        onTap: { showSortDeck = true }
                    )
                }

                if !isSelecting {
                    DarkroomZoomBar(
                        zoom: zoom,
                        anchor: anchor,
                        sub: DarkroomZoomChrome.sub(zoom: zoom, anchor: anchor, summaries: monthSummaries),
                        accent: accent,
                        onZoomOut: { zoomOut() },
                        onZoomIn: { zoomIn() }
                    )
                }

                Group {
                    switch zoom {
                    case .month: monthContent
                    case .year: yearContent
                    case .allTime: allTimeContent
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.22), value: zoom)
            }
        }
        .overlay {
            if showReveal { revealOverlay }
        }
        // The tab re-tap signal: scroll the current rung to its top, unless it's already there,
        // in which case it zooms OUT one rung instead (the ladder's other half of "tap the tab
        // you're already on"). `scrollOffsetY` is tracked per-rung by whichever `ScrollView` is
        // Tab re-tap means HOME, not "zoom out one rung". The shipped zoom-out rule assumed
        // re-taps mostly arrive mid-scroll; on device you are almost always already at the top,
        // so every tap zoomed out and repeated taps walked the whole ladder (owner-reported as
        // "cycling through the views", 2026-08-25). The platform-native semantic instead:
        // first tap scrolls the current rung to its top; a tap already at the top returns to
        // the DEFAULT view (Nights of the current month); once home, further taps do nothing.
        // Terminal, never cycles, and doubles as the escape hatch from any rung. Gated on
        // `!isSelecting`: a retap during selection keeps its scroll-to-top-only meaning and
        // never switches rungs out from under an in-progress selection.
        .onChange(of: scrollToTop) {
            let currentMonth = DarkroomYearMonth(date: .now)
            let atHome = zoom == .month && anchor == currentMonth
            if !isSelecting, scrollOffsetY <= 2, !atHome {
                // Through the same landing machinery a Year-row tap uses: an anchored view's
                // reset cleared the present's rows, so going home must RELOAD them, not just
                // flip the anchor and render an empty scope.
                selectMonth(currentMonth)
            } else {
                withAnimation(.snappy) { scrollProxy?.scrollTo("top", anchor: .top) }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                Button(role: .destructive) { deleteSelected() } label: {
                    Text(selectedIDs.isEmpty ? "Select photos to delete" : "Delete \(selectedIDs.count)")
                        .flimFont(15, weight: .semibold)
                        .foregroundStyle(selectedIDs.isEmpty ? FlimTheme.textTertiary : .white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(selectedIDs.isEmpty ? Color.white.opacity(0.08) : Color.red.opacity(0.85), in: Capsule())
                }
                .disabled(selectedIDs.isEmpty)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
            }
        }
        // Undo toast, deletes are deferred a few seconds so an accidental tap is recoverable.
        .overlay(alignment: .bottom) {
            if showUndoToast {
                HStack(spacing: 14) {
                    Text("Deleted \(pendingDelete.count) photo\(pendingDelete.count == 1 ? "" : "s")")
                        .flimFont(14).foregroundStyle(.white)
                    Button("Undo") { undoDelete() }
                        .flimFont(14, weight: .semibold)
                        .foregroundStyle(accent)
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 90)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: showUndoToast)
        .overlay(alignment: .top) {
            if let errorToast {
                Label(errorToast, systemImage: "exclamationmark.triangle.fill")
                    .flimFont(13.5, weight: .medium, relativeTo: .subheadline).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onAppear {
            resolveInitialZoomAndAnchor()
            // Builds the very first cache against the REAL anchor `resolveInitialZoomAndAnchor`
            // just resolved, not the placeholder default `anchor` starts at: `vm.photos` is still
            // empty at this point either way (nothing has loaded yet), so this is cheap, and
            // `.onChange(of: anchor)` below would otherwise be the only thing to build it, one
            // frame later than it needs to be.
            recomputeDayUnits()
            Task {
                await reload()
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-seedDemo"), vm.photos.isEmpty,
                   let uid = auth.currentUser?.id {
                    await photoService.seedDemoPhotos(userId: uid)
                    await reload()
                }
                #endif
            }
        }
        // The Darkroom scroll-hitch fix's other half (see `cachedDayUnits`'s own doc): every path
        // that can change either input recomputes the cache right here, ONCE per change, rather
        // than the grouping re-running per mounted row. `vm.photos` covers every reassignment
        // (`load`, `loadAnchored`, `loadMore`, `markReadyPhotos`'s poll, an optimistic delete, an
        // undo's restore); `anchor` covers every jump (`selectMonth`, the scroll-driven crumb
        // tracker, a cold-launch resolution).
        .onChange(of: vm.photos) { _, _ in recomputeDayUnits() }
        .onChange(of: anchor) { _, _ in recomputeDayUnits() }
        // The 60s develop poll only needs to run while this screen is on it, and an in-flight
        // anchored jump has no reason to keep running once nobody's watching for it to land. A
        // still-pending delete is flushed rather than left to its own 4s timer, see
        // `commitPendingDelete`'s own doc.
        .onDisappear { vm.stopRefreshing(); anchoredJumpTask?.cancel(); commitPendingDelete() }
        .fullScreenCover(item: $selectedPhoto) { photo in
            pager(for: photo)
        }
        .fullScreenCover(isPresented: $showSortDeck, onDismiss: { Task { await reload() } }) {
            SortDeckView(onFinish: {})
        }
        // On the outer chain, not on the grid's ScrollView: the grid does not exist in the empty
        // and loading states, and a widget tap that lands then would be silently dropped.
        .onChange(of: openSortDeckSignal) { _, _ in
            // Guarded on there being something to sort: a tap can land a moment after the deck
            // was emptied on another device, and an empty full-screen deck is a dead end.
            if !unsortedPhotos.isEmpty { showSortDeck = true }
        }
        .onChange(of: openPhotoId.wrappedValue) { _, _ in openRequestedPhoto() }
        .sheet(item: $shareItem) { SharePreviewSheet(photo: $0.image, caption: $0.caption) }
    }

    // MARK: - Rung content (PR 3 of the zoom redesign, revision 2)

    /// The `.month` rung. As of PR 5 of the zoom redesign, revision 2, this renders ONLY the
    /// anchor month's own nights, not a continuous multi-month scroll: see `monthScopedUnits`'s
    /// own doc for what happens to rows a page boundary drags in past that month. Owns its own
    /// loading/error/empty states, same as before the zoom ladder existed.
    @ViewBuilder
    private var monthContent: some View {
        if (vm.isLoading && vm.photos.isEmpty)
            || (monthScopedUnits.isEmpty && anchoredJumpTarget != nil) {
            // The second clause: an anchored jump is in flight for a month whose rows are not
            // loaded yet. `vm.photos` still holds the PREVIOUS anchor's rows, so the plain
            // isLoading/isEmpty gate would render an essentially blank night list (nothing
            // matches the new anchor) with no affordance until the fetch resolves. The
            // skeleton is the honest state for that window.
            ScrollView { DarkroomLoadingSkeleton(frameWidth: photoFrameWidth).padding(.top, 8) }
                .scrollDisabled(true)
        } else if let error = vm.error, vm.photos.isEmpty {
            ErrorState(message: error) { await reload() }
        } else if vm.photos.isEmpty {
            // Nothing loaded anywhere. `emptyState`'s "Your darkroom's empty" copy is written
            // for the present-day case (never shot anything); anchored on an older month it
            // reads as a lie the moment the person zooms back to the present and finds photos
            // after all. See `scopedEmptyMonthState`'s own doc.
            if anchor != DarkroomYearMonth(date: .now) {
                scopedEmptyMonthState
            } else {
                emptyState
            }
        } else if monthScopedUnits.isEmpty, anchoredJumpTarget == nil, pendingMonthLanding == nil {
            // Spillover: photos ARE loaded (an older or newer month's rows, most often left
            // behind by a previous anchored fetch's page boundary), just none of them belong to
            // THIS anchor, e.g. every shot in the month was just deleted. `emptyState` would be
            // actively wrong here, it claims the whole darkroom is empty. Gated on no jump being
            // in flight so this never flashes mid-fetch, ahead of the loading skeleton above.
            scopedEmptyMonthState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    Color.clear.frame(height: 0).id("top")
                    nightList
                }
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { scrollWidth = $0 }
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
                    scrollOffsetY = y
                }
                // The pagination backstop, alongside (not instead of) `loadMoreSentinel`'s own
                // mount/`.task(id:)` re-arm — see that view's own doc for why a second, geometry-
                // driven trigger earns its keep here. Fires on every scroll frame's geometry
                // update, so unlike the sentinel it cannot be starved by how much (or how little)
                // of the `LazyVStack` SwiftUI has chosen to realize: within 600pt of the bottom
                // of the currently measured content, ask for the next page. `loadMore`'s own
                // `hasMore`/`isLoading` guards make this safe to call redundantly every frame
                // that stays within the threshold.
                //
                // Gated on `monthPagingActive` (PR 5 of the zoom redesign, revision 2), the SAME
                // property `loadMoreSentinel` and the closing row read: once the oldest loaded
                // photo has crossed the anchor month's own edge, this must stop firing right
                // alongside the sentinel, or it would keep paging PAST the month the closing row
                // is already offering as the next step, forever, every frame near the bottom.
                .onScrollGeometryChange(for: Bool.self) { geo in
                    geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 600
                } action: { _, isNearBottom in
                    if isNearBottom, monthPagingActive { Task { await loadMoreIfNeeded() } }
                }
                .refreshable { await reload() }
                .onAppear { scrollProxy = proxy }
                // Consumes `pendingMonthLanding` using THIS `proxy`, the one that actually belongs
                // to the now-mounted `.month` rung — see `pendingMonthLanding`'s own doc for the
                // race this fixes. Keyed on the value itself, not a bare `Void` id, so a fresh
                // request landing while this same rung is already mounted (year -> month twice in
                // a row without leaving `.month` in between isn't currently reachable, but this
                // stays correct if that ever changes) reruns too, not just the initial mount.
                .task(id: pendingMonthLanding) {
                    guard let target = pendingMonthLanding else { return }
                    landOnAnchorMonth(target, proxy: proxy)
                }
            }
        }
    }

    /// One unit per night within the anchor month only (`monthScopedUnits`, see its own doc), no
    /// month Sections, no sticky band: the jump sheet and the month band it lived under are both
    /// gone, replaced by the zoom ladder. Unit separators stay between every pair of nights, same
    /// as before; the closing row (PR 5) takes the separator's place after the LAST one, once
    /// pagination for this month has genuinely stopped.
    private var nightList: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(monthScopedUnits) { unit in
                DarkroomDayUnitView(
                    unit: unit,
                    capacity: stripCapacity,
                    frameWidth: photoFrameWidth,
                    accent: accent,
                    signedURLCache: vm.signedURLCache,
                    sharedIds: feed.myPostedPhotoIds,
                    isSelecting: isSelecting,
                    selectedIDs: selectedIDs,
                    rollName: { rollName(for: $0) },
                    photoNS: photoNS,
                    onTapDeveloped: { photo in
                        selectedURL = vm.signedURLCache[photo.id]
                        selectedPhoto = photo
                    },
                    onToggleSelect: { toggleSelect($0) },
                    developedMenu: { AnyView(developedMenu($0)) },
                    developingMenu: { AnyView(developingMenu($0)) },
                    onFrameAppear: { photo in await onFrameAppear(photo) },
                    onMountChange: { dayKey, isMounted in
                        if isMounted { mountedNightDayKeys.insert(dayKey) } else { mountedNightDayKeys.remove(dayKey) }
                        updateMonthAnchorFromScroll()
                    }
                )
                if unit.id != lastMonthScopedUnitId {
                    DarkroomUnitSeparator()
                }
            }
            loadMoreSentinel
            // Only once pagination has genuinely stopped (`loadMoreSentinel` itself has already
            // gone quiet, see its own doc) AND a next-older month is actually known: never shown
            // while a page may still arrive, or it would flash under the real next night. Also
            // hidden entirely in select mode, the same convention the zoom bar and sort banner
            // already follow: `selectMonth` doesn't clear `isSelecting`/`selectedIDs`, so jumping
            // months mid-selection would leave a selection referring to a photo no longer even
            // being rendered.
            if !isSelecting, let info = closingRowInfo {
                DarkroomMonthClosingRow(month: info.month, shotCount: info.shotCount) {
                    Haptics.tap()
                    selectMonth(info.month)
                }
            }
        }
        .padding(.bottom, 12)
    }

    /// The `.year` rung: one row per month with photos in `anchor.year`, newest first.
    ///
    /// Three states, not two: `monthSummaries` resolved with rows -> full content (real counts);
    /// `isLoadingSummaries` and nothing resolved yet -> the quiet loading structure, rows derived
    /// from `loadedYearMonths` with counts omitted rather than guessed, still fully tappable
    /// (`DarkroomYearRow`'s `meta: nil` case exists for exactly this); resolved to `nil` (the
    /// fetch genuinely failed, or the RPC isn't reachable) -> `rungUnavailableState`. Landing on
    /// Year/All-time on every warm relaunch is the DEFAULT case whenever `SceneStorage` restored a
    /// non-`.month` rung, so the middle state is not an edge case, it is the first frame.
    @ViewBuilder
    private var yearContent: some View {
        if let monthSummaries {
            let rows = monthSummaries
                .filter { $0.yearMonth.year == anchor.year && $0.shotCount > 0 }
                .sorted { $0.monthStart > $1.monthStart }
            if rows.isEmpty {
                emptyRungState("Nothing shot in \(anchor.year) yet.")
            } else {
                yearScrollList {
                    ForEach(rows, id: \.monthStart) { row in
                        DarkroomYearRow(
                            summary: row,
                            isAnchor: row.yearMonth == anchor,
                            accent: accent,
                            capacity: yearRowCapacity,
                            onTap: { selectMonth(row.yearMonth) }
                        )
                    }
                }
            }
        } else if isLoadingSummaries {
            let months = loadedYearMonths.filter { $0.year == anchor.year }.sorted { $0.month > $1.month }
            if months.isEmpty {
                // Nothing loaded yet at all (the very first frame of a cold reload): a blank,
                // quiet region rather than a message that might turn out to be wrong a moment
                // later either way.
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                yearScrollList {
                    ForEach(months, id: \.self) { ym in
                        DarkroomYearRow(
                            monthStart: dateFromYearMonth(ym),
                            isAnchor: ym == anchor,
                            meta: nil,
                            hasDeveloping: false,
                            accent: accent,
                            capacity: yearRowCapacity,
                            onTap: { selectMonth(ym) }
                        )
                    }
                }
            }
        } else {
            rungUnavailableState
        }
    }

    /// The scroll chrome shared by both the resolved and loading-state Year rung content, so the
    /// offset tracking / refresh / proxy wiring isn't duplicated between them.
    private func yearScrollList<Rows: View>(@ViewBuilder rows: () -> Rows) -> some View {
        // Built once, up front, as a concrete value rather than left as a closure: `rows` isn't
        // `@escaping`, and `ScrollViewReader`'s own content closure IS, so calling `rows()` from
        // inside it is a non-escaping-capture error. Capturing the already-built view instead
        // sidesteps that; it costs nothing extra since a `LazyVStack`'s children are lazy either
        // way.
        let content = rows()
        return ScrollViewReader { proxy in
            ScrollView {
                Color.clear.frame(height: 0).id("top")
                LazyVStack(alignment: .leading, spacing: 0) { content }
            }
            // Keeps `scrollWidth` (and so `yearRowCapacity`) current while `.year` is the
            // mounted rung, the same way the `.month` night list's own `ScrollView` does: a cold
            // launch (or a warm relaunch) that lands directly on Year, never having mounted
            // `.month` first, would otherwise derive the Year row's own frame capacity from the
            // 393pt first-paint default forever.
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { scrollWidth = $0 }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
                scrollOffsetY = y
            }
            .refreshable { await reload() }
            .onAppear { scrollProxy = proxy }
        }
    }

    /// The `.allTime` rung: one row per year, newest first. Same three-state shape as
    /// `yearContent`, see its own doc.
    @ViewBuilder
    private var allTimeContent: some View {
        if let monthSummaries {
            let totals = DarkroomSummaryAggregation.yearTotals(from: monthSummaries)
            if totals.isEmpty {
                emptyRungState("Nothing developed yet.")
            } else {
                allTimeScrollList {
                    ForEach(totals, id: \.year) { yearTotal in
                        DarkroomAllTimeRow(
                            totals: yearTotal,
                            monthSummaries: monthSummaries.filter { $0.yearMonth.year == yearTotal.year },
                            anchor: anchor,
                            accent: accent,
                            onSelectMonth: { selectMonth($0) }
                        )
                    }
                }
            }
        } else if isLoadingSummaries {
            let years = Set(loadedYearMonths.map(\.year)).sorted(by: >)
            if years.isEmpty {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                allTimeScrollList {
                    ForEach(years, id: \.self) { year in
                        DarkroomAllTimeRow(
                            year: year,
                            headerMeta: nil,
                            monthHasPhotos: { month in loadedYearMonths.contains(DarkroomYearMonth(year: year, month: month)) },
                            // Never a guessed number: "present" is known from what's loaded,
                            // "how many" is not, until the real summary resolves.
                            monthShotCount: { _ in nil },
                            anchor: anchor,
                            accent: accent,
                            onSelectMonth: { selectMonth($0) }
                        )
                    }
                }
            }
        } else {
            rungUnavailableState
        }
    }

    private func allTimeScrollList<Rows: View>(@ViewBuilder rows: () -> Rows) -> some View {
        let content = rows()   // see `yearScrollList`'s own doc for why this is captured, not called, inside
        return ScrollViewReader { proxy in
            ScrollView {
                Color.clear.frame(height: 0).id("top")
                LazyVStack(alignment: .leading, spacing: 0) { content }
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
                scrollOffsetY = y
            }
            .refreshable { await reload() }
            .onAppear { scrollProxy = proxy }
        }
    }

    /// Reconstructs a `Date` (first of the month) from a `DarkroomYearMonth`, for the loading-state
    /// Year rows, which have no `DarkroomMonthSummaryV2.monthStart` to read yet.
    private func dateFromYearMonth(_ ym: DarkroomYearMonth) -> Date {
        Calendar.current.date(from: DateComponents(year: ym.year, month: ym.month, day: 1)) ?? .now
    }

    /// A rung with nothing in it (a real, server-confirmed zero, not "unavailable").
    private func emptyRungState(_ message: String) -> some View {
        VStack(spacing: 8) {
            Text(message)
                .flimFont(14)
                .foregroundStyle(FlimTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The Year/All-time rungs' genuine failure state: the summary fetch has RESOLVED (not merely
    /// pending, see `isLoadingSummaries`) to `nil` — a real failure, or a pre-migration RPC 404,
    /// mirroring the predecessor `darkroomMonthCounts`'s own degraded-state doc. Pull-to-refresh
    /// retries the same way the month list's own error state does.
    private var rungUnavailableState: some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: "square.stack.3d.up.slash")
                    .font(.system(size: 34, weight: .ultraLight))
                    .foregroundStyle(accent.opacity(0.7))
                Text("This view isn't ready yet.")
                    .flimFont(15, weight: .light)
                    .foregroundStyle(FlimTheme.textSecondary)
                Text("Pull down to try again, or zoom back in.")
                    .flimFont(12.5, relativeTo: .footnote)
                    .foregroundStyle(FlimTheme.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            .frame(maxWidth: .infinity, minHeight: 260)
        }
        .refreshable { await reload() }
    }

    /// The pagination trigger, moved OUT of `onFrameAppear`/per-frame `.task` (see below) and
    /// into its own view, last in the `LazyVStack`. `.task` on a frame only ever fires once per
    /// that frame's OWN identity: `reload()` (fired from `.onAppear` every time this tab is
    /// revisited) resets `vm.photos` back to page one, but the frames for those same photo ids
    /// stay mounted with the same identity across that reassignment, so a frame whose `.task`
    /// already ran in an earlier session never re-fires, and the "last ready frame" trigger it
    /// used to carry could then never fire again: the library stuck at 30 photos, permanently,
    /// the moment you'd once scrolled far enough to load a second page and then left the tab.
    ///
    /// This sentinel has no such per-photo identity to get stuck on. `LazyVStack` mounts/
    /// unmounts it as it scrolls in and out of the viewport (unlike a rack's own frames, which
    /// sit inside a plain, non-lazy `HStack` and all mount together the moment their night is
    /// realized), so scrolling away and back always gives it a fresh `onAppear`. While it stays
    /// visible, `.task(id: vm.photos.count)` re-arms itself every time a page actually lands
    /// (the id changes), chaining pages automatically until `monthPagingActive` goes false (the
    /// `if` below then removes the sentinel outright — PR 5 of the zoom redesign, revision 2,
    /// widened this from a bare `photoService.hasMore` check to also stop once the oldest loaded
    /// photo crosses the anchor month's own edge, see `monthPagingActive`'s own doc) or the guard
    /// inside `DarkroomViewModel.loadMore` no-ops because a fetch is already in flight.
    ///
    /// INVARIANT (found 2026-08-25, the zoom redesign's PR 3): this sentinel's mount is no longer
    /// the ONLY thing driving pagination, and must not become the only thing again. PR 3 added
    /// `DarkroomDayUnitView.onMountChange`, which mutates `mountedNightDayKeys` (a `DarkroomView`
    /// `@State` `Set`) on every single night's mount AND unmount — nothing this screen's scroll
    /// region did before PR 3 touched `@State` at all. A fast scroll through months of nights now
    /// drives dozens of full `DarkroomView` body re-evaluations per second where it used to drive
    /// zero, and that is exactly the kind of render pressure that can leave a `LazyVStack` behind
    /// on realizing the cells nearest the bottom of the currently-scrolled-to viewport, this
    /// sentinel included: its `.onAppear` (and by extension its `.task(id:)` re-arm) never fires,
    /// pagination silently stalls, and nothing scrolled past it looks any different than "there's
    /// nothing more". `monthContent`'s own `.onScrollGeometryChange(for: Bool.self)` near-bottom
    /// trigger is the fix: it is driven by scroll geometry alone, which SwiftUI reports every
    /// frame regardless of what the `LazyVStack` has chosen to realize, so it cannot be starved
    /// the way this sentinel's mount can. Keep both, and keep both reading `monthPagingActive`, or
    /// they will disagree about when to stop. Removing the geometry trigger because "the sentinel
    /// already does this" reopens this exact stall.
    ///
    /// A jump straight to an OLDER anchor (a Year row, an All-time cell, or the closing row below)
    /// is a different mechanism entirely (`landOnAnchorMonth`): a single awaited anchored fetch,
    /// never a scroll-driven loop, so it cannot be starved by any of the above and this sentinel's
    /// own starvation risk doesn't apply to it.
    @ViewBuilder
    private var loadMoreSentinel: some View {
        if monthPagingActive {
            Color.clear
                .frame(height: 44)
                .onAppear { Task { await loadMoreIfNeeded() } }
                .task(id: vm.photos.count) { await loadMoreIfNeeded() }
        }
    }

    private func loadMoreIfNeeded() async {
        guard let uid = auth.currentUser?.id else { return }
        await vm.loadMore(photoService: photoService, userId: uid)
    }

    /// Resolves a frame's signed URL if it isn't cached yet (freshly-loaded pages aren't covered
    /// by `reload()`'s batched prefetch). Pagination itself is `loadMoreSentinel`'s job now, see
    /// its own doc for why this used to also carry that trigger and why that broke.
    private func onFrameAppear(_ photo: Photo) async {
        if photo.isReady, vm.signedURLCache[photo.id] == nil {
            _ = await vm.signedURL(for: photo, photoService: photoService)
        }
    }

    // MARK: - Grid long-press menu

    /// Long-press actions on a developed shot. This replaces the old bare long-press-to-select
    /// gesture: selecting is still one item in here, alongside the actions that until now
    /// required opening the photo full-screen first. A context menu and an `onLongPressGesture`
    /// on the same cell would compete for the gesture, so the menu subsumes it rather than
    /// stacking on top.
    @ViewBuilder
    private func developedMenu(_ photo: Photo) -> some View {
        Button { beginSelecting(photo.id) } label: { Label("Select", systemImage: "checkmark.circle") }
        // "Tag people" used to live here, routing into the share composer with the tag sheet up
        // (tags belong to a post, so there was nothing to attach one to until the photo was being
        // shared). Removed 2026-08-24: tagging an unshared archive shot from the grid contradicts
        // the rule that tagging only ever happens AT share time or on an already-shared shot,
        // even though this route technically went through the composer first. The viewer's own
        // promoted "Tag" action (only shown once a shot is already shared) is the one remaining
        // way to tag a Darkroom photo.
        Button { share(photo) } label: { Label("Share", systemImage: "square.and.arrow.up") }
        Button {
            Haptics.tap()
            // Reports the outcome. This returns Bool so a failure can be surfaced, and
            // three of the four call sites were dropping it: you tapped 'Set as profile
            // photo', nothing happened, and nothing said why.
            Task {
                if await auth.setAvatar(fromPhotoPath: photo.storagePath) {
                    Haptics.success()
                } else {
                    Haptics.error()
                    flashError("Couldn't update your profile photo. Check your connection and try again.")
                }
            }
        } label: { Label("Set as profile photo", systemImage: "person.crop.circle") }
        Divider()
        Button(role: .destructive) { requestDelete([photo]) } label: { Label("Delete", systemImage: "trash") }
    }

    /// A still-developing shot has no viewable image yet, so its menu is select + delete only.
    @ViewBuilder
    private func developingMenu(_ photo: Photo) -> some View {
        Button { beginSelecting(photo.id) } label: { Label("Select", systemImage: "checkmark.circle") }
        Divider()
        Button(role: .destructive) { requestDelete([photo]) } label: { Label("Delete", systemImage: "trash") }
    }

    /// Pulls the full-res file down and hands it to the share composer, the same path the feed
    /// card's "Save to Camera Roll" uses.
    ///
    /// Checks the disk cache's raw bytes for this exact object first (see `DiskImageCache.
    /// loadRaw`): a long-press Share used to go through a bare `URLSession` every single time,
    /// re-downloading the ~1MB+ master even when it was already sitting on the device from an
    /// earlier repair pass or a previous share this session. A miss still falls all the way
    /// through to the same download this always did, and now saves those bytes for next time.
    private func share(_ photo: Photo) {
        Haptics.tap()
        Task {
            if let raw = await DiskImageCache.loadRaw(path: photo.storagePath), let image = UIImage(data: raw) {
                shareItem = ShareImage(image: image, caption: BrandedExport.Caption(date: photo.takenAt))
                return
            }
            guard let url = try? await photoService.signedURL(for: photo.storagePath),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else {
                Haptics.error()
                return
            }
            DiskImageCache.saveRaw(data, path: photo.storagePath)
            shareItem = ShareImage(image: image, caption: BrandedExport.Caption(date: photo.takenAt))
        }
    }

    /// Top-slot toast for a failure that must not decline silently. Auto-hides.
    private func flashError(_ message: String) {
        withAnimation { errorToast = message }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { errorToast = nil }
        }
    }

    private func toggleSelect(_ id: UUID) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
        Haptics.tap()
    }

    private func deleteSelected() {
        requestDelete((vm.developedPhotos + vm.developingPhotos).filter { selectedIDs.contains($0.id) })
    }

    /// Optimistically hides the photos and shows an Undo toast; the real (irreversible) server
    /// delete only commits after a few seconds if the user doesn't undo. The single delete
    /// entry point for both the selection toolbar and a cell's long-press menu. Roll shots
    /// used to ALSO confirm in a dialog first, which was two safety nets for one tap
    /// (confirmations redesign); the undo window is the net now, for every batch alike.
    private func requestDelete(_ toDelete: [Photo]) {
        guard !toDelete.isEmpty else { return }
        Haptics.warning()
        commitDeleteBatch(toDelete)
    }

    private func commitDeleteBatch(_ toDelete: [Photo]) {
        // If a previous pending delete is still waiting, commit it now before starting a new one.
        commitPendingDelete()

        let ids = Set(toDelete.map(\.id))
        vm.photos.removeAll { ids.contains($0.id) }   // optimistic hide
        // Held for the whole undo window (and past it, until the server delete actually
        // resolves), so a reload or the 60s develop poll landing in between can't reassign
        // `vm.photos` from the server and resurrect this batch with the Undo toast still up.
        // See `DarkroomViewModel.assign`.
        vm.pendingHiddenIds.formUnion(ids)
        pendingDelete = toDelete
        selectedIDs = []
        isSelecting = false
        showUndoToast = true

        undoTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            let batch = pendingDelete
            let ok = await photoService.deletePhotos(batch)
            showUndoToast = false
            pendingDelete = []
            vm.pendingHiddenIds.subtract(ids)
            if ok {
                // Confirmed gone server-side, so any post among these photos has to go too, or
                // this device's already-loaded feed keeps showing an imageless card for it.
                // Removed directly rather than trusting the (now-lifted) `pendingHiddenIds`
                // filter alone: a reload could have landed inside the window and, filtered or
                // not, this batch belongs gone from `vm.photos` regardless of what it currently
                // holds.
                vm.photos.removeAll { ids.contains($0.id) }
                feed.dropPosts(forDeletedPhotoIds: batch.map(\.id))
            } else {
                restoreAfterFailedDelete(batch)
            }
        }
    }

    private func undoDelete() {
        undoTask?.cancel()
        showUndoToast = false
        // Lifted before the restoring reload below, or that reload's own reassignment would
        // filter this batch right back out.
        vm.pendingHiddenIds.subtract(pendingDelete.map(\.id))
        pendingDelete = []
        Task { await reload() }   // restore from the server, nothing was actually deleted
    }

    /// Flush a still-pending delete immediately: a new delete starting while one is still in its
    /// undo window, or the screen disappearing (wired from `.onDisappear`) while one is still
    /// waiting out its 4 seconds. Timing a delete's commit to a view that may already be torn
    /// down is what the undo window risks otherwise; flushing on disappear is strictly safer than
    /// leaving the timer to fire into whatever is left of this screen.
    private func commitPendingDelete() {
        guard !pendingDelete.isEmpty else { return }
        undoTask?.cancel()
        let batch = pendingDelete
        let ids = Set(batch.map(\.id))
        pendingDelete = []
        showUndoToast = false
        Task {
            let ok = await photoService.deletePhotos(batch)
            vm.pendingHiddenIds.subtract(ids)
            if ok {
                vm.photos.removeAll { ids.contains($0.id) }
                feed.dropPosts(forDeletedPhotoIds: batch.map(\.id))
            } else {
                restoreAfterFailedDelete(batch)
            }
        }
    }

    /// Puts photos back into the grid after the server refused a delete (network dropped, the
    /// Storage removal itself failed). `commitDeleteBatch` already hid these optimistically the
    /// moment Undo's window opened; `deletePhotos` returning `false` means the row was
    /// deliberately left in place rather than deleted out from under a failed Storage removal
    /// (see its own doc), so without this the photo stays correctly present server-side but
    /// invisible here until the next full reload.
    private func restoreAfterFailedDelete(_ batch: [Photo]) {
        guard !batch.isEmpty else { return }
        let existingIds = Set(vm.photos.map(\.id))
        let restored = batch.filter { !existingIds.contains($0.id) }
        guard !restored.isEmpty else { return }
        vm.photos.append(contentsOf: restored)
        // The personal Darkroom now pages (and renders) in `taken_at` order, not `develops_at`,
        // see `PhotoService.PhotoOrderColumn`'s own doc; restoring here has to land these frames
        // back where that order would have put them, or a restored photo can appear under the
        // wrong night.
        vm.photos.sort { $0.takenAt > $1.takenAt }
        Haptics.error()
        flashError(restored.count == 1
            ? "Couldn't delete that photo. Check your connection and try again."
            : "Couldn't delete those photos. Check your connection and try again.")
    }

    /// Long-press a photo to jump into selection mode with it selected.
    private func beginSelecting(_ id: UUID) {
        if !isSelecting { isSelecting = true }
        if !selectedIDs.contains(id) { selectedIDs.insert(id) }
        Haptics.select()
    }

    /// The name of the roll a photo belongs to (for labeling roll shots in the Darkroom).
    private func rollName(for rollId: UUID?) -> String? {
        guard let rollId else { return nil }
        return rolls.rolls.first { $0.id == rollId }?.name
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(accent.opacity(0.8))
            Text("Your darkroom's empty.")
                .flimFont(17, weight: .light)
                .foregroundStyle(FlimTheme.textSecondary)
            Text("Head to the camera and take your first shot. Sort it here, then keep it or post it.")
                .flimFont(13.5, relativeTo: .subheadline)
                .foregroundStyle(FlimTheme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                NotificationCenter.default.post(name: .openCamera, object: nil)
            } label: {
                Label("Take a shot", systemImage: "camera.aperture")
                    .flimFont(14, weight: .semibold)
                    .foregroundStyle(accent)
                    .padding(.horizontal, 20).padding(.vertical, 11)
                    .overlay(Capsule().stroke(accent, lineWidth: 1))
            }
            .padding(.top, 4)
        }
    }

    /// The `.month` rung's own empty state for an anchor with nothing in it: EITHER photos
    /// loaded elsewhere (spillover, an older/newer month's rows a previous anchored fetch's page
    /// boundary left behind) with none of them belonging to THIS anchor, e.g. every shot in the
    /// month was just deleted, or an anchored jump/reload that resolved to a genuinely empty
    /// month. Distinct from `emptyState` above (the whole-library "you've never shot anything"
    /// case): that copy is wrong the moment photos are known to exist, just not here, and reduced
    /// in prominence relative to it (smaller icon, one line, no camera CTA) since it's a scoped,
    /// recoverable dead end, not the app's very first empty moment.
    ///
    /// Copy reported for owner veto (consolidated fix pass, item 4).
    private var scopedEmptyMonthState: some View {
        VStack(spacing: 10) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 28, weight: .ultraLight))
                .foregroundStyle(accent.opacity(0.5))
            Text("Nothing left in \(scopedEmptyMonthName).")
                .flimFont(14, weight: .light)
                .foregroundStyle(FlimTheme.textTertiary)
            // The same closing row `nightList` shows once pagination for a non-empty month
            // genuinely stops: here it's the only way out of an anchor that has nothing at all.
            if !isSelecting, let info = closingRowInfo {
                DarkroomMonthClosingRow(month: info.month, shotCount: info.shotCount) {
                    Haptics.tap()
                    selectMonth(info.month)
                }
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The anchor month's full name ("August"), for `scopedEmptyMonthState`'s copy only — the
    /// zoom bar's own crumb formatting lives elsewhere and is not reused here on purpose, this
    /// is prose ("Nothing left in August."), not a label.
    private var scopedEmptyMonthName: String {
        DarkroomDayUnit.monthNameFormatter.string(from: dateFromYearMonth(anchor))
    }

    /// The full-screen pager for a tapped frame.
    ///
    /// Its own function because the body could no longer be type-checked with it inline, and
    /// because there are two genuinely different cases. A frame opened from the grid pages
    /// through the whole grid and zooms out of its own cell. A frame opened from a widget need
    /// not be in the loaded page at all (see `openRequestedPhoto`) — `firstIndex ?? 0` would then
    /// silently open whatever happens to be newest instead, which is the wrong photograph with
    /// nothing to indicate it. That one is paged alone and gets no zoom, because there is no cell
    /// on screen for it to zoom out of.
    @ViewBuilder
    private func pager(for photo: Photo) -> some View {
        // The flattened render order: units newest first, each night's own frames oldest first,
        // developing shots included in their true chronological place, so swiping plays a night
        // forward (develops-at wells and all) and then continues into the adjacent one.
        let orderedPhotos = renderOrderPhotos
        let index = orderedPhotos.firstIndex(where: { $0.id == photo.id })
        if let index {
            PhotoPagerView(photos: orderedPhotos,
                           startIndex: index,
                           signedURLs: vm.signedURLCache,
                           showsNightRack: true,
                           rollName: { rollName(for: $0) },
                           onDelete: { Task { await reload() } })
                .navigationTransition(.zoom(sourceID: photo.id, in: photoNS))
        } else {
            PhotoPagerView(photos: [photo],
                           startIndex: 0,
                           signedURLs: vm.signedURLCache,
                           showsNightRack: true,
                           rollName: { rollName(for: $0) },
                           onDelete: { Task { await reload() } })
        }
    }

    /// Opens a frame a widget asked for.
    ///
    /// Fetches it BY ID rather than looking in `vm.developedPhotos`, and that is the fix rather
    /// than a refinement. That array is one page of `is_sorted = true` photos, thirty at a time,
    /// newest first — so a frame from a month ago is essentially never in it, which is exactly
    /// the horizon the look-back tile is built to surface. Every tap on an older memory searched
    /// a list that could not contain it and quietly did nothing.
    ///
    /// The pager takes a single photo here, the same way the widget-less deep links in `FlimApp`
    /// present one. A frame that is gone (deleted, moderated, or belonging to an account no
    /// longer signed in) comes back nil and leaves a real, populated Darkroom on screen, which is
    /// the graceful no-op every other deep link here takes.
    private func openRequestedPhoto() {
        guard let id = openPhotoId.wrappedValue else { return }
        openPhotoId.wrappedValue = nil
        if let loaded = vm.developedPhotos.first(where: { $0.id == id }) {
            selectedPhoto = loaded          // already on screen: no round trip, keeps the zoom transition
            return
        }
        Task {
            guard let photo = await photoService.fetchPhoto(id: id) else { return }
            await MainActor.run { selectedPhoto = photo }
        }
    }

    // MARK: - Zoom ladder navigation

    /// The single choke point for every rung/anchor mutation: sets the state, writes the
    /// `@SceneStorage` mirror, and fires the "rung changed" haptic. Every other zoom function
    /// (`zoomOut`, `zoomIn`, `selectMonth`, the tab-retap handler) routes through this rather than
    /// touching `zoom` directly, so none of them can change rungs silently.
    ///
    /// Also the one place that cancels a still-running anchored-jump fetch (`landOnAnchorMonth`)
    /// whenever the destination rung ISN'T `.month`: leaving `.month` (zooming out, or any other
    /// future path) with a jump still in flight used to leave it running headless, landing a
    /// scroll nobody was looking at once it eventually finished, or worse fighting a second, newer
    /// request. Zooming TO `.month` never cancels here — `pendingMonthLanding` (set by the caller
    /// right after this returns) is what starts a landing, this only ever tears one down.
    private func setZoom(_ newZoom: DarkroomZoom) {
        guard newZoom != zoom else { return }
        Haptics.tap()
        zoom = newZoom
        storedRung = newZoom.rawValue
        if newZoom != .month {
            anchoredJumpTask?.cancel()
            anchoredJumpTask = nil
            anchoredJumpTarget = nil
            pendingMonthLanding = nil
        }
    }

    private func zoomOut() {
        guard let out = zoom.zoomedOut else { return }
        setZoom(out)
    }

    /// Plus from `.year` lands `.month` on the ANCHOR month, not the newest: the anchor itself is
    /// untouched by zooming (only a row/cell tap or the `.month` rung's own scroll tracking ever
    /// changes it), so this only has to ask the `.month` rung to land there once it mounts (see
    /// `pendingMonthLanding`'s own doc).
    private func zoomIn() {
        guard let deeper = zoom.zoomedIn else { return }
        setZoom(deeper)
        if deeper == .month { pendingMonthLanding = anchor }
    }

    /// The one entry point the Year row, the All-time cell, and the closing row taps all call:
    /// sets a new anchor, zooms to `.month`, and asks that rung to land there once it mounts (see
    /// `pendingMonthLanding`'s own doc for why this doesn't fetch/scroll directly, in the same
    /// call stack, the way an early version did). `landOnAnchorMonth` is what actually performs
    /// the anchored fetch and the scroll, once `.month`'s own `ScrollViewReader` exists.
    private func selectMonth(_ ym: DarkroomYearMonth) {
        anchor = ym
        storedAnchor = DarkroomAnchorCoding.encode(ym)
        setZoom(.month)
        pendingMonthLanding = ym
    }

    /// Lands `ym`'s topmost (newest) night at the top of the `.month` scroller, using `proxy` —
    /// the `.month` rung's OWN `ScrollViewReader` proxy, handed in by `monthContent`'s `.task(id:)`
    /// once that rung actually exists (never the shared `scrollProxy` state, which can still
    /// belong to the rung being left behind at the moment this is called).
    ///
    /// A month already loaded (its own night already sitting in `dayUnits`, most often SPILLOVER
    /// a previous anchored fetch's page boundary already warmed, see `monthScopedUnits`'s own
    /// doc) scrolls immediately, no fetch. A month that isn't loaded issues exactly ONE anchored
    /// fetch (`PhotoService.fetchPersonalPhotos(userId:anchoredBefore:)`, seeded at `ym.upperEdge`)
    /// and then scrolls, rather than paging forward from the top: tapping an old month costs one
    /// round trip, not N.
    ///
    /// PR 5 of the zoom redesign, revision 2, replaced this function's predecessor
    /// (`pageUntilMonth`) entirely: that one drove a client-side `while` loop calling `vm.loadMore`
    /// repeatedly until `ym`'s own night appeared, with no guaranteed progress per iteration —
    /// `loadMore`'s own `!photoService.isLoading` guard can return synchronously, doing nothing at
    /// all, the moment another fetch (the geometry backstop, ordinary scroll pagination) is
    /// already in flight, and a loop with no `await` guaranteed to suspend on every path through
    /// it can spin the main actor indefinitely. A single awaited call cannot repeat that failure
    /// mode; do not reintroduce a paging loop here.
    ///
    /// A SECOND target arriving while one is already in flight (`anchoredJumpTarget` differs)
    /// cancels the first task and starts a new one for the new target, rather than being silently
    /// dropped — the earlier bug this pattern fixes let the first target's scroll land under the
    /// second target's crumb once it eventually finished. Cancelled outright by `setZoom` on
    /// leaving `.month`, and from `.onDisappear` if the whole screen goes away mid-fetch.
    ///
    /// A fetch that fails or is superseded (`applied == false`, or the request throws) still
    /// clears `pendingMonthLanding` and returns rather than spinning or retrying on its own: the
    /// `.month` rung lands on whatever IS loaded, its crumb still reads the real anchor, and pull-
    /// to-refresh (which re-runs the same anchored fetch, see `reload()`'s own doc) is the
    /// retry path, the same as every other failed fetch on this screen.
    private func landOnAnchorMonth(_ ym: DarkroomYearMonth, proxy: ScrollViewProxy) {
        if let firstUnit = dayUnits.first(where: { DarkroomYearMonth(date: $0.dayKey) == ym }) {
            // This landing is authoritative now: bump the token so any anchored fetch still
            // running for an earlier target (cancelled below, but possibly already past its own
            // last `await`) discards its result instead of assigning into `vm.photos` behind it.
            jumpToken += 1
            anchoredJumpTask?.cancel()
            anchoredJumpTask = nil
            anchoredJumpTarget = nil
            withAnimation(.snappy) { proxy.scrollTo(firstUnit.id, anchor: .top) }
            if pendingMonthLanding == ym { pendingMonthLanding = nil }
            return
        }

        guard let uid = auth.currentUser?.id else {
            if pendingMonthLanding == ym { pendingMonthLanding = nil }
            return
        }

        // The same target already fetching: leave it running rather than starting a redundant
        // second request, and leave `jumpToken` alone, this IS that same jump, not a new one.
        // A DIFFERENT target replaces it.
        if anchoredJumpTarget == ym, anchoredJumpTask != nil { return }
        jumpToken += 1
        let myToken = jumpToken
        anchoredJumpTask?.cancel()
        anchoredJumpTarget = ym
        anchoredJumpTask = Task {
            defer { if anchoredJumpTarget == ym { anchoredJumpTarget = nil } }
            await vm.loadAnchored(photoService: photoService, userId: uid, upperEdge: ym.upperEdge(),
                                   shouldApply: { jumpTokenIsCurrent(myToken, latest: jumpToken) })
            guard !Task.isCancelled, jumpTokenIsCurrent(myToken, latest: jumpToken),
                  let firstUnit = dayUnits.first(where: { DarkroomYearMonth(date: $0.dayKey) == ym })
            else {
                if pendingMonthLanding == ym { pendingMonthLanding = nil }
                return
            }
            withAnimation(.snappy) { proxy.scrollTo(firstUnit.id, anchor: .top) }
            if pendingMonthLanding == ym { pendingMonthLanding = nil }
        }
    }

    /// Resolves the entry rung and anchor once, from `.onAppear`. Cold launch (the `-1` sentinel)
    /// starts the anchor at the current month; the quiet-month fallback (stepping back to the
    /// newest month that actually has photos) needs data that isn't loaded yet, and is applied
    /// once `reload()`'s fetches land, see `applyColdLaunchAnchorIfNeeded`. A warm return decodes
    /// the stored anchor directly, garbage falling back to the current month.
    private func resolveInitialZoomAndAnchor() {
        zoom = DarkroomZoom.resolveEntry(storedRung: storedRung)
        let currentMonth = DarkroomYearMonth(date: .now)
        anchor = storedRung == -1 ? currentMonth : DarkroomAnchorCoding.decode(storedAnchor, fallback: currentMonth)
    }

    /// The other half of `resolveInitialZoomAndAnchor`: only meaningful on a genuine cold launch
    /// (`storedRung` still `-1`, meaning the person has never explicitly changed rungs this
    /// install), and safe to call every `reload()` regardless, since it's a no-op once that's no
    /// longer true.
    private func applyColdLaunchAnchorIfNeeded() {
        guard storedRung == -1 else { return }
        let currentMonth = DarkroomYearMonth(date: .now)
        let resolved = DarkroomAnchorResolution.coldLaunchAnchor(
            currentMonth: currentMonth,
            summaries: monthSummaries,
            loadedMonths: dayUnits.map { DarkroomYearMonth(date: $0.dayKey) }
        )
        anchor = resolved
        storedAnchor = DarkroomAnchorCoding.encode(resolved)
    }

    /// The `.month` rung's crumb follows the topmost currently MOUNTED night (a coarse stand-in
    /// for true visibility, see `DarkroomDayUnitView.onMountChange`'s own doc): since the list
    /// renders newest-first, the night with the latest `dayKey` among whatever's mounted is the
    /// one nearest the top of the current scroll window. Only updates while `.month` is the
    /// active rung — Year/All-time change the anchor solely through an explicit row/cell tap.
    ///
    /// Also skipped entirely while `pendingMonthLanding != nil`: a fresh mount at scroll offset 0
    /// fires this from every initially-visible night's `onAppear` before the requested scroll has
    /// had a chance to run, and without this guard it overwrote the just-made selection right back
    /// to the newest month every time. It re-arms itself the moment the landing clears (see
    /// `landOnAnchorMonth`), so real scrolling resumes driving the anchor immediately after.
    ///
    /// PR 5 of the zoom redesign, revision 2, made this function effectively a no-op in ordinary
    /// use: `nightList` now only ever mounts nights from `monthScopedUnits` (the anchor's own
    /// month), so `mountedNightDayKeys.max()` can only ever resolve back to `anchor` itself, and
    /// the `guard ym != anchor` below always holds. Left in place rather than removed: it is still
    /// correct, still cheap, and still the one thing standing between a hypothetical future
    /// caller that mounts a night outside the anchor month and a silently wrong crumb.
    private func updateMonthAnchorFromScroll() {
        guard zoom == .month, pendingMonthLanding == nil, let topKey = mountedNightDayKeys.max() else { return }
        let ym = DarkroomYearMonth(date: topKey)
        guard ym != anchor else { return }
        anchor = ym
        storedAnchor = DarkroomAnchorCoding.encode(ym)
    }

    /// Every fetch here that assigns into screen state follows the same rule (`vm.totalCount`'s
    /// own doc names it first): a fetch that fails or is cancelled — and `.refreshable`'s task IS
    /// cancelled as the pull gesture settles, not merely paused — resolves to `nil`/a failure
    /// default, and that default must never overwrite state a previous, successful load already
    /// put on screen. Before this pass, `monthSummaries` and `unsortedPhotos` both broke that
    /// rule: `monthSummaries = await summaries` assigned the RPC's `nil` straight through on a
    /// cancelled pull, which flips the Year/All-time rungs to `rungUnavailableState` (their
    /// `nil`-and-resolved case) the instant a refresh lands mid-settle; the NEXT successful pull
    /// puts a real value back, which is the exact alternation the owner saw pulling down
    /// repeatedly at Year/All-time. `unsortedPhotos = unsorted` had the same shape one level
    /// down: `fetchUnsorted` folded a failure to `[]` internally, so a cancelled refresh emptied
    /// the sort banner (and the "shots to sort" it names) even though the shots themselves were
    /// never touched. Both now only assign a resolved SUCCESS; a failure leaves the last known
    /// value exactly where it was, silently, and `isLoadingSummaries` still drops to `false`
    /// either way since the fetch DID resolve, just not with new data.
    ///
    /// PR 5 of the zoom redesign, revision 2, split the personal-photo half of this into two
    /// paths: at `.month`, anchored on anything OTHER than the current month (a warm relaunch
    /// that restored an older `@SceneStorage` anchor, or — the common case — pull-to-refresh while
    /// browsing an old month), this re-runs the SAME anchored fetch `landOnAnchorMonth` uses,
    /// keeping the anchor exactly where it was; every other case (cold launch, `.year`/`.allTime`,
    /// the sort deck dismissing, a reveal) uses the plain, unconstrained `vm.load()` it always
    /// has. The plain fetch is functionally identical to an anchored one for the CURRENT month
    /// anyway (`DarkroomYearMonth.upperEdge` for the current month is always in the future), so
    /// this only forks where it actually changes the result: an anchored pull-to-refresh must
    /// never teleport the person back to the present month they weren't looking at.
    private func reload() async {
        guard let userId = auth.currentUser?.id else { return }
        // Captured once, re-checked before every write past an await below: a sign-out then
        // straight back in as someone else (or a plain account switch) mid-reload is otherwise a
        // window for a stale response, resolved after the epoch has moved on, to paint the
        // DEPARTED account's months. Mirrors `FeedService`'s own per-write pattern, see
        // `AccountEpoch`'s own doc for why a single guard partway through this function is not
        // enough: `monthSummaries`, `unsortedPhotos`/`unsortedURLCache` (guarded inline, see
        // `loadUnsortedAndPreviews`), `feed.loadMyPostedPhotoIds`'s own write (guarded inside that
        // service call itself), and the trailing `checkForReveal`/`openRequestedPhoto` chain each
        // need their own.
        let epoch = AccountEpoch.current
        isLoadingSummaries = true
        // 8 covers: the WIDEST any device's Year strip fits at the rack's 44x59/46pt pitch (see
        // `yearRowCapacity`'s own doc; owner report 2026-08-27: a 402pt phone fits 8, and asking
        // for 7 left its eighth slot as an empty frame). Narrower devices render the first
        // `capacity` of the array and simply never show the extras. The All-time rung draws its
        // single per-month cover from `top_cover_path` instead, the same row's own field, so
        // nothing here needs a second, separately-ordered request.
        async let summaries = photoService.darkroomMonthSummaryV2(timezone: TimeZone.current.identifier, covers: 8)
        let anchoredBranch = zoom == .month && anchor != DarkroomYearMonth(date: .now)
        if anchoredBranch {
            await vm.loadAnchored(photoService: photoService, userId: userId, upperEdge: anchor.upperEdge())
        } else {
            await vm.load(photoService: photoService, userId: userId)
        }
        if let resolvedSummaries = await summaries, AccountEpoch.isCurrent(epoch) {
            monthSummaries = resolvedSummaries
        }
        isLoadingSummaries = false
        applyColdLaunchAnchorIfNeeded()
        // Warm the grid's thumbnails so cells appear instantly as you scroll. 120, not the grid
        // cell's own 400: this only has to cover the sort banner's tiny preview strip
        // (`DarkroomSortBanner`'s thumbnails), the same size every other Darkroom surface that
        // shows these previews decodes at.
        let prefetch = vm.photos.compactMap { photo -> (url: URL, cacheKey: String?)? in
            vm.signedURLCache[photo.id].map { ($0, photo.displayPath) }
        }
        ImageLoader.prefetch(prefetch, maxPixel: 120, scale: displayScale)
        // The rest of this reload is three independent round trips — roll names, the unsorted
        // preview strip, and the "shared to your page" badge query — none of which reads or
        // writes what either of the others touches, so they run concurrently rather than one
        // after another. Each still guards its OWN write with `epoch`: `loadRollsIfNeeded` and
        // `feed.loadMyPostedPhotoIds` do that internally (see `RollService.fetchRolls`'s own doc,
        // "guard the assignment, not the call"), and `loadUnsortedAndPreviews` does it inline,
        // same as before this pass. Running them concurrently doesn't change WHEN any of them are
        // allowed to write, only whether they wait on each other first.
        async let rollsTask: Void = loadRollsIfNeeded(userId: userId)
        async let unsortedTask: Void = loadUnsortedAndPreviews(userId: userId, epoch: epoch)
        async let postedTask: Void = feed.loadMyPostedPhotoIds(userId: userId)
        _ = await (rollsTask, unsortedTask, postedTask)
        // The trailing chain: a reveal check and a widget-tap deep link, neither of which belongs
        // to whoever is signed in now if the epoch has moved on.
        guard AccountEpoch.isCurrent(epoch) else { return }
        // ONLY on the unanchored (present-spanning) load. `checkForReveal` scans
        // `vm.developedPhotos` for rolls that developed since `lastRevealCheck` and then
        // unconditionally advances that watermark. An anchored load holds only an OLD month's
        // photos, so running the check against it would find nothing and still burn the
        // window: a roll that developed while you were parked on last month would never get
        // its reveal, permanently. The anchored branch leaves the watermark alone so the next
        // present-anchored reload still gets its chance.
        if !anchoredBranch { checkForReveal() }
        // The library is loaded now, so a pending widget tap can finally be answered — or
        // recognised as pointing at something that is gone.
        openRequestedPhoto()
    }

    /// One of `reload()`'s three independent tail round trips, see its own doc. For roll labels;
    /// only fetches when nothing is loaded yet, same guard `reload()` always had.
    private func loadRollsIfNeeded(userId: UUID) async {
        guard rolls.rolls.isEmpty else { return }
        try? await rolls.fetchRolls(for: userId)
    }

    /// The other of `reload()`'s three independent tail round trips: the unsorted set itself,
    /// then (chained, not parallel — the previews need `fetchUnsorted`'s OWN result, not merely a
    /// later read of `unsortedPhotos`) signed URLs for its preview strip. Both writes keep the
    /// same keep-last-known shape `reload()` always used: a failed or superseded fetch leaves
    /// whatever was last known exactly where it was, silently.
    private func loadUnsortedAndPreviews(userId: UUID, epoch: Int) async {
        if let unsorted = await photoService.fetchUnsorted(userId: userId), AccountEpoch.isCurrent(epoch) {
            unsortedPhotos = unsorted
        }
        // Read back from `unsortedPhotos` (not the local `fetchUnsorted` result above), so a
        // failed fetch's previews still come from whatever was last known, the same keep-last-
        // known shape as the assignment right above.
        let previews = DarkroomDayUnit.pickPreview(from: unsortedPhotos)
        guard !previews.isEmpty else { return }
        let map = await photoService.signedURLs(for: previews.map(\.displayPath))
        guard AccountEpoch.isCurrent(epoch) else { return }
        for previewPhoto in previews {
            if let url = map[previewPhoto.displayPath] { unsortedURLCache[previewPhoto.id] = url }
        }
    }

    /// Celebrate shots that have finished developing since the last time the Darkroom was open.
    private func checkForReveal() {
        // A skipped check leaves the watermark alone. Advancing it unconditionally meant a
        // reload landing mid-selection (pull-to-refresh stays live in select mode) or under
        // an already-showing overlay jumped the watermark past rolls it never scanned, and
        // no later call could ever surface them: that batch's celebration was silently and
        // permanently lost.
        guard !showReveal, !isSelecting else { return }
        let now = Date().timeIntervalSince1970
        if lastRevealCheck > 0 {
            // Roll shots only, personal instants get the sort deck as their reveal moment.
            let newlyReady = vm.developedPhotos.filter {
                $0.rollId != nil && $0.developsAt.timeIntervalSince1970 > lastRevealCheck && $0.isReady
            }
            if !newlyReady.isEmpty {
                revealCount = newlyReady.count
                Haptics.reveal()
                SoundFX.reveal()
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { showReveal = true }
            }
        }
        lastRevealCheck = now
    }

    private var revealOverlay: some View {
        ZStack {
            Color.black.opacity(0.94).ignoresSafeArea()
            // A soft glow that blooms behind the icon as it lands.
            RadialGradient(colors: [accent.opacity(0.28), .clear],
                           center: .center, startRadius: 2, endRadius: 280)
                .ignoresSafeArea()
                .scaleEffect(revealAnim ? 1 : 0.5)
                .opacity(revealAnim ? 1 : 0)

            VStack(spacing: 14) {
                ZStack {
                    Circle().fill(accent.opacity(0.12)).frame(width: 112, height: 112)
                    Image(systemName: "sparkles")
                        .font(.system(size: 48, weight: .ultraLight))
                        .foregroundStyle(accent)
                        .symbolEffect(.pulse)
                }
                .scaleEffect(revealAnim ? 1 : 0.4)

                VStack(spacing: 6) {
                    Text("Your photos are ready")
                        .flimFont(27, weight: .thin)
                        .foregroundStyle(.white)
                    Text("\(revealCount) new \(revealCount == 1 ? "shot" : "shots") developed")
                        .flimFont(14)
                        .foregroundStyle(FlimTheme.textSecondary)
                }
                .opacity(revealAnim ? 1 : 0)
                .offset(y: revealAnim ? 0 : 14)

                Button { dismissReveal() } label: {
                    Text("See them")
                        .flimFont(16, weight: .semibold)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 34).padding(.vertical, 14)
                        .background(accent, in: Capsule())
                        .shadow(color: accent.opacity(0.5), radius: 12)
                }
                .opacity(revealAnim ? 1 : 0)
                .padding(.top, 10)
            }
        }
        .transition(.opacity)
        .onAppear {
            if reduceMotion {
                revealAnim = true   // no spring/scale, appear settled
            } else {
                revealAnim = false
                withAnimation(.spring(response: 0.55, dampingFraction: 0.68).delay(0.05)) { revealAnim = true }
            }
        }
        .onTapGesture { dismissReveal() }
    }

    private func dismissReveal() {
        withAnimation(.easeOut(duration: 0.25)) { revealAnim = false }
        withAnimation(.easeInOut(duration: 0.3)) { showReveal = false }
    }
}
