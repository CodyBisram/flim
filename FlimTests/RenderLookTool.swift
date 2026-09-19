import Foundation
import Testing
@testable import Flim

/// Not a test: a way to run the real capture pipeline over a file from the command line, so a
/// photograph taken outside FLIM can carry the exact shipped look (the LUT, the adaptive
/// exposure, bloom, vignette, grain, the flash falloff if the EXIF says so). Skipped unless
/// both paths are set:
///
///   TEST_RUNNER_FLIM_RENDER_IN=/path/in.jpg TEST_RUNNER_FLIM_RENDER_OUT=/path/out.jpg \
///   xcodebuild test -scheme Flim -only-testing:FlimTests/RenderLookTool ...
///
/// Written 2026-09-18 when the owner asked for a phone photo to be straightened and graded
/// into his Darkroom; anything else that approximated the look in Python would not be FLIM's.
@Suite struct RenderLookTool {
    @Test("render a file through the shipped look, when asked to")
    func render() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let inPath = env["FLIM_RENDER_IN"], let outPath = env["FLIM_RENDER_OUT"] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: inPath))
        let out = try #require(await InstantFilmProcessor.process(data, stock: .original))
        try out.data.write(to: URL(fileURLWithPath: outPath))
        print("RENDERED \(out.data.count) bytes as \(out.format) to \(outPath)")
    }
}
