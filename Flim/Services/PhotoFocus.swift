import CoreGraphics
import ImageIO
import UIKit
import Vision

/// Where a photograph's subject is, for crops that show only part of it (a month box's 3:2 cover
/// shows half of a 3:4 frame). On device, from the image already decoded for the screen: the
/// faces Vision finds, else a person's head, else the middle as before. Nothing leaves the phone
/// and nothing is stored past the session.
///
/// No attention-saliency fallback: tried on a standing portrait whose face Vision missed, it
/// chose the legs and the floor, a worse crop than the middle (2026-11-14).
enum PhotoFocus {
    /// What to keep in view, in 0...1 coordinates with the origin at the photo's top left.
    struct Subject: Equatable, Sendable {
        /// The one thing that must stay in: the largest face, or a person's head.
        var primary: CGRect
        /// Everything of that kind together (every face), kept in when it fits.
        var group: CGRect
        var kind: Kind
        /// The decoded image's width over height.
        var aspect: CGFloat
    }

    enum Kind: Sendable { case face, person }

    /// The top of a window `visible` tall (a fraction of the photo's height) that keeps the
    /// subject in view. Faces and heads sit a little above the window's middle, for headroom; the
    /// whole group when it fits, else the primary. No subject is the middle, as before.
    static func windowTop(for subject: Subject?, visible: CGFloat) -> CGFloat {
        guard visible < 1 else { return 0 }
        let centred = (1 - visible) / 2
        guard let subject else { return centred }
        let rect = subject.group.height <= visible * 0.9 ? subject.group : subject.primary
        var top = rect.midY - visible * 0.42
        // A face is never cut at the top of the window when the window can hold it.
        if rect.height < visible { top = min(top, rect.minY - min(0.04, (visible - rect.height) / 2)) }
        return min(max(top, 0), 1 - visible)
    }

    // MARK: - Finding it

    private static let cache = NSCache<NSString, Box>()
    private final class Box { let subject: Subject?; init(_ subject: Subject?) { self.subject = subject } }

    /// The cached answer for `key`, if this session has asked already. `.some(nil)` means asked,
    /// and nothing was found.
    static func cached(_ key: String) -> Subject?? {
        cache.object(forKey: key as NSString).map { $0.subject }
    }

    /// Finds the subject of `image`, once per `key` per session, off the main thread.
    static func subject(of image: UIImage, key: String) async -> Subject? {
        if let hit = cached(key) { return hit }
        guard let cg = image.cgImage else { return nil }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        let size = image.size
        let found = await Task.detached(priority: .utility) {
            find(in: cg, orientation: orientation, aspect: size.height > 0 ? size.width / size.height : 0.75)
        }.value
        cache.setObject(Box(found), forKey: key as NSString)
        return found
    }

    /// Vision's two passes, faces first. Vision's rectangles are normalised with the
    /// origin at the bottom left, so each is flipped to top-left.
    static func find(in image: CGImage, orientation: CGImagePropertyOrientation, aspect: CGFloat) -> Subject? {
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation)
        let faces = VNDetectFaceRectanglesRequest()
        let people = VNDetectHumanRectanglesRequest()
        people.upperBodyOnly = false
        try? handler.perform([faces, people])

        let faceBoxes = (faces.results ?? []).map { flip($0.boundingBox) }
        if let largest = faceBoxes.max(by: { $0.area < $1.area }) {
            return Subject(primary: largest, group: union(faceBoxes), kind: .face, aspect: aspect)
        }
        // A person whose face Vision can't read (turned away, in shadow, cut off): their head is
        // the top seventh of the box.
        let bodies = (people.results ?? []).filter { $0.confidence > 0.5 }.map { flip($0.boundingBox) }
        if let largest = bodies.max(by: { $0.area < $1.area }) {
            let head = { (b: CGRect) in CGRect(x: b.minX, y: b.minY, width: b.width, height: b.height / 7) }
            return Subject(primary: head(largest), group: union(bodies.map(head)), kind: .person, aspect: aspect)
        }
        return nil
    }

    private static func flip(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
    }

    private static func union(_ rects: [CGRect]) -> CGRect {
        rects.dropFirst().reduce(rects.first ?? .zero) { $0.union($1) }
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}

extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
