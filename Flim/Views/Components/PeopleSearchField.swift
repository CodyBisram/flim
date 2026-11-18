import SwiftUI

/// The search field that sits above every list of people: Discover, the tag picker, and the
/// followers/following lists.
///
/// Extracted at the third use, not the second. Discover and `FollowingList` had already grown
/// their own copies, and they had drifted: one cleared with a haptic, the other silently, and the
/// clear button's size differed. Adding a fourth copy to the follow lists would have made the
/// inconsistency permanent.
///
/// Deliberately only the FIELD, not the searching. Discover queries the server
/// (`FeedService.searchProfiles`) because it looks through everyone; the other two filter a list
/// they already hold in memory. Those are genuinely different jobs and sharing them would mean one
/// of the two doing something awkward, so what is shared is the part that should look and behave
/// identically, and nothing else.
struct PeopleSearchField: View {
    @Environment(\.flimAccent) private var accent
    @Binding var query: String
    var prompt: String = "Search by name or username"
    /// Set when this field is the first thing inside a bare sheet, under a visible drag indicator,
    /// rather than under a navigation bar.
    ///
    /// SwiftUI draws `.presentationDragIndicator(.visible)` OVER the sheet's content instead of
    /// insetting anything for it: the grabber sits roughly 5 to 9 points below the sheet's top
    /// edge, and the default 8 points of top padding put the capsule's own top edge at 8.5, so the
    /// two literally overlapped and the grabber read as part of the search field. Measured off a
    /// device screenshot of the emoji picker, which is the only host with this problem — the other
    /// three all sit under a navigation bar, where 8 is right and anything more looks adrift.
    var underSheetGrabber = false
    /// Space above and below the field, for a host that sets it apart differently (Friends sits it
    /// under a full-width rule, owner 2026-11-18).
    var topPadding: CGFloat?
    var bottomPadding: CGFloat = 12

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(FlimTheme.textTertiary)
            TextField("", text: $query,
                      prompt: Text(prompt).foregroundStyle(FlimTheme.textTertiary))
                .foregroundStyle(FlimTheme.textPrimary).tint(accent)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityLabel(prompt)
            if !query.isEmpty {
                Button {
                    Haptics.tap()
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(FlimTheme.textTertiary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Clear search")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: query.isEmpty)
        .frame(minHeight: 44)
        .padding(.horizontal, 14)
        .background(FlimTheme.bgElevated, in: Capsule())
        .padding(.horizontal, AppInfo.is17 ? 24 : 16)
        // Enough to clear the grabber with real space under it, and close enough to the 12 + 16
        // that separates this from whatever follows that the field doesn't sit lopsided.
        .padding(.top, topPadding ?? (underSheetGrabber ? 22 : 8))
        .padding(.bottom, bottomPadding)
    }
}

/// Whether `profile` matches `query` by either the handle or the display name.
///
/// Pulled out as a free function so the follow lists and the tag picker cannot drift on what
/// "matches" means. Someone searching a list of people they know will reach for whichever of the
/// two names they happen to remember, so both have to match, and an empty query matches
/// everything rather than nothing.
func personMatches(_ profile: UserProfile, query: String) -> Bool {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return true }
    let handleQuery = query.hasPrefix("@") ? String(query.dropFirst()) : query
    if handleQuery.isEmpty { return true }
    let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    return (profile.username ?? "").range(of: handleQuery, options: options, locale: .current) != nil
        || (profile.displayName ?? "").range(of: query, options: options, locale: .current) != nil
}
