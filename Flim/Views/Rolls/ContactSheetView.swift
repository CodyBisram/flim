import SwiftUI

/// The pre-share screen for a roll's contact sheet: a live preview of exactly what is about to be
/// shared, generated once on appear, with the share sheet only reachable from a visible "Share"
/// button below it.
///
/// This is deliberate, not incidental: a roll's photos belong to everyone in it, so posting a
/// contact sheet is more consequential than posting one of your own shots, and the person doing it
/// should see the whole thing before it goes anywhere, not get a share sheet the instant they tap
/// a menu item.
struct ContactSheetView: View {
    @Environment(\.flimAccent) private var accent
    @Environment(PhotoService.self) private var photoService
    @Environment(AuthService.self) private var auth
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dismiss) private var dismiss

    let rollName: String
    let inviteCode: String
    /// When the roll developed, `Roll.revealAt`.
    let developedAt: Date
    /// Every developed photo in the roll. Callers gate this to already-developed shots (see
    /// `RollDetailView`'s `chronologicalDeveloped` and `RollRevealView`'s deck), and
    /// `ContactSheetRenderer` re-checks `isReady` itself as a second, cheap backstop.
    let photos: [Photo]

    @State private var rendered: UIImage?
    @State private var failed = false
    @State private var shareItem: ShareImage?

    private var photographerCount: Int { Set(photos.map(\.userId)).count }

    var body: some View {
        NavigationStack {
            ZStack {
                FlimTheme.bg.ignoresSafeArea()
                content
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .flimInlineTitle("Share this roll")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }.tint(accent)
                }
            }
        }
        .task { await render() }
        .sheet(item: $shareItem) { item in
            ActivityView(items: [item.image])
        }
    }

    @ViewBuilder
    private var content: some View {
        if let rendered {
            VStack(spacing: 18) {
                Spacer(minLength: 4)

                Image(uiImage: rendered)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
                    .padding(.horizontal, 32)

                // What's about to go out, stated plainly before the share sheet ever opens: a
                // roll's photos belong to everyone in it, not just whoever taps Share.
                Text(inclusionCopy)
                    .flimFont(13, relativeTo: .caption)
                    .foregroundStyle(FlimTheme.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                Button {
                    Haptics.tap()
                    shareItem = ShareImage(image: rendered)
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .flimFont(16, weight: .semibold)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(accent, in: Capsule())
                        .padding(.horizontal, 24)
                }

                Spacer(minLength: 12)
            }
        } else if failed {
            ErrorState(title: "Couldn't build the contact sheet", message: "Check your connection and try again.") {
                await render()
            }
        } else {
            VStack(spacing: 14) {
                ProgressView().tint(.white)
                Text("Putting the contact sheet together…")
                    .flimFont(13, relativeTo: .caption)
                    .foregroundStyle(FlimTheme.textTertiary)
            }
        }
    }

    private var inclusionCopy: String {
        let shots = photos.count == 1 ? "1 photo" : "\(photos.count) photos"
        guard photographerCount > 1 else { return "Includes \(shots) from this roll." }
        return "Includes \(shots) from all \(photographerCount) people in this roll."
    }

    private func render() async {
        guard rendered == nil else { return }
        guard let uid = auth.currentUser?.id else { failed = true; return }
        failed = false
        let input = ContactSheetRenderer.Input(
            rollName: rollName, developedAt: developedAt,
            joinURL: AppInfo.rollInviteLink(code: inviteCode), photos: photos, sharerId: uid
        )
        let result = await ContactSheetRenderer.render(input, photoService: photoService, scale: displayScale)
        if let result {
            rendered = result
        } else {
            failed = true
            Haptics.error()
        }
    }
}
