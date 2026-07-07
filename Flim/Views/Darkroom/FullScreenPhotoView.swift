import SwiftUI
import UIKit

struct FullScreenPhotoView: View {
    let photo: Photo
    let url: URL?
    /// Who took this shot (shown in shared rolls); nil in your personal Darkroom.
    var photographer: String? = nil
    /// Roll member names for comment attribution (empty for personal photos).
    var memberNames: [UUID: String] = [:]
    /// Called after the photo is deleted so the parent can refresh its grid.
    var onDelete: () -> Void = {}
    @Environment(PhotoService.self) private var photoService
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed
    @Environment(\.dismiss) private var dismiss

    @State private var shared = false
    @State private var showSharedToast = false
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    @State private var showReportConfirm = false
    @State private var reportSent = false
    @State private var shareItem: ShareImage?
    @State private var resolvedURL: URL?
    @State private var reactions: [PhotoReaction] = []
    @State private var showShareComposer = false
    @State private var shareCaptionDraft = ""
    @State private var pendingTags: [PendingTag] = []
    @State private var showTagSheet = false
    @State private var showComments = false
    @FocusState private var captionFocused: Bool

    private var isOwnPhoto: Bool { photo.userId == auth.currentUser?.id }
    private var isRollPhoto: Bool { photo.rollId != nil }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // ONE vertical layout — top controls / flexible photo / bottom bar — so when the
            // reaction bar expands (or the keyboard rises), the photo SHRINKS instead of
            // anything overlapping the metadata or the image.
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
                    // Comments (shared roll photos only).
                    if isRollPhoto {
                        Button { showComments = true } label: {
                            Image(systemName: "bubble.right")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(12)
                                .glassCapsule(interactive: true)
                        }
                        .accessibilityLabel("Comments")
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
                                Haptics.tap()
                                Task { await auth.setAvatar(fromPhotoPath: photo.storagePath) }
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

                // Flexible middle: the photo scales to whatever room the bars leave.
                Group {
                    if let resolvedURL {
                        // CachedImage serves a screen-sized, already-decoded image from memory,
                        // so opening a photo you can see in the grid is instant.
                        CachedImage(url: resolvedURL, maxPixel: 1600) { image in
                            // Photographer + date live UNDER the photo's bottom edge, inside
                            // its layout — never on the image, on any aspect ratio.
                            VStack(spacing: 10) {
                                image
                                    .resizable()
                                    .scaledToFit()
                                    .scaleEffect(scale)
                                    .offset(offset)
                                    .gesture(dragToDismiss)
                                    .gesture(pinchToZoom)
                                    .onTapGesture(count: 2) {
                                        withAnimation(.spring(duration: 0.3)) {
                                            if scale > 1 {
                                                scale = 1; offset = .zero; lastOffset = .zero
                                            } else {
                                                scale = 2.5
                                            }
                                        }
                                    }
                                VStack(spacing: 2) {
                                    if let photographer {
                                        Text("@\(photographer)")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(.white)
                                    }
                                    Text(photo.takenAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Color(white: 0.68))
                                }
                                .opacity(scale > 1 ? 0 : 1)   // tuck away while zoomed in
                                .animation(.easeOut(duration: 0.2), value: scale > 1)
                            }
                        } placeholder: {
                            ProgressView().tint(.white)
                        }
                    } else {
                        ProgressView().tint(.white)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 12)

                bottomBar
                    .padding(.horizontal, 20)
                    .padding(.bottom, 44)
            }
        }
        // Container edges only — keep KEYBOARD avoidance, so the bottom bar (and the shrinking
        // photo) ride above the emoji-search keyboard instead of being covered by it.
        .ignoresSafeArea(.container)
        .statusBarHidden()
        .sheet(isPresented: $showComments) {
            PhotoCommentsSheet(photoId: photo.id, memberNames: memberNames)
        }
        .sheet(isPresented: $showTagSheet) {
            TagPhotoSheet(url: resolvedURL, tags: $pendingTags)
        }
        .overlay(alignment: .top) {
            if showSharedToast {
                Label("Shared to your page", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 64)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .task {
            reactions = await photoService.fetchReactions(photoId: photo.id)
            if isOwnPhoto, let uid = auth.currentUser?.id {
                shared = await feed.hasPosted(photoId: photo.id, userId: uid)
            }
            // Show the grid's (cached, instant) thumbnail first, then upgrade to the full-res
            // image so full-screen is never a downscaled thumb.
            if let url { resolvedURL = url }
            if let full = try? await photoService.signedURL(for: photo.storagePath) {
                resolvedURL = full
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
            Text("Flag this for review. Thanks for keeping \(AppInfo.appName) safe.")
        }
        .sheet(item: $shareItem) { item in
            SharePreviewSheet(photo: item.image)
        }
        .safeAreaInset(edge: .bottom) {
            if showShareComposer { shareComposer }
        }
    }

    // MARK: - Reactions + share composer

    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: 14) {
            if photo.rollId != nil {
                reactionBar
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Prominent share-to-page action for your own photos.
            if isOwnPhoto && !showShareComposer {
                Button { shareToPage() } label: {
                    Label(shared ? "Shared to your page" : "Share to your page",
                          systemImage: shared ? "checkmark.circle.fill" : "square.and.arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(shared ? .white : .black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(shared ? Color.white.opacity(0.15) : FlimTheme.accent, in: Capsule())
                }
                .disabled(shared)
            }
        }
    }

    private var reactionBar: some View {
        ReactionBar(
            defaults: PostEmoji.all,
            counts: Dictionary(grouping: reactions, by: \.emoji).mapValues(\.count),
            mine: Set(reactions.filter { $0.userId == auth.currentUser?.id }.map(\.emoji))
        ) { toggleReaction($0) }
    }

    /// Inline caption composer, shown at the bottom when publishing a photo to your page.
    private var shareComposer: some View {
        VStack(spacing: 10) {
            // Tag people — opens the Instagram-style tagging sheet.
            Button { showTagSheet = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 14))
                    Text(pendingTags.isEmpty ? "Tag people" : "\(pendingTags.count) tagged")
                        .font(.system(size: 14))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.white.opacity(0.1), in: Capsule())
            }

            HStack(spacing: 10) {
                TextField("Add a caption…", text: $shareCaptionDraft, axis: .vertical)
                    .lineLimit(1...3)
                    .focused($captionFocused)
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .tint(FlimTheme.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.14), in: Capsule())
                Button {
                    showShareComposer = false
                    captionFocused = false
                } label: {
                    Text("Cancel").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                }
                Button { confirmShare() } label: {
                    Text("Share")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(FlimTheme.accent, in: Capsule())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private func shareToPage() {
        shareCaptionDraft = ""
        pendingTags = []
        showShareComposer = true
        captionFocused = true
    }

    private func confirmShare() {
        guard let uid = auth.currentUser?.id else { return }
        let caption = shareCaptionDraft
        let tags = pendingTags
        Haptics.tap()
        shared = true
        showShareComposer = false
        captionFocused = false
        Task {
            do {
                try await feed.createPost(photo: photo, caption: caption, userId: uid, tags: tags)
                Haptics.reveal()   // success confirmation
                withAnimation { showSharedToast = true }
                try? await Task.sleep(for: .seconds(2))
                withAnimation { showSharedToast = false }
            } catch {
                // Didn't reach the server — un-mark so the Share button comes back for a retry.
                shared = false
                Haptics.error()
            }
        }
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
                if scale > 1 {
                    // Pan the zoomed image.
                    offset = CGSize(width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height)
                } else {
                    offset = value.translation
                }
            }
            .onEnded { value in
                if scale > 1 {
                    lastOffset = offset
                } else if abs(value.translation.height) > 120 {
                    dismiss()
                } else {
                    withAnimation(.spring(duration: 0.3)) { offset = .zero }
                }
            }
    }

    private var pinchToZoom: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                // Cap at 3× — enough to inspect detail, and keeps the image from turning to mush
                // (uncapped zoom looks bad at any resolution).
                scale = min(3, max(1, value))
            }
            .onEnded { _ in
                withAnimation(.spring(duration: 0.3)) {
                    if scale < 1.2 { scale = 1; offset = .zero; lastOffset = .zero }
                }
            }
    }
}

/// Identifiable wrapper so a shared image can drive `.sheet(item:)`. Framing (the FLIM print
/// border) is the user's choice, made live in SharePreviewSheet — this holds the untouched photo.
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
