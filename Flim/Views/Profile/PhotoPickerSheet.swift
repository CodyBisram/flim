import SwiftUI
import PhotosUI

/// The user's Darkroom photos for choosing a profile photo or cover, plus a way in from the
/// device photo library.
///
/// The library option uses `PhotosPicker`, which is backed by the out-of-process system picker,
/// so it needs no photo-library permission and the app only ever receives the one image the user
/// chose. That's why there's no Info.plist usage string to go with this.
struct PhotoPickerSheet: View {
    let title: String
    let onPick: (String) -> Void   // the chosen photo's storage path
    /// Raw data for a photo picked from the device library. Omit to offer Darkroom photos only.
    var onPickLibraryImage: ((Data) -> Void)? = nil

    @Environment(AuthService.self) private var auth
    @Environment(PhotoService.self) private var photoService
    @Environment(\.dismiss) private var dismiss

    @State private var photos: [Photo] = []
    @State private var urls: [UUID: URL] = [:]
    @State private var loaded = false
    @State private var libraryItem: PhotosPickerItem?
    @State private var importing = false

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
                            .font(.system(size: 14)).foregroundStyle(FlimTheme.textTertiary)
                        if onPickLibraryImage != nil {
                            // Used to be a dead end for anyone who hadn't shot yet.
                            Text("Choose one from your library below.")
                                .font(.system(size: 13)).foregroundStyle(FlimTheme.textTertiary)
                        }
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 3) {
                            ForEach(photos) { photo in
                                Button {
                                    onPick(photo.storagePath)
                                    dismiss()
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
                if let onPickLibraryImage {
                    PhotosPicker(selection: $libraryItem, matching: .images, photoLibrary: .shared()) {
                        Label(importing ? "Adding…" : "Choose from Library", systemImage: "photo.on.rectangle")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(FlimTheme.accent, in: Capsule())
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
                            onPickLibraryImage(data)
                            dismiss()
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }.foregroundStyle(.white)
                }
            }
            .task {
                guard let uid = auth.currentUser?.id else { loaded = true; return }
                photos = await photoService.fetchDarkroom(userId: uid)
                loaded = true
                for photo in photos {
                    urls[photo.id] = try? await photoService.signedURL(for: photo.storagePath)
                }
            }
        }
        .presentationBackground(FlimTheme.bg)
    }
}

/// A full-screen image viewer with pinch + double-tap zoom and pan.
struct ImageViewer: View {
    let url: URL?
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let url {
                CachedImage(url: url, maxPixel: 1600) { image in
                    image.resizable().scaledToFit()
                        .scaleEffect(scale).offset(offset)
                        .gesture(dragGesture).gesture(pinch)
                        .onTapGesture(count: 2) {
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

    private var pinch: some Gesture {
        MagnificationGesture()
            .onChanged { scale = max(1, $0) }
            .onEnded { _ in withAnimation(.spring(duration: 0.3)) { if scale < 1.2 { scale = 1; offset = .zero; lastOffset = .zero } } }
    }
}
