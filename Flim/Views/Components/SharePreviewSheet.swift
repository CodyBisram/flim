import SwiftUI
import UniformTypeIdentifiers

/// Wraps the outgoing photo so ShareLink exports JPEG. (Sharing a SwiftUI `Image` directly
/// exports PNG, ~10× the bytes for a photo, which makes Messages/AirDrop shares slow.)
struct SharedPhoto: Transferable {
    let image: UIImage
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .jpeg) { photo in
            photo.image.jpegData(compressionQuality: 0.9) ?? Data()
        }
    }
}

/// Which artifact leaves the app.
///
/// Three named outputs, one row, one decision. Note what is deliberately absent: plain at 9:16.
/// Frame × ratio would be four cells and a two-axis mental model, and the two axes are not
/// independent in practice — a plain photo is what you send to Messages or save to Photos, and a
/// story is a designed canvas.
enum ShareFormat: String, CaseIterable {
    case print, story, plain

    var label: String {
        switch self {
        case .print: "Print"
        case .story: "Story"
        case .plain: "Plain"
        }
    }

    var ratio: String {
        switch self {
        case .print, .plain: "3:4"
        case .story: "9:16"
        }
    }

    /// The button names the artifact, so you know what leaves.
    var action: String {
        switch self {
        case .print: "Share print"
        case .story: "Share story"
        case .plain: "Share photo"
        }
    }
}

/// Pre-share sheet: the photo as one of three artifacts, chosen from live thumbnails at their
/// true aspect. The choice is remembered.
///
/// This replaced a single "FLIM print frame" toggle. A switch was a settings row explaining what
/// the preview already showed, and it could not express a second axis at all; three thumbnails
/// state the shape by BEING that shape.
struct SharePreviewSheet: View {
    @Environment(\.flimAccent) private var accent
    let photo: UIImage
    /// What the footer writes on the print. Nil at every call site until the metadata is plumbed
    /// through, which is why `BrandedExport.print` still centres the wordmark on its own.
    var caption: BrandedExport.Caption?

    @AppStorage("shareExportFormat") private var formatRaw = ShareFormat.print.rawValue
    @Environment(\.dismiss) private var dismiss

    /// Rendered once each, off-main. `plain` needs no render.
    @State private var printImage: UIImage?
    @State private var storyImage: UIImage?

    private var format: ShareFormat { ShareFormat(rawValue: formatRaw) ?? .print }

    /// The exact image that will leave. Falls back to the plain photo while a render is still in
    /// flight, so the sheet always shows the photograph rather than a spinner.
    private var outgoing: UIImage {
        switch format {
        case .print: printImage ?? photo
        case .story: storyImage ?? photo
        case .plain: photo
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar

            // The preview: whatever is selected, at its true aspect.
            Spacer(minLength: 0)
            preview
                .padding(.vertical, 18)
            Spacer(minLength: 0)

            chooser
                .padding(.horizontal, 20)
                .padding(.bottom, 4)

            shareButton
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 40)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .flimSheetSurface()
        .task {
            migrateLegacyChoice()
            // One decode, two renders, print first because the story is placed FROM it.
            let source = photo
            let cap = caption
            let rendered = await Task.detached(priority: .userInitiated) {
                BrandedExport.print(source, caption: cap)
            }.value
            printImage = rendered
            storyImage = await Task.detached(priority: .userInitiated) {
                BrandedExport.story(print: rendered)
            }.value
        }
    }

    /// X dismisses, title centres. The old trailing "Done" was wrong for this sheet: it commits
    /// nothing, so there was nothing to be done with.
    private var titleBar: some View {
        ZStack {
            Text("Share")
                .flimFont(16, weight: .medium, relativeTo: .body)
                .foregroundStyle(.white)
            HStack {
                Button { Haptics.tap(); dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 19, weight: .regular))
                        .foregroundStyle(FlimTheme.textTertiary)
                }
                .accessibilityLabel("Close")
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    @ViewBuilder
    private var preview: some View {
        switch format {
        case .print:
            Image(uiImage: outgoing)
                .resizable()
                .scaledToFit()
                .shadow(color: .black.opacity(0.55), radius: 17, y: 14)
                .padding(.horizontal, 36)
        case .story:
            // The 9:16 box is HELD from the first frame rather than adopted when the render
            // lands. Until then `outgoing` is the plain photo, which is 3:4, and letting the
            // preview take its shape opened the bordered canvas at 3:4 and snapped it to 9:16 a
            // beat later — on every open, for anyone whose remembered format is story. The
            // placeholder photo just sits inside the real canvas instead.
            ZStack {
                Color.clear
                Image(uiImage: outgoing)
                    .resizable()
                    .scaledToFit()
            }
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
            // Without a hairline the canvas bounds vanish into the sheet and the story reads
            // as a floating print rather than a designed 9:16 artifact.
            .overlay(Rectangle().strokeBorder(Color(red: 0.204, green: 0.216, blue: 0.290),
                                              lineWidth: 1))
            .shadow(color: .black.opacity(0.55), radius: 17, y: 14)
            .padding(.horizontal, 36)
        case .plain:
            Image(uiImage: outgoing)
                .resizable()
                .scaledToFit()
                // Rounded in the PREVIEW only, so it reads as a screen object rather than a
                // print. The exported file has square corners.
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.55), radius: 17, y: 14)
                .padding(.horizontal, 36)
        }
    }

    private var chooser: some View {
        HStack(spacing: 14) {
            ForEach(ShareFormat.allCases, id: \.self) { option in
                chooserCell(option)
            }
            Spacer(minLength: 0)
        }
    }

    private func chooserCell(_ option: ShareFormat) -> some View {
        let selected = option == format
        return Button {
            guard option != format else { return }
            Haptics.tap()
            withAnimation(.snappy(duration: 0.25)) { formatRaw = option.rawValue }
        } label: {
            VStack(spacing: 6) {
                thumb(option)
                    .frame(height: 64)
                    .overlay {
                        if selected {
                            Rectangle().stroke(accent, lineWidth: 1)
                                .padding(-0.5)
                        } else {
                            Rectangle().stroke(Color(white: 0.26), lineWidth: 1)
                                .padding(-0.5)
                        }
                    }
                    // The selection halo, outside the ring.
                    .overlay {
                        if selected {
                            Rectangle().stroke(accent.opacity(0.18), lineWidth: 3)
                                .padding(-2.5)
                        }
                    }
                Text(option.label)
                    .flimFont(11, weight: .medium, relativeTo: .caption2)
                    .foregroundStyle(selected ? accent : FlimTheme.textTertiary)
                Text(option.ratio)
                    .flimFont(9.5, relativeTo: .caption2)
                    .foregroundStyle(FlimTheme.textTertiary)
            }
            .frame(width: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(option.label), \(option.ratio)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// Each thumbnail is the format's own shape, built from the photo rather than from a render:
    /// three more full renders to fill a 48pt box would be work nobody sees.
    @ViewBuilder
    private func thumb(_ option: ShareFormat) -> some View {
        switch option {
        case .print:
            miniPrint(width: 48, padding: 2)
        case .story:
            ZStack {
                Color(red: 0.071, green: 0.075, blue: 0.122)
                miniPrint(width: 28, padding: 1.5)
            }
            .frame(width: 36, height: 64)
        case .plain:
            Image(uiImage: photo)
                .resizable()
                .scaledToFill()
                .frame(width: 48, height: 64)
                .clipped()
        }
    }

    /// A miniature of the print: paper, the photo at 3:4, and the sliver of footer below it.
    private func miniPrint(width: CGFloat, padding: CGFloat) -> some View {
        VStack(spacing: 0) {
            Image(uiImage: photo)
                .resizable()
                .scaledToFill()
                .frame(width: width - padding * 2, height: (width - padding * 2) * 4 / 3)
                .clipped()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, padding)
        .padding(.top, padding)
        // 3:4, the same outer the real file has, so the thumbnail is the shape it describes.
        .frame(width: width, height: width * 4 / 3)
        .background(Color(red: 0.955, green: 0.945, blue: 0.915))
    }

    private var shareButton: some View {
        ShareLink(
            item: SharedPhoto(image: outgoing),
            preview: SharePreview("Photo", image: Image(uiImage: outgoing))
        ) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 18, weight: .regular))
                Text(format.action)
                    .flimFont(15, weight: .medium, relativeTo: .body)
                    .contentTransition(.opacity)
            }
            .foregroundStyle(accent)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            // Outlined, not the filled accent capsule this sheet used to have: it matches the
            // reveal's own primary and lets the print be the only bright thing on the sheet.
            .overlay(Capsule().strokeBorder(accent, lineWidth: 1))
        }
        .simultaneousGesture(TapGesture().onEnded { Haptics.tap() })
    }

    /// The frame toggle was a Bool. Carry the remembered answer over exactly once, so nobody who
    /// had turned the frame off opens this sheet to find it back on.
    private func migrateLegacyChoice() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "shareExportFormat") == nil,
              defaults.object(forKey: "shareWithFrame") != nil else { return }
        formatRaw = defaults.bool(forKey: "shareWithFrame") ? ShareFormat.print.rawValue
                                                            : ShareFormat.plain.rawValue
    }
}
