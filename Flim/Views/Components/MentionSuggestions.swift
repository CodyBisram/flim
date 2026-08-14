import SwiftUI

/// The @mention autocomplete row, sat directly above a comment composer.
///
/// A component rather than something each composer implements, because there are FOUR comment
/// composers (the feed card's inline field, the comments sheet, post detail, and a roll photo's
/// comments) and the first version of mentions was wired into exactly one of them. Typing `@`
/// anywhere else did nothing, which reads as the feature being broken rather than as partially
/// built. Anything with a draft binding gets the same behaviour from one line now.
///
/// Shows itself only while a mention is actually being typed, so it never competes with the
/// content above it.
struct MentionSuggestions: View {
    @Binding var draft: String

    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed
    @State private var matches: [UserProfile] = []

    var body: some View {
        Group {
            if !matches.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(matches) { profile in
                            Button {
                                Haptics.tap()
                                draft = completingMention(in: draft, with: profile.username ?? "")
                            } label: {
                                HStack(spacing: 6) {
                                    AvatarView(path: profile.avatarPath, name: profile.username, size: 22)
                                    Text(profile.handle)
                                        .flimFont(13, weight: .medium, relativeTo: .subheadline)
                                        .foregroundStyle(.white)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(Color.white.opacity(0.1), in: Capsule())
                            }
                            .accessibilityLabel("Mention \(profile.handle)")
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .frame(height: 44)
                // Picking a suggestion must insert the mention and leave the keyboard up, not
                // lose the tap to the app-level "tap anywhere to dismiss" gesture. See
                // KeyboardDismiss.swift.
                .keyboardDismissExempt()
                .transition(.opacity)
            }
        }
        .onChange(of: draft) { _, new in
            // Driven by what's being typed RIGHT NOW, so the row disappears the moment the
            // mention is finished rather than lingering over the next word.
            guard let query = mentionQuery(in: new), let uid = auth.currentUser?.id else {
                withAnimation(.snappy(duration: 0.2)) { matches = [] }
                return
            }
            Task {
                // A just-typed "@" has nothing to search on (searchProfiles returns nothing for an
                // empty query), so it offers the people you follow instead: the likeliest mention
                // targets, and it makes the row useful from the first keystroke, not the second.
                let found = query.isEmpty
                    ? await feed.fetchFollowingProfiles(of: uid)
                    : await feed.searchProfiles(query: query, excluding: uid)
                // The draft can move on while that query is in flight; only apply the result if it
                // still describes what's on screen.
                guard mentionQuery(in: draft) == query else { return }
                withAnimation(.snappy(duration: 0.2)) { matches = Array(found.prefix(8)) }
            }
        }
    }
}
