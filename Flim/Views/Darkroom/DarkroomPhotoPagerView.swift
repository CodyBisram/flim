import SwiftUI

/// Swipeable walk through the Darkroom grid, opened at whichever photo was tapped. Every photo
/// reachable from the Darkroom grid is the signed-in user's own (personal shots, plus their own
/// contributions to rolls) — RollDetailView is the separate surface for browsing everyone's shots
/// in a roll — so this never needs the "someone else's photo" branches FullScreenPhotoView also
/// supports (report, photographer attribution).
///
/// Each page is a full, independent `FullScreenPhotoView` instance rather than a stripped-down
/// copy: TabView(.page) keeps more than just the current page "warm" (RollCarouselView's own
/// windowed URL-loading exists because of exactly this), so reusing the same view means every
/// existing behavior — delete, share-to-page, tagging, comments, pinch-zoom-to-dismiss — keeps
/// working per-page for free, with its own state, instead of being reimplemented and risking
/// drift from the single-photo version. `showsReactions: false` skips both the reaction UI and
/// its fetch, since a many-photo pager can hold several pages' `.task` alive simultaneously and
/// reactions are a roll thing, not a personal-library thing, here anyway.
struct DarkroomPhotoPagerView: View {
    let photos: [Photo]
    var startIndex: Int = 0
    /// Grid's already-resolved thumbnail URLs, keyed by photo id — seeds each page's image
    /// instantly (matching FullScreenPhotoView's own "thumbnail first, then upgrade" behavior)
    /// instead of every page starting from a blank placeholder.
    let signedURLs: [UUID: URL]
    let rollName: (UUID?) -> String?
    var onDelete: () -> Void = {}

    @State private var selection: Int

    init(photos: [Photo], startIndex: Int = 0, signedURLs: [UUID: URL],
         rollName: @escaping (UUID?) -> String?, onDelete: @escaping () -> Void = {}) {
        self.photos = photos
        self.startIndex = startIndex
        self.signedURLs = signedURLs
        self.rollName = rollName
        self.onDelete = onDelete
        _selection = State(initialValue: min(max(startIndex, 0), max(0, photos.count - 1)))
    }

    var body: some View {
        TabView(selection: $selection) {
            ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                FullScreenPhotoView(
                    photo: photo,
                    url: signedURLs[photo.id],
                    rollName: rollName(photo.rollId),
                    onDelete: onDelete,
                    showsReactions: false,
                    // dragToDismiss is a plain, unrestricted DragGesture on the image — inside
                    // a TabView(.page) it competes with the TabView's own horizontal paging for
                    // every touch, which is a real, sufficient reason for paging to not work at
                    // all here. The header's X (already in FullScreenPhotoView) covers dismissal
                    // instead.
                    allowsDragToDismiss: false
                )
                // Belt-and-suspenders, matching the roll carousel's own fix: without this a
                // page's width is only as wide as its content, which is how paging TabViews
                // have broken before in this app.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }
}
