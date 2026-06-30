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

            if vm.isLoading && vm.photos.isEmpty {
                ProgressView().tint(.white)
            } else if vm.photos.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 36, weight: .ultraLight))
                        .foregroundStyle(Color(white: 0.3))
                    Text("No photos in this roll yet.")
                        .font(.system(size: 14))
                        .foregroundStyle(Color(white: 0.4))
                    Text("Take a photo and send it to \"\(roll.name)\".")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(white: 0.3))
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
        .navigationTitle(roll.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showMembers = true } label: {
                    Image(systemName: "person.2")
                        .foregroundStyle(FlimTheme.accent)
                }
                Button {
                    UIPasteboard.general.string = roll.inviteCode
                    Haptics.tap()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(FlimTheme.accent)
                }
            }
        }
        .onAppear {
            Task { await vm.loadRoll(photoService: photoService, rollId: roll.id) }
        }
        .fullScreenCover(item: $selectedPhoto) { photo in
            FullScreenPhotoView(photo: photo, url: selectedURL)
        }
        .sheet(isPresented: $showMembers) {
            RollMembersView(roll: roll)
        }
    }
}
