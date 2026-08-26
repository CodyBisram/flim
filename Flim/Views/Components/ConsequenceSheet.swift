import SwiftUI

/// The facts behind a roll action that touches other people: confirmations redesign rule 2.
/// Irreversible-for-others actions ask once, name the roll, count the people, and lead with
/// what survives. ONE enum builds every variant, which is the structural fix for the old
/// three-copies-of-"Leave this roll?" drift (RollsView, RollDetailView and RollMembersView
/// each shipped their own message, and two disagreed about needing the code to rejoin).
///
/// Counts are optional on purpose: a screen that genuinely knows "all 6 people" says so, a
/// screen that doesn't says "everyone" rather than inventing a number. Copy must not claim
/// more than the data does.
enum RollConsequence: Identifiable {
    case deleteShot(rollName: String, people: Int?, myOtherShots: Int?)
    case deleteRoll(name: String, people: Int?)
    case leave(name: String, myShots: Int?)
    case removeMember(handle: String, rollName: String, theirShots: Int?)

    var id: String { title }

    var contextLabel: String {
        switch self {
        case .deleteShot(let name, _, _), .deleteRoll(let name, _),
             .leave(let name, _), .removeMember(_, let name, _):
            // A caller without the name in hand passes "" rather than inventing one.
            return name.isEmpty ? "Shared roll" : "Shared roll · \(name)"
        }
    }

    var title: String {
        switch self {
        case .deleteShot(_, let people, _):
            if let people, people > 1 { return "Delete this shot for all \(people) people?" }
            return "Delete this shot for everyone?"
        case .deleteRoll(let name, let people):
            if let people, people > 1 { return "Delete \(name) for all \(people) people?" }
            return "Delete \(name) for everyone?"
        case .leave(let name, _):
            return "Leave \(name)?"
        case .removeMember(let handle, let name, _):
            return "Remove \(handle) from \(name)?"
        }
    }

    /// The ✓ line: what survives, always said first.
    var survives: String {
        switch self {
        case .deleteShot(_, _, let mine):
            guard let mine, mine > 0 else { return "Everything else in the roll stays exactly where it is." }
            return mine == 1
                ? "Your other shot in this roll stays exactly where it is."
                : "Your other \(mine) shots in this roll stay exactly where they are."
        case .deleteRoll:
            return "Everyone keeps the photos they took."
        case .leave(_, let mine):
            guard let mine, mine > 0 else { return "Your shots stay in your Darkroom." }
            return mine == 1
                ? "Your shot stays in your Darkroom."
                : "Your \(mine) shots stay in your Darkroom."
        case .removeMember(_, _, let theirs):
            guard let theirs, theirs > 0 else { return "They keep their own shots." }
            return theirs == 1
                ? "They keep their own shot."
                : "They keep their own \(theirs) shots."
        }
    }

    /// The ✕ line: what is lost, stated without softening.
    var loses: String {
        switch self {
        case .deleteShot:
            return "This one leaves the roll for everyone. There's no undo once it's gone."
        case .deleteRoll:
            return "Nobody keeps the roll."
        case .leave:
            return "You'll need the invite code to come back."
        case .removeMember:
            return "They'll need a new invite to come back."
        }
    }

    /// Rule 5: no bare verbs on destructive buttons.
    var confirmLabel: String {
        switch self {
        case .deleteShot, .deleteRoll: return "Delete for everyone"
        case .leave: return "Leave roll"
        case .removeMember: return "Remove from roll"
        }
    }

    var cancelLabel: String {
        switch self {
        case .deleteShot: return "Keep it"
        case .deleteRoll: return "Keep the roll"
        case .leave: return "Stay"
        case .removeMember: return "Keep them"
        }
    }
}

/// The sheet itself: context line, the question, a ✓/✕ fact table, then the two choices.
/// Present with `.sheet(item:)`; confirming dismisses and calls `onConfirm`.
struct ConsequenceSheet: View {
    @Environment(\.flimAccent) private var accent
    @Environment(\.dismiss) private var dismiss

    let consequence: RollConsequence
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(consequence.contextLabel)
                .flimFont(10, relativeTo: .caption2)
                .tracking(1.5)
                .textCase(.uppercase)
                .foregroundStyle(accent)
            Text(consequence.title)
                .flimFont(23, weight: .light, relativeTo: .title2)
                .foregroundStyle(FlimTheme.textPrimary)
                .padding(.top, 8)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                factRow(mark: "✓", markColor: .green.opacity(0.85), text: consequence.survives)
                Divider().overlay(Color.white.opacity(0.07))
                factRow(mark: "✕", markColor: .red.opacity(0.85), text: consequence.loses)
            }
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            .padding(.top, 20)

            Button {
                Haptics.warning()
                dismiss()
                onConfirm()
            } label: {
                Text(consequence.confirmLabel)
                    .flimFont(16, weight: .medium, relativeTo: .body)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color.red.opacity(0.1), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.red.opacity(0.8), lineWidth: 1))
            }
            .padding(.top, 24)
            Button {
                dismiss()
            } label: {
                Text(consequence.cancelLabel)
                    .flimFont(16, relativeTo: .body)
                    .foregroundStyle(FlimTheme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 22)
        .padding(.top, 26)
        .padding(.bottom, 10)
        .presentationDetents([.height(360)])
        .presentationDragIndicator(.hidden)
        .flimSheetSurface()
        .accessibilityElement(children: .contain)
    }

    private func factRow(mark: String, markColor: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Text(mark)
                .flimFont(14, weight: .semibold, relativeTo: .subheadline)
                .foregroundStyle(markColor)
            Text(text)
                .flimFont(14, relativeTo: .subheadline)
                .foregroundStyle(FlimTheme.textPrimary.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .accessibilityElement(children: .combine)
    }
}
