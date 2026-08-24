import SwiftUI

// MARK: - Pure logic
//
// Pulled out as free functions so the destination line's verb, the count line's shape, and the
// consequence line's pluralization are each testable without a view, a network round trip, or a
// clock. See `ShareToFeedSheet` for how they're wired together.

/// Whether the server's count of the caller's own posts already in today's 4am-bounded day has
/// resolved. `.loading` deliberately carries no guessed number: it is what the sheet shows for
/// the instant between opening and `FeedService.todayPostCount` answering, and neither
/// `shareDestinationLine1` nor `shareDestinationLine2` may claim a specific count until this is
/// `.resolved`.
enum ShareDestinationCount: Equatable {
    case loading
    case resolved(Int)
}

/// Line 1 of the share sheet's destination row, the verb only: `dayLabel` is already formatted
/// (`shareDestinationDayLabel`). While the count is still loading this reads the neutral
/// "Starts..." form, the one shape that's true regardless of what the server turns out to say;
/// claiming "Adds to" before the count confirms there IS something to add to would be a guess.
func shareDestinationLine1(dayLabel: String, count: ShareDestinationCount) -> String {
    switch count {
    case .loading: return "Starts your \(dayLabel) post"
    case .resolved(let n): return n > 0 ? "Adds to your \(dayLabel) post" : "Starts your \(dayLabel) post"
    }
}

/// Line 2: the shot's own capture time, plus what's already on today's post unit. While the
/// count is loading this says only the time, never "nothing from today is on the feed yet" (that
/// clause is itself a claim about the count, just as much as a number would be) and never a
/// guessed shot total.
func shareDestinationLine2(shotTime: String, count: ShareDestinationCount) -> String {
    switch count {
    case .loading:
        return "Shot \(shotTime)"
    case .resolved(let n) where n > 0:
        let shotsLabel = n == 1 ? "1 shot" : "\(n) shots"
        return "\(shotsLabel) already there · this one shot \(shotTime)"
    case .resolved:
        return "Shot \(shotTime) · nothing from today is on the feed yet"
    }
}

/// Fixed `EEE d MMM` (`Fri 22 Aug`), `en_US_POSIX`, matching `DarkroomDayUnit`'s own day
/// formatter exactly (that one is private to its file, so this is a second, deliberately
/// identical formatter rather than a visibility change to a file outside this feature).
func shareDestinationDayLabel(_ dayKey: Date, calendar: Calendar = .current) -> String {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "EEE d MMM"
    return formatter.string(from: dayKey)
}

/// The consequence line under the primary button, matching the tag-chip count exactly. Never
/// omitted: a share with nobody tagged still states that plainly, rather than leaving the
/// button's outcome unsaid.
func shareConsequenceLine(taggedCount: Int) -> String {
    switch taggedCount {
    case 0: return "Nobody is notified until you share."
    case 1: return "1 person will be notified when this posts."
    default: return "\(taggedCount) people will be notified when this posts."
    }
}

/// Orders `people` most-recently-tagged first, per `recency` (a tagged user id to the caller's
/// own most recent tag of them, `FeedService.tagRecency`'s shape). Anyone with no entry (never
/// tagged) sorts after everyone who has one, in whatever relative order `people` already held
/// them, so the picker falls back to the follows list's own order rather than inventing one for
/// people the server has no signal on.
func orderPeopleByRecency(_ people: [UserProfile], recency: [UUID: Date]) -> [UserProfile] {
    let indexed = Array(people.enumerated())
    return indexed.sorted { a, b in
        switch (recency[a.element.id], recency[b.element.id]) {
        case let (ra?, rb?): return ra > rb
        case (.some, nil): return true
        case (nil, .some): return false
        case (nil, nil): return a.offset < b.offset
        }
    }.map(\.element)
}

// MARK: - The sheet

/// The Darkroom viewer's (night-rack mode) share compose sheet, opened from the promoted
/// `Share` capsule. Replaces the legacy inline caption composer (`shareToPage`/`confirmShare`/
/// `shareComposer` in `PhotoPagerView`) for that one path only; the roll pager's own inline
/// composer is untouched, see that trio's own doc comments for the split.
///
/// Nothing here posts until `Share to Feed` is tapped: dismissing any other way (swipe down)
/// discards the caption and any tags with it, and reopening always starts from a blank sheet.
/// The primary button is live on an empty sheet on purpose, so the fast path is Share, then
/// Share again, one extra tap over posting blind.
struct ShareToFeedSheet: View {
    @Environment(\.flimAccent) private var accent
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed

    let photo: Photo
    /// The grid's already-resolved thumbnail for this photo (`displayPath`), so the destination
    /// row paints instantly instead of waiting on its own signed-URL fetch. `cacheKey` is always
    /// `photo.displayPath` to match, per the image cache's own URL/key contract.
    let thumbURL: URL?
    /// Fired after `feed.createPost` succeeds outright (every tag saved too). The sheet has
    /// already dismissed itself by the time this runs; the caller owns the success toast/haptic.
    var onSuccess: () -> Void = {}
    /// Fired when the post itself landed but its tags didn't (see `shouldWarnThatTagsDidNotSave`).
    /// The share still stands, this is not the "didn't reach the server" branch.
    var onPartialFailure: (String) -> Void = { _ in }

    @State private var caption = ""
    @State private var tags: [PendingTag] = []
    @State private var showAddPeople = false
    @State private var todayCount: ShareDestinationCount = .loading
    /// In-flight guard: `share()` dismisses synchronously on tap, so a second tap has no button
    /// left to land on, but the guard is cheap and matches the app's async-button convention
    /// regardless.
    @State private var isSharing = false
    /// The SCROLLABLE region's own measured height (title through the tagged-people row): the
    /// primary button and consequence line live outside the `ScrollView`, in a
    /// `safeAreaInset(edge: .bottom)` footer, so they can never end up under the keyboard with
    /// no way to reach them (a long caption plus the keyboard used to push both off the fixed,
    /// non-scrolling sheet entirely). Seeded to a reasonable first-paint size and corrected by
    /// the real measurement the instant it's known, same "fitted detent" shape `PhotoTags` uses
    /// with a formula and `PhotoPagerView` itself uses with `onGeometryChange` for
    /// `screenWidth`/`rackWidth`. An app-wide sheet-surface token is Phase E's job; this is
    /// deliberately a one-off measurement, not a new shared primitive.
    @State private var scrollContentHeight: CGFloat = 250

    /// The footer (button + consequence line, including its own padding) never grows: neither
    /// line wraps to more than one row in practice, so this is a measured constant rather than a
    /// second `onGeometryChange`.
    private static let footerHeight: CGFloat = 108
    /// Comfortable bounds for the sheet's own height: short enough that an empty sheet (no
    /// caption, no tags) isn't oversized, tall enough that a maxed-out caption plus the footer
    /// still has room, and capped so a very tall measurement never asks for more than the sheet
    /// system reasonably grants. Content past this simply scrolls, which is the whole point of
    /// splitting the scrollable region from the pinned footer.
    private var detentHeight: CGFloat {
        min(max(scrollContentHeight + Self.footerHeight, 340), 560)
    }

    private var dayLabel: String { shareDestinationDayLabel(FeedUnit.dayKey(for: .now)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Share to Feed")
                    .flimFont(17, weight: .light, relativeTo: .body)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .center)

                destinationRow
                captionField
                taggedSection
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 4)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { scrollContentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        // Pinned OUTSIDE the scroll region, so it can never scroll out of reach and, more to the
        // point, can never end up under the keyboard: a `safeAreaInset` on the presented view
        // reserves its own space above whatever the system already reserves for the keyboard,
        // the same guarantee `.safeAreaInset` gives any other keyboard-avoiding footer.
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                shareButton
                Text(shareConsequenceLine(taggedCount: tags.count))
                    .flimFont(11.5, relativeTo: .caption)
                    .foregroundStyle(FlimTheme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 24)
        }
        .presentationDetents([.height(detentHeight)])
        .presentationDragIndicator(.visible)
        .flimSheetSurface()
        .sheet(isPresented: $showAddPeople) {
            AddPeopleSheet(tags: $tags)
        }
        .task {
            // A failed fetch (or no signed-in id, which should never happen here but costs
            // nothing to guard) leaves `todayCount` at `.loading`, not a resolved 0: a flaky
            // network must not produce the specific false claim "nothing from today is on the
            // feed yet" (see `todayPostCount`'s own doc and `shareDestinationLine2`).
            guard let uid = auth.currentUser?.id, let count = await feed.todayPostCount(userId: uid)
            else { return }
            todayCount = .resolved(count)
        }
    }

    // MARK: - Rows

    private var destinationRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let thumbURL {
                    CachedImage(url: thumbURL, maxPixel: 120, cacheKey: photo.displayPath) {
                        $0.resizable().scaledToFill()
                    } placeholder: { ShimmerPlaceholder(cornerRadius: 8) }
                } else {
                    ShimmerPlaceholder(cornerRadius: 8)
                }
            }
            .frame(width: 44, height: 59)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(shareDestinationLine1(dayLabel: dayLabel, count: todayCount))
                    .flimFont(14, weight: .medium, relativeTo: .subheadline)
                    .foregroundStyle(.white)
                Text(shareDestinationLine2(shotTime: FeedUnit.clockTime(photo.takenAt), count: todayCount))
                    .flimFont(12, relativeTo: .caption)
                    .foregroundStyle(FlimTheme.textTertiary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }

    private var captionField: some View {
        TextField("Add a caption…", text: $caption, axis: .vertical)
            .lineLimit(2...6)
            .flimFont(15, relativeTo: .body)
            .foregroundStyle(.white)
            .tint(accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 62, alignment: .topLeading)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Always visible, even with nothing tagged yet: `+ Add people` sits FIRST, so the affordance
    /// never moves when the first chip lands, only the content after it grows.
    private var taggedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("IN THIS PHOTO")
                .flimFont(11.5, weight: .medium, relativeTo: .caption)
                .tracking(1)
                .foregroundStyle(FlimTheme.textTertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    addPeopleButton
                    ForEach(tags) { tag in chip(tag) }
                }
            }
        }
    }

    private var addPeopleButton: some View {
        Button {
            Haptics.tap()
            showAddPeople = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                Text("Add people").flimFont(13, weight: .medium, relativeTo: .subheadline)
            }
            .foregroundStyle(accent)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .overlay(Capsule().strokeBorder(accent.opacity(0.55), lineWidth: 1))
        }
    }

    private func chip(_ tag: PendingTag) -> some View {
        HStack(spacing: 6) {
            AvatarView(path: tag.user.avatarPath, name: tag.user.username, size: 22)
            Text(tag.user.name)
                .flimFont(13, weight: .medium, relativeTo: .subheadline)
                .foregroundStyle(.white)
                .lineLimit(1)
            Button {
                Haptics.tap()
                tags.removeAll { $0.id == tag.id }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            // The glyph alone is a ~10pt target; the frame + contentShape grow the tappable area
            // to the chip's own 32pt height without touching the glyph's drawn size.
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
            .accessibilityLabel("Remove \(tag.user.name)")
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .frame(height: 32)
        .background(accent.opacity(0.15), in: Capsule())
    }

    private var shareButton: some View {
        Button { share() } label: {
            Text("Share to Feed")
                .flimFont(15, weight: .semibold, relativeTo: .body)
                .foregroundStyle(accent)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .overlay(Capsule().strokeBorder(accent, lineWidth: 1.5))
        }
        .disabled(isSharing)
    }

    // MARK: - Actions

    /// Mirrors the legacy composer's `confirmShare`: optimistic `myPostedPhotoIds` insert, the
    /// sheet dismisses immediately (not gated on the network), and a genuine failure to reach the
    /// server rolls the optimistic mark back. A tag-insert failure is a DIFFERENT, milder branch:
    /// the post itself is live, so that one surfaces a warning instead of un-marking anything.
    private func share() {
        guard !isSharing, let uid = auth.currentUser?.id else { return }
        isSharing = true
        Haptics.tap()
        let capturedCaption = caption
        let capturedTags = tags
        feed.myPostedPhotoIds.insert(photo.id)
        dismiss()
        Task {
            do {
                let tagsSaved = try await feed.createPost(
                    photo: photo, caption: capturedCaption, userId: uid, tags: capturedTags)
                if shouldWarnThatTagsDidNotSave(tagsSaved) {
                    Haptics.error()
                    // Deliberately its own string, not the legacy composer's: this flow's own
                    // viewer has a promoted "Tag" capsule once a shot is shared (`tagCapsule` in
                    // `PhotoPagerView`), and that's the retry path from here, not "Edit tags".
                    onPartialFailure("Shared, but the tags didn't save. Tap Tag to try again.")
                } else {
                    Haptics.success()
                    onSuccess()
                }
            } catch {
                feed.myPostedPhotoIds.remove(photo.id)
                Haptics.error()
            }
        }
    }
}

// MARK: - People picker

/// `ShareToFeedSheet`'s `+ Add people` step: everyone the caller follows, most-recently-tagged
/// first (`orderPeopleByRecency`, backed by `FeedService.tagRecency`), search above the list, one
/// flat list, no sections. Presented as its own sheet over the compose sheet, which stays alive
/// behind it; `tags` is a live binding, so the compose sheet's chips update the instant a row
/// toggles, with no separate confirm step, `Done` simply returns.
///
/// Only people already followed appear: there is no way to tag anyone else, matching the
/// tagging-only-at-share model (see `PhotoPagerView`'s own rule that tagging never exists on an
/// unshared shot).
struct AddPeopleSheet: View {
    @Environment(\.flimAccent) private var accent
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed

    @Binding var tags: [PendingTag]

    @State private var following: [UserProfile] = []
    @State private var query = ""
    @State private var loaded = false

    private var results: [UserProfile] {
        following.filter { personMatches($0, query: query) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                VStack(spacing: 0) {
                    PeopleSearchField(query: $query, prompt: "Search people you follow")
                    if loaded && results.isEmpty {
                        emptyState
                    } else {
                        List(results) { profile in
                            Button { toggle(profile) } label: { row(profile) }
                                .listRowBackground(FlimTheme.sheetRow)
                                .listRowSeparatorTint(Color(white: 0.15))
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .flimInlineTitle("In this photo")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(accent).fontWeight(.semibold)
                }
            }
        }
        .flimSheetSurface()
        .task { await load() }
    }

    private func row(_ profile: UserProfile) -> some View {
        let selected = tags.contains { $0.user.id == profile.id }
        return HStack(spacing: 12) {
            AvatarView(path: profile.avatarPath, name: profile.username, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name).flimFont(15, weight: .medium, relativeTo: .body).foregroundStyle(.white)
                Text(profile.handle).flimFont(12, relativeTo: .caption).foregroundStyle(FlimTheme.textTertiary)
            }
            Spacer()
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20))
                .foregroundStyle(selected ? accent : FlimTheme.textTertiary)
        }
        .padding(.vertical, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "person.2").font(.system(size: 32, weight: .ultraLight))
                .foregroundStyle(FlimTheme.textTertiary)
            Text(query.isEmpty ? "Follow people to tag them." : "No matches.")
                .flimFont(14, relativeTo: .subheadline).foregroundStyle(FlimTheme.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func toggle(_ profile: UserProfile) {
        Haptics.tap()
        if let existing = tags.firstIndex(where: { $0.user.id == profile.id }) {
            tags.remove(at: existing)
        } else {
            tags.append(PendingTag(user: profile, x: 0.5, y: 0.5))
        }
    }

    private func load() async {
        guard let uid = auth.currentUser?.id else { return }
        await feed.loadBlocked(userId: uid)
        async let followingList = feed.fetchFollowingProfiles(of: uid)
        async let recencyMap = feed.tagRecency(taggedBy: uid)
        following = orderPeopleByRecency(await followingList, recency: await recencyMap)
        loaded = true
    }
}
