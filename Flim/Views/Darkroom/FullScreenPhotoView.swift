import SwiftUI
import UIKit

struct FullScreenPhotoView: View {
    let photo: Photo
    let url: URL?
    /// Who took this shot (shown in shared rolls); nil in your personal Darkroom.
    var photographer: String? = nil
    /// Called after the photo is deleted so the parent can refresh its grid.
    var onDelete: () -> Void = {}
    @Environment(PhotoService.self) private var photoService
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed
    @Environment(\.dismiss) private var dismiss

    @State private var shared = false
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    @State private var showReportConfirm = false
    @State private var reportSent = false
    @State private var shareItem: ShareImage?
    @State private var resolvedURL: URL?
    @State private var reactions: [PhotoReaction] = []
    @State private var localCaption: String?
    @State private var showCaptionEditor = false
    @State private var captionDraft = ""

    private let reactionEmojis = ["❤️", "🔥", "😂", "👀"]
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
                    VStack(alignment: .trailing, spacing: 2) {
                        if let photographer {
                            Text("@\(photographer)")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        Text(photo.takenAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color(white: 0.7))
                    }
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
                    // Own photo → a menu (set avatar / delete); someone else's → report.
                    if isOwnPhoto {
                        Menu {
                            Button {
                                shareToPage()
                            } label: {
                                Label(shared ? "Shared to your page" : "Share to my page",
                                      systemImage: shared ? "checkmark.circle" : "square.and.arrow.up.on.square")
                            }
                            .disabled(shared)
                            Button {
                                Haptics.tap()
                                Task { await auth.setAvatar(path: photo.storagePath) }
                            } label: { Label("Set as profile photo", systemImage: "person.crop.circle") }
                            Button(role: .destructive) {
                                showDeleteConfirm = true
                            } label: { Label("Delete photo", systemImage: "trash") }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(12)
                                .glassCapsule(interactive: true)
                        }
                        .accessibilityLabel("More")
                        .disabled(isDeleting)
                    } else {
                        Button {
                            showReportConfirm = true
                        } label: {
                            Image(systemName: reportSent ? "flag.fill" : "flag")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(12)
                                .glassCapsule(interactive: true)
                        }
                        .accessibilityLabel("Report photo")
                        .disabled(reportSent)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 60)

                Spacer()

                bottomBar
                    .padding(.horizontal, 20)
                    .padding(.bottom, 44)
            }
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .task {
            reactions = await photoService.fetchReactions(photoId: photo.id)
            localCaption = photo.caption
            if isOwnPhoto, let uid = auth.currentUser?.id {
                shared = await feed.hasPosted(photoId: photo.id, userId: uid)
            }
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
        .sheet(isPresented: $showCaptionEditor) {
            captionEditor
        }
    }

    // MARK: - Caption + reactions

    @ViewBuilder
    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            if photo.rollId != nil {
                reactionBar
            }
            captionView
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var reactionBar: some View {
        HStack(spacing: 8) {
            ForEach(reactionEmojis, id: \.self) { emoji in
                let count = reactions.filter { $0.emoji == emoji }.count
                let mine = reactions.contains { $0.emoji == emoji && $0.userId == auth.currentUser?.id }
                Button { toggleReaction(emoji) } label: {
                    HStack(spacing: 4) {
                        Text(emoji).font(.system(size: 16))
                        if count > 0 {
                            Text("\(count)")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(mine ? FlimTheme.accent.opacity(0.28) : Color.white.opacity(0.12), in: Capsule())
                    .overlay(Capsule().strokeBorder(mine ? FlimTheme.accent : .clear, lineWidth: 1))
                }
                .accessibilityLabel("React \(emoji)")
            }
        }
    }

    @ViewBuilder
    private var captionView: some View {
        let text = localCaption ?? ""
        if isOwnPhoto {
            Button {
                captionDraft = text
                showCaptionEditor = true
            } label: {
                Text(text.isEmpty ? "Add a caption…" : text)
                    .font(.system(size: 14))
                    .foregroundStyle(text.isEmpty ? Color(white: 0.55) : .white)
                    .multilineTextAlignment(.leading)
            }
        } else if !text.isEmpty {
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(.white)
        }
    }

    private var captionEditor: some View {
        NavigationStack {
            ZStack {
                FlimTheme.bg.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 16) {
                    TextField("Add a caption…", text: $captionDraft, axis: .vertical)
                        .lineLimit(1...4)
                        .font(.system(size: 17))
                        .foregroundStyle(.white)
                        .tint(.white)
                        .padding(16)
                        .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 12))
                    Spacer()
                }
                .padding(20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .flimInlineTitle("Caption")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { showCaptionEditor = false }.foregroundStyle(.white)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        let value = captionDraft
                        localCaption = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
                        showCaptionEditor = false
                        Task { await photoService.setCaption(photoId: photo.id, caption: value) }
                    }
                    .foregroundStyle(FlimTheme.accent)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationBackground(FlimTheme.bg)
    }

    private func shareToPage() {
        guard let uid = auth.currentUser?.id else { return }
        Haptics.tap()
        shared = true
        Task { try? await feed.createPost(photo: photo, caption: localCaption, userId: uid) }
    }

    private func toggleReaction(_ emoji: String) {
        guard let uid = auth.currentUser?.id else { return }
        let mine = reactions.contains { $0.emoji == emoji && $0.userId == uid }
        Haptics.tap()
        Task {
            if mine {
                reactions.removeAll { $0.emoji == emoji && $0.userId == uid }
                await photoService.removeReaction(photoId: photo.id, emoji: emoji, userId: uid)
            } else {
                reactions.append(PhotoReaction(id: UUID(), photoId: photo.id, userId: uid, emoji: emoji))
                await photoService.addReaction(photoId: photo.id, emoji: emoji, userId: uid)
            }
            reactions = await photoService.fetchReactions(photoId: photo.id)
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
