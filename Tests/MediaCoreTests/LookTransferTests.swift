import CoreImage
import Foundation
import Testing
@testable import MediaCore

struct LookTransferTests {
    /// A 48×48 sRGB image with hue across, brightness down.
    private func sample(warmth: Double = 0) -> CGImage {
        let size = 48
        var bytes = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size { for x in 0..<size {
            let h = Double(x) / Double(size), v = 0.15 + 0.8 * Double(y) / Double(size)
            let r = v * (0.5 + 0.5 * cos(2 * .pi * h)) + warmth, g = v * (0.5 + 0.5 * cos(2 * .pi * (h - 0.33))), b = v * (0.5 + 0.5 * cos(2 * .pi * (h - 0.66))) - warmth
            let i = (y * size + x) * 4
            bytes[i] = UInt8(min(255, max(0, r * 255))); bytes[i + 1] = UInt8(min(255, max(0, g * 255))); bytes[i + 2] = UInt8(min(255, max(0, b * 255)))
        } }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                       space: ColorPipeline.outputSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
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

    @Test func testBakedLUTReproducesTheColorGrade() throws {
        var edits = MediaEdits()
        edits.adjustments.contrast = 30; edits.adjustments.warmth = 25; edits.adjustments.saturation = -20
        edits.adjustments.sharpness = 60 // spatial: must be left out without breaking the bake
        edits.hsl[.blue, .luminance] = -30
        edits.curves.master = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.25, y: 0.2), CurvePoint(x: 0.75, y: 0.82), CurvePoint(x: 1, y: 1)]
        let cube = try LUTBaker.bake(edits, size: 33, title: "test")
        #expect(cube.dimension == 33 && cube.rgb.count == 33 * 33 * 33 * 3)
        #expect(cube.textRepresentation().contains("LUT_3D_SIZE 33"))

        let image = CIImage(cgImage: sample())
        var colorOnly = edits; colorOnly.bypass.insert(.detail)
        let direct = pixels(try ColorPipeline.grade(image, edits: colorOnly))
        let viaLUT = pixels(try ColorPipeline.grade(image, edits: MediaEdits(lut: CreativeLUT(cube: cube, name: "baked"), strength: 1)))
        let differences = zip(direct, viaLUT).enumerated().filter { $0.offset % 4 != 3 }.map { abs($0.element.0 - $0.element.1) }
        let mean = differences.reduce(0, +) / Float(differences.count)
        #expect(mean < 0.006, "mean difference \(mean)")
        #expect(differences.max()! < 0.05)
    }

    @Test func testLabRoundTrip() {
        for color in [SIMD3(0.0, 0.0, 0.0), SIMD3(1.0, 1.0, 1.0), SIMD3(0.8, 0.2, 0.1), SIMD3(0.1, 0.5, 0.9), SIMD3(0.5, 0.5, 0.5)] {
            let back = LookMatch.rgb(LookMatch.lab(color))
            #expect(abs(back.x - color.x) < 1e-4 && abs(back.y - color.y) < 1e-4 && abs(back.z - color.z) < 1e-4)
        }
        let gray = LookMatch.lab(SIMD3(0.5, 0.5, 0.5))
        #expect(abs(gray.y) < 0.01 && abs(gray.z) < 0.01)
    }

    @Test func testMatchingMovesColorsTowardTheReference() throws {
        let neutral = try #require(LookMatch.statistics(sample()))
        let warm = try #require(LookMatch.statistics(sample(warmth: 0.15)))
        #expect(warm.mean.z > neutral.mean.z + 5) // warmer = more yellow in b*

        // Same statistics: nothing changes.
        let same = LookMatch.lut(from: neutral, to: neutral, size: 9, title: "same")
        for (index, point) in CubeLUT.lattice(9).enumerated() {
            #expect(abs(same.rgb[index * 3] - point.x) < 0.002 && abs(same.rgb[index * 3 + 2] - point.z) < 0.002)
        }
        // Toward a warm reference: mid gray comes out warmer (red above blue).
        let warmer = LookMatch.lut(from: neutral, to: warm, size: 9, title: "warm")
        let middle = (4 * 9 + 4) * 9 + 4
        #expect(warmer.rgb[middle * 3] > warmer.rgb[middle * 3 + 2] + 0.03)
    }
}
