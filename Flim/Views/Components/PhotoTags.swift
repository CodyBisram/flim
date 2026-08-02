import SwiftUI

/// Overlay for a shared photo: a small tag indicator that reveals name labels pinned at each
/// tagged person's (x, y). Tapping a label opens that profile. Apply via `.overlay { }` on the
/// photo, the labels position within the photo's own frame.
///
/// The indicator lives in the BOTTOM-left and never moves. Showing the labels hides it entirely
/// rather than relocating it, so it can't cover a label and there's only ever one place to look
/// for it; a tap anywhere on the photo puts everything back. It also fades out on its own after a
/// few seconds, so a photo worth looking at isn't permanently wearing a badge, and comes back
/// with a tap.
struct PhotoTags: View {
    let tags: [PostTag]
    let profiles: [UUID: UserProfile]
    let onProfile: (UUID) -> Void

    @State private var showLabels = false
    /// The resting indicator fades itself out; any tap on the photo brings it back.
    @State private var indicatorVisible = true
    @State private var fadeTask: Task<Void, Never>?

    /// How long the indicator sits there before fading. Long enough to notice, short enough that
    /// it isn't part of the photo.
    private static let fadeAfter: Duration = .seconds(5)

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

                    // While the labels are up, a tap anywhere on the photo puts things back. Sits
                    // UNDER the labels and the indicator so tapping either of those still does
                    // its own thing.
                    if showLabels {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { hideLabels() }
                    }

                    // Indicator, tap to show the labels. Hidden entirely while they're up.
                    //
                    // The corner is pinned by this view's OWN full-size frame rather than by the
                    // ZStack's alignment. The ZStack only fills the GeometryReader when the
                    // positioned labels above exist (`.position` claims all offered space), so
                    // with a plain `ZStack(alignment: .bottomLeading)` the stack collapsed to the
                    // size of this button and got placed top-left, then jumped to the bottom the
                    // moment labels appeared. Pinning it here is what keeps it in one corner.
                    if !showLabels {
                        Button { revealLabels() } label: {
                            Image(systemName: "person.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 26, height: 26)
                                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
                        }
                        .opacity(indicatorVisible ? 1 : 0)
                        // Still tappable once faded, so its corner keeps working as a target and
                        // the first tap brings it back rather than being swallowed.
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .accessibilityLabel("Show tagged people")
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .onAppear { scheduleFade() }
                .onDisappear { fadeTask?.cancel() }
            }
        }
    }

    private func revealLabels() {
        fadeTask?.cancel()
        Haptics.tap()
        withAnimation(.snappy(duration: 0.25)) {
            indicatorVisible = true      // so it's already there when the labels close again
            showLabels = true
        }
    }

    private func hideLabels() {
        withAnimation(.snappy(duration: 0.25)) { showLabels = false }
        scheduleFade()                   // indicator is back, and restarts its clock
    }

    /// Fades the resting indicator out after a few seconds so it stops sitting on the photo.
    /// Cancelled and restarted rather than stacked, so re-showing never leaves an older timer
    /// running that would fade it early.
    private func scheduleFade() {
        fadeTask?.cancel()
        indicatorVisible = true
        fadeTask = Task {
            try? await Task.sleep(for: Self.fadeAfter)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.5)) { indicatorVisible = false }
        }
    }
}
