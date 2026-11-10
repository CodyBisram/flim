import SwiftUI

/// 1.7's tab bar (the Blend board, 1c): five tabs on a solid pill in the box tone, no glass.
/// Darkroom, Rolls, Camera in the middle, Feed, You. The active tab takes ink and a 1.5pt
/// underline under its label; the camera is the one filled circle, amber while it is showing.
///
/// The tab values are `MainTabView`'s own (0 camera, 1 darkroom, 2 rolls, 3 feed), plus 4 for
/// You, so every route that picks a tab works unchanged.
struct DeskTabBar: View {
    @Binding var selection: Int
    /// A red dot: something new behind the tab (owner rule: every "something new" dot is red).
    var rollsDot: Bool
    var feedDot: Bool
    var youDot: Bool
    var avatarURL: URL?
    var avatarKey: String?
    var initial: String

    /// The Duo's rail (Blend 2, 6a to 6j): the same five, stood up on one edge.
    var vertical = false

    @Environment(\.flimAccent) private var accent
    @Environment(\.dynamicTypeSize) private var typeSize

    /// At accessibility text sizes the bar grows and its labels go, as iOS does for its own tab
    /// bars (Blend 4, 16b); holding a tab shows its name large (the Large Content Viewer), and
    /// VoiceOver reads every tab by name at any size.
    private var large: Bool { typeSize.isAccessibilitySize }

    /// The bar's height for a text size, for the space each tab keeps clear under it.
    static func height(for size: DynamicTypeSize) -> CGFloat { size.isAccessibilitySize ? 84 : height }

    static let camera = 0, darkroom = 1, rolls = 2, feed = 3, you = 4
    /// The bar's height without the home indicator, for screens that need to sit above it.
    static let height: CGFloat = 64
    /// Space between the bar and the home indicator's safe area.
    static let bottomGap: CGFloat = 4
    /// The rail's width, and the gap between it and the display's edge.
    static let railWidth: CGFloat = 76
    static let railGap: CGFloat = 14

    @ViewBuilder
    var body: some View {
        if vertical {
            VStack(spacing: 0) {
                items
            }
            .padding(.vertical, 8)
            .frame(width: Self.railWidth)
            .frame(maxHeight: .infinity)
            .background(Capsule().fill(DeskColor.box))
            .padding(.vertical, 12)
        } else {
            HStack(spacing: 0) {
                items
            }
            .padding(.horizontal, 6)
            .frame(height: Self.height(for: typeSize))
            .background(Capsule().fill(DeskColor.box))
            .padding(.horizontal, 16)
            .padding(.bottom, Self.bottomGap)
        }
    }

    @ViewBuilder
    private var items: some View {
        item(Self.darkroom, "Darkroom", symbol: MainTabSymbol.darkroom, dot: false)
        item(Self.rolls, "Rolls", symbol: MainTabSymbol.rolls, dot: rollsDot)
        cameraButton
        item(Self.feed, "Feed", symbol: MainTabSymbol.feed, dot: feedDot)
        youItem
    }

    private func tap(_ value: Int) {
        // Through the binding, so MainTabView's haptic and re-tap-to-top still run.
        selection = value
    }

    private func item(_ value: Int, _ title: String, symbol: String, dot: Bool) -> some View {
        let active = selection == value
        return Button { tap(value) } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: large ? 26 : 17, weight: .regular))
                    .frame(height: large ? 30 : 22)
                    .overlay(alignment: .topTrailing) { if dot { Self.redDot.offset(x: 5, y: -1) } }
                if large {
                    Rectangle().fill(active ? DeskColor.ink : .clear).frame(width: 18, height: 1.5)
                } else {
                    label(title, active: active)
                }
            }
            .foregroundStyle(active ? DeskColor.ink : DeskColor.ink3)
            .frame(maxWidth: .infinity, maxHeight: vertical ? .infinity : nil)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(dot ? "New" : "")
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityShowsLargeContentViewer { Label(title, systemImage: symbol) }
    }

    private func label(_ title: String, active: Bool) -> some View {
        // Fixed size: the bar is fixed chrome, and the labels sit in a fixed-height pill.
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(active ? DeskColor.ink : .clear)
                    .frame(height: 1.5)
                    .offset(y: 3)
            }
    }

    private var cameraButton: some View {
        let active = selection == Self.camera
        return Button { tap(Self.camera) } label: {
            Circle()
                .fill(active ? accent : DeskColor.solid)
                .frame(width: large ? 62 : 52, height: large ? 62 : 52)
                .overlay {
                    Image(systemName: MainTabSymbol.camera)
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(active ? Color(white: 0.1) : DeskColor.onSolid)
                }
                .frame(maxWidth: .infinity, maxHeight: vertical ? .infinity : nil)
                .frame(minHeight: 52)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Camera")
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityShowsLargeContentViewer { Label("Camera", systemImage: MainTabSymbol.camera) }
    }

    private var youItem: some View {
        let active = selection == Self.you
        return Button { tap(Self.you) } label: {
            VStack(spacing: 4) {
                Circle()
                    .fill(accent)
                    .frame(width: 22, height: 22)
                    .overlay {
                        if let avatarURL {
                            CachedImage(url: avatarURL, maxPixel: 66, cacheKey: avatarKey) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                                .clipShape(Circle())
                        } else {
                            Text(initial)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Color(white: 0.1))
                        }
                    }
                    .padding(2)
                    .overlay { Circle().strokeBorder(active ? DeskColor.ink : .clear, lineWidth: 1.5) }
                    .frame(height: 26)
                    .overlay(alignment: .topTrailing) { if youDot { Self.redDot.offset(x: 2, y: 0) } }
                    .frame(height: 22)
                if large {
                    Rectangle().fill(active ? DeskColor.ink : .clear).frame(width: 18, height: 1.5)
                } else {
                    label("You", active: active)
                }
            }
            .foregroundStyle(active ? DeskColor.ink : DeskColor.ink3)
            .frame(maxWidth: .infinity, maxHeight: vertical ? .infinity : nil)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("You")
        .accessibilityValue(youDot ? "New" : "")
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityShowsLargeContentViewer { Label("You", systemImage: "person.crop.circle") }
    }

    static var redDot: some View {
        Circle().fill(FlimTheme.newRed).frame(width: 7, height: 7)
    }
}
