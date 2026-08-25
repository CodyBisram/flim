import SwiftUI

/// The Darkroom's one-unit-per-night rendering: a night's band + contact-sheet film rack, the
/// sticky month band, the sort row, and the loading skeleton. Pulled out of `DarkroomView.swift`
/// because that file already owns the screen's state, actions, and delete/undo flow.

// MARK: - Day unit (band + rack)

struct DarkroomDayUnitView: View {
    let unit: DarkroomDayUnit
    let capacity: Int
    let accent: Color
    let signedURLCache: [UUID: URL]
    let sharedIds: Set<UUID>
    let isSelecting: Bool
    let selectedIDs: Set<UUID>
    let rollName: (UUID?) -> String?
    let photoNS: Namespace.ID
    let onTapDeveloped: (Photo) -> Void
    let onToggleSelect: (UUID) -> Void
    let developedMenu: (Photo) -> AnyView
    let developingMenu: (Photo) -> AnyView
    /// Fires once per real frame as it appears: resolves its signed URL if still missing, and
    /// (only for the very last ready frame in render order) triggers the next page load.
    let onFrameAppear: (Photo) async -> Void

    private var strips: [DarkroomFilmStrip] { DarkroomDayUnit.cutStrips(photos: unit.photos, capacity: capacity) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            band
            rack
        }
    }

    private var band: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // Month bands render unconditionally now (see `DarkroomView.nightList`'s own
                // doc), so the day title is always the short form; the full "Sat 16 Aug" form
                // stays reachable for the pager header (`PhotoPagerView.currentNightTitle`),
                // which has no band of its own to say the month.
                Text(unit.title(shortForm: true))
                    .flimFont(17, weight: .light)
                    .tracking(0.4)
                    .foregroundStyle(FlimTheme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let pillText = unit.developingPillText() {
                    Text(pillText)
                        .flimFont(11, weight: .medium)
                        .foregroundStyle(accent)
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .overlay(Capsule().stroke(accent.opacity(0.42), lineWidth: 1))
                }
            }
            Text(unit.metaLine(sharedIds: sharedIds))
                .flimFont(11.5)
                .foregroundStyle(FlimTheme.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 10)
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.bottom, 5)
        .accessibilityElement(children: .combine)
    }

    private var rack: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(strips) { strip in
                perforation(slotCount: strip.slots.count)
                HStack(spacing: 2) {
                    ForEach(strip.slots) { slot in frameView(slot) }
                }
                .padding(.vertical, 2)
            }
            if let last = strips.last {
                perforation(slotCount: last.slots.count)
            }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func frameView(_ slot: DarkroomFrameSlot) -> some View {
        switch slot {
        case .photo(let photo):
            DarkroomFrameView(
                photo: photo,
                accent: accent,
                signedURL: signedURLCache[photo.id],
                isShared: sharedIds.contains(photo.id),
                rollName: rollName(photo.rollId),
                isSelecting: isSelecting,
                isSelected: selectedIDs.contains(photo.id),
                photoNS: photoNS,
                onTap: { onTapDeveloped(photo) },
                onToggleSelect: { onToggleSelect(photo.id) },
                menu: { photo.isReady ? developedMenu(photo) : developingMenu(photo) }
            )
            .task { await onFrameAppear(photo) }
        case .empty:
            // An unexposed slot: holds its space, draws nothing, no hit target.
            Color.clear
                .frame(width: DarkroomDayUnit.framePitch - DarkroomDayUnit.frameGap, height: 56)
                .accessibilityHidden(true)
        }
    }

    private func perforation(slotCount: Int) -> some View {
        DarkroomPerforationLine()
            .frame(width: DarkroomDayUnit.perforationWidth(slotCount: slotCount), height: 3)
    }
}

/// The repeating-dash perforation line above (and below the last of) a strip. Also reused by
/// `PhotoPagerView`'s own night-rack (the same atom above and below that row too), so this is
/// package-visible rather than private to this file.
struct DarkroomPerforationLine: View {
    var body: some View {
        GeometryReader { geo in
            Path { path in
                path.move(to: CGPoint(x: 0, y: geo.size.height / 2))
                path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height / 2))
            }
            .stroke(FlimTheme.stroke, style: StrokeStyle(lineWidth: 3, dash: [4, 6]))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - One frame

struct DarkroomFrameView: View {
    let photo: Photo
    let accent: Color
    let signedURL: URL?
    let isShared: Bool
    let rollName: String?
    let isSelecting: Bool
    let isSelected: Bool
    let photoNS: Namespace.ID
    let onTap: () -> Void
    let onToggleSelect: () -> Void
    /// `nil` skips `.contextMenu` entirely rather than attaching one with nothing in it: an empty
    /// `.contextMenu` still triggers the long-press blur/preview with nothing to show. The
    /// pager's own rack (Phase C) has no long-press action at all, so it passes `nil`; the grid
    /// keeps passing a real menu.
    var menu: (() -> AnyView)? = nil
    /// The pager's own rack, added in Phase C: `true` draws a 1.5pt accent ring around the
    /// image, `false` dims it to 45% opacity, `nil` (every caller before this one, the
    /// Darkroom's own night-per-unit grid) leaves the frame exactly as it always rendered, no
    /// ring or dim ever applied there.
    var isCurrent: Bool? = nil
    /// The pager's own rack renders a developing frame as a live jump target (tapping it lands
    /// the pager on that photo's develops-at state); the grid's long-press menu is still the
    /// only way to act on a developing frame there, so every existing caller keeps `false`.
    var allowsDevelopingTap: Bool = false
    /// An empty outlined well instead of the image, for a frame whose fetch failed. Only the
    /// pager's rack can be in this state; the grid never sets it.
    var isFailed: Bool = false
    /// The pager's own night rack, at the feed strip's own density: a bare 30x40 frame with no
    /// padding to 36x44 and no gesture or accessibility wrapper of its own. The row above this
    /// frame owns ONE `SpatialTapGesture` resolving where a touch landed (see
    /// `PhotoPagerView.rackSection`), matching `FeedUnitCard.FilmStrip`'s own tap mechanism
    /// verbatim; a per-frame recognizer here would compete with that gesture for the same touch.
    /// The list's own grid (every caller before this one) never sets this and keeps its 36x44
    /// frame, own tap gesture, and own accessibility element exactly as before.
    var compact: Bool = false

    /// The list's frames are 42x56 (readable, PR 1 of the zoom redesign); the pager's compact
    /// rack keeps the feed strip's 30x40. One shared `imageArea`, two geometries.
    private var imgW: CGFloat { compact ? 30 : 42 }
    private var imgH: CGFloat { compact ? 40 : 56 }

    var body: some View {
        if let menu {
            frame.contextMenu { menu() }
        } else {
            frame
        }
    }

    @ViewBuilder
    private var frame: some View {
        if compact {
            // No tap gesture of its own (the row's SpatialTapGesture owns touches), but each
            // frame stays its OWN accessibility element with the button trait: VoiceOver focuses
            // frames individually and a double-tap lands a synthetic touch at the frame's
            // center, which the row's recognizer resolves to exactly this frame.
            imageArea
                .accessibilityElement()
                .accessibilityLabel(accessibilityLabel)
                .accessibilityAddTraits(.isButton)
        } else {
            imageArea
            .frame(width: imgW, height: imgH)
            .contentShape(Rectangle())
            .onTapGesture {
                if isSelecting {
                    onToggleSelect()
                } else if photo.isReady || allowsDevelopingTap {
                    onTap()
                }
            }
            .accessibilityElement()
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits((photo.isReady || allowsDevelopingTap) ? .isButton : [])
        }
    }

    @ViewBuilder
    private var imageArea: some View {
        ZStack(alignment: .topTrailing) {
            if isFailed {
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(FlimTheme.stroke, lineWidth: 1)
                    .frame(width: imgW, height: imgH)
            } else if photo.isReady {
                CachedImage(url: signedURL, maxPixel: 120, cacheKey: photo.displayPath) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.06)
                }
                .frame(width: imgW, height: imgH)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .matchedTransitionSource(id: photo.id, in: photoNS)
            } else {
                developingWell
            }
            if isSelecting {
                selectionOverlay
            }
        }
        .frame(width: imgW, height: imgH)
        .overlay {
            if isCurrent == true {
                RoundedRectangle(cornerRadius: 2).stroke(accent, lineWidth: 1.5)
            }
        }
        .opacity(isCurrent == false ? 0.45 : 1)
        // The shared mark rides INSIDE the photograph's bottom edge (owner's call, on device,
        // 2026-08-24: the reserved under-frame slot left every strip floating loose inside its
        // perforations, and a 14x2 bar at the very bottom of the image costs about 1% of it).
        // A dark keyline plus a stronger shadow keep it legible on bright bottoms too (2026-08-24
        // follow-up: the shadow alone washed out on a light sky/wall), without a scrim behind it
        // or any change to its size.
        .overlay(alignment: .bottom) {
            if photo.isReady, isShared {
                Capsule()
                    .fill(accent)
                    .frame(width: 14, height: 2)
                    .overlay(Capsule().strokeBorder(Color.black.opacity(0.5), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.7), radius: 1.5)
                    .padding(.bottom, compact ? 2 : 3)
            }
        }
    }

    private var developingWell: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color(white: 0.063))
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(FlimTheme.stroke, lineWidth: 1)
            )
            .overlay(
                Circle()
                    .strokeBorder(accent.opacity(0.7), lineWidth: 1.5)
                    .frame(width: compact ? 9 : 11, height: compact ? 9 : 11)
            )
            .frame(width: imgW, height: imgH)
    }

    private var selectionOverlay: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(isSelected ? 0.4 : 0.001))
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? accent : .white.opacity(0.85))
                .padding(2)
                .shadow(radius: 1)
        }
        .allowsHitTesting(false)
    }

    /// Parity with what `PhotoGridCell` announces today: date, roll membership if any, shared
    /// state, developing state.
    private var accessibilityLabel: String {
        photo.isReady
            ? "Photo\(rollName.map { " from \($0)" } ?? ""), \(photo.takenAt.formatted(date: .abbreviated, time: .omitted))\(isShared ? ", shared to your page" : "")"
            : "Developing photo"
    }
}

// MARK: - Unit separator

/// A 1pt hairline between day units, faded to transparent over 48pt at each end.
struct DarkroomUnitSeparator: View {
    var body: some View {
        GeometryReader { geo in
            let fade = geo.size.width > 0 ? min(0.45, 48 / geo.size.width) : 0
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: FlimTheme.stroke, location: fade),
                    .init(color: FlimTheme.stroke, location: 1 - fade),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading, endPoint: .trailing)
        }
        .frame(height: 1)
        .padding(.top, 11)
        .padding(.horizontal, 16)
        .accessibilityHidden(true)
    }
}

// MARK: - Month band

/// A sticky section header naming the month, with its server-counted shot total when one is
/// known, and a caret. Solid background so frames scroll under it. The whole band is the tap
/// target for the jump sheet, one object rather than a label plus a separate filter chip.
struct DarkroomMonthBandView: View {
    let group: DarkroomMonthGroup
    /// The server's photo count for this month, `nil` when the RPC hasn't answered (the count
    /// segment is then omitted entirely, never a page-derived guess and never "0 shots").
    let shotCount: Int?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(group.title().uppercased())
                        .flimFont(12, weight: .semibold)
                        .tracking(1.1)
                        .foregroundStyle(FlimTheme.textSecondary)
                    if let shotCount {
                        Text("· \(shotCount) shot\(shotCount == 1 ? "" : "s")")
                            .flimFont(11.5)
                            .foregroundStyle(FlimTheme.textTertiary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(FlimTheme.textTertiary)
                }
                LinearGradient(
                    stops: [
                        .init(color: FlimTheme.stroke, location: 0),
                        .init(color: .clear, location: 0.6),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .leading, endPoint: .trailing)
                    .frame(height: 1)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FlimTheme.bg)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits([.isHeader, .isButton])
        .accessibilityHint("Jump to month")
    }
}

// MARK: - Sort banner

/// The one accent-labelled surface on the screen: a shortcut into the sort deck, with up to
/// three preview thumbnails from distinct nights. Pinned under the header, outside the scroll
/// (PR 2 of the zoom redesign, 2026-08-25), so it stays visible at every scroll offset rather
/// than scrolling away the moment a scan reaches night two. `DarkroomView` mounts this at all
/// only when there's something to sort and nobody's mid-select: hidden entirely at zero
/// unsorted, and while selecting (it is a destination, select is a mode).
struct DarkroomSortBanner: View {
    let accent: Color
    let count: Int
    /// Distinct nights among the unsorted photos (see `DarkroomDayUnit.distinctNightCount`'s
    /// own doc for why deriving this client-side, here, is correct).
    let nightCount: Int
    let previewPhotos: [Photo]
    let previewURLs: [UUID: URL]
    let onTap: () -> Void

    /// New copy pending owner sign-off. Kept as one named constant so a reword touches exactly
    /// one place.
    private var subtitle: String {
        "from \(nightCount) night\(nightCount == 1 ? "" : "s") \u{00B7} keep or share"
    }

    /// 26pt-wide thumbs overlapped by 9pt (17pt visible pitch each).
    private var deckWidth: CGFloat {
        guard !previewPhotos.isEmpty else { return 0 }
        return 26 + CGFloat(previewPhotos.count - 1) * 17
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(count) shot\(count == 1 ? "" : "s") to sort")
                        .flimFont(13.5, weight: .medium)
                        .foregroundStyle(accent)
                    Text(subtitle)
                        .flimFont(11)
                        .foregroundStyle(FlimTheme.textTertiary)
                }
                Spacer(minLength: 8)
                previewDeck
                Image(systemName: "chevron.right")
                    .font(.system(size: 13))
                    .foregroundStyle(accent)
            }
            .padding(.top, 9)
            .padding(.bottom, 9)
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .background(
                LinearGradient(
                    stops: [
                        .init(color: accent.opacity(0.09), location: 0),
                        .init(color: .clear, location: 0.7)
                    ],
                    startPoint: .leading, endPoint: .trailing)
            )
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(accent.opacity(0.42), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(count) shot\(count == 1 ? "" : "s") to sort")
        .accessibilityAddTraits(.isButton)
    }

    /// A small overlapped deck reading front-to-back: the first preview photo sits frontmost
    /// (drawn last, on top), the rest recede behind it toward the trailing edge. Built as an
    /// offset `ZStack` rather than a negative-spacing `HStack`: an `HStack`'s later (rightmost)
    /// child paints on top, which would put the LAST preview photo frontmost instead of the
    /// first.
    private var previewDeck: some View {
        ZStack(alignment: .leading) {
            ForEach(Array(previewPhotos.enumerated().reversed()), id: \.element.id) { index, photo in
                CachedImage(url: previewURLs[photo.id], maxPixel: 120, cacheKey: photo.displayPath) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.06)
                }
                .frame(width: 26, height: 35)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(FlimTheme.bg, lineWidth: 1))
                .offset(x: CGFloat(index) * 17)
            }
        }
        .frame(width: deckWidth, height: 35, alignment: .leading)
    }
}

// MARK: - Loading skeleton

/// Real geometry instead of `LoadingGrid`: four skeleton night units, each a breathing band
/// (two bars) over one static rack strip of three empty wells. Only the bars animate.
struct DarkroomLoadingSkeleton: View {
    private let barWidths: [(title: CGFloat, meta: CGFloat)] = [
        (150, 78), (112, 58), (168, 92), (98, 52)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<4, id: \.self) { i in
                VStack(alignment: .leading, spacing: 6) {
                    DarkroomSkeletonBar(width: barWidths[i].title, height: 15)
                    DarkroomSkeletonBar(width: barWidths[i].meta, height: 9)
                }
                .padding(.top, 10)
                .padding(.leading, 16)
                .padding(.trailing, 12)
                .padding(.bottom, 5)

                VStack(alignment: .leading, spacing: 0) {
                    DarkroomPerforationLine().frame(width: DarkroomDayUnit.perforationWidth(slotCount: 3), height: 3)
                    HStack(spacing: 2) {
                        ForEach(0..<3, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.white.opacity(0.06))
                                .frame(width: 42, height: 56)
                        }
                    }
                    .padding(.vertical, 2)
                    DarkroomPerforationLine().frame(width: DarkroomDayUnit.perforationWidth(slotCount: 3), height: 3)
                }
                .padding(.horizontal, 16)

                if i < 3 { DarkroomUnitSeparator() }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct DarkroomSkeletonBar: View {
    let width: CGFloat
    let height: CGFloat
    @State private var dim = false

    var body: some View {
        RoundedRectangle(cornerRadius: height / 2.5)
            .fill(FlimTheme.bgElevated)
            .frame(width: width, height: height)
            .opacity(dim ? 0.45 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}
