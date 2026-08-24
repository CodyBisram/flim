import SwiftUI

/// The Darkroom's one-unit-per-night rendering: a night's band + contact-sheet film rack, the
/// sticky month band, the sort row, and the loading skeleton. Pulled out of `DarkroomView.swift`
/// because that file already owns the screen's state, actions, and delete/undo flow.

// MARK: - Day unit (band + rack)

struct DarkroomDayUnitView: View {
    let unit: DarkroomDayUnit
    let capacity: Int
    let showsMonth: Bool
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
                Text(unit.title(shortForm: showsMonth))
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
                .frame(width: DarkroomDayUnit.framePitch - DarkroomDayUnit.frameGap, height: 44)
                .accessibilityHidden(true)
        }
    }

    private func perforation(slotCount: Int) -> some View {
        DarkroomPerforationLine()
            .frame(width: DarkroomDayUnit.perforationWidth(slotCount: slotCount), height: 3)
    }
}

/// The repeating-dash perforation line above (and below the last of) a strip.
private struct DarkroomPerforationLine: View {
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
    @ViewBuilder var menu: () -> AnyView

    var body: some View {
        imageArea
        .frame(width: 36, height: 44)
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelecting {
                onToggleSelect()
            } else if photo.isReady {
                onTap()
            }
        }
        .contextMenu { menu() }
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(photo.isReady ? .isButton : [])
    }

    @ViewBuilder
    private var imageArea: some View {
        ZStack(alignment: .topTrailing) {
            if photo.isReady {
                CachedImage(url: signedURL, maxPixel: 120, cacheKey: photo.displayPath) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.06)
                }
                .frame(width: 30, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .matchedTransitionSource(id: photo.id, in: photoNS)
            } else {
                developingWell
            }
            if isSelecting {
                selectionOverlay
            }
        }
        .frame(width: 30, height: 40)
        // The shared mark rides INSIDE the photograph's bottom edge (owner's call, on device,
        // 2026-08-24: the reserved under-frame slot left every strip floating loose inside its
        // perforations, and a 14x2 bar at the very bottom of the image costs about 1% of it).
        // The faint shadow keeps it legible over a bright bottom edge without scrimming anything.
        .overlay(alignment: .bottom) {
            if photo.isReady, isShared {
                Capsule()
                    .fill(accent)
                    .frame(width: 14, height: 2)
                    .shadow(color: .black.opacity(0.55), radius: 1)
                    .padding(.bottom, 2)
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
                    .frame(width: 9, height: 9)
            )
            .frame(width: 30, height: 40)
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

// MARK: - Sort row

/// The one accent-labelled row on the screen: a shortcut into the sort deck, with up to three
/// preview thumbnails from distinct nights. Hidden entirely at zero unsorted, and while
/// selecting (it is a destination, select is a mode).
struct DarkroomSortRowView: View {
    let accent: Color
    let count: Int
    let previewPhotos: [Photo]
    let previewURLs: [UUID: URL]
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onTap) {
                HStack(spacing: 10) {
                    Text("\(count) shot\(count == 1 ? "" : "s") to sort")
                        .flimFont(14, weight: .medium)
                        .foregroundStyle(accent)
                    Spacer(minLength: 8)
                    HStack(spacing: 2) {
                        ForEach(previewPhotos) { photo in
                            CachedImage(url: previewURLs[photo.id], maxPixel: 120, cacheKey: photo.displayPath) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Color.white.opacity(0.06)
                            }
                            .frame(width: 30, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                        }
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13))
                        .foregroundStyle(FlimTheme.textTertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(count) shot\(count == 1 ? "" : "s") to sort")
            .accessibilityAddTraits(.isButton)

            DarkroomUnitSeparator()
        }
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
                                .frame(width: 30, height: 40)
                                .frame(width: 36, height: 44)
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
