import SwiftUI
import Photos

/// 1.7's Post (Blend 3, 9b and 9c): one screen for one shot or a selection, always on Slate so
/// the photographs read true. Each shot keeps its own caption; the strip moves between them.
/// Tags apply to the whole group. "Send to Spotlight too" puts the shot on screen up for this
/// week's Spotlight once it's posted (1.6's rules: private, the team picks).
struct DeskPostView: View {
    let photos: [Photo]
    /// Display URLs the grid already resolved, keyed by photo id.
    let urls: [UUID: URL]
    /// Called once the posts have been sent, with how many went up.
    var onPosted: (Int) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.flimAccent) private var accent
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed

    @State private var index = 0
    @State private var captions: [UUID: String] = [:]
    @State private var tags: [PendingTag] = []
    @State private var sendToSpotlight = false
    @State private var showTags = false
    @State private var posting = false
    @FocusState private var captionFocused: Bool

    private var current: Photo? { photos.indices.contains(index) ? photos[index] : nil }

    /// Offered only while this week's Spotlight is known and open for this account.
    private var spotlightOffered: Bool { feed.currentSpotlightEntry != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 14) {
                    pager
                    if photos.count > 1 { strip }
                    captionField
                    VStack(spacing: 0) {
                        tagRow
                        if spotlightOffered {
                            Rectangle().fill(FlimTheme.stroke).frame(height: 1)
                            spotlightRow
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
            .scrollDismissesKeyboard(.interactively)
            postButton
        }
        .background(FlimTheme.bg.ignoresSafeArea())
        // The Post screen is always Slate (the board), whatever the desk: the colours, and the
        // status bar and keyboard with them.
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showTags) {
            AddPeopleSheet(tags: $tags)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Close")
            Text("Post")
                .font(.system(size: 18, weight: .semibold))
            Spacer()
            if photos.count > 1 {
                Text("\(index + 1) / \(photos.count)")
                    .font(DeskType.data(11))
                    .tracking(1.4)
                    .foregroundStyle(FlimTheme.textTertiary)
            }
        }
        .foregroundStyle(FlimTheme.textPrimary)
        .padding(.leading, 12)
        .padding(.trailing, 24)
        .frame(minHeight: 52)
    }

    private var pager: some View {
        TabView(selection: $index) {
            ForEach(Array(photos.enumerated()), id: \.element.id) { i, photo in
                CachedImage(url: urls[photo.id], maxPixel: 1400, cacheKey: photo.displayPath) {
                    $0.resizable().scaledToFill()
                } placeholder: { FlimTheme.well }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .tag(i)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .aspectRatio(FlimTheme.frameAspect, contentMode: .fit)
        .accessibilityLabel("Shot \(index + 1) of \(photos.count)")
    }

    private var strip: some View {
        HStack(spacing: 6) {
            ForEach(Array(photos.enumerated()), id: \.element.id) { i, photo in
                Button { withAnimation(.snappy) { index = i } } label: {
                    CachedImage(url: urls[photo.id], maxPixel: 150, cacheKey: photo.displayPath) {
                        $0.resizable().scaledToFill()
                    } placeholder: { FlimTheme.well }
                    .frame(width: 40, height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(i == index ? accent : .clear, lineWidth: 2))
                    .opacity(i == index ? 1 : 0.7)
                }
                .accessibilityLabel("Shot \(i + 1)")
            }
            Spacer(minLength: 0)
        }
    }

    private var captionField: some View {
        let binding = Binding<String>(
            get: { current.flatMap { captions[$0.id] } ?? "" },
            set: { if let id = current?.id { captions[id] = $0 } })
        return TextField("", text: binding, prompt: Text("Add a caption").foregroundStyle(FlimTheme.textTertiary), axis: .vertical)
            .lineLimit(1...4)
            .focused($captionFocused)
            .flimFont(15, relativeTo: .body)
            .foregroundStyle(FlimTheme.textPrimary)
            .tint(accent)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(FlimTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityLabel(photos.count > 1 ? "Caption for shot \(index + 1)" : "Caption")
    }

    private var tagRow: some View {
        Button { showTags = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "tag")
                    .foregroundStyle(FlimTheme.textSecondary)
                Text("Tag friends")
                    .foregroundStyle(FlimTheme.textPrimary)
                Spacer()
                if !tags.isEmpty {
                    Text(tags.map(\.user.handle).joined(separator: ", "))
                        .foregroundStyle(FlimTheme.textSecondary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FlimTheme.textTertiary)
            }
            .flimFont(15, relativeTo: .body)
            .frame(minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var spotlightRow: some View {
        Toggle(isOn: $sendToSpotlight) {
            HStack(spacing: 12) {
                Image(systemName: "star")
                    .foregroundStyle(FlimTheme.textSecondary)
                Text("Send to Spotlight too")
                    .foregroundStyle(FlimTheme.textPrimary)
            }
            .flimFont(15, relativeTo: .body)
        }
        .tint(DeskColor.solid)
        .frame(minHeight: 50)
        .accessibilityHint("Sends the shot on screen. One shot a week; the team picks a few to show everyone.")
    }

    private var postButton: some View {
        Button { post() } label: {
            Text(photos.count > 1 ? "Post \(photos.count) shots" : "Post")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(white: 0.1))
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(accent, in: Capsule())
        }
        .disabled(posting || photos.isEmpty)
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    /// Posts every shot with its own caption and the group's tags, in shot order so the feed
    /// groups them the way it groups any day's shots. The posted marks go up at once; a shot
    /// that fails comes back down.
    private func post() {
        guard !posting, let uid = auth.currentUser?.id else { return }
        posting = true
        Haptics.tap()
        let ordered = photos.sorted { $0.takenAt < $1.takenAt }
        let capturedCaptions = captions
        let capturedTags = tags
        let spotlightPhotoId = sendToSpotlight ? current?.id : nil
        let service = feed
        for photo in ordered { service.myPostedPhotoIds.insert(photo.id) }
        let count = ordered.count
        dismiss()
        onPosted(count)
        Task {
            var failed = 0
            for photo in ordered {
                do {
                    let created = try await service.createPost(photo: photo, caption: capturedCaptions[photo.id],
                                                               userId: uid, tags: capturedTags)
                    if photo.id == spotlightPhotoId {
                        await service.putUpForSpotlight(created.post)
                    }
                } catch {
                    service.myPostedPhotoIds.remove(photo.id)
                    failed += 1
                }
            }
            if failed > 0 {
                Haptics.error()
                UndoCenter.shared.showNotice(failed == count
                    ? "Couldn't post. Check your connection and try again."
                    : "\(failed) of \(count) didn't post. Check your connection and try again.")
            } else {
                Haptics.success()
            }
        }
    }
}

/// Saves shots to Photos from their master files, for 1.7's Select bar (Blend 3, 9a).
enum DeskSaveToPhotos {
    /// How many were saved; nil when Photos access was refused.
    @MainActor
    static func save(_ photos: [Photo], photoService: PhotoService) async -> Int? {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return nil }
        var saved = 0
        for photo in photos where photo.isReady {
            var bytes = await DiskImageCache.loadRaw(path: photo.storagePath)
            if bytes == nil, let url = try? await photoService.signedURL(for: photo.storagePath),
               let (data, _) = try? await URLSession.shared.data(from: url) {
                bytes = data
            }
            if let data = bytes, await CameraRollAutoSave.addToLibrary(data) { saved += 1 }
        }
        return saved
    }
}
