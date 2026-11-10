import SwiftUI

/// Shown once, on the first open of 1.7, over whatever the person had before (Blend 1, 5b, with
/// Blend 2's fix: "FLIM 1.7"). It opens on Slate so 1.6 users land somewhere familiar, says the
/// four things that moved, and lets them pick a desk. A brand-new account never sees it (first
/// run marks it seen).
struct DeskUpdateCard: View {
    static let seenKey = "deskUpdateCardSeen"

    var onContinue: () -> Void

    @AppStorage(Desk.storageKey) private var deskRaw = Desk.fallback.rawValue
    @Environment(\.flimAccent) private var accent

    private let lines: [(String, String)] = [
        ("Your page has its own tab.", "Tap You, bottom right."),
        ("Friends go both ways.", "If you followed each other, you're friends now. One-way follows became requests, waiting in Friends."),
        ("Months go on a shelf.", "On the 1st, last month moves to your page as one box you can play."),
        ("Light or dark.", "Pick a desk below. You can change it in Appearance."),
    ]

    private var desk: Desk { Desk(rawValue: deskRaw) ?? Desk.fallback }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("FLIM 1.7")
                        .font(DeskType.data(11))
                        .tracking(2)
                        .foregroundStyle(accent)
                        .padding(.top, 40)
                    Text("Same tabs. A few things moved.")
                        .font(DeskType.serif(32, relativeTo: .largeTitle))
                        .foregroundStyle(FlimTheme.textPrimary)
                        .padding(.top, 12)
                        .accessibilityAddTraits(.isHeader)
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                            HStack(alignment: .firstTextBaseline, spacing: 14) {
                                Text(String(format: "%02d", i + 1))
                                    .font(DeskType.data(11))
                                    .foregroundStyle(accent)
                                (Text(line.0 + " ").fontWeight(.semibold).foregroundColor(FlimTheme.textPrimary)
                                 + Text(line.1).foregroundColor(FlimTheme.textSecondary))
                                    .flimFont(15.5, relativeTo: .body)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(.top, 28)
                    HStack(spacing: 10) {
                        deskButton(.paper)
                        deskButton(.slate)
                    }
                    .padding(.top, 28)
                }
                .padding(.horizontal, 28)
            }
            Button(action: onContinue) {
                Text("Continue")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(white: 0.1))
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(accent, in: Capsule())
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 16)
        }
        .background(DeskGround())
    }

    private func deskButton(_ choice: Desk) -> some View {
        let chosen = desk == choice
        let ground = choice == .paper ? DeskColor.rgb(0xF3E7DC) : DeskColor.rgb(0x1C1917)
        let ink = choice == .paper ? DeskColor.rgb(0x2A2420) : DeskColor.rgb(0xF3E7DC)
        return Button {
            Haptics.tap()
            withAnimation(.easeInOut(duration: 0.35)) { deskRaw = choice.rawValue }
        } label: {
            Text(choice.label)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ink)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(ground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(chosen ? accent : FlimTheme.stroke, lineWidth: chosen ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}
