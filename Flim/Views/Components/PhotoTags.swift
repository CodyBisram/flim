import SwiftUI

/// Overlay for a shared photo: a small tag indicator (bottom-left) that reveals name labels pinned
/// at each tagged person's (x, y). Tapping a label opens that profile. Apply via `.overlay { }` on
/// the photo — the labels position within the photo's own frame.
struct PhotoTags: View {
    let tags: [PostTag]
    let profiles: [UUID: UserProfile]
    let onProfile: (UUID) -> Void

    @State private var showLabels = false

    var body: some View {
        if !tags.isEmpty {
            GeometryReader { geo in
                ZStack(alignment: .bottomLeading) {
                    if showLabels {
                        ForEach(tags) { tag in
                            if let profile = profiles[tag.taggedUserId] {
                                Button { onProfile(tag.taggedUserId) } label: {
                                    Text(profile.handle)
                                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                                        .padding(.horizontal, 9).padding(.vertical, 5)
                                        .background(.black.opacity(0.72), in: Capsule())
                                        .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                                        .fixedSize()
                                }
                                .position(x: tag.x * geo.size.width, y: tag.y * geo.size.height)
                                .transition(.opacity.combined(with: .scale(scale: 0.8)))
                            }
                        }
                    }

                    // Indicator — tap to toggle the labels.
                    Button { withAnimation(.snappy(duration: 0.25)) { showLabels.toggle() } } label: {
                        Image(systemName: "person.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
                    }
                    .padding(10)
                    .accessibilityLabel(showLabels ? "Hide tagged people" : "Show tagged people")
                }
            }
        }
    }
}
