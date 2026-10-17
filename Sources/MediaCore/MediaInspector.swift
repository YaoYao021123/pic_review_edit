import AVFoundation
import Foundation
import ImageIO

/// Header/track inspection only. Does not decode every frame or establish Live pairing.
public struct MediaMetadata: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case image, video }
    public let path: String
    public let kind: Kind
    public let format: String?
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let displayWidth: Int
    public let displayHeight: Int
    public let orientation: Int?
    public let durationSeconds: Double?
    public let nominalFrameRate: Float?
    public let hasAudio: Bool?
    public let colorPrimaries: String?
    public let transferFunction: String?
    public let yCbCrMatrix: String?
}

public enum MediaInspectionError: Error, LocalizedError {
    case unreadable(String)
    case unsupported(String)
    public var errorDescription: String? {
        switch self {
        case let .unreadable(path): return L("无法读取文件：\(path)")
        case let .unsupported(path): return L("未找到有效图片或视频轨道：\(path)")
        }
    }
}

public enum MediaInspector {
    public static func inspect(_ url: URL) async throws -> MediaMetadata {
        var directory: ObjCBool = false
        guard url.isFileURL,
              FileManager.default.fileExists(atPath: url.path, isDirectory: &directory),
              !directory.boolValue,
              FileManager.default.isReadableFile(atPath: url.path) else {
            throw MediaInspectionError.unreadable(url.path)
        }
        if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
           let height = properties[kCGImagePropertyPixelHeight] as? NSNumber {
            let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            let swapped = (5...8).contains(orientation)
            return MediaMetadata(
                path: url.path, kind: .image, format: CGImageSourceGetType(source).map { $0 as String },
                pixelWidth: width.intValue, pixelHeight: height.intValue,
                displayWidth: swapped ? height.intValue : width.intValue,
                displayHeight: swapped ? width.intValue : height.intValue,
                orientation: orientation, durationSeconds: nil, nominalFrameRate: nil, hasAudio: nil,
                colorPrimaries: nil, transferFunction: nil, yCbCrMatrix: nil
            )
        }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaInspectionError.unsupported(url.path)
        }
        let (size, transform, fps, formats) = try await track.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions
        )
        let duration = try await asset.load(.duration).seconds
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let display = CGRect(origin: .zero, size: size).applying(transform).standardized.size
        guard [size.width, size.height, display.width, display.height].allSatisfy({
            $0.isFinite && $0 > 0 && $0 < CGFloat(Int32.max)
        }) else { throw MediaInspectionError.unsupported(url.path) }
        let extensions = formats.first.flatMap { CMFormatDescriptionGetExtensions($0) as? [String: Any] }
        func color(_ key: CFString) -> String? { extensions?[key as String] as? String }
        return MediaMetadata(
            path: url.path, kind: .video, format: url.pathExtension.lowercased(),
            pixelWidth: Int(size.width.rounded()), pixelHeight: Int(size.height.rounded()),
            displayWidth: Int(display.width.rounded()), displayHeight: Int(display.height.rounded()),
            orientation: nil, durationSeconds: duration.isFinite ? duration : nil,
            nominalFrameRate: fps.isFinite ? fps : nil, hasAudio: !audio.isEmpty,
            colorPrimaries: color(kCMFormatDescriptionExtension_ColorPrimaries),
            transferFunction: color(kCMFormatDescriptionExtension_TransferFunction),
            yCbCrMatrix: color(kCMFormatDescriptionExtension_YCbCrMatrix)
        )
    }
}
