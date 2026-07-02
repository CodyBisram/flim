import SwiftUI

/// A grid of the user's Darkroom photos for choosing a profile photo or cover.
struct PhotoPickerSheet: View {
    let title: String
    let onPick: (String) -> Void   // the chosen photo's storage path

    @Environment(AuthService.self) private var auth
    @Environment(PhotoService.self) private var photoService
    @Environment(\.dismiss) private var dismiss

    @State private var photos: [Photo] = []
    @State private var urls: [UUID: URL] = [:]
    @State private var loaded = false

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
