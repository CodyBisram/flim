import SwiftUI

/// The recap's closing card, "the month in numbers": shown by `ChapterRecapView` after the viewer
/// closes, for a month `ChapterRecapViewModel.hasClosingCard` says has anything to say. Has its
/// own X that ends the recap for good, and a small "Play again" text button back into the viewer.
///
/// Reuses the opening card's own radial wash rather than inventing new chrome, and speaks the same
/// film-edge language the opening card's `CHAPTER 08` kicker and date stamp do: a mono, accent
/// value under a light label, not a badge pill. Takes plain values and closures, same split as
/// `BadgePickerContent`, so it previews and screenshots without a live recap session behind it.
struct ChapterClosingCardView: View {
    @Environment(\.flimAccent) private var accent

    let monthName: String
    let lines: [ChapterStatLine]
    /// Signed URLs for every line's `photoThumbPath`, resolved by the caller before this ever
    /// renders (`ChapterRecapViewModel.load()` folds these into the same `urls` map the viewer
    /// uses). Missing entries just show the placeholder tile rather than blocking the card.
    let thumbURLs: [String: URL]
    let onSelectPhoto: (ChapterStatLine) -> Void
    let onPlayAgain: () -> Void
    let onClose: () -> Void

    /// Drives this card's own swipe-to-dismiss, same as the opening card's `cardOffset`: a plain
    /// drag-anywhere gesture, not a paging surface, so `View.swipeToDismiss(offset:onDismiss:)`
    /// applies exactly the way it does there.
    @State private var cardOffset: CGSize = .zero

    var body: some View {
        ZStack {
            radialWash
            VStack(spacing: 0) {
                closeButton
                header
                Spacer(minLength: 16)
                VStack(alignment: .leading, spacing: 26) {
                    ForEach(lines) { line in
                        lineRow(line)
                    }
                }
                .padding(.horizontal, 32)
                Spacer(minLength: 16)
                Button {
                    Haptics.tap()
                    onPlayAgain()
                } label: {
                    Text("Play again")
                        .flimFont(14, weight: .medium, relativeTo: .subheadline)
                        .foregroundStyle(accent)
                }
                .padding(.bottom, 30)
            }
        }
        .transition(.opacity)
        .swipeToDismiss(offset: $cardOffset) { Haptics.tap(); onClose() }
    }

    private var closeButton: some View {
        HStack {
            Button {
                Haptics.tap()
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .accessibilityLabel("Close")
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text(monthName.uppercased())
                .flimFont(11, weight: .medium, relativeTo: .caption)
                .tracking(2)
                .foregroundStyle(Color(white: 0.5))
                .padding(.top, 22)

            Text("The month in numbers")
                .flimFont(20, weight: .light, relativeTo: .title3)
                .foregroundStyle(.white)
        }
    }

    private var radialWash: some View {
        GeometryReader { geo in
            // Same reasoning as the opening card's own wash: fill the whole screen and let the
            // gradient fade to `.clear` well inside it, so nothing draws a visible ring at a
            // shorter frame's edge.
            RadialGradient(colors: [accent.opacity(0.24), .clear],
                           center: UnitPoint(x: 0.5, y: 0.22), startRadius: 0,
                           endRadius: geo.size.width * 0.85)
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func lineRow(_ line: ChapterStatLine) -> some View {
        if line.opensPhoto {
            Button {
                Haptics.tap()
                onSelectPhoto(line)
            } label: {
                lineContent(line)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens this photo")
        } else {
            lineContent(line)
        }
    }

    private func lineContent(_ line: ChapterStatLine) -> some View {
        HStack(alignment: .center, spacing: 14) {
            if let path = line.photoThumbPath {
                CachedImage(url: thumbURLs[path], maxPixel: 200, cacheKey: path) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.06)
                }
                // Small, 3:4, the app's own frame shape, matching every other photo tile in FLIM.
                .frame(width: 48, height: 48 / FlimTheme.frameAspect)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(line.label.uppercased())
                    .flimFont(11, weight: .light, relativeTo: .caption)
                    .tracking(1.5)
                    .foregroundStyle(Color(white: 0.55))
                valueLine(line)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(line.label), \(line.value)")
    }

    /// The value itself, mono and in the accent, matching `CHAPTER 08`/the date stamp's own
    /// language. Split in two for `.mostReacted` when it carries an emoji suffix: SF Mono (what
    /// `design: .monospaced` actually is) doesn't reliably cascade to Apple Color Emoji when an
    /// emoji sits inline in the same `Text`, and renders a tofu box instead. Rendering the emoji
    /// in the system's own default-design font, right next to the mono count, sidesteps that
    /// without giving up mono styling for the digits.
    @ViewBuilder
    private func valueLine(_ line: ChapterStatLine) -> some View {
        if let (count, emoji) = Self.mostReactedEmojiSuffix(line) {
            HStack(spacing: 6) {
                Text(count)
                    .flimFont(17, weight: .medium, design: .monospaced, relativeTo: .body)
                    .foregroundStyle(accent)
                Text(emoji)
                    .flimFont(17, relativeTo: .body)
            }
        } else {
            Text(line.value)
                .flimFont(17, weight: .medium, design: .monospaced, relativeTo: .body)
                .foregroundStyle(accent)
        }
    }

    /// Splits `line.value` into its numeric prefix and trailing emoji when it's the emoji form of
    /// the "Most reacted" line ("12 ❤️"), as opposed to the plain-count form ("12 reactions"/"12
    /// reaction"), the only two shapes `ChapterStatsFormatting` ever produces for that line.
    private static func mostReactedEmojiSuffix(_ line: ChapterStatLine) -> (count: String, emoji: String)? {
        guard line.kind == .mostReacted else { return nil }
        guard !line.value.hasSuffix("reactions"), !line.value.hasSuffix("reaction") else { return nil }
        guard let spaceIndex = line.value.lastIndex(of: " ") else { return nil }
        let count = String(line.value[..<spaceIndex])
        let emoji = String(line.value[line.value.index(after: spaceIndex)...])
        guard !count.isEmpty, !emoji.isEmpty else { return nil }
        return (count, emoji)
    }
}

// MARK: - Previews

#Preview("Full five lines") {
    ZStack {
        Color.black.ignoresSafeArea()
        ChapterClosingCardView(
            monthName: "August",
            lines: [
                ChapterStatLine(kind: .mostReacted, label: "Most reacted", value: "12 ❤️",
                                 photoId: UUID(), photoThumbPath: "demo.jpg"),
                ChapterStatLine(kind: .mostCommented, label: "Most commented", value: "5 comments",
                                 photoId: UUID(), photoThumbPath: "demo2.jpg"),
                ChapterStatLine(kind: .busiestDay, label: "Busiest day", value: "Saturday the 12th · 9 shots",
                                 photoId: nil, photoThumbPath: nil),
                ChapterStatLine(kind: .nightOwl, label: "After dark", value: "7 shots between 10pm and 4am",
                                 photoId: nil, photoThumbPath: nil),
                ChapterStatLine(kind: .rolls, label: "Rolls", value: "3 rolls · 7 people",
                                 photoId: nil, photoThumbPath: nil),
            ],
            thumbURLs: [:],
            onSelectPhoto: { _ in }, onPlayAgain: {}, onClose: {}
        )
    }
}

#Preview("One line only") {
    ZStack {
        Color.black.ignoresSafeArea()
        ChapterClosingCardView(
            monthName: "March",
            lines: [
                ChapterStatLine(kind: .busiestDay, label: "Busiest day", value: "Tuesday the 3rd · 2 shots",
                                 photoId: nil, photoThumbPath: nil),
            ],
            thumbURLs: [:],
            onSelectPhoto: { _ in }, onPlayAgain: {}, onClose: {}
        )
    }
}
