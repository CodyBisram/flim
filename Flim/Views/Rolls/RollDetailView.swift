import SwiftUI

struct RollDetailView: View {
    let roll: Roll
    @Environment(PhotoService.self) private var photoService
    @Environment(RollService.self) private var rollService
    @State private var vm = DarkroomViewModel()
    @State private var showMembers = false
    @State private var selectedPhoto: Photo?
    @State private var selectedURL: URL?

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    var body: some View {
        ZStack {
            FlimTheme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                FlimNavTitle(roll.name)

                if let count = rollService.memberCounts[roll.id] {
                    Label("\(count) member\(count == 1 ? "" : "s")", systemImage: "person.2.fill")
                        .font(.system(size: 13, weight: .medium))
                        .imageScale(.small)
                        .foregroundStyle(FlimTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                }

                Group {
                    if vm.isLoading && vm.photos.isEmpty {
                        ProgressView().tint(.white)
                    } else if vm.photos.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 36, weight: .ultraLight))
                                .foregroundStyle(FlimTheme.accent.opacity(0.8))
                            Text("No photos in this roll yet.")
                                .font(.system(size: 15, weight: .light))
                                .foregroundStyle(FlimTheme.textSecondary)
                            Text("Take a photo and send it to \"\(roll.name)\".")
                                .font(.system(size: 13))
                                .foregroundStyle(FlimTheme.textTertiary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)
                        }
                    } else {
                        ScrollView {
                            LazyVGrid(columns: columns, spacing: 2) {
                                ForEach(vm.photos) { photo in
                                    PhotoGridCell(photo: photo, signedURL: vm.signedURLCache[photo.id])
                                        .onTapGesture {
                                            selectedURL = vm.signedURLCache[photo.id]
                                            selectedPhoto = photo
                                        }
                                        .task {
                                            if photo.isReady, vm.signedURLCache[photo.id] == nil {
                                                _ = await vm.signedURL(for: photo, photoService: photoService)
                                            }
                                            if photo.id == vm.photos.last?.id {
                                                await vm.loadMoreRoll(photoService: photoService, rollId: roll.id)
                                            }
                                        }
                                }
                            }
                            .padding(.horizontal, 2)
                        }
                        .refreshable {
                            await vm.loadRoll(photoService: photoService, rollId: roll.id)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showMembers = true } label: {
                    Image(systemName: "person.2")
                        .foregroundStyle(FlimTheme.accent)
                }
                .accessibilityLabel("Members")
                Button {
                    UIPasteboard.general.string = roll.inviteCode
                    Haptics.tap()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(FlimTheme.accent)
                }
                .accessibilityLabel("Copy invite code")
            }
        }
        .onAppear {
            Task { await vm.loadRoll(photoService: photoService, rollId: roll.id) }
        }
        .fullScreenCover(item: $selectedPhoto) { photo in
            FullScreenPhotoView(photo: photo, url: selectedURL,
                                onDelete: { Task { await vm.loadRoll(photoService: photoService, rollId: roll.id) } })
        }
        .sheet(isPresented: $showMembers) {
            RollMembersView(roll: roll)
        }
    }
}
