import SwiftUI

/// Overlay for a shared photo: a small tag indicator that reveals name labels pinned at each
/// tagged person's (x, y). Tapping a label opens that profile. Apply via `.overlay { }` on the
/// photo, the labels position within the photo's own frame.
///
/// The indicator rests in the BOTTOM-left and moves to the TOP-left while the labels are showing,
/// so it can't sit on top of a label pinned near the bottom of the photo.
struct PhotoTags: View {
    let tags: [PostTag]
    let profiles: [UUID: UserProfile]
    let onProfile: (UUID) -> Void

    @State private var showLabels = false

    var body: some View {
        if !tags.isEmpty {
            GeometryReader { geo in
                ZStack {
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

                    // Indicator, tap to toggle the labels.
                    //
                    // The corner is pinned by this view's OWN full-size frame rather than by the
                    // ZStack's alignment. The ZStack only fills the GeometryReader when the
                    // positioned labels above exist (`.position` claims all offered space), so
                    // with a plain `ZStack(alignment: .bottomLeading)` the stack collapsed to the
                    // size of this button while collapsed and got placed top-left, then jumped to
                    // the bottom the moment labels appeared. That corner swap was the bug.
                    Button { withAnimation(.snappy(duration: 0.25)) { showLabels.toggle() } } label: {
                        Image(systemName: "person.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: showLabels ? .topLeading : .bottomLeading)
                    .accessibilityLabel(showLabels ? "Hide tagged people" : "Show tagged people")
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }
}
