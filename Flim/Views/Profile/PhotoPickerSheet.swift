import SwiftUI
import PhotosUI

/// The user's Darkroom photos for choosing a profile photo or cover, plus a way in from the
/// device photo library.
///
/// The library option uses `PhotosPicker`, which is backed by the out-of-process system picker,
/// so it needs no photo-library permission and the app only ever receives the one image the user
/// chose. That's why there's no Info.plist usage string to go with this.
struct PhotoPickerSheet: View {
    @Environment(\.flimAccent) private var accent
    let title: String
    let onPick: (String) -> Void   // the chosen photo's storage path
    /// Raw data for a photo picked from the device library. Omit to offer Darkroom photos only.
    var onPickLibraryImage: ((Data) -> Void)? = nil
    /// When set, BOTH sources route through a 1:1 crop step and deliver the cropped JPEG bytes
    /// here instead of calling `onPick` / `onPickLibraryImage`.
    ///
    /// The crop is presented from inside this sheet rather than from the caller, so a Darkroom
    /// pick and a library pick converge on one path, and so the cropper isn't racing this sheet's
    /// own dismissal (presenting a cover from the parent while a sheet is dismissing drops it).
    var onPickCropped: ((Data) -> Void)? = nil

    @Environment(AuthService.self) private var auth
    @Environment(PhotoService.self) private var photoService
    @Environment(\.dismiss) private var dismiss

    @State private var photos: [Photo] = []
    @State private var urls: [UUID: URL] = [:]
    @State private var loaded = false
    @State private var libraryItem: PhotosPickerItem?
    @State private var importing = false
    @State private var cropSource: CropSource?

    /// Identifiable so the cropper can be presented with `fullScreenCover(item:)`, which ties the
    /// presentation to the data instead of to a separate bool that can drift out of sync with it.
    private struct CropSource: Identifiable {
        let id = UUID()
        let data: Data
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)

    var body: some View {
        NavigationStack {
            ZStack {
                FlimTheme.bg.ignoresSafeArea()
                if photos.isEmpty && loaded {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 30, weight: .ultraLight)).foregroundStyle(FlimTheme.textTertiary)
                        Text("No photos in your Darkroom yet")
                            .flimFont(14, relativeTo: .subheadline).foregroundStyle(FlimTheme.textTertiary)
                        if onPickLibraryImage != nil || onPickCropped != nil {
                            // Used to be a dead end for anyone who hadn't shot yet.
                            Text("Choose one from your library below.")
                                .flimFont(13, relativeTo: .footnote).foregroundStyle(FlimTheme.textTertiary)
                        }
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 3) {
                            ForEach(photos) { photo in
                                Button {
                                    choose(photo)
                                } label: {
                                    Color.clear
                                        .aspectRatio(1, contentMode: .fit)
                                        .overlay {
                                            CachedImage(url: urls[photo.id], maxPixel: 400) { $0.resizable().scaledToFill() }
                                                placeholder: { ShimmerPlaceholder(cornerRadius: 4) }
                                        }
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(3)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .flimInlineTitle(title)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                // Either delivery route offers the library. Gating this on `onPickLibraryImage`
                // alone would hide the button entirely from the cropping callers, which pass only
                // `onPickCropped`.
                if onPickLibraryImage != nil || onPickCropped != nil {
                    PhotosPicker(selection: $libraryItem, matching: .images, photoLibrary: .shared()) {
                        Label(importing ? "Adding…" : "Choose from Library", systemImage: "photo.on.rectangle")
                            .flimFont(15, weight: .semibold)
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(accent, in: Capsule())
                    }
                    .disabled(importing)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .onChange(of: libraryItem) { _, item in
                        guard let item else { return }
                        importing = true
                        Task {
                            // loadTransferable hands back the ORIGINAL file bytes, which for a
                            // modern iPhone shot is several MB of HEIC. AuthService downscales
                            // before upload, so nothing that size is ever stored or served.
                            let data = try? await item.loadTransferable(type: Data.self)
                            importing = false
                            libraryItem = nil
                            guard let data else { Haptics.error(); return }
                            Haptics.tap()
                            if onPickCropped != nil {
                                cropSource = CropSource(data: data)
                            } else {
                                onPickLibraryImage?(data)
                                dismiss()
                            }
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }.foregroundStyle(.white)
                }
            }
            .fullScreenCover(item: $cropSource) { source in
                SquareCropSheet(imageData: source.data, title: title) { cropped in
                    onPickCropped?(cropped)
                    dismiss()
                }
            }
            .task {
                guard let uid = auth.currentUser?.id else { loaded = true; return }
                photos = await photoService.fetchDarkroom(userId: uid)
                loaded = true
                // One batched call rather than one round trip per photo: this grid can hold a
                // whole Darkroom, so the thumbnails used to fill in one by one, top to bottom.
                let map = await photoService.signedURLs(for: photos.map(\.storagePath))
                for photo in photos { urls[photo.id] = map[photo.storagePath] }
            }
        }
        .presentationBackground(FlimTheme.bg)
    }

    /// A Darkroom photo goes straight through unless a crop was requested, in which case its
    /// bytes are fetched first so the cropper has something to show. The spinner state is shared
    /// with the library import, so only one import can be in flight either way.
    private func choose(_ photo: Photo) {
        guard onPickCropped != nil else {
            onPick(photo.storagePath)
            dismiss()
            return
        }
        guard !importing else { return }
        importing = true
        Task {
            let data = await auth.imageData(atPath: photo.storagePath)
            importing = false
            guard let data else { Haptics.error(); return }
            Haptics.tap()
            cropSource = CropSource(data: data)
        }
    }
}

/// A full-screen image viewer with pinch + double-tap zoom and pan.
struct ImageViewer: View {
    let url: URL?
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    /// The scale the photo was resting at when the current pinch started, so releasing returns it
    /// there. Nil when no pinch is in flight.
    @State private var pinchStart: CGFloat?
    /// Where the current pinch went down, so the photo grows from there instead of its middle.
    @State private var zoomAnchor: UnitPoint = .center

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let url {
                CachedImage(url: url, maxPixel: 1600) { image in
                    image.resizable().scaledToFit()
                        .scaleEffect(scale, anchor: zoomAnchor).offset(offset)
                        .gesture(dragGesture).gesture(pinch)
                        .onTapGesture(count: 2) {
                            zoomAnchor = .center
                            withAnimation(.spring(duration: 0.3)) {
                                if scale > 1 { scale = 1; offset = .zero; lastOffset = .zero } else { scale = 2.5 }
                            }
                        }
                } placeholder: { ProgressView().tint(.white) }
            }
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white).padding(12).glassCapsule(interactive: true)
                    }
                    .accessibilityLabel("Close")
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.top, 20)
                Spacer()
            }
        }
        .statusBarHidden()
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if scale > 1 {
                    offset = CGSize(width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height)
                } else { offset = value.translation }
            }
            .onEnded { value in
                if scale > 1 { lastOffset = offset }
                else if abs(value.translation.height) > 120 { dismiss() }
                else { withAnimation(.spring(duration: 0.3)) { offset = .zero } }
            }
    }

    /// Transient, matching every other photo in the app: pinch to look closer, let go and it
    /// settles back to where it was resting. Double tap is the hold.
    private var pinch: some Gesture {
        TransientPinch(scale: $scale, anchor: $zoomAnchor, restingScale: $pinchStart) { resting in
            if resting <= 1 { offset = .zero; lastOffset = .zero }
        }
    }
}
