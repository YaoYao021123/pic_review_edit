import CoreImage
import Foundation
import Testing
@testable import MediaCore

struct FilmEffectsTests {
    /// A 96×64 sRGB scene with hue across and brightness down, optionally under a gray haze.
    private func scene(haze: Double = 0) -> CIImage {
        let width = 96, height = 64
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let h = Double(x) / Double(width), v = 0.1 + 0.85 * Double(y) / Double(height)
            let rgb = [v * (0.5 + 0.5 * cos(2 * .pi * h)), v * (0.5 + 0.5 * cos(2 * .pi * (h - 0.33))), v * (0.5 + 0.5 * cos(2 * .pi * (h - 0.66)))]
            let i = (y * width + x) * 4
            for c in 0..<3 { bytes[i + c] = UInt8(min(255, max(0, (rgb[c] * (1 - haze) + 0.8 * haze) * 255))) }
        } }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                            space: ColorPipeline.outputSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return CIImage(cgImage: image)
    }

    private func pixels(_ image: CIImage) -> [Float] {
        let extent = image.extent.integral
        var out = [Float](repeating: 0, count: Int(extent.width * extent.height) * 4)
        out.withUnsafeMutableBytes {
            ColorPipeline.shared.render(image, toBitmap: $0.baseAddress!, rowBytes: Int(extent.width) * 16, bounds: extent,
                                        format: .RGBAf, colorSpace: ColorPipeline.outputSpace)
        }
        return out
    }

    private func render(_ image: CIImage, _ change: (inout BasicAdjustments) -> Void) throws -> [Float] {
        var edits = MediaEdits()
        change(&edits.adjustments)
        return pixels(try ColorPipeline.grade(image, edits: edits))
    }

    /// Spread of luminance: haze flattens it, dehaze should restore it.
    private func spread(_ p: [Float]) -> Float {
        let luma = stride(from: 0, to: p.count, by: 4).map { 0.2126 * p[$0] + 0.7152 * p[$0 + 1] + 0.0722 * p[$0 + 2] }
        let mean = luma.reduce(0, +) / Float(luma.count)
        return (luma.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(luma.count)).squareRoot()
    }

    @Test func testDehazeRestoresContrastAndAddingHazeFlattensIt() throws {
        let hazy = scene(haze: 0.45)
        let before = spread(pixels(hazy))
        let cleared = spread(try render(hazy) { $0.dehaze = 70 })
        let foggier = spread(try render(hazy) { $0.dehaze = -70 })
        #expect(cleared > before * 1.25, "dehaze \(before) → \(cleared)")
        #expect(foggier < before * 0.85, "add haze \(before) → \(foggier)")
        #expect(try render(hazy) { $0.dehaze = 70 }.allSatisfy(\.isFinite))
    }

    @Test func testBlackAndWhiteRemovesColorAndKeepsBrightness() throws {
        let image = scene()
        let gray = try render(image) { $0.monochrome = 100 }
        for i in stride(from: 0, to: gray.count, by: 4) {
            #expect(abs(gray[i] - gray[i + 1]) < 0.004 && abs(gray[i + 1] - gray[i + 2]) < 0.004)
        }
        let half = try render(image) { $0.monochrome = 50 }
        let original = pixels(image)
        let chroma = { (p: [Float]) in stride(from: 0, to: p.count, by: 4).map { max(p[$0], p[$0 + 1], p[$0 + 2]) - min(p[$0], p[$0 + 1], p[$0 + 2]) }.reduce(0, +) }
        #expect(chroma(half) < chroma(original) * 0.75 && chroma(half) > chroma(original) * 0.25)
    }

    @Test func testFadeLiftsBlacksAndLowersWhites() throws {
        var bytes = [UInt8](repeating: 0, count: 8 * 4)
        for x in 4..<8 { for c in 0..<3 { bytes[x * 4 + c] = 255 } }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let cg = CGImage(width: 8, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 32, space: ColorPipeline.outputSpace,
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                         decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let faded = try render(CIImage(cgImage: cg)) { $0.fade = 100 }
        #expect(abs(faded[0] - 0.13) < 0.01, "black → \(faded[0])")
        #expect(abs(faded[16] - 0.91) < 0.01, "white → \(faded[16])")
    }

    @Test func testGrainIsRepeatableAndOnlyAtNonZero() throws {
        let image = scene()
        let first = try render(image) { $0.grain = 80 }
        let second = try render(image) { $0.grain = 80 }
        #expect(first == second, "grain must not change between renders")
        let original = pixels(image)
        let change = zip(first, original).map { abs($0 - $1) }.reduce(0, +) / Float(first.count)
        #expect(change > 0.005, "grain too faint: \(change)")
        #expect(change < 0.08, "grain too strong: \(change)")
        #expect(try render(image) { $0.grain = 0 } == original)
    }

    @Test func testOldRecipesReadNewSlidersAsZero() throws {
        let decoded = try JSONDecoder().decode(BasicAdjustments.self, from: Data(#"{"exposure":0.5,"vignette":20}"#.utf8))
        #expect(decoded.exposure == 0.5 && decoded.vignette == 20)
        #expect(decoded.dehaze == 0 && decoded.fade == 0 && decoded.grain == 0 && decoded.monochrome == 0)
        var a = BasicAdjustments(); a.dehaze = -500; a.grain = 500; a.monochrome = -3
        #expect(a.sanitized.dehaze == -100 && a.sanitized.grain == 100 && a.sanitized.monochrome == 0)
    }

    @Test func testBakedLUTKeepsBlackAndWhiteAndFadeButNotGrain() throws {
        var edits = MediaEdits()
        edits.adjustments.monochrome = 60; edits.adjustments.fade = 50; edits.adjustments.contrast = 20
        edits.adjustments.grain = 70; edits.adjustments.dehaze = 40 // spatial: left out of the bake
        let cube = try LUTBaker.bake(edits, size: 33, title: "film")
        let image = scene()
        var perPixel = edits; perPixel.adjustments = edits.adjustments.withoutSpatial
        let direct = pixels(try ColorPipeline.grade(image, edits: perPixel))
        let viaLUT = pixels(try ColorPipeline.grade(image, edits: MediaEdits(lut: CreativeLUT(cube: cube, name: "baked"), strength: 1)))
        let differences = zip(direct, viaLUT).enumerated().filter { $0.offset % 4 != 3 }.map { abs($0.element.0 - $0.element.1) }
        let mean = differences.reduce(0, +) / Float(differences.count)
        #expect(mean < 0.006, "mean difference \(mean)")
    }

    @Test func testEffectsSectionListsTheNewSliders() {
        #expect(AdjustmentSection.effects.parameters == [.dehaze, .fade, .grain, .monochrome, .vignette])
        #expect(AdjustmentParameter.dehaze.range == -100...100 && AdjustmentParameter.grain.range == 0...100)
        #expect(LocalAdjustment.parameters.contains(.dehaze))
        #expect(!LocalAdjustment.parameters.contains(.grain))
    }
}
