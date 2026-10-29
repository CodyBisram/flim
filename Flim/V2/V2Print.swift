import SwiftUI
import UIKit

/// The print's proportions, as fractions of its width, measured from the prototype's full-size
/// print (340 pt wide: a 16 pt border on three sides, a 93 pt foot) so a print of any size keeps
/// the same shape. The window is FLIM's 3:4 frame (`FlimTheme.frameAspect`), so a photograph is
/// never cropped to fit a print.
enum V2PrintGeometry {
    static let borderFraction: CGFloat = 16.0 / 340
    static let footFraction: CGFloat = 93.0 / 340
    /// Height over width of the photograph's window.
    static let windowAspect: CGFloat = 4.0 / 3
    /// The date stamp's segment height, as a fraction of the window's width.
    static let stampCellFraction: CGFloat = 0.045

    static func border(width: CGFloat) -> CGFloat { width * borderFraction }
    static func foot(width: CGFloat) -> CGFloat { width * footFraction }
    static func windowWidth(width: CGFloat) -> CGFloat { width - border(width: width) * 2 }
    static func windowHeight(width: CGFloat) -> CGFloat { windowWidth(width: width) * windowAspect }
    static func height(width: CGFloat) -> CGFloat {
        border(width: width) + windowHeight(width: width) + foot(width: width)
    }
    /// The width of the print that fits a box, whichever side binds.
    static func width(fitting size: CGSize) -> CGFloat {
        let perUnitHeight = height(width: 1)
        return max(0, min(size.width, size.height / perUnitHeight))
    }
}

/// The card every print is drawn on: cream, an i-Type border on three sides, the window and the
/// foot. `V2Print` puts a photograph and its caption in it; the camera puts the viewfinder and its
/// controls in it. The card is always cream, whatever the desk: "Prints are always cream. That
/// part isn't a setting."
struct V2PrintCard<Window: View, Foot: View>: View {
    let width: CGFloat
    /// Rotation on the desk, a degree or two for a print lying loose.
    var tilt: Angle = .zero
    var showsShadow = true
    /// The border as a fraction of the width. The full-size print's 16 of 340 by default; the
    /// feed's group print is drawn tighter (10 of 232).
    var borderFraction: CGFloat = V2PrintGeometry.borderFraction
    /// The foot as a fraction of the width.
    var footFraction: CGFloat = V2PrintGeometry.footFraction
    @ViewBuilder var window: () -> Window
    @ViewBuilder var foot: () -> Foot

    @Environment(\.v2Palette) private var palette

    var body: some View {
        let border = width * borderFraction
        let windowWidth = width - border * 2
        VStack(spacing: 0) {
            window()
                .frame(width: windowWidth, height: windowWidth * V2PrintGeometry.windowAspect)
                .clipped()
                .padding(.top, border)
            foot()
                .frame(width: windowWidth, height: width * footFraction)
        }
        .frame(width: width)
        // The shadow belongs to the card alone. Hung on the whole print, SwiftUI shadows each
        // layer inside it too, and the photograph and the caption picked up shadows of their own.
        .background(
            Rectangle()
                .fill(V2Color.print)
                .shadow(color: showsShadow ? palette.shadowNear.color : .clear,
                        radius: palette.shadowNear.radius, y: palette.shadowNear.y)
                .shadow(color: showsShadow ? palette.shadowFar.color : .clear,
                        radius: palette.shadowFar.radius, y: palette.shadowFar.y)
        )
        .rotationEffect(tilt)
    }
}

/// One print: the photograph in a 3:4 window, the caption in the foot, and the date stamp burned
/// into the window's bottom right in the bright stamp colour.
struct V2Print<Photo: View>: View {
    let width: CGFloat
    var caption: String?
    /// The day the photograph was taken; nil leaves the window unstamped.
    var date: Date?
    var tilt: Angle = .zero
    var showsShadow = true
    @ViewBuilder var photo: () -> Photo

    @Environment(\.v2Stamp) private var stamp

    var body: some View {
        let windowWidth = V2PrintGeometry.windowWidth(width: width)
        V2PrintCard(width: width, tilt: tilt, showsShadow: showsShadow) {
            photo()
                .frame(width: windowWidth, height: V2PrintGeometry.windowHeight(width: width))
                .clipped()
                .overlay(alignment: .bottomTrailing) {
                    if let date {
                        V2DateStamp(text: BrandedExport.dateText(.init(date: date)),
                                    cellHeight: windowWidth * V2PrintGeometry.stampCellFraction,
                                    stamp: stamp)
                            .padding(.trailing, windowWidth * 0.04)
                            .padding(.bottom, windowWidth * 0.035)
                    }
                }
        } foot: {
            HStack {
                if let caption, !caption.isEmpty {
                    // 17 pt italic at the full 340 pt print, scaled with the print so a small
                    // print's foot reads as the same handwriting, smaller.
                    Text(caption)
                        .font(V2Type.serif(max(9, 17 * width / 340), italic: true))
                        .foregroundStyle(V2Color.printInk)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4 * width / 340)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The burned-in date: FLIM's segment display (BrandedExport's own cell, the same one the export
/// prints), in the bright stamp colour with its glow. Fixed size, like every stamp.
struct V2DateStamp: View {
    let text: String
    let cellHeight: CGFloat
    let stamp: V2Stamp

    var body: some View {
        if let image = Self.image(text: text, cellHeight: cellHeight, stamp: stamp) {
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: image.size.width / Self.renderScale,
                       height: image.size.height / Self.renderScale)
                // The handoff's 5 pt glow in the stamp's own colour, then a dark one under it so
                // the mark holds on a bright sky.
                .shadow(color: stamp.bright.opacity(0.75), radius: cellHeight * 0.12)
                .shadow(color: .black.opacity(0.5), radius: cellHeight * 0.3)
                // The segment image carries a one-cell margin for the glow; cancel it so the
                // padding the print gives is the visible inset.
                .padding(-cellHeight)
                .accessibilityLabel(text)
        }
    }

    /// The segment image is drawn at 1x by BrandedExport; drawing it larger and showing it smaller
    /// keeps the bars crisp at the sizes a print uses.
    static let renderScale: CGFloat = 3

    static func image(text: String, cellHeight: CGFloat, stamp: V2Stamp) -> UIImage? {
        let cell = CGSize(width: cellHeight * BrandedExport.cellAspect * renderScale,
                          height: cellHeight * renderScale)
        return BrandedExport.segmentImage(text, cell: cell, colour: stamp.brightUIColor, ghost: 0.17)
    }
}
