import SwiftUI

/// The plain swipe-to-dismiss every full-screen photo surface in the app that is NOT a paging
/// `TabView` uses: drag anywhere, the content follows the finger 1:1, and letting go past
/// `RevealPacing.dismissThreshold` dismisses; short of it, it springs back to rest.
///
/// Extracted from `ImageViewer`'s own drag gesture (the avatar/photo-picker viewer) so it and
/// `ChapterRecapView`'s opening card share the exact same feel rather than two hand-rolled copies
/// of the same threshold. `ImageViewer` keeps `isEnabled` to stand this down while its own
/// pan-while-zoomed gesture owns the same drag instead.
///
/// Deliberately NOT applied to a native `TabView(.page)` pager. `PhotoPagerView.pagerCore` and
/// `RollRevealView`'s own playback both used to carry a vertical drag-to-dismiss riding alongside
/// their pager, and both removed it for the same reason: a second gesture recognizer tracking
/// touches simultaneously with a native paging `UIScrollView`, even one that only acts on a
/// vertical component, visibly damps the paging physics on device. A pager that wants a way out
/// uses its own close button, the same as those two do; do not attach this to one.
private struct SwipeToDismissModifier: ViewModifier {
    @Binding var offset: CGSize
    var isEnabled: Bool = true
    let onDismiss: () -> Void

    func body(content: Content) -> some View {
        content
            .offset(offset)
            .gesture(
                DragGesture()
                    .onChanged { offset = $0.translation }
                    .onEnded { value in
                        if RevealPacing.shouldDismiss(translation: value.translation) {
                            onDismiss()
                        } else {
                            withAnimation(.spring(duration: 0.3)) { offset = .zero }
                        }
                    },
                including: isEnabled ? .all : .none
            )
    }
}

extension View {
    /// Applies the app's plain swipe-to-dismiss. `offset` is the caller's own state, so a surface
    /// with its own zoom (like `ImageViewer`) can share it with a pan-while-zoomed gesture rather
    /// than tracking two competing offsets.
    func swipeToDismiss(offset: Binding<CGSize>, isEnabled: Bool = true,
                         onDismiss: @escaping () -> Void) -> some View {
        modifier(SwipeToDismissModifier(offset: offset, isEnabled: isEnabled, onDismiss: onDismiss))
    }
}
