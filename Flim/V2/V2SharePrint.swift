import SwiftUI

/// What a shared print shows and who it belongs to.
struct V2ShareablePrint {
    let path: String
    let takenAt: Date
    let caption: String?
    /// The photographer, named under the print ("FLIM · NADIA.BALI").
    let handle: String
}

/// Share this print (board 12b): the print exported as an object, border, burned-in date, caption
/// and a small wordmark, on Paper, Slate or nothing. It shares an image, never a link back to
/// anyone's page, and the photographer's name is always on it.
struct V2SharePrintView: View {
    let print: V2ShareablePrint

    @Environment(\.dismiss) private var dismiss
    @Environment(\.v2Palette) private var palette
    @Environment(FeedService.self) private var feed

    private enum Behind: String, CaseIterable { case paper = "Paper", slate = "Slate", none = "None" }

    @State private var behind: Behind = .paper
    @State private var showsCaption = true
    @State private var photo: UIImage?
    @State private var file: URL?
    @State private var failed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Text("Cancel").font(V2Type.control()).foregroundStyle(palette.ink3).frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                Spacer()
                Text("Share this print").font(V2Type.serif(15, relativeTo: .subheadline)).accessibilityAddTraits(.isHeader)
                Spacer()
                Group {
                    if let file {
                        ShareLink(item: file) {
                            Text("Share").font(V2Type.control()).underline().frame(minHeight: 44)
                        }
                    } else {
                        Text("Share").font(V2Type.control()).foregroundStyle(palette.ink3).frame(minHeight: 44)
                    }
                }
                .frame(width: 60, alignment: .trailing)
            }
            .padding(.horizontal, V2Metrics.margin)
            Spacer(minLength: 12)
            Group {
                if let photo {
                    V2ShareArtwork(photo: photo, print: print, showsCaption: showsCaption, behind: backdrop)
                        .frame(width: 240, height: 320)
                        .shadow(color: .black.opacity(behind == .none ? 0 : 0.15), radius: 6, y: 3)
                } else if failed {
                    Text("Couldn't load this print.")
                        .font(V2Type.serif(15, italic: true, relativeTo: .body))
                        .foregroundStyle(palette.ink3)
                } else {
                    ProgressView()
                }
            }
            .frame(height: 340)
            Spacer(minLength: 12)
            VStack(spacing: 0) {
                Button { showsCaption.toggle(); Haptics.tap() } label: {
                    HStack {
                        Text("Caption").font(.system(.subheadline))
                        Spacer()
                        Text(showsCaption ? "On" : "Off").font(V2Type.control(.subheadline))
                    }
                    .padding(.vertical, 12)
                    .frame(minHeight: 44)
                    .overlay(alignment: .bottom) { Rectangle().fill(palette.rule).frame(height: 1) }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(print.caption?.isEmpty ?? true)
                .opacity(print.caption?.isEmpty ?? true ? 0.4 : 1)
                HStack {
                    Text("Behind the print").font(.system(.subheadline))
                    Spacer()
                    ForEach(Behind.allCases, id: \.self) { option in
                        Button { behind = option; Haptics.tap() } label: {
                            Text(option.rawValue)
                                .font(V2Type.control(.subheadline))
                                .foregroundStyle(behind == option ? palette.ink : palette.ink3)
                                .padding(.bottom, 2)
                                .overlay(alignment: .bottom) {
                                    if behind == option { Rectangle().fill(palette.ink).frame(height: 1.5) }
                                }
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(behind == option ? .isSelected : [])
                    }
                }
                .overlay(alignment: .bottom) { Rectangle().fill(palette.rule).frame(height: 1) }
            }
            .padding(.horizontal, V2Metrics.margin)
            Text("Shares an image of the print. No link back to anyone's page.")
                .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
                .foregroundStyle(palette.ink3)
                .multilineTextAlignment(.center)
                .padding(V2Metrics.margin)
        }
        .background { V2Desktop(palette: palette) }
        .foregroundStyle(palette.ink)
        .task { await loadPhoto() }
        .task(id: "\(behind.rawValue)\(showsCaption)\(photo != nil)") { render() }
    }

    private var backdrop: Color? {
        switch behind {
        case .paper: V2Palette.paper.background
        case .slate: V2Palette.slate.background
        case .none: nil
        }
    }

    private func loadPhoto() async {
        // The original bytes are usually on the phone already, from opening the print.
        if let data = await DiskImageCache.loadRaw(path: print.path), let image = UIImage(data: data) {
            photo = image
            return
        }
        guard let url = await feed.signedURL(for: print.path),
              let image = await ImageLoader.fetch(url: url, maxPixel: 2048, scale: 1, cacheKey: print.path) else {
            failed = true
            return
        }
        photo = image
    }

    /// Draws the artwork at 1080 wide into a file the share sheet hands on.
    @MainActor
    private func render() {
        guard let photo else { return }
        let renderer = ImageRenderer(content: V2ShareArtwork(photo: photo, print: print, showsCaption: showsCaption,
                                                             behind: backdrop)
            .frame(width: 360, height: 480))
        renderer.scale = 3
        renderer.isOpaque = backdrop != nil
        guard let image = renderer.uiImage,
              let data = backdrop == nil ? image.pngData() : image.jpegData(compressionQuality: 0.92) else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FLIM-print-\(UUID().uuidString.prefix(6)).\(backdrop == nil ? "png" : "jpg")")
        if (try? data.write(to: url, options: .atomic)) != nil { file = url }
    }
}

/// The shared image itself: the print, a little turned, on its backdrop, with the wordmark.
private struct V2ShareArtwork: View {
    let photo: UIImage
    let print: V2ShareablePrint
    let showsCaption: Bool
    let behind: Color?

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width * 0.72
            ZStack {
                if let behind { behind }
                VStack(spacing: proxy.size.height * 0.04) {
                    V2PrintCard(width: width, tilt: .degrees(-2), showsShadow: behind != nil) {
                        Image(uiImage: photo).resizable().scaledToFill()
                            .overlay(alignment: .bottomTrailing) {
                                V2DateStamp(text: BrandedExport.dateText(.init(date: print.takenAt)),
                                            cellHeight: width * 0.04, stamp: .amber)
                                    .padding(.trailing, width * 0.04)
                                    .padding(.bottom, width * 0.035)
                            }
                    } foot: {
                        HStack {
                            if showsCaption, let caption = print.caption, !caption.isEmpty {
                                Text(caption)
                                    .font(V2Type.serif(width * 0.05, italic: true))
                                    .foregroundStyle(V2Color.printInk)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    Text("\(AppInfo.appName) · \(print.handle.uppercased())")
                        .font(V2Type.data(max(7, width * 0.03)))
                        .tracking(width * 0.008)
                        .foregroundStyle(behind == V2Palette.slate.background ? V2Palette.slate.ink3 : V2Palette.paper.ink3)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}
