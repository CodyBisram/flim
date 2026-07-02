import SwiftUI

/// A dark placeholder box with a soft highlight sweeping across it — shown where content
/// (usually a photo) will appear while it loads, so the layout is stable and the wait reads
/// as intentional rather than broken.
struct ShimmerPlaceholder: View {
    var cornerRadius: CGFloat = 8
    @State private var animate = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(FlimTheme.bgElevated)
            .overlay {
                GeometryReader { geo in
                    let w = geo.size.width
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.10), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: w * 0.55)
                    .offset(x: animate ? w * 0.9 : -w * 0.55)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .onAppear {
                withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) {
                    animate = true
                }
            }
            .accessibilityHidden(true)
    }
}

extension View {
    /// Applies a sweeping shimmer highlight over the view (for custom skeleton shapes).
    func shimmering() -> some View { modifier(ShimmerModifier()) }
}

private struct ShimmerModifier: ViewModifier {
    @State private var animate = false
    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geo in
                    let w = geo.size.width
                    LinearGradient(colors: [.clear, Color.white.opacity(0.10), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: w * 0.55)
                        .offset(x: animate ? w * 0.9 : -w * 0.55)
                }
                .allowsHitTesting(false)
            }
            .onAppear {
                withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) { animate = true }
            }
    }
}
