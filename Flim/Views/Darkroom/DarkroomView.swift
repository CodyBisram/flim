import SwiftUI

struct DarkroomView: View {
    @Environment(AuthService.self) private var auth
    @Environment(PhotoService.self) private var photoService
    @Environment(RollService.self) private var rolls

    @State private var vm = DarkroomViewModel()
    @State private var selectedPhoto: Photo?
    @State private var selectedURL: URL?
    @State private var showProfile = false

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    var body: some View {
        ZStack {
            FlimTheme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                FlimNavTitle("Darkroom")

                Group {
                    if vm.isLoading && vm.photos.isEmpty {
                        ScrollView { LoadingGrid().padding(.top, 8) }
                            .scrollDisabled(true)
                    } else if let error = vm.error, vm.photos.isEmpty {
                        ErrorState(message: error) { await reload() }
                    } else if vm.photos.isEmpty {
                        emptyState
                    } else {
                        ScrollView {
                            photoGrid
                                .padding(.horizontal, 2)
                        }
                        .refreshable { await reload() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showProfile = true } label: {
                    Image(systemName: "person.circle")
                        .foregroundStyle(FlimTheme.accent)
                }
                .accessibilityLabel("Profile")
            }
        }
        .onAppear {
            Task {
                await reload()
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-seedDemo"), vm.photos.isEmpty,
                   let uid = auth.currentUser?.id {
                    await photoService.seedDemoPhotos(userId: uid)
                    await reload()
                }
                #endif
            }
        }
        .fullScreenCover(item: $selectedPhoto) { photo in
            FullScreenPhotoView(photo: photo, url: selectedURL, onDelete: { Task { await reload() } })
        }
        .sheet(isPresented: $showProfile) {
            ProfileView()
        }
    }

    // MARK: - Grid

    @ViewBuilder
    private var photoGrid: some View {
        if !vm.developingPhotos.isEmpty {
            developingSection
        }
        if !vm.developedPhotos.isEmpty {
            developedSection
        }
    }

    private var developingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(vm.developingPhotos.count) DEVELOPING")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(2)
                    .foregroundStyle(Color(white: 0.4))
                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.top, 16)

            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(vm.developingPhotos) { photo in
                    PhotoGridCell(photo: photo, signedURL: nil, rollName: rollName(for: photo.rollId))
                }
            }
        }
    }

    /// The name of the roll a photo belongs to (for labeling roll shots in the Darkroom).
    private func rollName(for rollId: UUID?) -> String? {
        guard let rollId else { return nil }
        return rolls.rolls.first { $0.id == rollId }?.name
    }

    private var developedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("DEVELOPED")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(2)
                    .foregroundStyle(Color(white: 0.4))
                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.top, 16)

            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(vm.developedPhotos) { photo in
                    PhotoGridCell(photo: photo, signedURL: vm.signedURLCache[photo.id], rollName: rollName(for: photo.rollId))
                        .onTapGesture {
                            selectedURL = vm.signedURLCache[photo.id]
                            selectedPhoto = photo
                        }
                        .task {
                            if vm.signedURLCache[photo.id] == nil {
                                _ = await vm.signedURL(for: photo, photoService: photoService)
                            }
                            // Load the next page as the last photo scrolls into view.
                            if photo.id == vm.developedPhotos.last?.id, let uid = auth.currentUser?.id {
                                await vm.loadMore(photoService: photoService, userId: uid)
                            }
                        }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(FlimTheme.accent.opacity(0.8))
            Text("Your darkroom's empty.")
                .font(.system(size: 17, weight: .light))
                .foregroundStyle(FlimTheme.textSecondary)
            Text("Take a shot — it'll quietly develop, then show up here.")
                .font(.system(size: 13))
                .foregroundStyle(FlimTheme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    private func reload() async {
        guard let userId = auth.currentUser?.id else { return }
        await vm.load(photoService: photoService, userId: userId)
        if rolls.rolls.isEmpty { try? await rolls.fetchRolls(for: userId) }   // for roll labels
    }
}
