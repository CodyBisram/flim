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

/// A tappable full-screen viewer for a single image (e.g. a profile photo).
struct ImageViewer: View {
    let url: URL?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let url {
                CachedImage(url: url, maxPixel: 1200) { $0.resizable().scaledToFit() } placeholder: { ProgressView().tint(.white) }
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
        .onTapGesture { dismiss() }
        .statusBarHidden()
    }
}
