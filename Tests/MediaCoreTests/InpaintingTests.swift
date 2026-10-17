import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MediaCore

struct InpaintingTests {
    /// Diagonal stripes, period 8: a texture the fill has to continue, not blur.
    private func stripes(_ width: Int, _ height: Int) -> Inpainting.Image {
        var pixels: [SIMD4<Float>] = []
        for y in 0..<height { for x in 0..<width {
            let on = (x + y) % 8 < 4
            pixels.append(on ? SIMD4(0.8, 0.6, 0.2, 1) : SIMD4(0.1, 0.2, 0.5, 1))
        } }
        return Inpainting.Image(width: width, height: height, pixels: pixels)
    }

    private func square(_ width: Int, _ height: Int, _ rect: (Int, Int, Int, Int)) -> [Bool] {
        (0..<(width * height)).map { i in
            let x = i % width, y = i / width
            return x >= rect.0 && x < rect.0 + rect.2 && y >= rect.1 && y < rect.1 + rect.3
        }
    }

    @Test func testFillContinuesATexture() throws {
        let original = stripes(96, 80)
        let hole = square(96, 80, (40, 30, 14, 14))
        var damaged = original
        for i in hole.indices where hole[i] { damaged.pixels[i] = SIMD4(1, 0, 1, 1) }
        let result = try #require(Inpainting.fill(damaged, hole: hole))
        let errors = hole.indices.filter { hole[$0] }.map { i -> Float in
            let d = result.image.pixels[i] - original.pixels[i]
            return (d * d).x + (d * d).y + (d * d).z
        }
        let mean = errors.reduce(0, +) / Float(errors.count)
        // A blur would land halfway between the two colours (error ≈ 0.4 per pixel).
        #expect(mean < 0.05, "mean squared error \(mean)")
        #expect(!result.image.pixels.contains { $0 == SIMD4(1, 0, 1, 1) }, "no hole colour left")
        for i in hole.indices where !hole[i] { #expect(result.image.pixels[i] == damaged.pixels[i]) }
    }

    @Test func testFillIsRepeatableAndRefinesLargePicturesQuickly() throws {
        let image = stripes(300, 200)
        let hole = square(300, 200, (120, 80, 30, 30))
        let a = try #require(Inpainting.fill(image, hole: hole, searchSize: 100))
        let b = try #require(Inpainting.fill(image, hole: hole, searchSize: 100))
        #expect(a.image == b.image)
        let errors = hole.indices.filter { hole[$0] }.map { i -> Float in
            let d = a.image.pixels[i] - image.pixels[i]
            return (d * d).x + (d * d).y + (d * d).z
        }
        #expect(errors.reduce(0, +) / Float(errors.count) < 0.08)
    }

    @Test func testNothingToCopyFromGivesUp() {
        let image = stripes(20, 20)
        #expect(Inpainting.fill(image, hole: Array(repeating: true, count: 400)) == nil)
        let untouched = Inpainting.fill(image, hole: Array(repeating: false, count: 400))
        #expect(untouched?.image == image)
    }

    @Test func testRemoveLayerFillsThePaintedSpotOnly() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("remove-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // A gray picture with a black dot in the middle.
        let context = CGContext(data: nil, width: 200, height: 150, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 150))
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fillEllipse(in: CGRect(x: 92, y: 67, width: 16, height: 16))
        let url = folder.appendingPathComponent("dot.png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))

        var layer = LocalAdjustment(shape: .remove)
        #expect(!layer.hasEffect, "nothing painted yet")
        layer.strokes = [BrushStroke(points: [CGPoint(x: 0.5, y: 0.5)], radius: 0.07)]
        #expect(layer.hasEffect)
        var options = ImageExportOptions(); options.keepMetadata = false
        let removed = try ImageExporter.render(url, edits: MediaEdits(locals: [layer]), options: options).bitmap
        let data = removed.dataProvider!.data! as Data
        func red(_ x: Int, _ y: Int) -> Int { Int(data[y * removed.bytesPerRow + x * 4]) }
        #expect(red(100, 75) > 140, "the dot is gone: \(red(100, 75))")
        #expect(abs(red(10, 10) - red(100, 75)) < 12)
    }
}
