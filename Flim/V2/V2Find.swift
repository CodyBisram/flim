import SwiftUI

/// Find: a name, or a roll code (prototype; board 16-1j). Empty, it lists the people you follow;
/// typing searches everyone by name, and six letters and digits that look like a roll code offer
/// to join that roll. Invite opens your invite.
struct V2FindView: View {
    var close: () -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.v2Palette) private var palette
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed

    @State private var query = ""
    @State private var friends: [UserProfile] = []
    @State private var results: [UserProfile]?
    @State private var searchFailed = false
    @State private var profile: ProfileRoute?
    @State private var joinCode: JoinCode?
    @FocusState private var typing: Bool

    private struct JoinCode: Identifiable {
        let code: String
        var id: String { code }
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let mode = V2LayoutMode.resolve(horizontalSizeClass: sizeClass, size: proxy.size)
                Group {
                    if mode == .outer { outer } else { stacked }
                }
                .environment(\.v2LayoutMode, mode)
            }
            .background { V2Desktop(palette: palette) }
            .foregroundStyle(palette.ink)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $profile) { V2PageView(userId: $0.id, openInvite: $0.openInvite) }
        }
        .sheet(item: $joinCode) { JoinRollView(initialCode: $0.code) }
        .task {
            guard let me = auth.currentUser?.id else { return }
            if feed.followingIds.isEmpty { await feed.loadFollowing(userId: me) }
            friends = await feed.fetchFollowingProfiles(of: me)
        }
        .task(id: query) { await search() }
    }

    // MARK: Arrangements

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                backButton
                Spacer(minLength: 8)
                Text("Find")
                    .font(V2Type.serif(15, relativeTo: .subheadline))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                inviteButton
            }
            field
                .padding(.top, 12)
            results(list)
                .padding(.top, 18)
        }
        .padding(.horizontal, V2Metrics.margin)
    }

    /// Closed: the field and the results fill the left; Back leads the column and Invite ends it.
    /// The keyboard takes the lower half, so results stay at the top (16-1j).
    private var outer: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                field
                results(list)
                    .padding(.top, 14)
            }
            .padding(.leading, V2Metrics.margin)
            .padding(.trailing, 12)
            .padding(.top, 12)
            VStack(alignment: .trailing) {
                backButton
                Spacer()
                inviteButton
            }
            .padding(.vertical, 12)
            .padding(.trailing, 14)
            .frame(width: V2RootMetrics.columnWidth, alignment: .trailing)
        }
    }

    private var backButton: some View {
        Button(action: close) {
            Text("Back").font(V2Type.control()).frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var inviteButton: some View {
        Button {
            if let me = auth.currentUser?.id { profile = ProfileRoute(id: me, openInvite: true) }
        } label: {
            Text("Invite")
                .font(V2Type.control())
                .foregroundStyle(palette.ink3)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var field: some View {
        TextField("", text: $query,
                  prompt: Text("a name, or a roll code")
                    .font(V2Type.serif(18, italic: true, relativeTo: .title3))
                    .foregroundStyle(palette.ink3))
            .font(V2Type.serif(18, relativeTo: .title3))
            .foregroundStyle(palette.ink)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .focused($typing)
            .frame(minHeight: 44)
            .overlay(alignment: .bottom) { Rectangle().fill(palette.ink).frame(height: 1.5) }
            .accessibilityLabel("Find a name, or a roll code")
    }

    // MARK: Results

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Six letters and digits: a roll's invite code (`JoinRollView` takes six).
    private var rollCode: String? {
        let code = trimmed.uppercased()
        guard code.count == 6, code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return code
    }

    private var list: [UserProfile] {
        trimmed.isEmpty ? friends : (results ?? [])
    }

    private func results(_ people: [UserProfile]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let rollCode {
                    Button { joinCode = JoinCode(code: rollCode) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rollCode)
                                    .font(V2Type.data(15))
                                    .tracking(2)
                                Text("a roll code")
                                    .font(.system(.caption))
                                    .foregroundStyle(palette.ink2)
                            }
                            Spacer()
                            Text("Join")
                                .font(V2Type.control(.caption))
                        }
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .bottom) { Rectangle().fill(palette.rule).frame(height: 1) }
                }
                Text(trimmed.isEmpty ? "Your friends" : "People")
                    .font(V2Type.serif(13, italic: true, relativeTo: .footnote))
                    .foregroundStyle(palette.ink3)
                    .padding(.top, rollCode == nil ? 0 : 14)
                    .accessibilityAddTraits(.isHeader)
                ForEach(people) { person in row(person) }
                if !trimmed.isEmpty, results != nil, people.isEmpty, rollCode == nil {
                    Text(searchFailed ? UserFacingError.genericMessage
                                      : "Nobody by that name yet.\nFLIM is invite only; send them one.")
                        .font(V2Type.serif(15, italic: true, relativeTo: .body))
                        .foregroundStyle(palette.ink3)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
            }
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    private func row(_ person: UserProfile) -> some View {
        HStack(spacing: 12) {
            Button { profile = ProfileRoute(id: person.id) } label: {
                HStack(spacing: 12) {
                    AvatarView(path: person.avatarPath, name: person.username, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(person.name)
                            .font(V2Type.serif(16, relativeTo: .body))
                            .lineLimit(1)
                        Text(person.handle)
                            .font(.system(.caption))
                            .foregroundStyle(palette.ink2)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if feed.isFollowing(person.id) {
                Text("friend")
                    .font(V2Type.control(.caption))
                    .foregroundStyle(palette.ink3)
            } else {
                Button { follow(person) } label: {
                    Text("Follow")
                        .font(V2Type.control(.caption))
                        .underline()
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.rule).frame(height: 1) }
    }

    // MARK: Actions

    private func search() async {
        let text = trimmed
        guard !text.isEmpty, let me = auth.currentUser?.id else {
            results = nil
            return
        }
        // A short pause, so each keystroke does not send its own search.
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let found = await feed.searchProfiles(query: text, excluding: me)
        guard !Task.isCancelled else { return }
        searchFailed = found == nil
        results = (found ?? []).filter { !feed.isBlocked($0.id) }
    }

    private func follow(_ person: UserProfile) {
        guard let me = auth.currentUser?.id else { return }
        Haptics.tap()
        Task { _ = await feed.follow(person.id, from: me) }
    }
}
