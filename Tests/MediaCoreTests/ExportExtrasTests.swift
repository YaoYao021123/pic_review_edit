import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MediaCore

struct ExportExtrasTests {
    private func values(_ name: String = "DJI_0042", sequence: Int = 3, total: Int = 12) -> ExportNaming.Values {
        .init(name: name, day: "20261016", sequence: sequence, total: total, width: 4000, height: 3000)
    }

    @Test func testNamingFillsTokens() {
        #expect(ExportNaming.name("{name}", values()) == "DJI_0042")
        #expect(ExportNaming.name("{date}-{seq}-{name}", values()) == "20261016-03-DJI_0042")
        #expect(ExportNaming.name("{name}_{width}x{height}", values()) == "DJI_0042_4000x3000")
        #expect(ExportNaming.name("trip-{seq}", values(sequence: 7, total: 250)) == "trip-007")
        // A name that itself looks like a token is left as it is.
        #expect(ExportNaming.name("{name}-{seq}", values("{date}")) == "{date}-03")
    }

    @Test func testNamingRejectsBadPatternsAndFallsBack() {
        #expect(ExportNaming.problem("{date}-{name}") == nil)
        #expect(ExportNaming.problem("{camera}") != nil)
        #expect(ExportNaming.problem("a/b-{name}") != nil)
        #expect(ExportNaming.problem("{name") != nil)
        #expect(ExportNaming.problem("  ") != nil)
        #expect(ExportNaming.name("../{camera}", values()) == "DJI_0042")
        #expect(ExportNaming.safeName("  a:b?.jpg. ") == "a_b_.jpg")
        #expect(ExportNaming.name("{width}", .init(name: "x", day: "", sequence: 1, total: 1)) == "x")
    }

    @Test func testCaptureDayComesFromEXIF() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("day-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, gray(), [kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2025:07:04 18:30:00"]] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        #expect(ExportNaming.day(of: url) == "20250704")
    }

    private func gray(_ width: Int = 600, _ height: Int = 400, level: CGFloat = 0.5) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: level, green: level, blue: level, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// Darkest and brightest red values in a region given in top-left pixel coordinates.
    private func range(_ image: CIImage, _ region: CGRect) -> ClosedRange<Float> {
        let extent = image.extent
        let flipped = CGRect(x: region.minX, y: extent.height - region.maxY, width: region.width, height: region.height)
        var out = [Float](repeating: 0, count: Int(region.width * region.height) * 4)
        out.withUnsafeMutableBytes {
            ColorPipeline.shared.render(image, toBitmap: $0.baseAddress!, rowBytes: Int(region.width) * 16, bounds: flipped,
                                        format: .RGBAf, colorSpace: ColorPipeline.outputSpace)
        }
        let reds = stride(from: 0, to: out.count, by: 4).map { out[$0] }
        return reds.min()!...reds.max()!
    }

    @Test func testWatermarkDrawsInTheChosenCorner() {
        let image = CIImage(cgImage: gray())
        var mark = Watermark(text: "© Lucet 光集")
        mark.opacity = 1; mark.shadow = false; mark.size = 6
        let bottomRight = mark.drawn(over: image)
        #expect(range(bottomRight, CGRect(x: 300, y: 340, width: 288, height: 50)).upperBound > 0.95, "white text in the bottom right")
        #expect(range(bottomRight, CGRect(x: 0, y: 0, width: 200, height: 100)) == range(image, CGRect(x: 0, y: 0, width: 200, height: 100)), "top left untouched")
        mark.position = .topLeft; mark.ink = .black
        let topLeft = mark.drawn(over: image)
        #expect(range(topLeft, CGRect(x: 10, y: 10, width: 288, height: 50)).lowerBound < 0.05, "black text in the top left")
        #expect(range(topLeft, CGRect(x: 400, y: 300, width: 200, height: 100)) == range(image, CGRect(x: 400, y: 300, width: 200, height: 100)))
        #expect(topLeft.extent == image.extent)
    }

    @Test func testWatermarkTextIsCleanedAndLongTextShrinks() {
        #expect(Watermark(text: "  line one \n\n line two\nline three\u{0007}").cleanedText == "line one\nline two")
        #expect(Watermark(text: String(repeating: "长", count: 200)).cleanedText.count == Watermark.maximumLength)
        let image = CIImage(cgImage: gray(300, 200))
        #expect(Watermark(text: " \n ").drawn(over: image).extent == image.extent)
        var long = Watermark(text: String(repeating: "Wide text ", count: 8)); long.size = 8; long.opacity = 1; long.shadow = false
        let wide = CIImage(cgImage: gray(1200, 800))
        #expect(range(long.drawn(over: wide), CGRect(x: 0, y: 700, width: 1200, height: 100)).upperBound > 0.9, "shrunk to fit instead of skipped")
        // Below the 8 px minimum it can't fit, so the picture is left as it is.
        #expect(range(long.drawn(over: image), CGRect(x: 0, y: 0, width: 300, height: 200)) == range(image, CGRect(x: 0, y: 0, width: 300, height: 200)))
    }

    @Test func testExportWritesDPIAndWatermark() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("in.png")
        let destination = try #require(CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, gray(), nil)
        #expect(CGImageDestinationFinalize(destination))

        var options = ImageExportOptions()
        options.dpi = 300; options.maxLongEdge = 300; options.watermark = Watermark(text: "LUCET")
        let rendered = try ImageExporter.render(source, edits: MediaEdits(), options: options)
        #expect(rendered.width == 300 && rendered.height == 200)
        #expect(ImageExporter.outputSize(source: CGSize(width: 600, height: 400), edits: MediaEdits(), options: options) == CGSize(width: 300, height: 200))
        let output = folder.appendingPathComponent("out.jpg")
        try ImageExporter.write(rendered, to: output, source: source)
        let written = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(written, 0, nil) as? [CFString: Any])
        #expect((properties[kCGImagePropertyDPIWidth] as? NSNumber)?.intValue == 300)
        #expect((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 300)
        #expect(throws: (any Error).self) { try ImageExporter.write(rendered, to: folder.appendingPathComponent("out.png"), source: source) }
    }

    @Test func testOldExportSettingsStillLoad() throws {
        let old = try JSONDecoder().decode(ImageExportOptions.self, from: Data(#"{"format":"heic","quality":0.8,"keepMetadata":false,"removeLocation":true}"#.utf8))
        #expect(old.format == .heic && old.quality == 0.8 && !old.keepMetadata && old.dpi == nil && old.watermark == nil)
        var options = ImageExportOptions(); options.dpi = 300; options.watermark = Watermark(text: "x")
        let roundTrip = try JSONDecoder().decode(ImageExportOptions.self, from: JSONEncoder().encode(options))
        #expect(roundTrip == options)
        let clamped = try JSONDecoder().decode(Watermark.self, from: Data(#"{"text":"a","opacity":9,"size":-1,"position":"middle"}"#.utf8))
        #expect(clamped.opacity == 1 && clamped.size == 1 && clamped.position == .bottomRight)
    }
}
