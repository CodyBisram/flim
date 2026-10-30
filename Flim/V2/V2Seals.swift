import SwiftUI

/// The seals drawer (board 7b): every seal you earned, in ink, and the ones not yet earned pressed
/// blind, so you can feel the ladder without being sold it. One leads your page, chosen by hand
/// (product rule 5); tap a seal to choose it. Unearned seals are only ever shown here, to you.
struct V2SealsDrawer: View {
    /// Founding 100's number, from the page.
    var signupNumber: Int?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.v2Palette) private var palette
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed

    @State private var earned: [ProfileBadge] = []
    @State private var leading: String?
    @State private var loaded = false
    @State private var saving = false
    @State private var problem: String?

    private var unearned: [ProfileBadgeKind] {
        let have = Set(earned.map(\.kind))
        return ProfileBadgeKind.allCases.filter { $0.isEarnable && !have.contains($0) }
    }

    var body: some View {
        V2Screen(title: "Seals", onBack: { dismiss() }) {
            Button { dismiss() } label: {
                Text("Done").font(V2Type.control()).frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("One leads your page. Tap to choose it.")
                        .font(V2Type.serif(15, italic: true, relativeTo: .body))
                        .foregroundStyle(palette.ink2)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 12)
                    if let lead = earned.first(where: { $0.id == leading }) {
                        VStack(spacing: 10) {
                            V2Seal(badge: lead, signupNumber: signup).scaleEffect(1.6).frame(height: 100)
                            Text("leads your page")
                                .font(V2Type.serif(13, italic: true, relativeTo: .footnote))
                                .foregroundStyle(palette.ink3)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                    }
                    if let problem {
                        Text(problem)
                            .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
                            .foregroundStyle(Color.red)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 10)
                    }
                    section("Earned · \(earned.count)")
                    grid {
                        ForEach(earned) { badge in
                            Button { choose(badge) } label: {
                                VStack(spacing: 6) {
                                    V2Seal(badge: badge, signupNumber: signup).scaleEffect(72.0 / 58).frame(width: 90, height: 84)
                                    Text(badge.kind.label)
                                        .font(.system(.caption2))
                                        .foregroundStyle(badge.id == leading ? palette.ink : palette.ink3)
                                        .lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(saving)
                            .accessibilityAddTraits(badge.id == leading ? .isSelected : [])
                            .accessibilityHint("Leads your page")
                        }
                    }
                    if loaded, earned.isEmpty {
                        Text("Your first seal comes with your first frame.")
                            .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
                            .foregroundStyle(palette.ink3)
                            .padding(.top, 8)
                    }
                    section("Not yet · \(unearned.count)")
                    grid {
                        ForEach(unearned, id: \.self) { kind in
                            VStack(spacing: 6) {
                                V2Seal(badge: ProfileBadge(id: kind.rawValue, kind: kind, earnedAt: .now), blind: true)
                                    .scaleEffect(72.0 / 58).frame(width: 90, height: 84)
                                Text(kind.label)
                                    .font(.system(.caption2))
                                    .foregroundStyle(palette.ink3)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .padding(.horizontal, V2Metrics.margin)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
        }
        .task { await load() }
    }

    private var signup: Int? { signupNumber }

    private func section(_ title: String) -> some View {
        Text(title)
            .font(V2Type.serif(13, italic: true, relativeTo: .footnote))
            .foregroundStyle(palette.ink3)
            .padding(.top, 30)
            .padding(.bottom, 10)
            .accessibilityAddTraits(.isHeader)
    }

    private func grid(@ViewBuilder _ content: () -> some View) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 12)], spacing: 18) { content() }
    }

    private func choose(_ badge: ProfileBadge) {
        guard badge.id != leading else { return }
        Haptics.tap()
        let before = leading
        withAnimation(V2Motion.setDown) { leading = badge.id }
        saving = true
        problem = nil
        Task {
            do {
                try await auth.setDisplayedBadges([badge.id])
                Haptics.success()
            } catch {
                Haptics.error()
                withAnimation { leading = before }
                problem = "Couldn't save that. Your seal is unchanged."
            }
            saving = false
        }
    }

    private func load() async {
        #if DEBUG
        if auth.currentUser == nil, ProcessInfo.processInfo.arguments.contains("-v2DemoPage") {
            let now = Date.now
            earned = [ProfileBadge(id: "founding_100", kind: .founding100, earnedAt: now),
                      ProfileBadge(id: "spotlight", kind: .spotlight, earnedAt: now),
                      ProfileBadge(id: "full_house", kind: .fullHouse, earnedAt: now),
                      ProfileBadge(id: "regular", kind: .regular, earnedAt: now),
                      ProfileBadge(id: "first_light", kind: .firstLight, earnedAt: now)]
            leading = "founding_100"
            loaded = true
            return
        }
        #endif
        guard let uid = auth.currentUser?.id else { loaded = true; return }
        async let badges = feed.fetchProfileBadges(uid)
        async let effective = feed.fetchOwnEffectiveDisplayedBadgeIds()
        earned = await badges
        let ids = await effective
        leading = (auth.currentUser?.displayedBadges ?? ids)?.first ?? ids?.first
        loaded = true
        await feed.markOwnBadgesSeen()
    }
}
