import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MediaCore

struct LUTParsingTests {
    let entries = "0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1"

    @Test func vendorTitleInGBKCRLFTabsAndBOMParse() throws {
        // "雪天2" in GBK, as shipped in DJI Pocket 3 Winter Pro.
        var bytes: [UInt8] = [0xEF, 0xBB, 0xBF]
        bytes += Array("#comment\r\nTITLE \"".utf8) + [0xD1, 0xA9, 0xCC, 0xEC, 0x32] + Array("\"\r\nLUT_3D_SIZE\t2\r\n".utf8)
        bytes += Array(entries.replacingOccurrences(of: "\n", with: "\r\n").replacingOccurrences(of: " ", with: "\t").utf8)
        let lut = try CubeLUT(data: Data(bytes))
        #expect(lut.title == "雪天2")
        #expect(lut.dimension == 2 && lut.rgb.count == 24)
        #expect(Array(lut.rgb.suffix(3)) == [1, 1, 1])
    }

    @Test func inputRangeAndUnknownHeaderKeywords() throws {
        let lut = try CubeLUT(text: "LUT_IN_VIDEO_RANGE\nLUT_3D_INPUT_RANGE 0 2\nLUT_3D_SIZE 2\n" + entries)
        #expect(lut.domainMax == [2, 2, 2])
        #expect(throws: CubeLUT.ParseError.self) { try CubeLUT(text: "LUT_3D_SIZE 2\n0 0 0\nSOMETHING\n" + entries) }
        #expect(throws: CubeLUT.ParseError.self) { try CubeLUT(text: "LUT_3D_SIZE 2\n0 0\n" + entries) }
        #expect(throws: CubeLUT.ParseError.self) { try CubeLUT(text: "LUT_3D_SIZE 2\n0 0 0 0\n" + entries) }
    }

    @Test func largeTableParsesQuickly() throws {
        let size = 64
        var text = "LUT_3D_SIZE \(size)\n"
        text.reserveCapacity(size * size * size * 24)
        for b in 0..<size { for g in 0..<size { for r in 0..<size {
            text += "\(Float(r) / 63) \(Float(g) / 63) \(Float(b) / 63)\n"
        } } }
        // CPU time of this thread, not wall-clock time, so other work on the Mac (or other tests
        // running in parallel) can't make it fail.
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let lut = try CubeLUT(text: text)
        let seconds = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1e9
        #expect(lut.rgb.count == size * size * size * 3)
        #expect(seconds < 1.0, "\(seconds) s")
    }

    @Test func storedLUTIsCachedAcrossLoads() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = DraftStore(root: folder)
        let reference = try store.storeLUT(.soft)
        let first = try store.loadLUT(reference)
        let second = try store.loadLUT(reference)
        #expect(first.id == second.id)
        try store.rememberImportedLUT(reference)
        #expect(store.importedLUTs() == [reference])
    }
}

struct GradeStageTests {
    private func pixel(_ values: [Float]) -> CIImage {
        CIImage(bitmapData: values.withUnsafeBytes { Data($0) }, bytesPerRow: 16, size: CGSize(width: 1, height: 1),
                format: .RGBAf, colorSpace: ColorPipeline.outputSpace)
    }
    private func sample(_ image: CIImage) -> [Float] {
        var values = [Float](repeating: 0, count: 4)
        values.withUnsafeMutableBytes {
            ColorPipeline.shared.render(image, toBitmap: $0.baseAddress!, rowBytes: 16,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: ColorPipeline.outputSpace)
        }
        return values
    }
    private func graded(_ values: [Float], _ configure: (inout MediaEdits) -> Void) throws -> [Float] {
        var edits = MediaEdits(); configure(&edits)
        return sample(try ColorPipeline.grade(pixel(values), edits: edits))
    }

    @Test func neutralStagesAreIdentity() throws {
        let edits = MediaEdits()
        #expect(edits.hasGrade == false)
        #expect(ColorWheels().isNeutral && ToneCurves().isIdentity && HSLAdjustments().isNeutral)
        let out = try graded([0.3, 0.5, 0.7, 1]) { $0.wheels.lift = WheelValue(); $0.curves = ToneCurves() }
        #expect(abs(out[0] - 0.3) < 0.003 && abs(out[2] - 0.7) < 0.003)
    }

    @Test func wheelsMoveTheirTonalRangeAndHue() throws {
        let lifted = try graded([0.05, 0.05, 0.05, 1]) { $0.wheels.lift.master = 0.5 }
        #expect(lifted[0] > 0.12)
        let liftedWhite = try graded([0.95, 0.95, 0.95, 1]) { $0.wheels.lift.master = 0.5 }
        #expect(abs(liftedWhite[0] - 0.95) < 0.03)
        let gained = try graded([0.8, 0.8, 0.8, 1]) { $0.wheels.gain.master = 0.3 }
        #expect(gained[0] > 0.9)
        // Puck toward +Cr (up on the vectorscope) warms toward red, not blue.
        let warm = try graded([0.5, 0.5, 0.5, 1]) { $0.wheels.gamma = WheelValue(x: 0, y: 0.8) }
        #expect(warm[0] > warm[2] + 0.02)
        let luma = 0.2126 * warm[0] + 0.7152 * warm[1] + 0.0722 * warm[2]
        #expect(abs(luma - 0.5) < 0.05)
    }

    @Test func curvesAndChannelCurves() throws {
        let brighter = try graded([0.5, 0.5, 0.5, 1]) {
            $0.curves.master = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.65), CurvePoint(x: 1, y: 1)]
        }
        #expect(brighter[0] > 0.6 && brighter[0] < 0.7)
        let redOnly = try graded([0.5, 0.5, 0.5, 1]) {
            $0.curves.red = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.3), CurvePoint(x: 1, y: 1)]
        }
        #expect(redOnly[0] < 0.4 && abs(redOnly[1] - 0.5) < 0.01)
        let samples = ToneCurves.sample([CurvePoint(x: 0, y: 0), CurvePoint(x: 0.3, y: 0.6), CurvePoint(x: 1, y: 1)])
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 + 1e-9 })
    }

    @Test func hslTargetsOneHueBand() throws {
        let blue = try graded([0.1, 0.2, 0.8, 1]) { $0.hsl[.blue, .saturation] = -100 }
        #expect(abs(blue[0] - blue[2]) < 0.05)
        let red = try graded([0.8, 0.15, 0.1, 1]) { $0.hsl[.blue, .saturation] = -100 }
        #expect(red[0] > 0.7 && red[1] < 0.25)
        let shifted = try graded([0.8, 0.15, 0.1, 1]) { $0.hsl[.red, .hue] = 100 }
        #expect(shifted[1] > 0.25)
    }

    @Test func bypassedStagesKeepValuesButSkipRendering() throws {
        let out = try graded([0.3, 0.3, 0.3, 1]) {
            $0.adjustments.exposure = 1; $0.bypass = [.basic]
        }
        #expect(abs(out[0] - 0.3) < 0.003)
        var edits = MediaEdits(lut: .warm); edits.bypass = [.lut]
        #expect(edits.hasLUT == false && edits.hasGrade == false)
    }

    @Test func versionOneRecipesDecodeAndNewFieldsRoundTrip() throws {
        let legacy = #"{"version":1,"adjustments":{"exposure":0.5},"degrees":2,"strength":1,"hdrEffect":false,"hdrPreview":true}"#
        let old = try JSONDecoder().decode(EditRecipe.self, from: Data(legacy.utf8))
        try old.validate()
        #expect(old.adjustments.exposure == 0.5 && old.wheels.isNeutral && old.bypass.isEmpty)
        var recipe = EditRecipe()
        recipe.wheels.gain = WheelValue(x: 0.2, y: -0.1, master: 0.3)
        recipe.curves.blue = [CurvePoint(x: 0, y: 0.1), CurvePoint(x: 1, y: 0.9)]
        recipe.hsl[.green, .luminance] = 40
        recipe.bypass = [.hsl]
        try recipe.validate()
        let decoded = try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(recipe))
        #expect(decoded == recipe)
        let copied = EditRecipe().applyingLook(from: recipe)
        #expect(copied.wheels == recipe.wheels && copied.hsl == recipe.hsl && copied.bypass == [.hsl])
        for preset in GradePreset.builtIns { try preset.recipe.validate() }
    }

    @Test func presetsPersistAndDelete() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = DraftStore(root: folder)
        var recipe = EditRecipe(); recipe.adjustments.vibrance = 30
        let preset = GradePreset(name: "我的风格", recipe: recipe)
        try store.savePreset(preset)
        #expect(store.presets().contains(preset))
        try store.deletePreset(preset)
        #expect(!store.presets().contains(preset))
        #expect(store.presets().count == GradePreset.builtIns.count)
    }
}

struct ScopeAndExportTests {
    @Test func scopesReportClippingAndBuildImages() throws {
        let white = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 32))
        let data = try #require(ScopeAnalyzer.analyze(white))
        #expect(data.clippedHighlights > 0.99 && data.clippedShadows == 0)
        #expect(data.waveform != nil && data.parade != nil && data.vectorscope != nil)
        let gray = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 32))
        let mid = try #require(ScopeAnalyzer.analyze(gray))
        #expect(mid.clippedHighlights == 0 && mid.clippedShadows == 0)
    }

    @Test func jpegExportKeepsCaptureDateDropsLocationAndResizes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("camera.jpg")
        let canvas = try #require(CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 1600,
            space: ColorPipeline.outputSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        canvas.setFillColor(CGColor(red: 0.4, green: 0.5, blue: 0.6, alpha: 1)); canvas.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let destination = try #require(CGImageDestinationCreateWithURL(source as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(canvas.makeImage()), [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:09:28 11:55:48"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "Test Camera"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 45.0, kCGImagePropertyGPSLatitudeRef: "N"]
        ] as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))

        var options = ImageExportOptions(); options.maxLongEdge = 200
        let output = folder.appendingPathComponent("edited.jpg")
        try ImageExporter.export(source, to: output, edits: MediaEdits(lut: .warm), options: options)
        let reopened = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(reopened, 0, nil) as? [CFString: Any])
        #expect((properties[kCGImagePropertyPixelWidth] as? Int) == 200)
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifDateTimeOriginal] as? String == "2026:09:28 11:55:48")
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect(CaptureInfo.read(source)?.camera == "Test Camera")
        #expect(CaptureInfo.read(source)?.hasLocation == true)
        #expect(throws: (any Error).self) { try ImageExporter.export(source, to: output, edits: .init(), options: options) }
        try ImageExporter.export(source, to: output, edits: .init(), options: options, allowReplacing: true)

        var heic = ImageExportOptions(); heic.format = .heic; heic.keepMetadata = false
        let heicURL = folder.appendingPathComponent("edited.heic")
        try ImageExporter.export(source, to: heicURL, edits: .init(), options: heic)
        #expect(CGImageSourceCreateWithURL(heicURL as CFURL, nil).flatMap { CGImageSourceGetType($0) } as String? == UTType.heic.identifier)
        #expect(throws: (any Error).self) { try ImageExporter.export(source, to: source, edits: .init(), options: options, allowReplacing: true) }
    }

    @Test func imageSessionLoadsFullResolutionOnDemand() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        let canvas = try #require(CGContext(data: nil, width: 800, height: 400, bitsPerComponent: 8, bytesPerRow: 3200,
            space: ColorPipeline.outputSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.setFillColor(CGColor(red: 0.6, green: 0.5, blue: 0.3, alpha: 1)); canvas.fill(CGRect(x: 0, y: 0, width: 800, height: 400))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(canvas.makeImage()), nil)
        try #require(CGImageDestinationFinalize(destination))
        let session = try ImageGradeSession(url: url, maximumDimension: 200)
        let proxy = try await session.frame(edits: .init(degrees: 2))
        #expect(proxy.image.extent.width < 210 && proxy.fullImage == nil)
        #expect(proxy.fullSize.width > 700)
        try await session.loadFullResolution()
        let full = try await session.frame(edits: .init(degrees: 2))
        let fullImage = try #require(full.fullImage)
        #expect(abs(fullImage.extent.width - full.fullSize.width) < 2)
        #expect(full.before.extent.size == full.image.extent.size)
    }
}
