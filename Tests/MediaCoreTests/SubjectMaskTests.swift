import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MediaCore

struct SubjectMaskTests {
    private func photo(in folder: URL) throws -> URL {
        let context = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        context.setFillColor(red: 0.8, green: 0.3, blue: 0.2, alpha: 1)
        context.fillEllipse(in: CGRect(x: 140, y: 80, width: 120, height: 140))
        let url = folder.appendingPathComponent("subject.png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    /// Red value at a pixel (top-left coordinates) of a rendered export.
    private func red(_ image: CGImage, _ x: Int, _ y: Int) -> Int {
        let data = image.dataProvider!.data! as Data
        return Int(data[y * image.bytesPerRow + x * (image.bitsPerPixel / 8)])
    }

    @Test func testSubjectLayerAdjustsOnlyTheSubjectOrTheBackground() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("subject-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try photo(in: folder)
        // A stand-in for Vision's answer: the ellipse, at a quarter of the size.
        let gray = CGContext(data: nil, width: 100, height: 75, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                             bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        gray.setFillColor(gray: 1, alpha: 1)
        gray.fillEllipse(in: CGRect(x: 35, y: 20, width: 30, height: 35))
        SubjectMask.store(CIImage(cgImage: gray.makeImage()!), for: url)

        var layer = LocalAdjustment(shape: .subject)
        layer.adjustments.exposure = 1.5; layer.feather = 0
        var options = ImageExportOptions(); options.keepMetadata = false
        let plain = try ImageExporter.render(url, edits: MediaEdits(), options: options).bitmap
        let subject = try ImageExporter.render(url, edits: MediaEdits(locals: [layer]), options: options).bitmap
        #expect(red(subject, 200, 150) > red(plain, 200, 150) + 20, "the subject is brighter")
        #expect(abs(red(subject, 20, 20) - red(plain, 20, 20)) <= 1, "the background is untouched")

        layer.invert = true
        let background = try ImageExporter.render(url, edits: MediaEdits(locals: [layer]), options: options).bitmap
        #expect(abs(red(background, 200, 150) - red(plain, 200, 150)) <= 1, "inverted: the subject is untouched")
        #expect(red(background, 20, 20) > red(plain, 20, 20) + 20, "inverted: the background is brighter")
    }

    @Test func testNoSubjectMeansNoEffectAndVisionRunsSafely() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("subject-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try photo(in: folder)
        // Whatever Vision decides about a flat drawing, it must not crash and must be cached.
        let first = SubjectMask.mask(for: url)
        #expect(SubjectMask.cached(for: url) != nil)
        if let first { #expect(first.extent.width > 0) }

        SubjectMask.store(nil, for: url)
        var options = ImageExportOptions(); options.keepMetadata = false
        let layer = LocalAdjustment(shape: .subject)
        let plain = try ImageExporter.render(url, edits: MediaEdits(), options: options).bitmap
        let none = try ImageExporter.render(url, edits: MediaEdits(locals: [layer]), options: options).bitmap
        #expect(red(none, 200, 150) == red(plain, 200, 150))
        // Without a source file (video, LUT baking) the layer does nothing either.
        let mask = LocalMask.image(layer, extent: CGRect(x: 0, y: 0, width: 10, height: 10))
        #expect(mask.extent == CGRect(x: 0, y: 0, width: 10, height: 10))
    }
}
