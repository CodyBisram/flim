import SwiftUI

/// The sort deck's compose path: caption + tag people, opened from the pill under the top card or
/// a tap on the card itself. Modeled on `PhotoPagerView`'s share composer (caption field, "Tag
/// people" row into `TagPhotoSheet`, Post action), as a standalone sheet rather than that
/// composer's inline bottom bar, since the deck has no persistent per-photo chrome to attach one
/// to.
///
/// This view never talks to the network itself: `onPost` is `SortDeckView.performSwipe`, the exact
/// swipe-right publish path (`photoService.markSorted` then `feed.createPost`, including its tri-
/// state tag-save handling), so a compose-sheet post and a fast swipe-right post can never diverge
/// in what actually happens server-side.
struct SortDeckComposeSheet: View {
    @Environment(\.flimAccent) private var accent
    @Environment(\.dismiss) private var dismiss

    let photo: Photo
    let url: URL?
    @Binding var caption: String
    @Binding var tags: [PendingTag]
    /// Publishes with the current caption/tags. The sheet is dismissed by the caller's `.sheet`
    /// binding flipping to `false`, not from in here, since posting also has to fly the card off
    /// the deck underneath.
    var onPost: () -> Void

    @State private var showTagSheet = false
    @FocusState private var captionFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                FlimTheme.bg.ignoresSafeArea()
                VStack(spacing: 16) {
                    photoPreview
                        .padding(.horizontal, 24)
                        .padding(.top, 12)

                    Button { showTagSheet = true } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 14))
                            Text(tags.isEmpty ? "Tag people" : "\(tags.count) tagged")
                                .flimFont(14)
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Color.white.opacity(0.1), in: Capsule())
                    }
                    .padding(.horizontal, 24)

                    TextField("Add a caption…", text: $caption, axis: .vertical)
                        .lineLimit(1...4)
                        .focused($captionFocused)
                        .flimFont(15)
                        .foregroundStyle(.white)
                        .tint(accent)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 24)

                    Spacer(minLength: 0)

                    PrimaryButton(title: "Post") {
                        captionFocused = false
                        onPost()
                        dismiss()
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .flimInlineTitle("New Post")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(.white)
                }
            }
        }
        .presentationBackground(FlimTheme.bg)
        .sheet(isPresented: $showTagSheet) {
            TagPhotoSheet(url: url, cacheKey: photo.viewPath, tags: $tags, rollId: photo.rollId)
        }
    }

    private var photoPreview: some View {
        Group {
            if let url {
                CachedImage(url: url, maxPixel: 900, cacheKey: photo.viewPath) { $0.resizable().scaledToFit() }
                    placeholder: { ShimmerPlaceholder(cornerRadius: 16) }
            } else {
                ShimmerPlaceholder(cornerRadius: 16)
            }
        }
        .aspectRatio(SortDeckView.cardAspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}
