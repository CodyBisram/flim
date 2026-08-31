import Testing
import CoreImage
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import Flim

/// Disposable-camera flash falloff: the gate, the stage, and the proof that everything which is
/// not a flash frame comes out of the pipeline exactly as it did before this existed.
///
/// The whole feature rests on one property, and it is not an aesthetic one: a photograph whose
/// EXIF says the flash did not fire must be BYTE-IDENTICAL to what the previous build produced.
/// The app is on the App Store and every existing user, and the reviewer, is on the old look; a
/// look change that leaked into ambient frames would be a silent regrade of the entire product.
/// `nonFlashFixtureOutputIsByteIdentical` below is that proof, and the digests it compares against
/// were recorded on the pipeline as it stood BEFORE the flash stage was written, on two different
/// simulator device models, which agreed exactly.
struct FlashFalloffTests {

    // MARK: - Byte-identity of the non-flash path

    /// The fixtures that existed when the digests below were recorded.
    ///
    /// Named explicitly rather than derived from `LookFixture.allCases`, because the digests are a
    /// claim about a PREVIOUS REVISION and `allCases` is a fact about this one. Deriving the list
    /// would let a future fixture quietly join the table with a digest recorded after the change it
    /// is supposed to predate, which is the one way this file could stop being evidence.
    static let preFlashEraFixtures: [LookFixture] = [.night, .dusk, .speculars, .daylight,
                                                     .gamut, .oversize]

    /// SHA-256 of `InstantFilmProcessor.process(_:stock:)`'s JPEG bytes, per scene, recorded on
    /// the PRE-flash-falloff pipeline.
    ///
    /// Deliberately a digest of the encoded FILE rather than a statistic. The look pin next door
    /// measures frame averages with a tolerance, because that is the right instrument for "did the
    /// grade move". It is the wrong instrument for a gate: the gate either fired or it did not, and
    /// a tolerance would let a faint, uniform darkening of every ambient photograph in the product
    /// slip through as "inside half an 8-bit level". Bytes admit no such thing.
    ///
    /// These cover both fixture families and every branch a flash frame could plausibly disturb:
    /// the dark scenes that take adaptive exposure and the reduced-bloom path (`night`, `dusk`),
    /// the oversize scene that takes the 2048 downscale, and the owner's five real captures.
    /// Including `parkview-flash`, which is the useful adversarial case: a genuine flash photograph
    /// that must STILL be treated as non-flash, because its neutral-capture export carries no EXIF
    /// at all (measured: the Film Lab export re-encodes through `CGImageDestination` without
    /// metadata) and the only thing the gate is allowed to read is the EXIF bit.
    static let nonFlashDigests: [String: String] = [
        "night": "4650f94d910cdc47128c589144c4ca67521a18a029b22a8e8b9b86d472484bfd",
        "dusk": "cabee630941ed0f946803849a4a1b43a1ca29da59125fbceeab568ce7a6f889c",
        "speculars": "a9ef3222ed6dc29d0f288e3d681b42f00e06f55011d7864928cf74fbc0ade590",
        "daylight": "ac0bbaad33235c411f1ce2d8328d772520ad4705ffe7107c25cd730eb383d5b5",
        "gamut": "40253b436e456c1afedc980b8d8feaaafcf30455aed3c0c2f38597df1c0e137e",
        "oversize": "b604b6a370d23bd901f6a3d9ffd49b4fe738b703a32ec9dc87e12aea4540df07",
        "parkview-noflash": "041b75279fc6fb3c9d89fcb388654ea211624fa8152b9d6068aaa84edfbdb4d7",
        "wide-dim": "80e35af9054eaa70d93d48ca98bc8ea4df7a2dbf46fb32c75b53579e2225e8bf",
        "parkview-flash": "afbfc762f0361606ee7373113387c2fb82e5404cde13c46ab4aaefc9ec7d42e3",
        "restaurant-a": "3133f81306e559f0bc31389632d14a950c68f050fe69f1a4e90fdb21f4aaf74c",
        "plush": "cb1a34baabaf498ca30c736d8f05d327dcfff48beb9869ece61aa91170a09d32"
    ]

    static func digest(_ data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: 32)
        // CryptoKit is not linked into this target; a small, dependency-free SHA-256 keeps the
        // proof self-contained. Its correctness is checked by `digestMatchesAKnownVector` below.
        SHA256Lite.hash(Array(data), into: &hash)
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    @Test("the SHA-256 helper really is SHA-256")
    func digestMatchesAKnownVector() {
        #expect(Self.digest(Data("abc".utf8))
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(Self.digest(Data())
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test("a non-flash synthetic scene is byte-identical to the pre-flash-falloff pipeline",
          arguments: preFlashEraFixtures)
    func nonFlashFixtureOutputIsByteIdentical(_ fixture: LookFixture) async throws {
        #expect(fixture.firesFlash == false, "this test is only meaningful on non-flash inputs")
        let expected = try #require(Self.nonFlashDigests[fixture.rawValue],
                                    "no pre-change digest for \(fixture.rawValue)")
        let out = try #require(await InstantFilmProcessor.process(fixture.pngData(), stock: .original))
        #expect(Self.digest(out.data) == expected, """
            \(fixture.rawValue) is no longer byte-identical to the pre-flash-falloff pipeline. \
            The flash stage must be a complete no-op on anything whose EXIF flash bit is absent or \
            zero; every photograph already shipped, every existing user, and App Store review are \
            all on that path.
            """)
    }

    @Test("a non-flash real capture is byte-identical to the pre-flash-falloff pipeline",
          .enabled(if: LookPairs.isAvailable), arguments: LookPairs.scenes)
    func nonFlashPairOutputIsByteIdentical(_ scene: String) async throws {
        let expected = try #require(Self.nonFlashDigests[scene], "no pre-change digest for \(scene)")
        let data = try #require(LookPairs.neutralData(scene))
        let out = try #require(await InstantFilmProcessor.process(data, stock: .original))
        #expect(Self.digest(out.data) == expected,
                "\(scene) is no longer byte-identical to the pre-flash-falloff pipeline")
    }

    // MARK: - The gate

    /// The EXIF bit field, exhaustively, because `& 1` is the whole gate and getting it wrong in
    /// either direction is a shipped bug: treating 0x10 ("auto mode, did not fire") as a flash
    /// frame would darken ambient photographs taken with the flash set to auto, which is the app's
    /// own default flash setting.
    @Test("the gate reads bit 0 of EXIF Flash and nothing else",
          arguments: [(0x00, false),    // no flash function / did not fire
                      (0x01, true),     // fired
                      (0x05, true),     // fired, strobe return light not detected
                      (0x07, true),     // fired, strobe return light detected
                      (0x08, false),    // compulsory firing, did not fire
                      (0x09, true),     // fired, compulsory
                      (0x10, false),    // auto mode, did NOT fire
                      (0x18, false),    // auto mode, did not fire
                      (0x19, true),     // fired, auto mode
                      (0x20, false),    // no flash function
                      (0x41, true),     // fired, red-eye reduction
                      (0x50, false)])   // auto, did not fire, red-eye reduction
    func gateReadsTheFiredBit(_ value: Int, _ expected: Bool) throws {
        let data = try #require(Self.jpegCarrying(exifFlash: value))
        #expect(InstantFilmProcessor.flashFired(in: data) == expected,
                "EXIF Flash 0x\(String(value, radix: 16)) should read as fired=\(expected)")
    }

    @Test("a capture with no EXIF flash tag at all reads as did-not-fire")
    func gateFailsClosedWithoutTheTag() throws {
        let noExif = try #require(Self.jpegCarrying(exifFlash: nil))
        #expect(InstantFilmProcessor.flashFired(in: noExif) == false)
        // The fixtures the pin has always used are PNGs with no metadata, and every photograph
        // already in the product is in the same position.
        #expect(InstantFilmProcessor.flashFired(in: LookFixture.daylight.pngData()) == false)
        #expect(InstantFilmProcessor.flashFired(in: Data()) == false)
        #expect(InstantFilmProcessor.flashFired(in: Data("not an image".utf8)) == false)
    }

    @Test("the flash fixture really carries the EXIF bit, through a PNG")
    func flashFixtureReallyCarriesTheEXIFBit() {
        // If ImageIO ever stopped round-tripping EXIF through PNG's eXIf chunk, the flash fixture
        // would silently start rendering as an ambient frame and its pinned baseline would quietly
        // become a second copy of `flashAmbient`'s. The pin would still pass, measuring nothing.
        #expect(InstantFilmProcessor.flashFired(in: LookFixture.flash.pngData()))
        #expect(InstantFilmProcessor.flashFired(in: LookFixture.flashAmbient.pngData()) == false)
    }

    /// The matched pair, which is the gate stated as a measurement rather than as an argument.
    @Test("the flash pair differs by exactly the EXIF bit, and by exactly the stage")
    func matchedPairIsolatesTheGate() async throws {
        let flash = LookFixture.flash.pngData()
        let ambient = LookFixture.flashAmbient.pngData()

        // Same pixels. (Not the same bytes: one PNG carries an eXIf chunk.)
        let flashInput = try #require(LookMeasure.decode(flash))
        let ambientInput = try #require(LookMeasure.decode(ambient))
        #expect(Self.pixelDigest(flashInput) == Self.pixelDigest(ambientInput),
                "the flash pair must be pixel-identical; only their metadata may differ")

        let flashOut = try #require(await InstantFilmProcessor.process(flash, stock: .original))
        let ambientOut = try #require(await InstantFilmProcessor.process(ambient, stock: .original))

        // The ambient half must be exactly what the pipeline produces with the stage forced off.
        let stageOff = try #require(await InstantFilmProcessor.process(flash, stock: .original,
                                                                      flashOverride: false))
        #expect(Self.digest(ambientOut.data) == Self.digest(stageOff.data),
                "the un-tagged half of the pair is not identical to the stage being off")

        // And the flash half must not be.
        #expect(Self.digest(flashOut.data) != Self.digest(ambientOut.data),
                "the EXIF bit changed nothing; the gate is not wired to the stage")
    }

    // MARK: - What the stage does

    @Test("the stage only ever darkens, never brightens, any pixel")
    func flashFalloffOnlyEverDarkens() throws {
        // The map is clamped to at most 1 after the Lanczos upscale specifically so overshoot
        // cannot ring above unity and put light INTO a frame. A flash falloff that brightens
        // anywhere is not a falloff.
        let source = try #require(CIImage(data: LookFixture.flash.pngData()))
        let extent = source.extent
        let out = InstantFilmProcessor.flashFalloff(on: source, exponent: 1.0, extent: extent)
        let before = try #require(Self.samples(source, extent: extent))
        let after = try #require(Self.samples(out, extent: extent))
        var brightened = 0
        for (a, b) in zip(before, after) where b > a + 1 { brightened += 1 }
        #expect(brightened == 0, "\(brightened) samples got brighter under the falloff")
        #expect(zip(before, after).contains { $0 - $1 > 8 },
                "nothing measurably darkened; the stage did nothing at all")
    }

    @Test("exponent 0 is an exact no-op")
    func exponentZeroIsANoOp() throws {
        let source = try #require(CIImage(data: LookFixture.flash.pngData()))
        let out = InstantFilmProcessor.flashFalloff(on: source, exponent: 0, extent: source.extent)
        // Identical object identity is not required, identical pixels are.
        #expect(Self.samples(source, extent: source.extent) == Self.samples(out, extent: source.extent))
    }

    @Test("the stage is subject-shaped, not a centred radial")
    func falloffFollowsTheSubjectNotTheFrameCentre() throws {
        // Measured on the STAGE, not end to end, and that is deliberate. End to end this is
        // unmeasurable in exactly the region it matters: the shipped grain composite is
        // `.sourceOver`, which is a white veil rather than grey noise (see `precompensated`), so
        // any region the falloff crushes toward black gets lifted back to roughly 0.09 by the
        // grain alone. Two crushed corners then read as the same number whatever the falloff did
        // to them. Isolating the stage measures the thing the test is about.
        let source = try #require(CIImage(data: LookFixture.flash.pngData()))
        let extent = source.extent
        let out = InstantFilmProcessor.flashFalloff(on: source, exponent: 1.0, extent: extent)
        let before = try #require(Self.render(source, extent: extent))
        let after = try #require(Self.render(out, extent: extent))

        func kept(_ u: Double, _ v: Double) -> Double {
            let a = Self.regionLuma(after, u: u, v: v) ?? 0
            let b = Self.regionLuma(before, u: u, v: v) ?? 1
            return b > 0 ? a / b : 1
        }

        // The fixture's lit subject sits at (0.40, 0.58), left of centre and low.
        let subject = kept(0.40, 0.58)
        #expect(subject > 0.85, "the lit subject lost \(1 - subject) of its light; it should hold")

        // The two corners that a centred radial cannot tell apart. They are equidistant from the
        // frame's centre, so a vignette-shaped darkening would treat them identically. The flash
        // reached one of them and not the other, so this stage must not.
        let nearCorner = kept(0.10, 0.90)     // same side as the subject
        let farCorner = kept(0.90, 0.10)      // the corner the flash never reached
        #expect(farCorner < 0.35, "the unlit far corner kept \(farCorner) of its light")
        #expect(nearCorner > farCorner * 2, """
            the two corners equidistant from frame centre kept \(nearCorner) and \(farCorner). \
            A centred radial would keep the same fraction in both; this stage follows the light \
            rather than the frame.
            """)
    }

    /// How deep the falloff's blacks are ALLOWED to go, which is not a property of the falloff.
    ///
    /// The shipped grain composite is `.sourceOver`, and measured (`precompensated` has the
    /// numbers) that layer is a white veil at random opacity rather than grey noise, so it can only
    /// ever add light and it adds the most where there is least. Applied after this stage, it puts
    /// a floor under every region the falloff crushes: an area taken to true black comes back out
    /// at roughly 0.09 on the shipped path.
    ///
    /// This is recorded as a test rather than a comment because it is the ceiling on the whole
    /// feature. `.meanPreserving` already exists and is deliberately parked (flipping it splits the
    /// feed into two looks permanently), and this measures exactly what the flash look would gain
    /// if it is ever unparked. It is an observation, not a demand, so it asserts only the direction.
    @Test("the grain composite, not the falloff, sets how deep the shadows land")
    func grainCompositeBoundsTheShadowDepth() async throws {
        let data = LookFixture.flash.pngData()
        let shipped = try #require(await InstantFilmProcessor.process(data, stock: .original,
                                                                      grain: .sourceOver))
        let unbiased = try #require(await InstantFilmProcessor.process(data, stock: .original,
                                                                       grain: .meanPreserving))
        let shippedDeep = try #require(Self.shadowFraction(shipped.data))
        let unbiasedDeep = try #require(Self.shadowFraction(unbiased.data))
        #expect(unbiasedDeep > shippedDeep, """
            mean-preserving grain gave \(unbiasedDeep) below 0.04 against the shipped composite's \
            \(shippedDeep); the veil is supposed to be what holds the blacks up.
            """)
    }

    @Test("a flash frame gains the deep shadows a disposable actually has")
    func flashFrameGainsDeepShadows() async throws {
        // The audit's headline number: FLIM's flash frames had 0.00% of pixels below 0.04, where a
        // real single-use camera frame carries 15-35%. This is that number, on the pinned fixture.
        let ambient = try #require(await InstantFilmProcessor.process(LookFixture.flashAmbient.pngData(),
                                                                      stock: .original))
        let flash = try #require(await InstantFilmProcessor.process(LookFixture.flash.pngData(),
                                                                    stock: .original))
        let before = try #require(Self.shadowFraction(ambient.data))
        let after = try #require(Self.shadowFraction(flash.data))
        #expect(before < 0.01, "the ungated frame already has deep shadows; the fixture is wrong")
        #expect(after >= 0.15 && after <= 0.35,
                "flash frame has \(after) of its pixels below 0.04, want 0.15...0.35")
    }

    @Test("the shipped flash strength is the value the sweep settled on")
    func shippedStrengthIsPinned() {
        // Pinned like every other look number, for the reason the look pin gives: a range check
        // passes when someone nudges this, and a nudge here is a change to the product's signature
        // frame type. Re-fit with `FlashFalloffSweep` and get the owner to look at real photos
        // before moving it.
        #expect(FilmStock.original.params.flashFalloff == 1.0)
    }

    // MARK: - Measurement helpers

    /// Fraction of pixels whose Rec.601 luminance is below 0.04, the audit's shadow-depth number.
    static func shadowFraction(_ jpeg: Data, threshold: Double = 0.04) -> Double? {
        guard let cg = LookMeasure.decode(jpeg), let px = pixels(of: cg) else { return nil }
        var deep = 0
        for i in stride(from: 0, to: px.count, by: 4) {
            let l = 0.299 * Double(px[i]) + 0.587 * Double(px[i + 1]) + 0.114 * Double(px[i + 2])
            if l / 255 < threshold { deep += 1 }
        }
        return Double(deep) / Double(px.count / 4)
    }

    /// Mean luminance (0...255) of a small patch centred on a normalised (u, v) position, with v
    /// measured from the TOP of the frame like the fixture generator's own coordinates.
    static func regionLuma(_ jpeg: Data, u: Double, v: Double, radius: Int = 40) -> Double? {
        guard let cg = LookMeasure.decode(jpeg) else { return nil }
        return regionLuma(cg, u: u, v: v, radius: radius)
    }

    static func regionLuma(_ cg: CGImage, u: Double, v: Double, radius: Int = 40) -> Double? {
        guard let px = pixels(of: cg) else { return nil }
        let w = cg.width, h = cg.height
        let cx = Int(u * Double(w - 1)), cy = Int(v * Double(h - 1))
        var sum = 0.0, n = 0
        for y in max(0, cy - radius)...min(h - 1, cy + radius) {
            for x in max(0, cx - radius)...min(w - 1, cx + radius) {
                let i = (y * w + x) * 4
                sum += 0.299 * Double(px[i]) + 0.587 * Double(px[i + 1]) + 0.114 * Double(px[i + 2])
                n += 1
            }
        }
        return n > 0 ? sum / Double(n) : nil
    }

    /// A CIImage rendered to sRGB pixels, so a single stage can be measured without an encode.
    static func render(_ image: CIImage, extent: CGRect) -> CGImage? {
        LookMeasure.context.createCGImage(image, from: extent, format: .RGBA8,
                                          colorSpace: LookMeasure.srgb)
    }

    /// A coarse grid of luminance samples from a CIImage, for comparing two renders without
    /// materialising two full frames.
    static func samples(_ image: CIImage, extent: CGRect, steps: Int = 48) -> [Int]? {
        guard let cg = LookMeasure.context.createCGImage(image, from: extent, format: .RGBA8,
                                                         colorSpace: LookMeasure.srgb),
              let px = pixels(of: cg) else { return nil }
        var out: [Int] = []
        out.reserveCapacity(steps * steps)
        for sy in 0..<steps {
            let y = (cg.height - 1) * sy / max(1, steps - 1)
            for sx in 0..<steps {
                let x = (cg.width - 1) * sx / max(1, steps - 1)
                let i = (y * cg.width + x) * 4
                out.append(Int((299 * Int(px[i]) + 587 * Int(px[i + 1]) + 114 * Int(px[i + 2])) / 1000))
            }
        }
        return out
    }

    static func pixelDigest(_ cg: CGImage) -> String {
        guard let px = pixels(of: cg) else { return "unreadable" }
        return digest(Data(px))
    }

    static func pixels(of cg: CGImage) -> [UInt8]? {
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: LookMeasure.srgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return px
    }

    /// A tiny JPEG carrying (or deliberately not carrying) an EXIF `Flash` value.
    static func jpegCarrying(exifFlash: Int?) -> Data? {
        var px = [UInt8](repeating: 128, count: 16 * 16 * 4)
        guard let ctx = CGContext(data: &px, width: 16, height: 16, bitsPerComponent: 8,
                                  bytesPerRow: 16 * 4, space: LookMeasure.srgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cg = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString,
                                                          1, nil) else { return nil }
        var props: [CFString: Any] = [:]
        if let exifFlash {
            props[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifFlash: exifFlash] as [CFString: Any]
        }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}

// MARK: - Carrying the flash bit through the capture crop

/// The crop that runs between the sensor and the processor re-encodes through
/// `CGImageDestination`, which writes no metadata unless handed some, so before the flash work it
/// deleted the capture's entire EXIF block. Nothing read that block, so nothing noticed. The flash
/// gate reads it, so it would have meant the falloff silently not happening on any capture whose
/// crop actually fired.
struct CapturedPhotoCropperFlashTests {

    /// A capture-shaped image whose aspect ratio differs enough from the target that the crop
    /// really runs (the epsilon guard inside `centerCropRect` skips it otherwise).
    static func capture(exifFlash: Int?, width: Int = 400, height: Int = 300) -> Data? {
        var px = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                px[i] = UInt8((x * 255) / max(1, width - 1))
                px[i + 1] = UInt8((y * 255) / max(1, height - 1))
                px[i + 2] = 90
                px[i + 3] = 255
            }
        }
        guard let ctx = CGContext(data: &px, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: LookMeasure.srgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cg = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString,
                                                          1, nil) else { return nil }
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
        if let exifFlash {
            props[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifFlash: exifFlash] as [CFString: Any]
        }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    @Test("the crop carries the EXIF flash bit through to the processor")
    func cropPreservesTheFlashBit() throws {
        let fired = try #require(Self.capture(exifFlash: 0x19))
        #expect(InstantFilmProcessor.flashFired(in: fired))
        let cropped = try #require(CapturedPhotoCropper.croppedJPEGData(from: fired,
                                                                        targetAspectRatio: 0.75))
        #expect(InstantFilmProcessor.flashFired(in: cropped),
                "the crop dropped the flash bit; flash falloff would never fire on a cropped capture")
    }

    @Test("the crop does not invent a flash bit")
    func cropDoesNotInventAFlashBit() throws {
        for value in [nil, 0x00, 0x10] as [Int?] {
            let source = try #require(Self.capture(exifFlash: value))
            let cropped = try #require(CapturedPhotoCropper.croppedJPEGData(from: source,
                                                                            targetAspectRatio: 0.75))
            #expect(InstantFilmProcessor.flashFired(in: cropped) == false,
                    "the crop turned EXIF Flash \(String(describing: value)) into a flash frame")
        }
    }

    @Test("carrying the flash bit changes no pixels and no orientation")
    func cropIsPixelIdenticalWithAndWithoutTheTag() throws {
        // Only the one tag is copied, specifically so the source's ORIENTATION cannot come with it
        // and rotate every cropped photo. Same pixels, same size, either way.
        let withTag = try #require(Self.capture(exifFlash: 0x09))
        let without = try #require(Self.capture(exifFlash: nil))
        let a = try #require(CapturedPhotoCropper.croppedJPEGData(from: withTag, targetAspectRatio: 0.75))
        let b = try #require(CapturedPhotoCropper.croppedJPEGData(from: without, targetAspectRatio: 0.75))
        let ai = try #require(LookMeasure.decode(a)), bi = try #require(LookMeasure.decode(b))
        #expect(ai.width == bi.width && ai.height == bi.height)
        #expect(FlashFalloffTests.pixelDigest(ai) == FlashFalloffTests.pixelDigest(bi),
                "attaching the flash tag changed the cropped pixels")
        // And the orientation tag really is absent, so nothing downstream rotates.
        let source = try #require(CGImageSourceCreateWithData(a as CFData, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let tiff = props?[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        #expect(props?[kCGImagePropertyOrientation] == nil)
        #expect(tiff?[kCGImagePropertyTIFFOrientation] == nil)
    }
}

// MARK: - The strength sweep

/// Where `flashFalloff`'s default came from.
///
/// The doctrine on this codebase is that look numbers are measured, not felt, and this one has an
/// unusually concrete target to measure against: a real single-use camera frame carries 15 to 35%
/// of its pixels below 0.04 luminance, and FLIM's flash frames carried 0.00%. So the sweep walks
/// the exponent and reports, per scene, that shadow fraction plus the frame statistics the look pin
/// already speaks in, and the default is the value that lands the real captures inside that window
/// without collapsing the lit subject.
///
///     TEST_RUNNER_FLIM_FLASH_SWEEP=1 xcodebuild test -project Flim.xcodeproj -scheme Flim \
///       -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
///       -only-testing:FlimTests/FlashFalloffSweep
///
/// The real captures are forced through the stage with `flashOverride`, because the Film Lab's
/// neutral export strips EXIF and they would otherwise be measured as ambient frames. That override
/// exists for exactly this and is never taken in production.
struct FlashFalloffSweep {
    static let isSweeping = ProcessInfo.processInfo.environment["FLIM_FLASH_SWEEP"] == "1"
    static let isPreviewing = ProcessInfo.processInfo.environment["FLIM_FLASH_PREVIEW"] == "1"

    static let exponents: [CGFloat] = [0, 0.6, 0.8, 1.0, 1.15, 1.3, 1.5, 1.8, 2.2]

    /// Scenes where a flash genuinely fired: the synthetic fixture, plus the owner's two real
    /// flash captures.
    static let scenes: [String] = ["flash"]
        + (LookPairs.isAvailable ? ["parkview-flash", "hallway-flash"] : [])

    static func sourceData(_ scene: String) -> Data? {
        if let fixture = LookFixture(rawValue: scene) { return fixture.pngData() }
        return LookPairs.neutralData(scene)
    }

    @Test("flash falloff strength sweep", .enabled(if: isSweeping), arguments: scenes)
    func sweep(_ scene: String) async throws {
        let data = try #require(Self.sourceData(scene))
        for exponent in Self.exponents {
            try await Self.row(scene, data, exponent, grain: .sourceOver)
        }
        // One extra row per scene with the mean-preserving grain composite, which is built,
        // measured better, and parked (see `GrainComposite`). It is the ceiling this feature is
        // being measured against: the shipped veil holds crushed blacks up at about 0.09, so this
        // row says what the flash look would gain if that decision is ever revisited.
        try await Self.row(scene, data, 1.0, grain: .meanPreserving)
    }

    private static func row(_ scene: String, _ data: Data, _ exponent: CGFloat,
                            grain: InstantFilmProcessor.GrainComposite) async throws {
        var params = FilmStock.original.params
        params.flashFalloff = exponent
        let stock = FilmStock(id: "sweep", name: "sweep", tagline: "", params: params)
        // Wall-clock for the whole capture-time grade, so the stage's cost (an extra downscale,
        // blur, area-maximum readback, upscale and multiply, plus one forced evaluation for the
        // readback) is on the record next to what it buys. Compare any row against that scene's
        // k=0.00 row, which is the pipeline without the stage.
        let started = Date()
        let out = try #require(await InstantFilmProcessor.process(data, stock: stock,
                                                                  grain: grain,
                                                                  flashOverride: exponent > 0))
        let elapsed = Date().timeIntervalSince(started) * 1000
        let stats = try #require(LookMeasure.stats(ofJPEG: out.data))
        let shadow = try #require(FlashFalloffTests.shadowFraction(out.data))
        let deeper = try #require(FlashFalloffTests.shadowFraction(out.data, threshold: 0.10))
        print("""
        FLASHSWEEP scene=\(scene) k=\(String(format: "%.2f", exponent)) \
        grain=\(grain == .sourceOver ? "sourceOver" : "meanPreserving") \
        below04=\(String(format: "%.4f", shadow)) below10=\(String(format: "%.4f", deeper)) \
        mean=\(String(format: "%.5f", (stats.meanR + stats.meanG + stats.meanB) / 3)) \
        p5=\(String(format: "%.5f", stats.lumP5)) p50=\(String(format: "%.5f", stats.lumP50)) \
        p95=\(String(format: "%.5f", stats.lumP95)) \
        sat=\(String(format: "%.5f", stats.meanSaturation)) \
        lc=\(String(format: "%.5f", stats.localContrast)) bytes=\(out.data.count) \
        ms=\(String(format: "%.0f", elapsed))
        """)
    }

    /// Writes before/after JPEGs for every flash scene so the look can be LOOKED AT, which is the
    /// only test that actually decides this. Numbers say the shadows arrived; they cannot say
    /// whether the photograph is better.
    ///
    ///     TEST_RUNNER_FLIM_FLASH_PREVIEW=1 xcodebuild test -project Flim.xcodeproj -scheme Flim \
    ///       -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
    ///       -only-testing:FlimTests/FlashFalloffSweep/writePreviews
    ///
    /// Output goes to `pairs/_flash_preview/`, INSIDE the gitignored calibration directory and
    /// deliberately so: these are renders of the owner's own photographs and must never be
    /// committed. The path is printed on the way out. Simulator output is evidence, not approval;
    /// the device shots in the feel-test list are what settles the strength.
    @Test("write before/after previews for the owner", .enabled(if: isPreviewing), arguments: scenes)
    func writePreviews(_ scene: String) async throws {
        let directory = LookPairs.directory.appendingPathComponent("_flash_preview")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try #require(Self.sourceData(scene))
        for (label, fired) in [("before", false), ("after", true)] {
            let out = try #require(await InstantFilmProcessor.process(data, stock: .original,
                                                                      flashOverride: fired))
            let url = directory.appendingPathComponent("\(scene)_\(label).jpg")
            try out.data.write(to: url)
            print("FLASHPREVIEW \(url.path)")
        }
    }
}

/// Minimal SHA-256, so the byte-identity proof does not depend on a framework being linked.
enum SHA256Lite {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]

    static func hash(_ message: [UInt8], into out: inout [UInt8]) {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                           0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var padded = message
        let bitLength = UInt64(message.count) * 8
        padded.append(0x80)
        while padded.count % 64 != 56 { padded.append(0) }
        for i in (0..<8).reversed() { padded.append(UInt8((bitLength >> (UInt64(i) * 8)) & 0xff)) }

        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: padded.count, by: 64) {
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = (UInt32(padded[j]) << 24) | (UInt32(padded[j + 1]) << 16)
                     | (UInt32(padded[j + 2]) << 8) | UInt32(padded[j + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3]
            var e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1
                d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        for i in 0..<8 {
            out[i * 4] = UInt8((h[i] >> 24) & 0xff)
            out[i * 4 + 1] = UInt8((h[i] >> 16) & 0xff)
            out[i * 4 + 2] = UInt8((h[i] >> 8) & 0xff)
            out[i * 4 + 3] = UInt8(h[i] & 0xff)
        }
    }

    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
}

/// Prints the pre-change digest table for `FlashFalloffTests.nonFlashDigests`.
///
/// Run this BEFORE a change that is supposed to leave the non-flash path alone, never after, or
/// this file stops being evidence of anything:
///
///     TEST_RUNNER_FLIM_RECORD_FLASH_DIGESTS=1 xcodebuild test -project Flim.xcodeproj \
///       -scheme Flim -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
///       -only-testing:FlimTests/FlashDigestRecorder
struct FlashDigestRecorder {
    static let isRecording = ProcessInfo.processInfo.environment["FLIM_RECORD_FLASH_DIGESTS"] == "1"

    @Test("record non-flash digests: fixtures", .enabled(if: isRecording),
          arguments: LookFixture.allCases.filter { !$0.firesFlash })
    func recordFixtures(_ fixture: LookFixture) async throws {
        let out = try #require(await InstantFilmProcessor.process(fixture.pngData(), stock: .original))
        print("DIGEST \"\(fixture.rawValue)\": \"\(FlashFalloffTests.digest(out.data))\",")
    }

    @Test("record non-flash digests: pairs",
          .enabled(if: isRecording && LookPairs.isAvailable), arguments: LookPairs.scenes)
    func recordPairs(_ scene: String) async throws {
        let data = try #require(LookPairs.neutralData(scene))
        let out = try #require(await InstantFilmProcessor.process(data, stock: .original))
        print("DIGEST \"\(scene)\": \"\(FlashFalloffTests.digest(out.data))\",")
    }
}
