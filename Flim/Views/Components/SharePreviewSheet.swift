import SwiftUI

/// Pre-share sheet: a live preview of the photo with a toggle for the FLIM print frame
/// (warm border + wordmark). The choice is remembered for next time. Sharing hands the
/// exact previewed image to the system share sheet.
struct SharePreviewSheet: View {
    let photo: UIImage

    @AppStorage("shareWithFrame") private var withFrame = true
    @Environment(\.dismiss) private var dismiss
    @State private var framed: UIImage?   // rendered once, cached

    private var outgoing: UIImage { withFrame ? (framed ?? photo) : photo }

    var body: some View {
        NavigationStack {
            ZStack {
                FlimTheme.bg.ignoresSafeArea()
                VStack(spacing: 22) {
                    Spacer(minLength: 8)

                    // Live preview — swaps between the plain photo and the framed print.
                    Image(uiImage: outgoing)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: withFrame ? 4 : 14))
                        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
                        .padding(.horizontal, 36)
                        .animation(.snappy(duration: 0.25), value: withFrame)

                    // The frame toggle, as a tappable card.
                    Button {
                        Haptics.tap()
                        withAnimation(.snappy(duration: 0.25)) { withFrame.toggle() }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "photo.artframe")
                                .font(.system(size: 18, weight: .light))
                                .foregroundStyle(withFrame ? FlimTheme.accent : FlimTheme.textTertiary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(AppInfo.appName) print frame")
                                    .font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                                Text(withFrame ? "Shared as an instant print" : "Shared as the plain photo")
                                    .font(.system(size: 12)).foregroundStyle(FlimTheme.textTertiary)
                                    .contentTransition(.opacity)
                            }
                            Spacer()
                            Toggle("", isOn: $withFrame.animation(.snappy(duration: 0.25)))
                                .labelsHidden()
                                .tint(FlimTheme.accent)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .background(FlimTheme.bgElevated, in: RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 24)
                    }
                    .buttonStyle(.plain)

                    // Hand the previewed image to the system share sheet.
                    ShareLink(
                        item: Image(uiImage: outgoing),
                        preview: SharePreview("Photo", image: Image(uiImage: outgoing))
                    ) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(FlimTheme.accent, in: Capsule())
                            .padding(.horizontal, 24)
                    }
                    .simultaneousGesture(TapGesture().onEnded { Haptics.tap() })

                    Spacer(minLength: 12)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .flimInlineTitle("Share")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.tint(FlimTheme.accent)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task {
            // Render the framed print off-main once; the toggle then swaps instantly.
            let source = photo
            framed = await Task.detached(priority: .userInitiated) {
                BrandedExport.framed(source)
            }.value
        }
    }
}
