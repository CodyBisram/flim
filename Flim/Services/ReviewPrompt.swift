import Foundation
import StoreKit
import SwiftUI
import UIKit

/// Apple's own rating card (`@Environment(\.requestReview)`), asked for right after something
/// good, never cold. See docs/PLAN_1_6_2_BADGES_AND_RATING.md, section 2.
///
/// Apple decides whether the card actually appears and caps it at three a year per person; it
/// never appears in TestFlight at all. These are the app's own guards on top of that, so the ask
/// is spent on a good moment rather than on whichever screen happened to call first:
/// - not in an account's first seven days;
/// - at most once per app version, and at least 120 days between asks;
/// - not within a day of something failing in front of the person (an upload that queued, a
///   comment that didn't send, a reaction that rolled back).
///
/// The guard itself is `shouldAsk(state:accountCreatedAt:appVersion:lastVisibleFailure:now:)`,
/// pure so every rule is pinned by a test. State lives in UserDefaults per account
/// (`reviewAsk.<userId>`); the failure stamp is per device, since a failure on this phone is
/// what the person just saw, whoever is signed in.
///
/// The four moments, and where each is noticed:
/// - `spotlightChosen`: `PostDetailView`, the first time you open your own chosen frame;
/// - `rollReveal`: `RollRevealView`, when the reveal completes (its last frame, or Done);
/// - `tenthPost`: `FeedService.createPost`, when the server's count of your posts reaches ten;
/// - `fifthReaction`: `ReviewPromptCenter.checkReactionMilestone`, on the next app open after
///   the fifth reaction from someone else lands.
/// The first two ask from their own screen (`askWhenSettled`); the last two can happen under a
/// sheet, the camera or the sort deck, so they wait in `ReviewPromptCenter` until the tab host
/// is clear.
enum ReviewPrompt {
    enum Moment: String, CaseIterable, Sendable {
        case spotlightChosen = "spotlight_chosen"
        case rollReveal = "roll_reveal"
        case tenthPost = "tenth_post"
        case fifthReaction = "fifth_reaction"

        var usageEvent: UsageEvent {
            switch self {
            case .spotlightChosen: return .reviewAskedSpotlight
            case .rollReveal:      return .reviewAskedReveal
            case .tenthPost:       return .reviewAskedTenthPost
            case .fifthReaction:   return .reviewAskedReactions
            }
        }
    }

    /// One account's history of asks. Codable so it sits under one key as JSON.
    struct State: Codable, Equatable {
        var lastAskedAt: Date?
        var versionAsked: String?
        var count: Int = 0
    }

    static let firstWeek: TimeInterval = 7 * 86_400
    static let minimumGap: TimeInterval = 120 * 86_400
    static let failureQuiet: TimeInterval = 24 * 3_600
    static let postMilestone = 10
    static let reactionMilestone = 5
    /// How long a moment has to sit still before the ask, "about a second" in the plan.
    static let settleDelay: Duration = .seconds(1)

    // MARK: - The guard

    /// Whether the app may ask now. Pure: every input is passed in.
    ///
    /// Intervals compare by magnitude, so a stamp from a clock that was later wound back still
    /// blocks for its window and then lets go, instead of blocking for however far ahead the
    /// clock had been.
    static func shouldAsk(state: State, accountCreatedAt: Date, appVersion: String,
                          lastVisibleFailure: Date?, now: Date) -> Bool {
        guard now.timeIntervalSince(accountCreatedAt) >= firstWeek else { return false }
        if state.versionAsked == appVersion { return false }
        if let last = state.lastAskedAt, abs(now.timeIntervalSince(last)) < minimumGap { return false }
        if let failure = lastVisibleFailure, abs(now.timeIntervalSince(failure)) < failureQuiet { return false }
        return true
    }

    /// True only on the open that first sees the count at or past five after an open that saw
    /// it below. `previous == nil` is the first open ever measured, which only sets the baseline:
    /// an account that already had fifty reactions before this shipped has no fifth to notice.
    static func reactionMilestoneCrossed(previous: Int?, current: Int) -> Bool {
        guard let previous else { return false }
        return previous < reactionMilestone && current >= reactionMilestone
    }

    // MARK: - Storage

    static func stateKey(userId: UUID) -> String { "reviewAsk.\(userId.uuidString)" }
    static let failureKey = "reviewAsk.lastVisibleFailure"
    static func reactionsKey(userId: UUID) -> String { "reviewAsk.reactionsSeen.\(userId.uuidString)" }
    static func spotlightOpenedKey(postId: UUID) -> String { "reviewAsk.spotlightOpened.\(postId.uuidString)" }

    static func state(userId: UUID, in defaults: UserDefaults = .standard) -> State {
        guard let data = defaults.data(forKey: stateKey(userId: userId)),
              let decoded = try? JSONDecoder().decode(State.self, from: data) else { return State() }
        return decoded
    }

    static func recordAsk(userId: UUID, version: String, at now: Date, in defaults: UserDefaults = .standard) {
        var next = state(userId: userId, in: defaults)
        next.lastAskedAt = now
        next.versionAsked = version
        next.count += 1
        if let data = try? JSONEncoder().encode(next) {
            defaults.set(data, forKey: stateKey(userId: userId))
        }
    }

    /// Stamps "something just failed in front of the person". Called beside the `Haptics.error()`
    /// of a queued upload, a comment that didn't send, and a reaction that rolled back.
    static func noteVisibleFailure(at now: Date = .now, in defaults: UserDefaults = .standard) {
        defaults.set(now, forKey: failureKey)
    }

    static func lastVisibleFailure(in defaults: UserDefaults = .standard) -> Date? {
        defaults.object(forKey: failureKey) as? Date
    }

    /// The guard, read from storage for `userId`.
    static func mayAsk(userId: UUID, accountCreatedAt: Date, appVersion: String = AppInfo.shortVersion,
                       now: Date = .now, in defaults: UserDefaults = .standard) -> Bool {
        shouldAsk(state: state(userId: userId, in: defaults), accountCreatedAt: accountCreatedAt,
                  appVersion: appVersion, lastVisibleFailure: lastVisibleFailure(in: defaults), now: now)
    }

    /// Cheap pre-check before any server count: this version has already had its ask.
    static func askedThisVersion(userId: UUID, appVersion: String = AppInfo.shortVersion,
                                 in defaults: UserDefaults = .standard) -> Bool {
        state(userId: userId, in: defaults).versionAsked == appVersion
    }
}

// MARK: - Asking

@MainActor
extension ReviewPrompt {
    /// How many view controllers sit presented above the key window's root: sheets, full-screen
    /// covers, alerts and share sheets all count, and a presentation still animating in or out
    /// counts too, which is what keeps the ask off a moving screen.
    static func presentationDepth() -> Int {
        var controller = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
        var depth = 0
        while let next = controller?.presentedViewController {
            depth += 1
            controller = next
        }
        return depth
    }

    /// Checks the guards for `user`; if they pass, records the ask, logs which moment it was, and
    /// hands over to Apple. Returns whether it asked.
    @discardableResult
    static func askIfAllowed(_ moment: Moment, user: AppUser?, requestReview: RequestReviewAction,
                             defaults: UserDefaults = .standard, now: Date = .now) -> Bool {
        guard let user else { return false }
        let version = AppInfo.shortVersion
        guard mayAsk(userId: user.id, accountCreatedAt: user.createdAt, appVersion: version,
                     now: now, in: defaults) else { return false }
        recordAsk(userId: user.id, version: version, at: now, in: defaults)
        Usage.log(moment.usageEvent)
        requestReview()
        return true
    }

    /// For a moment on the screen that asks (the reveal's end, your chosen frame): waits for it
    /// to settle, then asks, unless the app left the foreground, something was presented over
    /// this screen in the meantime, or `isStill` says the screen is busy (a keyboard, its own
    /// sheet about to open).
    ///
    /// Returns whether the moment reached its decision (asked or refused by the guards). False
    /// only when it was interrupted first: the task cancelled because the screen went away, or
    /// the screen was not still. A caller that treats a moment as once-only spends it on true.
    @discardableResult
    static func askWhenSettled(_ moment: Moment, user: AppUser?, requestReview: RequestReviewAction,
                               extraDelay: Duration = .zero,
                               isStill: @MainActor () -> Bool = { true }) async -> Bool {
        guard let user else { return false }
        // Refused up front costs no wait, and still counts as the moment having happened.
        guard mayAsk(userId: user.id, accountCreatedAt: user.createdAt) else { return true }
        let depth = presentationDepth()
        try? await Task.sleep(for: settleDelay + extraDelay)
        guard !Task.isCancelled,
              UIApplication.shared.applicationState == .active,
              presentationDepth() == depth,
              isStill() else { return false }
        askIfAllowed(moment, user: user, requestReview: requestReview)
        return true
    }
}

/// Holds a moment that was noticed somewhere it cannot be asked about (the tenth post lands
/// while the sort deck or a share sheet is still up; the fifth reaction is noticed at launch,
/// usually on the camera) until the tab host is clear. `ReviewPromptHost` in MainTabView does the
/// waiting and the asking.
@MainActor
@Observable
final class ReviewPromptCenter {
    static let shared = ReviewPromptCenter()

    struct Pending: Equatable {
        let moment: ReviewPrompt.Moment
        let userId: UUID
        let armedAt: Date
    }

    private(set) var pending: Pending?
    /// A moment that could not be asked about within this long is dropped: by then it is no
    /// longer the moment.
    static let pendingLifetime: TimeInterval = 15 * 60
    private var checkingReactions = false

    func arm(_ moment: ReviewPrompt.Moment, userId: UUID, now: Date = .now) {
        guard pending == nil else { return }
        pending = Pending(moment: moment, userId: userId, armedAt: now)
    }

    func clear() { pending = nil }

    /// The fifth-reaction moment, checked at launch and on every return to the foreground. Stops
    /// querying for good once the count has been seen at five or more.
    func checkReactionMilestone(userId: UUID, feed: FeedService, defaults: UserDefaults = .standard) async {
        let key = ReviewPrompt.reactionsKey(userId: userId)
        let previous = defaults.object(forKey: key) as? Int
        if let previous, previous >= ReviewPrompt.reactionMilestone { return }
        guard !checkingReactions else { return }
        checkingReactions = true
        defer { checkingReactions = false }
        let epoch = AccountEpoch.current
        guard let current = await feed.receivedReactionCount(userId: userId),
              AccountEpoch.isCurrent(epoch) else { return }
        defaults.set(current, forKey: key)
        if ReviewPrompt.reactionMilestoneCrossed(previous: previous, current: current) {
            arm(.fifthReaction, userId: userId)
        }
    }
}

/// Asks about `ReviewPromptCenter`'s pending moment once the tab host has been still for a
/// second: the app in the foreground, off the camera, nothing presented at all (no sheet, no sort
/// deck, no reveal, no share sheet). Also where the fifth-reaction check runs, at launch and on
/// every foreground.
struct ReviewPromptHost: ViewModifier {
    /// Read live on every check, so a tab change while a moment waits is seen.
    let isCameraFrontmost: () -> Bool
    @Environment(\.requestReview) private var requestReview
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed

    private var center: ReviewPromptCenter { .shared }

    func body(content: Content) -> some View {
        content
            .task(id: center.pending) { await waitThenAsk() }
            .task { await checkReactions() }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await checkReactions() }
            }
    }

    private func checkReactions() async {
        guard let uid = auth.currentUser?.id, !ReviewPrompt.askedThisVersion(userId: uid) else { return }
        await center.checkReactionMilestone(userId: uid, feed: feed)
    }

    private func waitThenAsk() async {
        guard let pending = center.pending else { return }
        var stillSince: Date?
        while !Task.isCancelled {
            let now = Date()
            guard now.timeIntervalSince(pending.armedAt) < ReviewPromptCenter.pendingLifetime,
                  auth.currentUser?.id == pending.userId else {
                center.clear()
                return
            }
            let settled = UIApplication.shared.applicationState == .active
                && !isCameraFrontmost()
                && ReviewPrompt.presentationDepth() == 0
            if !settled {
                stillSince = nil
            } else if let since = stillSince {
                if now.timeIntervalSince(since) >= 1 { break }
            } else {
                stillSince = now
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard !Task.isCancelled else { return }
        center.clear()
        ReviewPrompt.askIfAllowed(pending.moment, user: auth.currentUser, requestReview: requestReview)
    }
}
