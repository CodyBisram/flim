import SwiftUI

/// Instagram-style "Tag People" screen: the photo at a fixed 3:4 frame; tap anywhere to drop a tag
/// (pick a person), tap a tag to remove it. Returns the tags via a binding.
struct TagPhotoSheet: View {
    let url: URL?
    @Binding var tags: [PendingTag]

    @Environment(\.dismiss) private var dismiss
    @State private var showPicker = false
    @State private var pendingPoint: CGPoint?   // normalized (0…1), awaiting a person

    var body: some View {
        NavigationStack {
            ZStack {
                FlimTheme.bg.ignoresSafeArea()
                VStack(spacing: 14) {
                    Text(tags.isEmpty ? "Tap the photo to tag someone" : "Tap a tag to remove it")
                        .font(.system(size: 13)).foregroundStyle(FlimTheme.textTertiary)
                        .padding(.top, 8)

                    GeometryReader { geo in
                        ZStack(alignment: .topLeading) {
                            if let url {
                                CachedImage(url: url, maxPixel: 1200) { $0.resizable().scaledToFit() } placeholder: {
                                    ShimmerPlaceholder(cornerRadius: 14)
                                }
                            } else {
                                ShimmerPlaceholder(cornerRadius: 14)
                            }

                            ForEach(tags) { tag in
                                tagMarker(tag)
                                    .position(x: tag.x * geo.size.width, y: tag.y * geo.size.height)
                            }
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .contentShape(Rectangle())
                        .onTapGesture(coordinateSpace: .local) { location in
                            pendingPoint = CGPoint(x: location.x / geo.size.width,
                                                   y: location.y / geo.size.height)
                            showPicker = true
                        }
                    }
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    .padding(.horizontal, 16)

                    Spacer()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .flimInlineTitle("Tag People")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(FlimTheme.accent).fontWeight(.semibold)
                }
            }
        }
        .sheet(isPresented: $showPicker) {
            PersonPickerSheet(exclude: Set(tags.map(\.user.id))) { profile in
                if let p = pendingPoint {
                    tags.append(PendingTag(user: profile, x: p.x, y: p.y))
                }
                pendingPoint = nil
            }
        }
    }

    private func tagMarker(_ tag: PendingTag) -> some View {
        HStack(spacing: 4) {
            Text(tag.user.handle)
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(.black.opacity(0.72), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
        .contentShape(Capsule())
        .onTapGesture { tags.removeAll { $0.id == tag.id } }
    }
}
