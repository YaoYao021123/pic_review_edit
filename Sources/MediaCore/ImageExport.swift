import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ImageExportOptions: Codable, Equatable, Sendable {
    public enum Format: String, Codable, CaseIterable, Sendable {
        case jpeg, heic, png
        public var title: String { switch self { case .jpeg: "JPEG"; case .heic: "HEIC"; case .png: "PNG" } }
        public var fileExtension: String { switch self { case .jpeg: "jpg"; case .heic: "heic"; case .png: "png" } }
        public var type: UTType { switch self { case .jpeg: .jpeg; case .heic: .heic; case .png: .png } }
        public var isLossy: Bool { self != .png }
    }
    public var format: Format = .jpeg
    /// 0...1, used by JPEG and HEIC.
    public var quality: Double = 0.9
    /// Longest output edge in pixels; nil keeps the edited size.
    public var maxLongEdge: Int?
    /// Copy capture date, camera, lens and exposure data from the original.
    public var keepMetadata = true
    /// Drop GPS data even when other metadata is kept.
    public var removeLocation = true
    /// Print resolution written into the file (72 when nil). Pixels are unchanged.
    public var dpi: Int?
    /// Text drawn onto exported photos; nil for none.
    public var watermark: Watermark?
    /// HDR photos keep their brightness range: an SDR picture plus a gain map (JPEG and HEIC).
    public var keepHDR = true
    public init() {}

    private enum CodingKeys: String, CodingKey { case format, quality, maxLongEdge, keepMetadata, removeLocation, dpi, watermark, keepHDR }
    /// Missing keys keep their defaults, so settings saved by older versions still load.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        format = (try? values.decodeIfPresent(Format.self, forKey: .format)) ?? .jpeg
        quality = min(1, max(0.1, try values.decodeIfPresent(Double.self, forKey: .quality) ?? 0.9))
        maxLongEdge = try values.decodeIfPresent(Int.self, forKey: .maxLongEdge)
        keepMetadata = try values.decodeIfPresent(Bool.self, forKey: .keepMetadata) ?? true
        removeLocation = try values.decodeIfPresent(Bool.self, forKey: .removeLocation) ?? true
        dpi = (try values.decodeIfPresent(Int.self, forKey: .dpi)).map { min(1200, max(72, $0)) }
        watermark = try? values.decodeIfPresent(Watermark.self, forKey: .watermark)
        keepHDR = try values.decodeIfPresent(Bool.self, forKey: .keepHDR) ?? true
    }
}

public enum ImageExporter {
    /// A finished picture waiting to be written: its size can name the file first.
    public struct Rendered: @unchecked Sendable {
        /// The SDR picture (the base image when there is a gain map).
        public let bitmap: CGImage
        let properties: [CFString: Any]
        let format: ImageExportOptions.Format
        /// JPEG or HEIC data with the SDR base and an HDR gain map.
        let hdrData: Data?
        public var width: Int { bitmap.width }
        public var height: Int { bitmap.height }
        public var isHDR: Bool { hdrData != nil }
    }

    /// Writes a new file. Refuses the source path; refuses other existing files
    /// unless `allowReplacing` is set (the user confirmed in a save panel).
    public static func export(_ url: URL, to output: URL, edits: MediaEdits, options: ImageExportOptions,
                              allowReplacing: Bool = false) throws {
        try validate(output, format: options.format, source: url, allowReplacing: allowReplacing)
        try write(try render(url, edits: edits, options: options), to: output, source: url, allowReplacing: allowReplacing)
    }

    /// Grades, straightens and crops, resizes, then adds the watermark.
    public static func render(_ url: URL, edits: MediaEdits, options: ImageExportOptions) throws -> Rendered {
        try Task.checkCancellation()
        var edits = edits
        edits.source = url
        let input = try ImageGradeSession.decode(url)
        let headroom = max(1, input.contentHeadroom)
        let graded = try ColorPipeline.grade(input, edits: edits, sourceHeadroom: headroom)
        let shaped = resized(try ColorPipeline.geometry(graded, edits: edits), options: options)
        let transformed = options.watermark.map { $0.drawn(over: shaped) } ?? shaped
        try Task.checkCancellation()
        let bitmap = try ColorPipeline.sdrBitmap(transformed, headroom: edits.hasGrade ? 1 : headroom)
        var hdrData: Data?
        if options.keepHDR, options.format != .png, headroom > 1.05 {
            // Unedited: the photo's own HDR. Edited: the grade works on the tone-mapped picture,
            // so the original's highlight lift (HDR ÷ tone-mapped) is put back on top of it.
            let original = Retouch.apply(input, edits: edits)
            var hdr = edits.hasGrade ? resized(try ColorPipeline.geometry(HDRGain.restore(graded, original: original, headroom: headroom), edits: edits), options: options) : shaped
            if let watermark = options.watermark { hdr = watermark.drawn(over: hdr) }
            try Task.checkCancellation()
            hdrData = HDRGain.encode(base: CIImage(cgImage: bitmap), hdr: hdr, format: options.format, quality: options.quality)
        }
        var properties: [CFString: Any] = [kCGImagePropertyOrientation: 1]
        if options.keepMetadata { properties.merge(metadata(of: url, removeLocation: options.removeLocation,
                                                            width: bitmap.width, height: bitmap.height)) { _, new in new } }
        if let dpi = options.dpi {
            properties[kCGImagePropertyDPIWidth] = dpi
            properties[kCGImagePropertyDPIHeight] = dpi
        }
        if options.format.isLossy { properties[kCGImageDestinationLossyCompressionQuality] = min(1, max(0.1, options.quality)) }
        return Rendered(bitmap: bitmap, properties: properties, format: options.format, hdrData: hdrData)
    }

    /// The pixel size an export will have, without rendering it.
    public static func outputSize(source: CGSize, edits: MediaEdits, options: ImageExportOptions) -> CGSize {
        let blank = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: source))
        let shaped = (try? ColorPipeline.geometry(blank, edits: edits)) ?? blank
        return resized(shaped, options: options).extent.size
    }

    private static func resized(_ image: CIImage, options: ImageExportOptions) -> CIImage {
        guard let limit = options.maxLongEdge, limit >= 16 else { return image }
        let longEdge = max(image.extent.width, image.extent.height)
        guard longEdge > CGFloat(limit) else { return image }
        let scaled = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: CGFloat(limit) / longEdge, kCIInputAspectRatioKey: 1])
        return scaled.cropped(to: CGRect(x: scaled.extent.minX, y: scaled.extent.minY,
                                         width: floor(scaled.extent.width), height: floor(scaled.extent.height)))
    }

    /// Checked before rendering too, so a wrong name fails at once.
    private static func validate(_ output: URL, format: ImageExportOptions.Format, source: URL, allowReplacing: Bool) throws {
        guard output.isFileURL, output.standardizedFileURL != source.standardizedFileURL else { throw VideoWorkError.outputExists }
        guard output.pathExtension.lowercased() == format.fileExtension
                || (format == .jpeg && output.pathExtension.lowercased() == "jpeg") else {
            throw VideoWorkError.failed(L("文件扩展名需与导出格式 \(format.title) 一致。"))
        }
        if !allowReplacing, FileManager.default.fileExists(atPath: output.path) { throw VideoWorkError.outputExists }
    }

    public static func write(_ rendered: Rendered, to output: URL, source: URL, allowReplacing: Bool = false) throws {
        let format = rendered.format
        try validate(output, format: format, source: source, allowReplacing: allowReplacing)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, format.type.identifier as CFString, 1, nil) else {
            throw VideoWorkError.failed(L("系统不支持写入 \(format.title)。"))
        }
        if let hdr = rendered.hdrData, let source = CGImageSourceCreateWithData(hdr as CFData, nil) {
            // The encoded HDR file plus our metadata; the gain map travels as auxiliary data.
            CGImageDestinationAddImageFromSource(destination, source, 0, rendered.properties as CFDictionary)
            for type in [kCGImageAuxiliaryDataTypeHDRGainMap, kCGImageAuxiliaryDataTypeISOGainMap] {
                if let auxiliary = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) {
                    CGImageDestinationAddAuxiliaryDataInfo(destination, type, auxiliary)
                }
            }
        } else {
            CGImageDestinationAddImage(destination, rendered.bitmap, rendered.properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw StraighteningError.renderFailed }
        let temporary = output.deletingLastPathComponent().appendingPathComponent(".workbench-\(UUID().uuidString).\(format.fileExtension)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try (data as Data).write(to: temporary, options: .atomic)
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: output.path) {
            guard allowReplacing else { throw VideoWorkError.outputExists }
            _ = try FileManager.default.replaceItemAt(output, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: output)
        }
    }

    /// Capture metadata worth keeping. Orientation is already applied to pixels;
    /// Apple maker data is dropped so the export is never mistaken for a Live Photo still.
    static func metadata(of url: URL, removeLocation: Bool, width: Int, height: Int) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return [:] }
        var result: [CFString: Any] = [:]
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = width
            exif[kCGImagePropertyExifPixelYDimension] = height
            exif.removeValue(forKey: kCGImagePropertyExifSubjectArea)
            result[kCGImagePropertyExifDictionary] = exif
        }
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff.removeValue(forKey: kCGImagePropertyTIFFOrientation)
            tiff[kCGImagePropertyTIFFSoftware] = L("光集")
            result[kCGImagePropertyTIFFDictionary] = tiff
        }
        for key in [kCGImagePropertyIPTCDictionary, kCGImagePropertyExifAuxDictionary] {
            if let value = properties[key] { result[key] = value }
        }
        if !removeLocation, let gps = properties[kCGImagePropertyGPSDictionary] { result[kCGImagePropertyGPSDictionary] = gps }
        return result
    }
}

/// Camera facts shown in the Info panel. All fields are optional.
public struct CaptureInfo: Sendable, Equatable {
    public var camera: String?
    public var lens: String?
    public var focalLength: String?
    public var aperture: String?
    public var shutter: String?
    public var iso: String?
    public var captured: String?
    public var hasLocation = false
    /// The same settings as numbers, for lessons that use the user's own photo.
    public var fNumber: Double?
    public var exposureTime: Double?
    public var isoValue: Int?
    public var focalLengthMM: Double?
    public var focalLength35mm: Double?

    public static func read(_ url: URL) -> CaptureInfo? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        var info = CaptureInfo()
        let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
        let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
        if let model { info.camera = make.map { model.hasPrefix($0) ? model : "\($0) \(model)" } ?? model }
        info.lens = exif[kCGImagePropertyExifLensModel] as? String
        if let focal = exif[kCGImagePropertyExifFocalLength] as? Double { info.focalLength = String(format: "%.0f mm", focal); info.focalLengthMM = focal }
        info.focalLength35mm = (exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber)?.doubleValue
        if let f = exif[kCGImagePropertyExifFNumber] as? Double { info.aperture = String(format: "ƒ/%.1f", f); info.fNumber = f }
        if let time = exif[kCGImagePropertyExifExposureTime] as? Double, time > 0 {
            info.shutter = time >= 1 ? String(format: "%.1f s", time) : "1/\(Int((1 / time).rounded())) s"
            info.exposureTime = time
        }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { info.iso = "ISO \(iso)"; info.isoValue = iso }
        info.captured = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        info.hasLocation = properties[kCGImagePropertyGPSDictionary] != nil
        let empty = info.camera == nil && info.lens == nil && info.focalLength == nil && info.aperture == nil
            && info.shutter == nil && info.iso == nil && info.captured == nil
        return empty ? nil : info
    }
}
