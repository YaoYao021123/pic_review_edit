import CoreImage
import Foundation
import ImageIO
import Vision

/// "Select subject": the main subjects of a photo (people, animals, objects in front), found by
/// Vision's foreground instance mask (the same model as lifting a subject in Photos). It runs
/// once per photo on a copy of at most 1536 px and is kept in memory.
public enum SubjectMask {
    private final class Entry {
        let mask: CIImage?
        init(_ mask: CIImage?) { self.mask = mask }
    }
    // NSCache is thread-safe.
    nonisolated(unsafe) private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 24
        return cache
    }()

    private static func key(_ url: URL) -> NSString {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(url.standardizedFileURL.path)#\(modified)" as NSString
    }

    /// The cached result, without running Vision: nil when the photo hasn't been analysed yet.
    public static func cached(for url: URL) -> CIImage?? { cache.object(forKey: key(url)).map(\.mask) }

    /// Gray mask (white = subject) of the upright photo, origin at the bottom left, or nil when
    /// Vision finds no subject. Runs Vision the first time; call it off the main thread.
    public static func mask(for url: URL) -> CIImage? {
        let key = key(url)
        if let entry = cache.object(forKey: key) { return entry.mask }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 1536, kCGImageSourceShouldCacheImmediately: true]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let mask = detect(image)
        cache.setObject(Entry(mask), forKey: key)
        return mask
    }

    /// Sets the result for a photo without running Vision (tests).
    static func store(_ mask: CIImage?, for url: URL) { cache.setObject(Entry(mask), forKey: key(url)) }

    /// Runs Vision on an upright image.
    public static func detect(_ image: CGImage) -> CIImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil, let result = request.results?.first, !result.allInstances.isEmpty,
              let buffer = try? result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler) else { return nil }
        // Render once into an 8-bit gray bitmap: small, and no dependency on Vision's buffer later.
        let raw = CIImage(cvPixelBuffer: buffer)
        guard let gray = ColorPipeline.shared.createCGImage(raw, from: raw.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray()) else { return nil }
        return CIImage(cgImage: gray)
    }

    /// The subject mask stretched over `extent`, with a soft edge.
    static func image(for url: URL?, extent: CGRect, feather: Double) -> CIImage {
        let black = CIImage(color: .black).cropped(to: extent)
        guard let url, let mask = mask(for: url), mask.extent.width > 0, mask.extent.height > 0 else { return black }
        var fitted = mask.transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY)
            .scaledBy(x: extent.width / mask.extent.width, y: extent.height / mask.extent.height))
        let blur = feather * 0.012 * Double(min(extent.width, extent.height))
        if blur > 0.5 { fitted = fitted.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur]) }
        // Single-channel input: copy the coverage into RGB so blending reads it.
        return fitted.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ]).cropped(to: extent)
    }
}
