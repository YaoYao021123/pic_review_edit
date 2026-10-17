import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

public enum ImageStraightener {
    public static func analyze(_ url: URL, policy: StraighteningPolicy = .init()) async throws -> StraighteningAssessment {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let source = try source(url)
            let dimensions = try dimensions(source)
            let thumbnail = try thumbnail(source, maximumDimension: 1024)
            let request = VNDetectHorizonRequest()
            request.revision = VNDetectHorizonRequestRevision1
            // ImageIO has already baked orientation into this thumbnail.
            try VNImageRequestHandler(cgImage: thumbnail, orientation: .up).perform([request])
            try Task.checkCancellation()
            let observation = request.results?.max(by: { $0.confidence < $1.confidence })
            // Use the correction transform instead of guessing the sign of angle.
            let transform = observation?.transform(forImageWidth: thumbnail.width, height: thumbnail.height)
            let radians = transform.map { atan2(Double($0.b), Double($0.a)) }
            return try StraighteningAssessment.evaluate(width: dimensions.width, height: dimensions.height,
                radians: radians, confidence: observation?.confidence, revision: Int(request.revision), policy: policy)
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    /// SDR sRGB 8-bit preview. HDR/gain-map preservation is outside this prototype.
    public static func preview(_ url: URL, degrees: Double, maximumDimension: Int = 1600) throws -> CGImage {
        guard (2...8192).contains(maximumDimension) else { throw StraighteningError.invalidGeometry }
        let source = try source(url)
        let image = try thumbnail(source, maximumDimension: maximumDimension)
        let plan = try StraighteningPlan(width: image.width, height: image.height, rotationRadians: degrees * .pi / 180)
        return try render(CIImage(cgImage: image), plan: plan)
    }

    /// Writes a new SDR PNG; refuses every existing destination, including originals.
    /// No source metadata is copied: location and stale orientation are not propagated.
    public static func exportPNG(_ url: URL, to output: URL, degrees: Double) throws -> StraighteningPlan {
        guard output.isFileURL, output.pathExtension.lowercased() == "png" else { throw StraighteningError.pngRequired }
        let source = try source(url)
        let dimensions = try dimensions(source)
        let plan = try StraighteningPlan(width: dimensions.width, height: dimensions.height, rotationRadians: degrees * .pi / 180)
        // Use the same ImageIO orientation/color decode path as the preview,
        // at full source resolution rather than an embedded small thumbnail.
        let decoded = try thumbnail(source, maximumDimension: max(dimensions.width, dimensions.height))
        let input = CIImage(cgImage: decoded)
        let normalized = input.transformed(by: CGAffineTransform(translationX: -input.extent.minX, y: -input.extent.minY))
        guard Int(normalized.extent.width.rounded()) == plan.sourceWidth,
              Int(normalized.extent.height.rounded()) == plan.sourceHeight else { throw StraighteningError.invalidGeometry }
        let image = try render(normalized, plan: plan)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw StraighteningError.renderFailed
        }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 1] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw StraighteningError.renderFailed }
        try (data as Data).write(to: output, options: .withoutOverwriting)
        return plan
    }

    static func source(_ url: URL) throws -> CGImageSource {
        guard url.isFileURL,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { throw StraighteningError.unreadableImage }
        return source
    }

    static func dimensions(_ source: CGImageSource) throws -> (width: Int, height: Int) {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { throw StraighteningError.unreadableImage }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation) ? (height.intValue, width.intValue) : (width.intValue, height.intValue)
    }

    static func thumbnail(_ source: CGImageSource, maximumDimension: Int) throws -> CGImage {
        guard (2...Int(Int32.max)).contains(maximumDimension), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else { throw StraighteningError.unreadableImage }
        return image
    }

    static func makeContext() -> CIContext {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        return CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                                  .outputColorSpace: srgb])
    }

    static func render(_ input: CIImage, plan: StraighteningPlan, context: CIContext? = nil) throws -> CGImage {
        let transformed = input.transformed(by: plan.transform).cropped(to: plan.cropRect)
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = context ?? makeContext()
        guard let output = context.createCGImage(transformed, from: plan.cropRect, format: .RGBA8, colorSpace: srgb) else {
            throw StraighteningError.renderFailed
        }
        return output
    }
}

/// Face rectangles for the coach (skin tones are judged on faces, not on
/// every orange-brown pixel). Normalized, bottom-left origin like Core Image.
public enum FaceDetector {
    public static func faces(in url: URL) async throws -> [CGRect] {
        let task = Task.detached(priority: .utility) { () -> [CGRect] in
            let thumbnail = try ImageStraightener.thumbnail(ImageStraightener.source(url), maximumDimension: 1024)
            let request = VNDetectFaceRectanglesRequest()
            try VNImageRequestHandler(cgImage: thumbnail, orientation: .up).perform([request])
            return (request.results ?? []).filter { $0.confidence > 0.6 }.map(\.boundingBox)
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
}
