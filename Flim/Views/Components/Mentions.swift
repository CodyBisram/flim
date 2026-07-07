import SwiftUI

/// @mention text helpers.
enum Mentions {
    /// The in-progress @mention query at the end of `text` (chars after the last "@" with no
    /// whitespace), or nil if not composing a mention. Assumes typing at the end (the common case).
    static func activeToken(in text: String) -> String? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        let after = text[text.index(after: at)...]
        if after.contains(where: { $0.isWhitespace || $0 == "\n" }) { return nil }
        // The "@" must start a word (start of string or preceded by whitespace).
        let atStartOfWord = at == text.startIndex
            || text[text.index(before: at)].isWhitespace
            || text[text.index(before: at)] == "\n"
        guard atStartOfWord else { return nil }
        return String(after)
    }

    /// Replaces the in-progress token with the chosen @username (plus a trailing space).
    static func complete(_ username: String, in text: inout String) {
        guard let at = text.lastIndex(of: "@") else { return }
        text = String(text[..<at]) + "@\(username) "
    }

    /// All distinct @usernames (lowercased) referenced in `text`.
    static func usernames(in text: String) -> [String] {
        let parts = text.split(whereSeparator: { $0.isWhitespace || $0 == "\n" })
        var names: [String] = []
        for p in parts where p.hasPrefix("@") {
            let name = p.dropFirst().prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
            if !name.isEmpty { names.append(String(name).lowercased()) }
        }
        return Array(Set(names))
    }
}

/// Renders text with @mentions in the accent color and tappable to the mentioned person's profile.
struct MentionText: View {
    let text: String
    var font: Font = .system(size: 15)
    var color: Color = .white
    /// Called with the tapped username (lowercased, no @).
    let onMention: (String) -> Void

    var body: some View {
        Text(attributed)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "flimmention" else { return .systemAction }
                let name = (url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent).lowercased()
                if !name.isEmpty { onMention(name) }
                return .handled
            })
    }

    private var attributed: AttributedString {
        var attr = AttributedString(text)
        attr.font = font
        attr.foregroundColor = color
        for username in Mentions.usernames(in: text) {
            let enc = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? username
            let link = URL(string: "flimmention://u/\(enc)")
            var search = attr.startIndex..<attr.endIndex
            while let r = attr[search].range(of: "@\(username)", options: [.caseInsensitive]) {
                attr[r].foregroundColor = FlimTheme.accent
                attr[r].link = link
                attr[r].underlineStyle = nil
                search = r.upperBound..<attr.endIndex
            }
        }
        return attr
    }
}

/// A horizontal suggestion bar shown above a text field while typing an @mention. Loads the people
/// you follow (mutuals first), completes the token when tapped, and renders nothing when inactive.
struct MentionSuggestionBar: View {
    @Binding var text: String
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed
    @State private var following: [UserProfile] = []
    @State private var mutualIds: Set<UUID> = []
    @State private var searched: [UserProfile] = []   // all-users fallback for the current query
    @State private var searchTask: Task<Void, Never>?

    private var matches: [UserProfile] {
        guard let q = Mentions.activeToken(in: text) else { return [] }
        let base = q.isEmpty ? following : following.filter {
            ($0.username ?? "").localizedCaseInsensitiveContains(q) ||
            ($0.displayName ?? "").localizedCaseInsensitiveContains(q)
        }
        let ranked = base.sorted { a, b in
            let am = mutualIds.contains(a.id), bm = mutualIds.contains(b.id)
            if am != bm { return am }
            return (a.username ?? "") < (b.username ?? "")
        }
        // Then anyone else who matched the search but isn't someone you follow.
        let extra = searched.filter { s in !ranked.contains { $0.id == s.id } }
        return Array((ranked + extra).prefix(10))
    }

    var body: some View {
        Group {
            if !matches.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(matches) { p in
                            Button {
                                if let u = p.username {
                                    Mentions.complete(u, in: &text)
                                    Haptics.tap()
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Circle().fill(FlimTheme.accent.opacity(0.18)).frame(width: 22, height: 22)
                                        .overlay {
                                            Text((p.username ?? "?").prefix(1).uppercased())
                                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(FlimTheme.accent)
                                        }
                                    Text(p.handle).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 6)
                                .background(Color.white.opacity(0.1), in: Capsule())
                            }
                            .buttonStyle(.plain)   // don't let the tap steal first-responder from the field
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                }
                .scrollDismissesKeyboard(.never)   // scrolling/tapping the strip keeps the keyboard up
                .background(.ultraThinMaterial)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: matches.isEmpty)   // smooth the height change
        .task { await load() }
        .onChange(of: text) { _, _ in scheduleSearch() }
    }

    /// Debounced search of all users for the current @token, so people you don't follow (e.g. the
    /// person whose photo you're commenting on) can still be mentioned.
    private func scheduleSearch() {
        searchTask?.cancel()
        guard let q = Mentions.activeToken(in: text), q.count >= 2 else { searched = []; return }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let uid = auth.currentUser?.id else { return }
            let results = await feed.searchProfiles(query: q, excluding: uid)
            if !Task.isCancelled { searched = results }
        }
    }

    private func load() async {
        guard following.isEmpty, let uid = auth.currentUser?.id else { return }
        async let f = feed.fetchFollowingProfiles(of: uid)
        async let followers = feed.fetchFollowers(of: uid)
        following = await f
        mutualIds = Set((await followers).map(\.id)).intersection(Set(following.map(\.id)))
    }
}
