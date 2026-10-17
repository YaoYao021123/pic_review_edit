import CoreImage
import Foundation
import ImageIO
import Testing
@testable import MediaCore

struct HDRExportTests {
    /// A JPEG with a gain map: a dim left half and a right half four times brighter than SDR white.
    private func hdrPhoto(in folder: URL) throws -> URL {
        let linear = ColorPipeline.linearSpace
        let dim = CIImage(color: CIColor(red: 0.18, green: 0.2, blue: 0.22, colorSpace: linear)!).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 200))
        let bright = CIImage(color: CIColor(red: 4, green: 3.8, blue: 3.5, colorSpace: linear)!).cropped(to: CGRect(x: 200, y: 0, width: 200, height: 200))
        let hdr = bright.composited(over: dim)
        let base = ColorPipeline.toneMap(hdr, sourceHeadroom: 4)
        let data = try #require(HDRGain.encode(base: base, hdr: hdr, format: .jpeg, quality: 0.95))
        let url = folder.appendingPathComponent("hdr.jpg")
        try data.write(to: url)
        return url
    }

    private func gainMaps(_ url: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return 0 }
        return [kCGImageAuxiliaryDataTypeHDRGainMap, kCGImageAuxiliaryDataTypeISOGainMap]
            .filter { CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, $0) != nil }.count
    }

    /// Brightest linear value in the decoded (HDR-expanded) file.
    private func peak(_ url: URL) throws -> Float {
        let image = try ImageGradeSession.decode(url)
        var out = [Float](repeating: 0, count: 4)
        let probe = image.applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
        out.withUnsafeMutableBytes {
            ColorPipeline.shared.render(probe, toBitmap: $0.baseAddress!, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                        format: .RGBAf, colorSpace: ColorPipeline.linearSpace)
        }
        return out[1]
    }

    @Test func testHDRPhotosKeepTheirGainMap() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hdr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try hdrPhoto(in: folder)
        #expect(try ImageGradeSession.decode(source).contentHeadroom > 2, "test photo should decode as HDR")
        #expect(gainMaps(source) > 0)

        var options = ImageExportOptions()
        for format in [ImageExportOptions.Format.jpeg, .heic] {
            options.format = format
            let plain = folder.appendingPathComponent("plain.\(format.fileExtension)")
            try ImageExporter.export(source, to: plain, edits: MediaEdits(), options: options)
            #expect(gainMaps(plain) > 0, "\(format) export keeps a gain map")
            #expect(try peak(plain) > 2.5, "\(format) export keeps the highlights above SDR white")
        }

        options.format = .jpeg
        var edits = MediaEdits(); edits.adjustments.saturation = -100; edits.adjustments.contrast = 10
        let edited = folder.appendingPathComponent("edited.jpg")
        let rendered = try ImageExporter.render(source, edits: edits, options: options)
        #expect(rendered.isHDR)
        try ImageExporter.write(rendered, to: edited, source: source)
        #expect(try peak(edited) > 2, "edits keep the original's highlight lift")

        options.keepHDR = false
        let sdr = folder.appendingPathComponent("sdr.jpg")
        try ImageExporter.export(source, to: sdr, edits: edits, options: options)
        #expect(gainMaps(sdr) == 0)
        #expect(try peak(sdr) <= 1.01)

        options.keepHDR = true; options.format = .png
        #expect(try !ImageExporter.render(source, edits: MediaEdits(), options: options).isHDR, "PNG has no gain maps")
    }

    @Test func testSDRPhotosStaySDR() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sdr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("sdr.jpg")
        let image = CIImage(color: CIColor(red: 0.9, green: 0.5, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        try ColorPipeline.context().writeJPEGRepresentation(of: image, to: url, colorSpace: ColorPipeline.outputSpace)
        #expect(try !ImageExporter.render(url, edits: MediaEdits(), options: ImageExportOptions()).isHDR)
    }
}
