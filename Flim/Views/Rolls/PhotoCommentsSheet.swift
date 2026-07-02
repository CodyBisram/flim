import SwiftUI

/// Comments on a shared roll photo. Reachable from the roll photo viewer + carousel.
/// Notifications (owner + thread) are handled server-side by send-social-push.
struct PhotoCommentsSheet: View {
    let photoId: UUID
    let memberNames: [UUID: String]   // userId → username, for attribution

    @Environment(AuthService.self) private var auth
    @Environment(PhotoService.self) private var photoService
    @Environment(\.dismiss) private var dismiss

    @State private var comments: [PhotoComment] = []
    @State private var draft = ""
    @State private var loaded = false
    @State private var route: ProfileRoute?
    @FocusState private var focused: Bool

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            ZStack {
                FlimTheme.bg.ignoresSafeArea()
                VStack(spacing: 0) {
                    if comments.isEmpty && loaded {
                        VStack(spacing: 8) {
                            Spacer()
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.system(size: 28, weight: .ultraLight)).foregroundStyle(FlimTheme.textTertiary)
                            Text("No comments yet").font(.system(size: 15)).foregroundStyle(.white)
                            Text("Start the conversation on this shot.")
                                .font(.system(size: 13)).foregroundStyle(FlimTheme.textTertiary)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 16) {
                                ForEach(comments) { row($0) }
                            }
                            .padding(16)
                        }
                    }
                    composer
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .flimInlineTitle("Comments")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationDestination(item: $route) { UserPageView(userId: $0.id) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.foregroundStyle(.white) }
            }
            .task { await load() }
        }
        .presentationBackground(FlimTheme.bg)
        .presentationDetents([.medium, .large])
    }

    private func row(_ comment: PhotoComment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Button { route = ProfileRoute(id: comment.userId) } label: {
                        Text(handle(comment.userId))
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    }
                    Text(comment.createdAt.formatted(.relative(presentation: .named)))
                        .font(.system(size: 10)).foregroundStyle(FlimTheme.textTertiary)
                    if comment.userId == auth.currentUser?.id {
                        Button { delete(comment) } label: {
                            Image(systemName: "xmark").font(.system(size: 9)).foregroundStyle(FlimTheme.textTertiary)
                        }
                    }
                }
                Text(comment.body).font(.system(size: 14)).foregroundStyle(FlimTheme.textSecondary)
            }
            Spacer()
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Add a comment…", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .font(.system(size: 15)).foregroundStyle(.white).tint(FlimTheme.accent)
                .focused($focused)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(FlimTheme.bgElevated, in: Capsule())
            Button { send() } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(canSend ? FlimTheme.accent : FlimTheme.textTertiary)
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(FlimTheme.bg)
    }

    private func handle(_ userId: UUID) -> String {
        memberNames[userId].map { "@\($0)" } ?? "@someone"
    }

    private func load() async {
        comments = await photoService.fetchPhotoComments(photoId: photoId)
        loaded = true
    }

    private func send() {
        guard let uid = auth.currentUser?.id, canSend else { return }
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        focused = false
        Task {
            _ = await photoService.addPhotoComment(photoId: photoId, body: body, userId: uid)
            await load()
        }
    }

    private func delete(_ comment: PhotoComment) {
        Task { await photoService.deletePhotoComment(id: comment.id); await load() }
    }
}
