import SwiftUI

/// The nuclear confirmation gets a page, not a sheet (confirmations redesign rule 3): a real
/// inventory of what is about to stop existing, and a button you HOLD, because the one action
/// with no restore, no grace period and no copy on our side deserves a still hand rather than
/// a reflex tap. The debug data wipe shares the shape (`mode: .wipeData`): same inventory,
/// same held confirm, different verb, because a second, flimsier door to almost the same
/// outcome would undercut the first one.
///
/// Failures land ON this page with Try again (rule 4), replacing the old "Couldn't delete
/// account" modal: nothing was deleted, and the page saying so is the honest state.
struct AccountDeleteView: View {
    enum Mode {
        case deleteAccount
        case wipeData
    }

    @Environment(\.flimAccent) private var accent
    @Environment(AuthService.self) private var auth
    @Environment(PhotoService.self) private var photos
    @Environment(\.dismiss) private var dismiss

    let mode: Mode

    @State private var inventory: AuthService.AccountInventory?
    @State private var inventoryFailed = false
    /// 0...1 while the button is held; reaching 1 commits. Driven by a timer while pressing,
    /// snapping back to 0 on release, so an accidental brush never gets close.
    @State private var holdProgress: Double = 0
    @State private var holdTask: Task<Void, Never>?
    @State private var isWorking = false
    @State private var failureText: String?

    private static let holdDuration: TimeInterval = 1.4

    private var title: String {
        switch mode {
        case .deleteAccount:
            let handle = auth.currentUser?.username.map { "@\($0)" } ?? "your account"
            return "Delete \(handle) and everything in it"
        case .wipeData:
            return "Wipe your data, keep the account"
        }
    }

    private var explainer: String {
        switch mode {
        case .deleteAccount:
            return "There is no restore, no grace period, and no copy on our side. Save anything you want first."
        case .wipeData:
            return "Deletes all your photos, thumbnails, avatar and cover, and posts from storage, and resets your egress baseline. Your account stays."
        }
    }

    private var holdLabel: String {
        if isWorking { return mode == .deleteAccount ? "Deleting" : "Wiping" }
        if holdProgress > 0 { return "Keep holding…" }
        return mode == .deleteAccount ? "Hold to delete everything" : "Hold to wipe your data"
    }

    var body: some View {
        ZStack {
            FlimTheme.bg.ignoresSafeArea()
            if isWorking && mode == .deleteAccount {
                deletingState
            } else {
                content
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await loadInventory() }
        .onDisappear { holdTask?.cancel() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Permanent")
                .flimFont(10, relativeTo: .caption2)
                .tracking(1.6)
                .textCase(.uppercase)
                .foregroundStyle(.red.opacity(0.85))
            Text(title)
                .flimFont(32, weight: .light, relativeTo: .title)
                .foregroundStyle(FlimTheme.textPrimary)
                .padding(.top, 10)
                .fixedSize(horizontal: false, vertical: true)
            Text(explainer)
                .flimFont(14, relativeTo: .subheadline)
                .foregroundStyle(FlimTheme.textSecondary)
                .padding(.top, 12)
                .fixedSize(horizontal: false, vertical: true)

            inventoryTable
                .padding(.top, 24)

            if let failureText {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.red.opacity(0.9))
                    Text(failureText)
                        .flimFont(13, relativeTo: .subheadline)
                        .foregroundStyle(FlimTheme.textPrimary)
                    Spacer(minLength: 6)
                    Button("Try again") { beginHoldCommit() }
                        .flimFont(13, weight: .semibold)
                        .foregroundStyle(accent)
                }
                .padding(.horizontal, 15).padding(.vertical, 13)
                .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.red.opacity(0.3), lineWidth: 1))
                .padding(.top, 16)
            }

            Spacer(minLength: 20)

            holdButton
            Button { dismiss() } label: {
                Text("Keep my account")
                    .flimFont(15, relativeTo: .body)
                    .foregroundStyle(FlimTheme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 24)
    }

    /// The numbers, or an honest line about not having them. Never zeros-by-default: showing
    /// "0 photos" to someone with 400 because a fetch failed would be worse than no table.
    @ViewBuilder
    private var inventoryTable: some View {
        if let inventory {
            VStack(spacing: 0) {
                inventoryRow("Photos", "\(inventory.photos)")
                Divider().overlay(Color.white.opacity(0.07))
                inventoryRow("Rolls you made", "\(inventory.rollsCreated)")
                Divider().overlay(Color.white.opacity(0.07))
                inventoryRow("Posts on your page", "\(inventory.posts)")
                if mode == .deleteAccount {
                    Divider().overlay(Color.white.opacity(0.07))
                    inventoryRow("Your handle", "released")
                }
            }
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        } else if inventoryFailed {
            Text("Couldn't load your numbers. Everything below still applies to all of it.")
                .flimFont(13, relativeTo: .subheadline)
                .foregroundStyle(FlimTheme.textTertiary)
        } else {
            ProgressView().tint(FlimTheme.textTertiary)
                .frame(maxWidth: .infinity)
        }
    }

    private func inventoryRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .flimFont(14, relativeTo: .subheadline)
                .foregroundStyle(FlimTheme.textPrimary.opacity(0.9))
            Spacer()
            Text(value)
                .flimFont(14, weight: .medium, relativeTo: .subheadline)
                .foregroundStyle(FlimTheme.textPrimary)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .accessibilityElement(children: .combine)
    }

    /// Press and hold: the fill tracks the hold, releasing before it completes snaps back to
    /// zero. VoiceOver users get an equivalent explicit action instead of a timing gesture.
    private var holdButton: some View {
        ZStack {
            GeometryReader { proxy in
                Rectangle()
                    .fill(Color.red.opacity(0.32))
                    .frame(width: proxy.size.width * holdProgress)
                    .animation(.linear(duration: 0.06), value: holdProgress)
            }
            Text(holdLabel)
                .flimFont(16, weight: .medium, relativeTo: .body)
                .foregroundStyle(.red)
        }
        .frame(height: 54)
        .frame(maxWidth: .infinity)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Color.red.opacity(0.8), lineWidth: 1))
        .contentShape(Capsule())
        .onLongPressGesture(minimumDuration: Self.holdDuration, maximumDistance: 60) {
            beginHoldCommit()
        } onPressingChanged: { pressing in
            guard !isWorking else { return }
            if pressing {
                startHoldFill()
            } else {
                holdTask?.cancel()
                withAnimation(.snappy(duration: 0.2)) { holdProgress = 0 }
            }
        }
        .disabled(isWorking)
        .accessibilityRepresentation {
            Button(mode == .deleteAccount ? "Delete everything, permanently" : "Wipe all data, permanently") {
                beginHoldCommit()
            }
        }
    }

    private func startHoldFill() {
        holdTask?.cancel()
        holdProgress = 0
        holdTask = Task {
            let steps = 40
            for step in 1...steps {
                try? await Task.sleep(for: .seconds(Self.holdDuration / Double(steps)))
                guard !Task.isCancelled else { return }
                holdProgress = Double(step) / Double(steps)
            }
        }
    }

    private func beginHoldCommit() {
        guard !isWorking else { return }
        holdTask?.cancel()
        holdProgress = 1
        failureText = nil
        isWorking = true
        Haptics.warning()
        Task {
            switch mode {
            case .deleteAccount:
                do {
                    try await auth.deleteAccount()
                    // Signed out; ContentView tears the whole UI down to auth. Nothing to
                    // dismiss, and nothing left to stand on if we tried.
                } catch {
                    isWorking = false
                    holdProgress = 0
                    Haptics.error()
                    failureText = "Couldn't finish deleting. Nothing was deleted."
                }
            case .wipeData:
                guard let uid = auth.currentUser?.id else { isWorking = false; return }
                await photos.deleteAllMyData(userId: uid)
                isWorking = false
                holdProgress = 0
                Haptics.success()
                dismiss()
            }
        }
    }

    private var deletingState: some View {
        VStack(spacing: 16) {
            ProgressView().tint(FlimTheme.textTertiary)
            Text("Deleting your account")
                .flimFont(22, weight: .light, relativeTo: .title2)
                .foregroundStyle(FlimTheme.textPrimary)
            Text("You'll be signed out when it's finished. This screen is the last thing that happens.")
                .flimFont(13.5, relativeTo: .subheadline)
                .foregroundStyle(FlimTheme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    private func loadInventory() async {
        guard inventory == nil else { return }
        if let fetched = await auth.accountInventory() {
            inventory = fetched
        } else {
            inventoryFailed = true
        }
    }
}
