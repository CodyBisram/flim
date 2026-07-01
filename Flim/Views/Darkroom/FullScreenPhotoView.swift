import SwiftUI

struct FullScreenPhotoView: View {
    let photo: Photo
    let url: URL?
    /// Called after the photo is deleted so the parent can refresh its grid.
    var onDelete: () -> Void = {}
    @Environment(PhotoService.self) private var photoService
    @Environment(\.dismiss) private var dismiss

    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let url {
                // CachedImage serves the already-decoded thumbnail from memory, so opening a
                // photo you can see in the grid is instant (no re-download, no reveal delay).
                CachedImage(url: url) { image in
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
                    Spacer()
                    Text(photo.takenAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(white: 0.7))
                    Button {
                        showDeleteConfirm = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(12)
                            .glassCapsule(interactive: true)
                    }
                    .disabled(isDeleting)
                }
                .padding(.horizontal, 20)
                .padding(.top, 60)
                Spacer()
            }
        }
        .ignoresSafeArea()
        .statusBarHidden()
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
