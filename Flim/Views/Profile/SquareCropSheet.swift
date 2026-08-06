import SwiftUI

/// Lets the user choose WHICH square of a photo becomes their profile picture, by dragging and
/// pinching it inside a fixed square window.
///
/// Before this, a picked photo was centre-cropped by the downscaler, so anyone whose face wasn't
/// dead centre got a profile picture of their shoulder. The window is square and the guide is a
/// circle because that is how avatars are actually drawn everywhere in the app, so what you frame
/// is what you get.
///
/// All coordinate maths lives in `ProfileCropGeometry`; this view owns the gestures and the pixels.
struct SquareCropSheet: View {
    @Environment(\.flimAccent) private var accent
    let imageData: Data
    var title: String = "Move and scale"
    let onUse: (Data) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var image: UIImage?
    @State private var failed = false
    @State private var working = false

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var laidOutSide: CGFloat = 0

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if let image {
                    GeometryReader { geo in
                        let side = windowSide(in: geo.size)
                        cropWindow(image: image, side: side)
                            .frame(width: geo.size.width, height: geo.size.height)
                            // The crop is computed from the side the window was actually laid out
                            // at, recorded here. Recomputing it from the screen bounds at save
                            // time would quietly disagree with this by the safe-area and toolbar
                            // insets, and crop a slightly different square than the one framed.
                            .onAppear { laidOutSide = side }
                            .onChange(of: side) { _, new in laidOutSide = new }
                    }
                } else if failed {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 30, weight: .ultraLight))
                        Text("That photo couldn't be opened")
                            .flimFont(14, relativeTo: .subheadline)
                    }
                    .foregroundStyle(FlimTheme.textTertiary)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .flimInlineTitle(title)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(.white)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(working ? "Saving…" : "Use") { use() }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(image == nil || working ? FlimTheme.textTertiary : accent)
                        .disabled(image == nil || working)
                }
            }
            .task { await load() }
        }
        .presentationBackground(.black)
    }

    // MARK: - Window

    /// The square is as wide as the screen allows, minus a margin, and never taller than 62% of
    /// the height so the toolbar and the hint below it stay clear on a small phone.
    private func windowSide(in size: CGSize) -> CGFloat {
        max(120, min(size.width - 32, size.height * 0.62))
    }

    private func cropWindow(image: UIImage, side: CGFloat) -> some View {
        let pixels = image.size
        let base = ProfileCropGeometry.baseScale(imageSize: pixels, windowSide: side)

        return VStack(spacing: 18) {
            Spacer(minLength: 0)

            Image(uiImage: image)
                .resizable()
                .frame(width: pixels.width * base, height: pixels.height * base)
                .scaleEffect(scale)
                .offset(offset)
                .frame(width: side, height: side)
                .clipped()
                // The circle is a guide, not the crop: the stored image is the full square, so a
                // square avatar somewhere else in the app still looks deliberate.
                .overlay {
                    Circle()
                        .strokeBorder(.white.opacity(0.9), lineWidth: 1)
                        .background(Circle().stroke(.black.opacity(0.25), lineWidth: 3))
                }
                .overlay(Rectangle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                .contentShape(Rectangle())
                .gesture(drag(imageSize: pixels, side: side)
                    .simultaneously(with: pinch(imageSize: pixels, side: side)))
                .accessibilityLabel("Drag to reposition, pinch to zoom")

            Text("Drag to reposition · pinch to zoom")
                .flimFont(13, relativeTo: .footnote)
                .foregroundStyle(FlimTheme.textTertiary)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Gestures

    private func drag(imageSize: CGSize, side: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let proposed = CGSize(width: lastOffset.width + value.translation.width,
                                      height: lastOffset.height + value.translation.height)
                offset = ProfileCropGeometry.clampedOffset(
                    proposed, imageSize: imageSize, windowSide: side, scale: scale)
            }
            .onEnded { _ in lastOffset = offset }
    }

    private func pinch(imageSize: CGSize, side: CGFloat) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = ProfileCropGeometry.clampedScale(lastScale * value)
                // Re-clamp the drag as we zoom OUT, otherwise an offset that was legal at 4x
                // leaves the image pulled off the window edge at 1x.
                offset = ProfileCropGeometry.clampedOffset(
                    offset, imageSize: imageSize, windowSide: side, scale: scale)
                lastOffset = offset
            }
            .onEnded { _ in
                lastScale = scale
                lastOffset = offset
            }
    }

    // MARK: - Pixels

    private func load() async {
        let prepared = await Task.detached(priority: .userInitiated) {
            Self.workingImage(from: imageData)
        }.value
        await MainActor.run {
            image = prepared
            failed = prepared == nil
        }
    }

    /// Decodes to a manageable, orientation-normalised image.
    ///
    /// Normalising matters more than it looks: a photo shot in portrait carries an EXIF
    /// orientation, and `CGImage.cropping(to:)` works in raw pixel space that ignores it. Without
    /// this the crop would come out rotated relative to what the user framed. Downscaling first
    /// keeps a 12MP HEIC from being held in memory at full size for a 512px avatar.
    /// `nonisolated` because it is called from a detached task, deliberately: it decodes and
    /// redraws a full-resolution image and has no business doing that on the main actor. Views are
    /// `@MainActor` by default, so without this the call crosses isolation, which is a warning in
    /// Swift 5 and an ERROR in Swift 6. It touches no view state, only its argument.
    nonisolated private static func workingImage(from data: Data) -> UIImage? {
        let source = InstantFilmProcessor.rendition(from: data, longEdge: 2048, quality: 0.95) ?? data
        guard let decoded = UIImage(data: source) else { return nil }
        guard decoded.imageOrientation != .up || decoded.scale != 1 else { return decoded }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: decoded.size, format: format).image { _ in
            decoded.draw(in: CGRect(origin: .zero, size: decoded.size))
        }
    }

    private func use() {
        guard let image, let cg = image.cgImage, !working, laidOutSide > 0 else { return }
        working = true

        let rect = ProfileCropGeometry.cropRect(
            imageSize: image.size, windowSide: laidOutSide, scale: scale, offset: offset)

        Task.detached(priority: .userInitiated) {
            guard let cropped = cg.cropping(to: rect.integral),
                  let data = InstantFilmProcessor.jpegData(from: cropped, quality: 0.92)
            else {
                await MainActor.run { working = false; Haptics.error() }
                return
            }
            await MainActor.run {
                Haptics.tap()
                onUse(data)
                dismiss()
            }
        }
    }
}
