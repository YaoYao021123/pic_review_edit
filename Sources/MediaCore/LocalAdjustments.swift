import CoreGraphics
import CoreImage
import Foundation

// Local adjustments (局部调整): a gradient, an ellipse or brush strokes that limit a set of
// basic sliders to part of the picture. The mask math follows the Lucet web edition
// (Apache-2.0, `masks.py`): smoothstep falloff, linear ramps from full at the start to none at
// the end, brush strokes as capsules, erase strokes, invert; rebuilt on Core Image.
//
// Coordinates are normalized to the picture before rotation and crop (0...1, origin top-left),
// so masks stay on the same content when the crop or rotation changes; GeometryMapping turns
// them into canvas positions.

public struct BrushStroke: Codable, Equatable, Sendable {
    public var points: [CGPoint]
    /// Brush radius as a fraction of the picture's shorter side.
    public var radius: Double
    public var erase: Bool
    public init(points: [CGPoint], radius: Double, erase: Bool = false) {
        self.points = points; self.radius = radius; self.erase = erase
    }
}

public struct LocalAdjustment: Codable, Equatable, Sendable, Identifiable {
    public enum Shape: String, Codable, Sendable, CaseIterable {
        case linear, radial, brush, subject, remove
        public var title: String {
            switch self { case .linear: L("渐变"); case .radial: L("椭圆"); case .brush: L("画笔"); case .subject: L("主体"); case .remove: L("去除") }
        }
        /// Painted with the brush (strokes, size, erase).
        public var isPainted: Bool { self == .brush || self == .remove }
        public var symbol: String {
            switch self {
            case .linear: "rectangle.tophalf.filled"; case .radial: "circle.dashed"; case .brush: "paintbrush.pointed"
            case .subject: "person.and.background.dotted"; case .remove: "eraser"
            }
        }
    }

    /// The sliders a local layer offers (Lightroom's masking panel, minus the RAW-only ones).
    public static let parameters: [AdjustmentParameter] = [.exposure, .contrast, .highlights, .shadows, .whites, .blackPoint,
                                                           .warmth, .tint, .saturation, .vibrance, .definition, .sharpness, .noiseReduction, .dehaze]
    public static let maximumLayers = 16
    public static let maximumPoints = 4096

    public var id = UUID()
    public var shape: Shape
    public var enabled = true
    public var invert = false
    /// Soft edge: for ellipses the share of the radius that fades; for brushes the blur.
    public var feather = 0.35
    /// Linear: full effect at `start`, none at `end`.
    public var start = CGPoint(x: 0.5, y: 0.1)
    public var end = CGPoint(x: 0.5, y: 0.55)
    /// Radial: center and radii as fractions of width and height.
    public var center = CGPoint(x: 0.5, y: 0.5)
    public var radii = CGSize(width: 0.25, height: 0.3)
    public var strokes: [BrushStroke] = []
    public var adjustments = BasicAdjustments()

    public init(shape: Shape) {
        self.shape = shape
        // Gradients start as the classic "darken the sky" filter; ellipses as a light spot.
        switch shape {
        case .linear: adjustments.exposure = -0.5
        case .radial: adjustments.exposure = 0.4
        case .brush: adjustments.exposure = 0.3
        case .subject: adjustments.exposure = 0.25; feather = 0.25
        case .remove: break
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, shape, enabled, invert, feather, start, end, center, radii, strokes, adjustments
    }

    /// Tolerant like the rest of the recipe: anything missing takes its default.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        shape = try values.decode(Shape.self, forKey: .shape)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        invert = try values.decodeIfPresent(Bool.self, forKey: .invert) ?? false
        feather = try values.decodeIfPresent(Double.self, forKey: .feather) ?? 0.35
        start = try values.decodeIfPresent(CGPoint.self, forKey: .start) ?? start
        end = try values.decodeIfPresent(CGPoint.self, forKey: .end) ?? end
        center = try values.decodeIfPresent(CGPoint.self, forKey: .center) ?? center
        radii = try values.decodeIfPresent(CGSize.self, forKey: .radii) ?? radii
        strokes = try values.decodeIfPresent([BrushStroke].self, forKey: .strokes) ?? []
        adjustments = try values.decodeIfPresent(BasicAdjustments.self, forKey: .adjustments) ?? .init()
    }

    public var title: String { shape.title }
    public var hasEffect: Bool {
        // Remove fills what is painted; it has no sliders.
        if shape == .remove { return enabled && strokes.contains { !$0.erase } }
        return enabled && !adjustments.sanitized.isNeutral && (shape != .brush || !strokes.isEmpty || invert)
    }

    public func validate() throws {
        let points = strokes.reduce(0) { $0 + $1.points.count }
        let finite = [start.x, start.y, end.x, end.y, center.x, center.y, radii.width, radii.height, feather].allSatisfy(\.isFinite)
        guard finite, (0...1).contains(feather), radii.width > 0.001, radii.height > 0.001, radii.width <= 2, radii.height <= 2,
              points <= Self.maximumPoints, strokes.allSatisfy({ $0.radius > 0.0005 && $0.radius <= 0.5 && !$0.points.isEmpty }),
              adjustments == adjustments.sanitized else {
            throw VideoWorkError.failed(L("局部调整的参数无效。"))
        }
    }
}

// MARK: - Masks

public enum LocalMask {
    /// Coverage 0...1 as a gray image over `extent` (Core Image coordinates). `source` is the
    /// photo file, for masks found in the picture itself (subject).
    public static func image(_ layer: LocalAdjustment, extent: CGRect, source: URL? = nil) -> CIImage {
        let w = extent.width, h = extent.height
        func point(_ p: CGPoint) -> CIVector { CIVector(x: extent.minX + p.x * w, y: extent.maxY - p.y * h) }
        var mask: CIImage
        switch layer.shape {
        case .linear:
            let start = layer.start
            var end = layer.end
            // Keep the two ends at least a pixel apart.
            if hypot((end.x - start.x) * w, (end.y - start.y) * h) < 1 { end.y = start.y + 1 / max(1, h) }
            mask = CIFilter(name: "CISmoothLinearGradient", parameters: [
                "inputPoint0": point(start), "inputPoint1": point(end),
                "inputColor0": CIColor.white, "inputColor1": CIColor.black
            ])!.outputImage!
        case .radial:
            // A unit circle gradient, stretched into the ellipse; then a smoothstep edge.
            let unit = 1000.0
            let inner = unit * max(0, 1 - layer.feather)
            let circle = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: 0, y: 0), "inputRadius0": inner, "inputRadius1": max(inner + 1, unit),
                "inputColor0": CIColor.white, "inputColor1": CIColor.black
            ])!.outputImage!
            let center = point(layer.center)
            mask = smoothstep(circle.transformed(by: CGAffineTransform(translationX: center.x, y: center.y)
                .scaledBy(x: layer.radii.width * w / unit, y: layer.radii.height * h / unit)))
        case .brush, .remove:
            mask = brush(layer, size: extent.size).transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        case .subject:
            mask = SubjectMask.image(for: source, extent: extent, feather: layer.feather)
        }
        if layer.invert { mask = mask.applyingFilter("CIColorInvert") }
        return mask.cropped(to: extent)
    }

    /// Blends `adjusted` over `base` where the mask is white.
    static func blend(_ adjusted: CIImage, over base: CIImage, mask: CIImage) -> CIImage {
        adjusted.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: base, kCIInputMaskImageKey: mask])
    }

    /// Red tint where the layer applies, for the "show mask" preview.
    static func overlay(_ image: CIImage, mask: CIImage) -> CIImage {
        let red = CIImage(color: CIColor(red: 1, green: 0.12, blue: 0.08)).cropped(to: image.extent)
        let half = mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.55, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0.55, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0.55, w: 0)
        ])
        return blend(red, over: image, mask: half)
    }

    private static let smoothKernel: CIColorKernel? = {
        let code = """
        #include <CoreImage/CoreImage.h>
        extern "C" float4 localSmoothstep(coreimage::sample_t s) {
            float t = clamp(s.r, 0.0, 1.0);
            t = t * t * (3.0 - 2.0 * t);
            return float4(t, t, t, 1.0);
        }
        """
        return (try? CIKernel.kernels(withMetalString: code))?.first as? CIColorKernel
    }()

    static func smoothstep(_ image: CIImage) -> CIImage {
        smoothKernel?.apply(extent: image.extent, arguments: [image]) ?? image
    }

    // Brush strokes are rasterized (at most 2048 px on the long side) and cached, since the
    // same strokes are drawn for every preview frame.
    // NSCache is thread-safe.
    nonisolated(unsafe) private static let cache = NSCache<NSString, CIImage>()

    static func brush(_ layer: LocalAdjustment, size: CGSize) -> CIImage {
        let scale = min(1, 2048 / max(size.width, size.height, 1))
        let width = max(1, Int((size.width * scale).rounded())), height = max(1, Int((size.height * scale).rounded()))
        var hasher = Hasher()
        for stroke in layer.strokes {
            hasher.combine(stroke.radius); hasher.combine(stroke.erase)
            for p in stroke.points { hasher.combine(p.x); hasher.combine(p.y) }
        }
        let key = "\(width)x\(height)#\(layer.feather)#\(layer.strokes.count)#\(hasher.finalize())" as NSString
        if let cached = cache.object(forKey: key) { return cached.transformed(by: CGAffineTransform(scaleX: size.width / CGFloat(width), y: size.height / CGFloat(height))) }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))
        }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setLineCap(.round); context.setLineJoin(.round)
        let short = CGFloat(min(width, height))
        for stroke in layer.strokes {
            let lineWidth = max(1, CGFloat(stroke.radius) * short * 2)
            context.setStrokeColor(gray: stroke.erase ? 0 : 1, alpha: 1)
            context.setFillColor(gray: stroke.erase ? 0 : 1, alpha: 1)
            context.setLineWidth(lineWidth)
            // Normalized y runs down; the bitmap's y runs up.
            let points = stroke.points.map { CGPoint(x: $0.x * CGFloat(width), y: (1 - $0.y) * CGFloat(height)) }
            if points.count == 1 {
                context.fillEllipse(in: CGRect(x: points[0].x - lineWidth / 2, y: points[0].y - lineWidth / 2, width: lineWidth, height: lineWidth))
            } else {
                context.addLines(between: points)
                context.strokePath()
            }
        }
        guard let bitmap = context.makeImage() else { return CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size)) }
        var mask = CIImage(cgImage: bitmap)
        let blur = layer.feather * 0.5 * Double(short) * (layer.strokes.map(\.radius).max() ?? 0.03)
        if blur > 0.5 { mask = mask.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur]).cropped(to: mask.extent) }
        cache.setObject(mask, forKey: key)
        return mask.transformed(by: CGAffineTransform(scaleX: size.width / CGFloat(width), y: size.height / CGFloat(height)))
    }
}

// MARK: - Applying layers

extension ColorPipeline {
    /// Local layers run on the globally graded picture, before rotation and crop.
    static func applyLocals(_ image: CIImage, edits: MediaEdits, reference: CGRect) throws -> CIImage {
        var result = image
        if edits.isActive(.local) {
            // Remove layers ran before grading (Retouch).
            for layer in edits.locals where layer.hasEffect && layer.shape != .remove {
                let a = layer.adjustments.sanitized
                var adjusted = result
                if a.noiseReduction > 0 { adjusted = BasicColorPipeline.denoise(adjusted, a) }
                adjusted = BasicColorPipeline.dehaze(adjusted, a, reference: reference)
                adjusted = try BasicColorPipeline.tone(adjusted, adjustments: a)
                if a.definition > 0 || a.sharpness > 0 { adjusted = BasicColorPipeline.sharpen(adjusted, a, reference: reference) }
                result = LocalMask.blend(adjusted, over: result, mask: LocalMask.image(layer, extent: reference, source: edits.source)).cropped(to: reference)
            }
        }
        if let id = edits.maskOverlay, let layer = edits.locals.first(where: { $0.id == id }) {
            result = LocalMask.overlay(result, mask: LocalMask.image(layer, extent: reference, source: edits.source)).cropped(to: reference)
        }
        return result
    }
}

// MARK: - Canvas mapping

/// Maps normalized points between the picture before geometry (where masks live) and the
/// rotated, cropped output the canvas shows. Both use 0...1 with the origin at the top left.
public struct GeometryMapping: Sendable {
    public let outputSize: CGSize
    private let forward: CGAffineTransform
    private let source: CGSize
    /// The picture's size before geometry, as given.
    public var sourceSize: CGSize { source }

    /// `source` is the oriented picture size before geometry (any scale).
    public init(source: CGSize, edits: MediaEdits) throws {
        let g = edits.geometry
        try g.validate()
        var transform = CGAffineTransform.identity
        var size = source
        let (w, h) = (source.width, source.height)
        switch g.quarterTurns {
        case 1: transform = transform.concatenating(.init(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)); size = CGSize(width: h, height: w)
        case 2: transform = transform.concatenating(.init(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h))
        case 3: transform = transform.concatenating(.init(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)); size = CGSize(width: h, height: w)
        default: break
        }
        if g.mirrored { transform = transform.concatenating(.init(a: -1, b: 0, c: 0, d: 1, tx: size.width, ty: 0)) }
        let plan = try StraighteningPlan(width: Int(size.width.rounded()), height: Int(size.height.rounded()),
                                         rotationRadians: edits.degrees * .pi / 180)
        transform = transform.concatenating(plan.transform)
            .concatenating(.init(translationX: -plan.cropRect.minX, y: -plan.cropRect.minY))
        let crop = g.cropRect(in: plan.cropRect.size)
        transform = transform.concatenating(.init(translationX: -crop.minX, y: -crop.minY))
        self.source = source
        forward = transform
        outputSize = crop.size
    }

    /// Picture-normalized → output-normalized (may fall outside 0...1 when cropped away).
    public func toOutput(_ p: CGPoint) -> CGPoint {
        let pixel = CGPoint(x: p.x * source.width, y: (1 - p.y) * source.height).applying(forward)
        return CGPoint(x: pixel.x / outputSize.width, y: 1 - pixel.y / outputSize.height)
    }

    /// Output-normalized → picture-normalized.
    public func toSource(_ p: CGPoint) -> CGPoint {
        let pixel = CGPoint(x: p.x * outputSize.width, y: (1 - p.y) * outputSize.height).applying(forward.inverted())
        return CGPoint(x: pixel.x / source.width, y: 1 - pixel.y / source.height)
    }

    /// How many output pixels one picture pixel spans (rotation keeps scale).
    public var scale: CGFloat { hypot(forward.a, forward.b) }
}
