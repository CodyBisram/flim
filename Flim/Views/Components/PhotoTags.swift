import SwiftUI

/// Overlay for a shared photo: a small tag indicator that reveals name labels pinned at each
/// tagged person's (x, y). Tapping a label opens that profile. Apply via `.overlay { }` on the
/// photo, the labels position within the photo's own frame.
///
/// The indicator lives in the BOTTOM-left and never moves. Showing the labels hides it entirely
/// rather than relocating it, so it can't cover a label and there's only ever one place to look
/// for it; a tap anywhere on the photo puts everything back. It also fades out on its own after a
/// few seconds, so a photo worth looking at isn't permanently wearing a badge.
///
/// The full cycle, since it is easy to break one half while fixing the other: the indicator rests
/// for `fadeAfter`, fades over `fadeDuration`, and once faded a tap anywhere on the photo brings
/// it back over `returnDuration` and restarts the clock. Tapping it opens the labels; tapping off
/// a label closes them and restarts the clock too. Nothing about it is ever permanently gone.
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

    /// How long the fade itself takes.
    ///
    /// 1.6s, up from 0.5s. Half a second on a small element in a corner is below the threshold at
    /// which the eye reads a fade at all: it registers as the badge blinking out. A slow fade is
    /// legible as a deliberate retreat, and it also gives someone who was about to reach for it a
    /// moment to notice it going.
    private static let fadeDuration: TimeInterval = 1.6

    /// How long it takes to come back. Deliberately much faster than it leaves: a response to a
    /// tap has to feel immediate, while a self-initiated retreat should not.
    private static let returnDuration: TimeInterval = 0.28

    var body: some View {
        if !tags.isEmpty {
            GeometryReader { geo in
                ZStack {
                    // While the labels are up, a tap anywhere ELSE on the photo puts things back.
                    //
                    // Declared FIRST so it is genuinely underneath the labels. It used to be
                    // declared after them, which in a ZStack means on top, so this transparent
                    // layer swallowed every tap: tapping a handle dismissed the labels instead of
                    // opening that person's profile. The comment here always claimed it sat under
                    // the labels; only the z-order disagreed.
                    if showLabels {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { hideLabels() }
                    }

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
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .accessibilityLabel("Show tagged people")
                        .accessibilityHidden(!indicatorVisible)
                    }

                    // Once the indicator has faded, a tap ANYWHERE on the photo brings it back.
                    //
                    // It was technically still tappable in its own corner while invisible, which
                    // is not a real affordance: nobody hunts for a 26pt target they cannot see, so
                    // in practice a faded indicator was gone for good and the tags with it.
                    //
                    // Present only while faded, so it costs exactly one tap and only in the state
                    // where the photo had nothing else to offer. Note the trade: in a host that
                    // opens something on tap (post detail opens the viewer), that first tap
                    // revives the indicator instead. That is the intended exchange, not an
                    // oversight, and it is why this layer removes itself the moment it fires.
                    if !showLabels, !indicatorVisible {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { scheduleFade() }
                            .accessibilityHidden(true)
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
        // Animated on the way back in too. This used to be a bare assignment, so an indicator
        // returning from a tap popped in while the one leaving faded, which read as two different
        // controls rather than one coming and going.
        if !indicatorVisible {
            Haptics.tap()
            withAnimation(.easeOut(duration: Self.returnDuration)) { indicatorVisible = true }
        } else {
            indicatorVisible = true
        }
        fadeTask = Task {
            try? await Task.sleep(for: Self.fadeAfter)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: Self.fadeDuration)) { indicatorVisible = false }
        }
    }
}
