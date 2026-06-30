import SwiftUI

struct FullScreenPhotoView: View {
    let photo: Photo
    let url: URL?
    @Environment(\.dismiss) private var dismiss

    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var revealed = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .saturation(revealed ? 1 : 0.3)
                            .blur(radius: revealed ? 0 : 8)
                            .overlay(GrainOverlay().opacity(revealed ? 0 : 1))
                            .scaleEffect(scale)
                            .offset(offset)
                            .gesture(dragToDismiss)
                            .gesture(pinchToZoom)
                            .onAppear {
                                // The intentional reveal moment — one satisfying beat + haptic.
                                Haptics.reveal()
                                withAnimation(.easeOut(duration: 1.0)) { revealed = true }
                            }
                    default:
                        ProgressView().tint(.white)
                    }
                }
            }

            // Metadata bar
            VStack {
                HStack {
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
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(photo.takenAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color(white: 0.7))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 60)
                Spacer()
            }
        }
        .ignoresSafeArea()
        .statusBarHidden()
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
