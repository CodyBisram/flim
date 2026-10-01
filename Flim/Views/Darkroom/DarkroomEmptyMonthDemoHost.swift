#if DEBUG
import SwiftUI

/// Simulator-only harness for the Darkroom's month rung on an empty month, launched with
/// `-darkroomEmptyMonthDemo`: the current month with nothing in it and September (121 shots) as
/// the closing row, inside the same four-tab bar `MainTabView` draws. Sign-in is OTP-only, and
/// an account with an empty current month and an older full one is not something a simulator
/// has, so the state is otherwise unreachable.
///
/// The header and the zoom bar are the real ones' parts (`DarkroomZoomBar`, the header's own
/// type), and the body is the real `DarkroomEmptyMonthView`; nothing here touches the network.
struct DarkroomEmptyMonthDemoHost: View {
    @Environment(\.flimAccent) private var accent
    @State private var selection = 1

    private var anchor: DarkroomYearMonth { DarkroomYearMonth(date: .now) }

    private var monthName: String {
        DarkroomDayUnit.monthNameFormatter.string(from: .now)
    }

    /// The month before the current one, standing in for the owner's September.
    private var previousMonth: DarkroomYearMonth {
        let date = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
        return DarkroomYearMonth(date: date)
    }

    var body: some View {
        TabView(selection: $selection) {
            Tab("Camera", systemImage: MainTabSymbol.camera, value: 0) { Color.black }
            Tab("Darkroom", systemImage: MainTabSymbol.darkroom, value: 1) {
                NavigationStack { darkroom }
            }
            Tab("Rolls", systemImage: MainTabSymbol.rolls, value: 2) { Color.black }
            Tab("Feed", systemImage: MainTabSymbol.feed, value: 3) { Color.black }
        }
        .tint(accent)
        .preferredColorScheme(.dark)
    }

    private var darkroom: some View {
        ZStack {
            FlimTheme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text("Darkroom")
                        .flimFont(17, weight: .light, relativeTo: .body)
                        .tracking(0.5)
                        .foregroundStyle(FlimTheme.textSecondary)
                    Text("·")
                        .flimFont(12.5, relativeTo: .footnote)
                        .foregroundStyle(FlimTheme.textTertiary)
                    Text("303 shots")
                        .flimFont(12.5, relativeTo: .footnote)
                        .foregroundStyle(FlimTheme.textTertiary)
                    Spacer()
                    Button("Select") {}
                        .flimFont(15)
                        .foregroundStyle(accent)
                }
                .frame(minHeight: 44)
                .padding(.horizontal, 20)

                DarkroomZoomBar(zoom: .month, anchor: anchor, sub: nil, accent: accent,
                                onZoomOut: {}, onZoomIn: {})

                DarkroomEmptyMonthView(monthName: monthName,
                                       next: (month: previousMonth, shotCount: 121),
                                       onSelectNext: { _ in })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }
}
#endif
