import SwiftUI
import UIKit

struct RollDetailView: View {
    let roll: Roll
    @Environment(PhotoService.self) private var photoService
    @Environment(RollService.self) private var rollService
    @Environment(AuthService.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var vm = DarkroomViewModel()
    @State private var showMembers = false
    @State private var selectedPhoto: Photo?
    @State private var selectedURL: URL?
    @State private var memberNames: [UUID: String] = [:]   // userId → username, for attribution
    @State private var showRename = false
    @State private var renameDraft = ""
    @State private var showDeleteRoll = false
    @State private var savingAll = false
    @State private var shareImages: [UIImage] = []
    @State private var showShareAll = false
    @State private var displayName = ""
    @State private var showInviteShare = false
    @State private var coverToast = false

    private var isCreator: Bool { auth.currentUser?.id == roll.createdBy }

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    var body: some View {
        ZStack {
            FlimTheme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                FlimNavTitle(displayName.isEmpty ? roll.name : displayName)

                if let count = rollService.memberCounts[roll.id] {
                    Label("\(count) member\(count == 1 ? "" : "s")", systemImage: "person.2.fill")
                        .font(.system(size: 13, weight: .medium))
                        .imageScale(.small)
                        .foregroundStyle(FlimTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                }

                // Shared-reveal anticipation banner while shots are still developing.
                if let revealAt = vm.developingPhotos.first?.developsAt {
                    revealBanner(revealAt: revealAt,
                                 shots: vm.developingPhotos.count,
                                 people: Set(vm.developingPhotos.map(\.userId)).count)
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
                            VStack(alignment: .leading, spacing: 0) {
                                if !vm.developingPhotos.isEmpty {
                                    sectionHeader("\(vm.developingPhotos.count) DEVELOPING")
                                    photoGrid(vm.developingPhotos, triggersLoadMore: false)
                                }
                                if !vm.developedPhotos.isEmpty {
                                    sectionHeader("DEVELOPED")
                                    photoGrid(vm.developedPhotos, triggersLoadMore: true)
                                }
                            }
                        }
                        .refreshable {
                            await vm.loadRoll(photoService: photoService, rollId: roll.id)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .top) {
            if coverToast {
                Label("Roll cover updated", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
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
                    Haptics.tap()
                    showInviteShare = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(FlimTheme.accent)
                }
                .accessibilityLabel("Share invite")

                Menu {
                    Button {
                        saveAll()
                    } label: { Label(savingAll ? "Saving…" : "Save all to Camera Roll", systemImage: "square.and.arrow.down.on.square") }
                        .disabled(savingAll || vm.developedPhotos.isEmpty)

                    if isCreator {
                        Button {
                            renameDraft = roll.name
                            showRename = true
                        } label: { Label("Rename roll", systemImage: "pencil") }
                        Button(role: .destructive) {
                            showDeleteRoll = true
                        } label: { Label("Delete roll", systemImage: "trash") }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(FlimTheme.accent)
                }
                .accessibilityLabel("More")
            }
        }
        .onAppear {
            Task { await vm.loadRoll(photoService: photoService, rollId: roll.id) }
            Task {
                if let members = try? await rollService.fetchMembers(for: roll.id) {
                    memberNames = Dictionary(members.map { ($0.id, $0.username ?? "unknown") },
                                             uniquingKeysWith: { first, _ in first })
                }
            }
        }
        .fullScreenCover(item: $selectedPhoto) { photo in
            FullScreenPhotoView(photo: photo, url: selectedURL,
                                photographer: memberNames[photo.userId],
                                onDelete: { Task { await vm.loadRoll(photoService: photoService, rollId: roll.id) } })
        }
        .sheet(isPresented: $showMembers) {
            RollMembersView(roll: roll)
        }
        .sheet(isPresented: $showShareAll) {
            ActivityView(items: shareImages)
        }
        .sheet(isPresented: $showInviteShare) {
            ActivityView(items: ["Join my roll “\(displayName.isEmpty ? roll.name : displayName)” on FLIM — use invite code \(roll.inviteCode)"])
        }
        .confirmationDialog("Delete this roll?", isPresented: $showDeleteRoll, titleVisibility: .visible) {
            Button("Delete Roll", role: .destructive) {
                Task {
                    try? await rollService.deleteRoll(rollId: roll.id)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The roll is removed for everyone. Each person keeps their own photos.")
        }
        .alert("Rename roll", isPresented: $showRename) {
            TextField("Roll name", text: $renameDraft)
            Button("Save") {
                let name = renameDraft.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                displayName = name
                Task { try? await rollService.renameRoll(rollId: roll.id, name: name) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func saveAll() {
        guard !savingAll else { return }
        savingAll = true
        Task {
            var images: [UIImage] = []
            for photo in vm.developedPhotos {
                if let url = try? await photoService.signedURL(for: photo.storagePath),
                   let (data, _) = try? await URLSession.shared.data(from: url),
                   let image = UIImage(data: data) {
                    images.append(image)
                }
            }
            shareImages = images
            savingAll = false
            if !images.isEmpty { showShareAll = true }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .medium)).tracking(2)
                .foregroundStyle(Color(white: 0.4))
            Spacer()
        }
        .padding(.horizontal, 6).padding(.top, 18).padding(.bottom, 8)
    }

    private func photoGrid(_ list: [Photo], triggersLoadMore: Bool) -> some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(list) { photo in
                PhotoGridCell(photo: photo, signedURL: vm.signedURLCache[photo.id])
                    .onTapGesture {
                        // Can't peek before it develops — only open ready shots.
                        guard photo.isReady else { return }
                        selectedURL = vm.signedURLCache[photo.id]
                        selectedPhoto = photo
                    }
                    .onLongPressGesture {
                        guard isCreator, photo.isReady else { return }
                        Haptics.select()
                        Task { await rollService.setRollCover(rollId: roll.id, path: photo.storagePath) }
                        withAnimation { coverToast = true }
                        Task { try? await Task.sleep(for: .seconds(1.6)); withAnimation { coverToast = false } }
                    }
                    .task {
                        if photo.isReady, vm.signedURLCache[photo.id] == nil {
                            _ = await vm.signedURL(for: photo, photoService: photoService)
                        }
                        if triggersLoadMore, photo.id == list.last?.id {
                            await vm.loadMoreRoll(photoService: photoService, rollId: roll.id)
                        }
                    }
            }
        }
        .padding(.horizontal, 2)
    }

    private func revealBanner(revealAt: Date, shots: Int, people: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let remaining = max(0, Int(revealAt.timeIntervalSince(timeline.date)))
                Label("Develops in \(Self.countdown(remaining))", systemImage: "hourglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(FlimTheme.accent)
            }
            Text("\(shots) shot\(shots == 1 ? "" : "s") waiting" + (people > 1 ? " from \(people) people" : ""))
                .font(.system(size: 12))
                .foregroundStyle(FlimTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(FlimTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16).padding(.bottom, 4)
    }

    private static func countdown(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }
}
