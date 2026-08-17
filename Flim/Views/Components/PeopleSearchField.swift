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

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(FlimTheme.textTertiary)
            TextField("", text: $query,
                      prompt: Text(prompt).foregroundStyle(FlimTheme.textTertiary))
                .foregroundStyle(.white).tint(accent)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !query.isEmpty {
                Button {
                    Haptics.tap()
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(FlimTheme.textTertiary)
                }
                .accessibilityLabel("Clear search")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: query.isEmpty)
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(FlimTheme.bgElevated, in: Capsule())
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
    }
}

/// Whether `profile` matches `query` by either the handle or the display name.
///
/// Pulled out as a free function so the follow lists and the tag picker cannot drift on what
/// "matches" means. Someone searching a list of people they know will reach for whichever of the
/// two names they happen to remember, so both have to match, and an empty query matches
/// everything rather than nothing.
func personMatches(_ profile: UserProfile, query: String) -> Bool {
    guard !query.isEmpty else { return true }
    return (profile.username ?? "").localizedCaseInsensitiveContains(query)
        || (profile.displayName ?? "").localizedCaseInsensitiveContains(query)
}
