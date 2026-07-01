import SwiftUI
import UIKit

struct FullScreenPhotoView: View {
    let photo: Photo
    let url: URL?
    /// Called after the photo is deleted so the parent can refresh its grid.
    var onDelete: () -> Void = {}
    @Environment(PhotoService.self) private var photoService
    @Environment(AuthService.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    @State private var showReportConfirm = false
    @State private var reportSent = false
    @State private var shareItem: ShareImage?
    @State private var resolvedURL: URL?

    private var isOwnPhoto: Bool { photo.userId == auth.currentUser?.id }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let resolvedURL {
                // CachedImage serves a screen-sized, already-decoded image from memory, so
                // opening a photo you can see in the grid is instant.
                CachedImage(url: resolvedURL, maxPixel: 1600) { image in
                    image
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(dragToDismiss)
                        .gesture(pinchToZoom)
                } placeholder: {
                    ProgressView().tint(.white)
                }
            }

            // Metadata bar
            VStack {
                HStack(spacing: 12) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(12)
                            .glassCapsule(interactive: true)
                    }
                    .accessibilityLabel("Close")
                    Spacer()
                    Text(photo.takenAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(white: 0.7))
                    // Share / save to Camera Roll (the on-screen, screen-sized image).
                    Button {
                        if let resolvedURL,
                           let image = ImageCache.shared.object(forKey: "\(resolvedURL.absoluteString)|1600" as NSString) {
                            shareItem = ShareImage(image: image)
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(12)
                            .glassCapsule(interactive: true)
                    }
                    .accessibilityLabel("Share photo")
                    // Your own photo → delete; someone else's → report (UGC safety).
                    Button {
                        if isOwnPhoto { showDeleteConfirm = true } else { showReportConfirm = true }
                    } label: {
                        Image(systemName: isOwnPhoto ? "trash" : (reportSent ? "flag.fill" : "flag"))
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(12)
                            .glassCapsule(interactive: true)
                    }
                    .accessibilityLabel(isOwnPhoto ? "Delete photo" : "Report photo")
                    .disabled(isDeleting || reportSent)
                }
                .padding(.horizontal, 20)
                .padding(.top, 60)
                Spacer()
            }
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .task {
            // Use the URL the grid already resolved; otherwise mint one so the photo always
            // loads (the grid resolves URLs lazily now, so the tapped one may not be ready).
            if let url {
                resolvedURL = url
            } else {
                resolvedURL = try? await photoService.signedURL(for: photo.storagePath)
            }
        }
        .confirmationDialog("Delete this photo?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                isDeleting = true
                Task {
                    await photoService.deletePhoto(photo)
                    onDelete()
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
        .confirmationDialog("Report this photo?", isPresented: $showReportConfirm, titleVisibility: .visible) {
            Button("Report", role: .destructive) {
                Task {
                    await photoService.reportPhoto(photo)
                    reportSent = true
                    Haptics.tap()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Flag this for review. Thanks for keeping FLIM safe.")
        }
        .sheet(item: $shareItem) { item in
            ActivityView(items: [item.image])
        }
    }

    // MARK: - Gestures

    private var dragToDismiss: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale <= 1 else { return }
                offset = value.translation
            }
            .onEnded { value in
                if abs(value.translation.height) > 120 {
                    dismiss()
                } else {
                    withAnimation(.spring(duration: 0.3)) { offset = .zero }
                }
            }
    }

    private var pinchToZoom: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = max(1, value)
            }
            .onEnded { _ in
                withAnimation(.spring(duration: 0.3)) {
                    if scale < 1.2 { scale = 1; offset = .zero }
                }
            }
    }
}

/// Identifiable wrapper so a shared image can drive `.sheet(item:)`.
struct ShareImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// Bridges UIKit's share sheet (Save to Photos, AirDrop, Messages, …) into SwiftUI.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
