import CoreGraphics
import CoreImage
import Foundation

/// "Remove": brush over something (a wire, a passer-by, litter, a dust spot) and it is filled
/// from its surroundings with Inpainting. Runs on the picture before grading, so later colour
/// changes apply to the filled area too. Each layer is solved around its own strokes; results
/// are cached per photo, strokes and size, since every preview frame needs them.
public enum Retouch {
    /// Longest side searched in full; larger pictures refine those matches level by level up
    /// to full resolution, which keeps the texture sharp.
    static let workingSize = 640.0

    final class Patch {
        let image: CIImage
        let mask: CIImage
        init(image: CIImage, mask: CIImage) { self.image = image; self.mask = mask }
    }
    // NSCache is thread-safe.
    nonisolated(unsafe) private static let cache: NSCache<NSString, Patch> = {
        let cache = NSCache<NSString, Patch>()
        cache.totalCostLimit = 400_000_000
        return cache
    }()

    static func layers(_ edits: MediaEdits) -> [LocalAdjustment] {
        edits.isActive(.local) ? edits.locals.filter { $0.shape == .remove && $0.hasEffect } : []
    }

    /// The picture with every Remove layer applied, in order. Needs the photo file (`edits.source`)
    /// to cache results; without one nothing is removed.
    public static func apply(_ image: CIImage, edits: MediaEdits) -> CIImage {
        let layers = layers(edits)
        guard !layers.isEmpty, let source = edits.source, !image.extent.isInfinite, image.extent.width >= 16, image.extent.height >= 16 else {
            return image
        }
        let modified = (try? source.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
        var key = "\(source.standardizedFileURL.path)#\(modified)#\(Int(image.extent.width))x\(Int(image.extent.height))"
        var result = image
        for layer in layers {
            key += "#" + strokeKey(layer)
            if let patch = cache.object(forKey: key as NSString) ?? solve(result, layer: layer).map({ patch in
                cache.setObject(patch, forKey: key as NSString, cost: Int(patch.image.extent.width * patch.image.extent.height) * 16)
                return patch
            }) {
                result = patch.image.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: result, kCIInputMaskImageKey: patch.mask])
                    .cropped(to: image.extent)
            }
        }
        return result
    }

    private static func strokeKey(_ layer: LocalAdjustment) -> String {
        var hasher = Hasher()
        for stroke in layer.strokes {
            hasher.combine(stroke.radius); hasher.combine(stroke.erase)
            for p in stroke.points { hasher.combine(p.x); hasher.combine(p.y) }
        }
        return "\(layer.strokes.count):\(hasher.finalize())"
    }

    /// Fills one layer's strokes; nil when there's nothing to fill or too little to copy from.
    static func solve(_ image: CIImage, layer: LocalAdjustment) -> Patch? {
        let extent = image.extent
        let short = Double(min(extent.width, extent.height))
        // Stroke bounds in Core Image coordinates.
        var bounds = CGRect.null
        for stroke in layer.strokes where !stroke.erase {
            let r = stroke.radius * short + 2
            for p in stroke.points {
                let x = extent.minX + p.x * extent.width, y = extent.maxY - p.y * extent.height
                bounds = bounds.union(CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
            }
        }
        guard !bounds.isNull else { return nil }
        // Room around the hole to copy from: at least as much again as the hole itself.
        let pad = max(32, 0.75 * max(bounds.width, bounds.height))
        let roi = bounds.insetBy(dx: -pad, dy: -pad).intersection(extent).integral
        guard roi.width >= 16, roi.height >= 16 else { return nil }
        let region = render(image, roi: roi, scale: 1)
        let mask = hole(layer, roi: roi, scale: 1, extent: extent, size: (region.width, region.height))
        guard mask.contains(true), let solved = Inpainting.fill(region, hole: mask, searchSize: Int(workingSize)) else { return nil }
        let filled = solved.image
        let patch = makeImage(filled).transformed(by: CGAffineTransform(translationX: roi.minX, y: roi.minY))
        // A slightly soft edge hides the seam between the filled and the untouched pixels.
        let edge = makeMask(mask, width: filled.width, height: filled.height)
            .transformed(by: CGAffineTransform(translationX: roi.minX, y: roi.minY))
            .clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(1, 0.002 * short)])
            .cropped(to: roi)
        guard let materialized = ColorPipeline.shared.createCGImage(patch, from: roi, format: .RGBAh, colorSpace: ColorPipeline.linearSpace),
              let maskBitmap = ColorPipeline.shared.createCGImage(edge, from: roi, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray()) else { return nil }
        let place = CGAffineTransform(translationX: roi.minX, y: roi.minY)
        return Patch(image: CIImage(cgImage: materialized).transformed(by: place), mask: CIImage(cgImage: maskBitmap).transformed(by: place))
    }

    /// The region as linear-light floats, top row first.
    static func render(_ image: CIImage, roi: CGRect, scale: Double) -> Inpainting.Image {
        let width = max(1, Int((roi.width * scale).rounded())), height = max(1, Int((roi.height * scale).rounded()))
        let placed = image.cropped(to: roi).transformed(by: CGAffineTransform(translationX: -roi.minX, y: -roi.minY)
            .concatenating(CGAffineTransform(scaleX: CGFloat(width) / roi.width, y: CGFloat(height) / roi.height)))
        var pixels = [SIMD4<Float>](repeating: .zero, count: width * height)
        pixels.withUnsafeMutableBytes {
            ColorPipeline.shared.render(placed, toBitmap: $0.baseAddress!, rowBytes: width * 16,
                                        bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAf, colorSpace: nil)
        }
        return Inpainting.Image(width: width, height: height, pixels: pixels)
    }

    /// The strokes rasterized over the region (top row first), a little wider than painted so
    /// an object's soft edge goes too.
    static func hole(_ layer: LocalAdjustment, roi: CGRect, scale: Double, extent: CGRect, size: (Int, Int)) -> [Bool] {
        let (width, height) = size
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return Array(repeating: false, count: width * height)
        }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setLineCap(.round); context.setLineJoin(.round)
        let short = Double(min(extent.width, extent.height))
        let sx = Double(width) / roi.width, sy = Double(height) / roi.height
        for stroke in layer.strokes {
            let lineWidth = max(1, 2 * stroke.radius * short * sx + (stroke.erase ? 0 : 3))
            context.setStrokeColor(gray: stroke.erase ? 0 : 1, alpha: 1)
            context.setFillColor(gray: stroke.erase ? 0 : 1, alpha: 1)
            context.setLineWidth(lineWidth)
            // Bitmap context y runs up, like Core Image; memory rows run from the top.
            let points = stroke.points.map { p in
                CGPoint(x: (extent.minX + p.x * extent.width - roi.minX) * sx, y: (extent.maxY - p.y * extent.height - roi.minY) * sy)
            }
            if points.count == 1 {
                context.fillEllipse(in: CGRect(x: points[0].x - lineWidth / 2, y: points[0].y - lineWidth / 2, width: lineWidth, height: lineWidth))
            } else {
                context.addLines(between: points)
                context.strokePath()
            }
        }
        guard let data = context.data else { return Array(repeating: false, count: width * height) }
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height)
        return (0..<(width * height)).map { bytes[$0] > 127 }
    }

    private static func makeImage(_ image: Inpainting.Image) -> CIImage {
        var pixels = image.pixels
        for i in pixels.indices { pixels[i].w = 1 }
        let data = pixels.withUnsafeBytes { Data($0) }
        return CIImage(bitmapData: data, bytesPerRow: image.width * 16, size: CGSize(width: image.width, height: image.height),
                       format: .RGBAf, colorSpace: ColorPipeline.linearSpace)
    }

    private static func makeMask(_ hole: [Bool], width: Int, height: Int) -> CIImage {
        let data = Data(hole.map { $0 ? 255 : 0 } as [UInt8])
        return CIImage(bitmapData: data, bytesPerRow: width, size: CGSize(width: width, height: height), format: .L8,
                       colorSpace: CGColorSpaceCreateDeviceGray())
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
    }
}
