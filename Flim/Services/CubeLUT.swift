import CoreImage
import Foundation

/// Loads and applies Adobe/Resolve `.cube` 3D LUTs via `CIColorCubeWithColorSpace`.
///
/// To use one: add a `.cube` file to the app bundle (e.g. `FlimFilm.cube`) and set a film stock's
/// `params.lut` to its name (no extension). The LUT then defines the color grade.
enum CubeLUT {
    /// A parsed LUT ready for Core Image.
    struct Loaded {
        let dimension: Int
        let data: Data   // Float32 RGBA, dimension³ × 4 values
    }

    // Parsing a .cube on every capture is wasteful — cache by resource name (nil = tried + failed).
    private static var cache: [String: Loaded?] = [:]

    /// Returns the parsed LUT for a bundle resource name, or nil if it's missing/malformed.
    static func load(_ name: String) -> Loaded? {
        if let cached = cache[name] { return cached }
        let loaded = parse(name)
        cache[name] = loaded
        return loaded
    }

    /// Applies the LUT to an image (sRGB working space). Returns the input unchanged on failure.
    static func apply(_ name: String, to image: CIImage) -> CIImage {
        guard let lut = load(name),
              let filter = CIFilter(name: "CIColorCubeWithColorSpace") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(lut.dimension, forKey: "inputCubeDimension")
        filter.setValue(lut.data, forKey: "inputCubeData")
        filter.setValue(CGColorSpace(name: CGColorSpace.sRGB), forKey: "inputColorSpace")
        return filter.outputImage ?? image
    }

    // MARK: - Parsing

    private static func parse(_ name: String) -> Loaded? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "cube"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(contents: text)
    }

    /// The core `.cube` text parser, separate from bundle-file loading so it's directly
    /// testable against in-memory fixtures. Case-insensitive on `LUT_3D_SIZE`; returns `nil`
    /// if the size line is missing or the value count doesn't match `dimension³ × 3`.
    static func parse(contents text: String) -> Loaded? {
        var dimension = 0
        var values: [Float] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.uppercased().hasPrefix("LUT_3D_SIZE") {
                dimension = Int(line.split(separator: " ").last.map(String.init) ?? "") ?? 0
                continue
            }
            // Skip other metadata (TITLE, DOMAIN_MIN/MAX, LUT_1D_SIZE, etc.).
            if line.first?.isLetter == true { continue }
            let parts = line.split(separator: " ").compactMap { Float($0) }
            if parts.count == 3 {
                // .cube orders red fastest — same layout CIColorCube expects — so append in order.
                values.append(contentsOf: [parts[0], parts[1], parts[2], 1.0])
            }
        }

        guard dimension > 1, values.count == dimension * dimension * dimension * 4 else { return nil }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        return Loaded(dimension: dimension, data: data)
    }
}
