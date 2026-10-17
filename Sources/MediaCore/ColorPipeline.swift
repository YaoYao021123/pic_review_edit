import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum LUTEncoding: String, Sendable, CaseIterable, Codable {
    case sRGB, rec709 = "Rec.709"
    public var colorSpace: CGColorSpace {
        CGColorSpace(name: self == .sRGB ? CGColorSpace.sRGB : CGColorSpace.itur_709)!
    }
}

/// The encoding describes both sides of a display-to-display creative LUT.
/// Camera Log conversion remains a separate operation.
public struct CreativeLUT: Sendable, Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public let id: UUID
    public let name: String
    public let cube: CubeLUT
    public let data: Data
    public let encoding: LUTEncoding

    public init(cube: CubeLUT, name: String, encoding: LUTEncoding = .sRGB) {
        id = UUID(); self.name = name; self.cube = cube; data = cube.rgbaData(); self.encoding = encoding
    }

    /// Same table, different declared encoding. Keeps the table data shared.
    public func with(encoding: LUTEncoding) -> CreativeLUT {
        CreativeLUT(cube: cube, name: name, encoding: encoding)
    }

    public static let warm = builtIn(name: L("暖调"), warm: true)
    public static let soft = builtIn(name: L("柔和"), warm: false)
    public var isBuiltIn: Bool { id == Self.warm.id || id == Self.soft.id }

    private static func builtIn(name: String, warm: Bool) -> CreativeLUT {
        let size = 17
        var lines = ["TITLE \"\(name)\"", "LUT_3D_SIZE \(size)"]
        for b in 0..<size { for g in 0..<size { for r in 0..<size {
            let values = [Double(r), Double(g), Double(b)].map { $0 / Double(size - 1) }
            let out = warm ? [min(1, values[0] * 1.04 + 0.015), values[1], values[2] * 0.94] : values.map { $0 * 0.90 + 0.04 }
            lines.append(out.map(String.init(describing:)).joined(separator: " "))
        } } }
        // Static tables are generated from finite values and a known dimension.
        return CreativeLUT(cube: try! CubeLUT(text: lines.joined(separator: "\n")), name: name)
    }
}

public struct MediaEdits: Sendable, Equatable {
    public var degrees: Double
    public var lut: CreativeLUT?
    public var strength: Double
    public var hdrEffect: Bool
    public var adjustments: BasicAdjustments
    public var geometry: GeometryAdjustments
    public var wheels: ColorWheels
    public var curves: ToneCurves
    public var hsl: HSLAdjustments
    /// Stages switched off in the inspector. Bypassed stages keep their values.
    public var bypass: Set<GradeStage>
    /// Local adjustment layers, applied after the global grade and before geometry.
    public var locals: [LocalAdjustment]
    /// Preview only: tints this layer's mask red. Never saved or exported.
    public var maskOverlay: UUID?
    /// The photo file, for masks found in the picture itself (subject). Set by whoever decodes
    /// the photo; not part of the recipe.
    public var source: URL?

    public init(degrees: Double = 0, lut: CreativeLUT? = nil, strength: Double = 1, hdrEffect: Bool = false,
                adjustments: BasicAdjustments = .init(), geometry: GeometryAdjustments = .init(),
                wheels: ColorWheels = .init(), curves: ToneCurves = .init(), hsl: HSLAdjustments = .init(),
                bypass: Set<GradeStage> = [], locals: [LocalAdjustment] = [], maskOverlay: UUID? = nil) {
        self.degrees = degrees; self.lut = lut; self.strength = strength; self.hdrEffect = hdrEffect
        self.adjustments = adjustments.sanitized; self.geometry = geometry
        self.wheels = wheels.sanitized; self.curves = curves; self.hsl = hsl; self.bypass = bypass
        self.locals = locals; self.maskOverlay = maskOverlay
    }

    /// The edits a saved recipe describes (its LUT already loaded).
    public init(recipe: EditRecipe, lut: CreativeLUT?, isVideo: Bool = false) {
        self.init(degrees: recipe.degrees, lut: lut, strength: recipe.strength, hdrEffect: isVideo && recipe.hdrEffect,
                  adjustments: recipe.adjustments, geometry: recipe.geometry, wheels: recipe.wheels, curves: recipe.curves,
                  hsl: recipe.hsl, bypass: recipe.bypass, locals: recipe.locals)
    }

    public func isActive(_ stage: GradeStage) -> Bool { !bypass.contains(stage) }
    public var hasGeometry: Bool { degrees != 0 || geometry.hasChanges }
    /// Any color work other than the LUT that is switched on.
    public var hasAdjustments: Bool {
        let a = adjustments.sanitized
        return (isActive(.basic) && !a.isToneNeutral)
            || (isActive(.detail) && !a.isDetailNeutral)
            || (isActive(.wheels) && !wheels.isNeutral)
            || (isActive(.curves) && !curves.isIdentity)
            || (isActive(.hsl) && !hsl.isNeutral)
            || (isActive(.local) && locals.contains(where: \.hasEffect))
            || maskOverlay != nil
    }
    public var hasLUT: Bool { lut != nil && strength > 0 && isActive(.lut) }
    public var hasGrade: Bool { hasLUT || hasAdjustments }
}

public enum ColorPipeline {
    public static let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    public static let outputSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// One GPU context for the whole process. Creating a CIContext costs
    /// 10–50 ms; a shared, thread-safe instance renders in well under 1 ms.
    public static let shared = CIContext(options: [.workingColorSpace: linearSpace,
                                                   .workingFormat: CIFormat.RGBAh.rawValue,
                                                   .cacheIntermediates: false])

    /// Returns the shared context. Kept as a function for existing callers.
    public static func context() -> CIContext { shared }

    public static func toneMap(_ image: CIImage, sourceHeadroom: Float, targetHeadroom: Float = 1) -> CIImage {
        guard sourceHeadroom > targetHeadroom else { return image }
        return image.applyingFilter("CIToneMapHeadroom", parameters: [
            "inputSourceHeadroom": sourceHeadroom, "inputTargetHeadroom": max(1, targetHeadroom)
        ])
    }

    /// Fixed node order (DaVinci-style): input → noise reduction → dehaze → basic → wheels →
    /// curves → HSL → black and white → LUT → sharpening → fade → vignette → grain → local layers.
    /// Geometry follows separately.
    public static func grade(_ image: CIImage, edits: MediaEdits, sourceHeadroom: Float = 1) throws -> CIImage {
        guard edits.hasGrade else { return image }
        let a = edits.adjustments.sanitized
        let reference = image.extent
        var result = toneMap(Retouch.apply(image, edits: edits), sourceHeadroom: sourceHeadroom)
        if edits.isActive(.detail) {
            result = BasicColorPipeline.denoise(result, a)
            result = BasicColorPipeline.dehaze(result, a, reference: reference)
        }
        if edits.isActive(.basic) { result = try BasicColorPipeline.tone(result, adjustments: a) }
        if edits.isActive(.wheels) { result = try GradeKernels.wheels(result, edits.wheels) }
        if edits.isActive(.curves) { result = GradeKernels.curves(result, edits.curves) }
        if edits.isActive(.hsl) { result = try GradeKernels.hsl(result, edits.hsl) }
        if edits.isActive(.detail) { result = BasicColorPipeline.monochrome(result, a) }
        if edits.hasLUT, let lut = edits.lut { result = applyLUT(result, lut: lut, strength: edits.strength, extent: reference) }
        if edits.isActive(.detail) {
            result = BasicColorPipeline.sharpen(result, a, reference: reference)
            result = BasicColorPipeline.fade(result, a)
            result = BasicColorPipeline.vignette(result, a, reference: reference)
            result = BasicColorPipeline.grain(result, a, reference: reference)
        }
        result = try applyLocals(result.cropped(to: reference), edits: edits, reference: reference)
        return result.cropped(to: reference)
    }

    static func applyLUT(_ base: CIImage, lut: CreativeLUT, strength: Double, extent: CGRect) -> CIImage {
        // Explicit conversion prevents applying a display LUT to linear-light RGB.
        let encoded = base.matchedFromWorkingSpace(to: lut.encoding.colorSpace)!
        let scales = zip(lut.cube.domainMin, lut.cube.domainMax).map { 1 / ($1 - $0) }
        let bias = zip(lut.cube.domainMin, scales).map { -$0 * $1 }
        let normalized = encoded.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(scales[0]), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: CGFloat(scales[1]), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(scales[2]), w: 0),
            "inputBiasVector": CIVector(x: CGFloat(bias[0]), y: CGFloat(bias[1]), z: CGFloat(bias[2]), w: 0)
        ])
        let graded = normalized.applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": lut.cube.dimension, "inputCubeData": lut.data
        ])
        let mixed = graded.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: encoded, kCIInputTimeKey: 1 - min(1, max(0, strength))
        ])
        return mixed.matchedToWorkingSpace(from: lut.encoding.colorSpace)!.cropped(to: extent)
    }

    public static func geometry(_ image: CIImage, degrees: Double) throws -> CIImage {
        let input = image.transformed(by: .init(translationX: -image.extent.minX, y: -image.extent.minY))
        let plan = try StraighteningPlan(width: Int(input.extent.width.rounded()), height: Int(input.extent.height.rounded()),
                                        rotationRadians: degrees * .pi / 180)
        return input.transformed(by: plan.transform).cropped(to: plan.cropRect)
            .transformed(by: .init(translationX: -plan.cropRect.minX, y: -plan.cropRect.minY))
    }

    public static func sdrBitmap(_ image: CIImage, headroom: Float = 1, context: CIContext? = nil) throws -> CGImage {
        let mapped = toneMap(image, sourceHeadroom: headroom)
        guard let result = (context ?? shared).createCGImage(mapped, from: mapped.extent,
            format: .RGBA8, colorSpace: outputSpace) else { throw StraighteningError.renderFailed }
        return result
    }

    public static func exportPNG(_ url: URL, to output: URL, edits: MediaEdits) throws {
        var options = ImageExportOptions()
        options.format = .png
        options.keepMetadata = false
        try ImageExporter.export(url, to: output, edits: edits, options: options)
    }
    public static func exportPNGAsync(_ url: URL, to output: URL, edits: MediaEdits) async throws {
        let worker = Task.detached(priority: .userInitiated) { try exportPNG(url, to: output, edits: edits) }
        try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}

public struct GradeFrame: Sendable {
    /// Graded preview after geometry, at proxy resolution.
    public let image: CIImage
    /// Untouched proxy (no grade, no geometry), for the "original" comparison.
    public let original: CIImage
    /// Same geometry as `image` but without grading; aligns with `image` for split views.
    public let before: CIImage
    public let headroom: Float
    public let sourceHeadroom: Float
    /// Full-resolution graphs, present once the session has decoded the full image.
    public let fullImage: CIImage?
    public let fullBefore: CIImage?
    /// Output size at full resolution after geometry, in pixels.
    public let fullSize: CGSize
}

/// Decodes one bounded floating-point proxy per opened image and, on request,
/// the full-resolution bitmap used for 100% zoom and pixel inspection.
public actor ImageGradeSession {
    private let image: CIImage
    private let headroom: Float
    private let url: URL
    private let sourceSize: CGSize
    private var full: CIImage?
    public nonisolated let proxyScale: CGFloat

    public init(url: URL, maximumDimension: Int = 1600) throws {
        let decoded = try Self.decode(url)
        self.url = url
        headroom = max(1, decoded.contentHeadroom)
        sourceSize = decoded.extent.size
        let scale = min(1, CGFloat(maximumDimension) / max(decoded.extent.width, decoded.extent.height))
        proxyScale = scale
        let small = decoded.transformed(by: .init(scaleX: scale, y: scale))
        image = try Self.materialize(small, hdr: headroom > 1)
        if scale == 1 { full = image }
    }

    /// SDR sources stay 8-bit sRGB (half the memory); HDR keeps half-float linear light.
    private static func materialize(_ source: CIImage, hdr: Bool) throws -> CIImage {
        let extent = source.extent.integral
        let bitmap = hdr
            ? ColorPipeline.shared.createCGImage(source, from: extent, format: .RGBAh, colorSpace: ColorPipeline.linearSpace)
            : ColorPipeline.shared.createCGImage(source, from: extent, format: .RGBA8, colorSpace: ColorPipeline.outputSpace)
        guard let bitmap else { throw StraighteningError.renderFailed }
        return CIImage(cgImage: bitmap)
    }

    public static func decode(_ url: URL) throws -> CIImage {
        guard url.isFileURL, let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true, .expandToHDR: true]),
              !image.extent.isInfinite, !image.extent.isEmpty else { throw StraighteningError.unreadableImage }
        return image.transformed(by: .init(translationX: -image.extent.minX, y: -image.extent.minY))
    }

    public var hasFullResolution: Bool { full != nil }

    /// Decodes the full image once. Safe to call repeatedly.
    public func loadFullResolution() throws {
        guard full == nil else { return }
        try Task.checkCancellation()
        full = try Self.materialize(try Self.decode(url), hdr: headroom > 1)
    }

    public func frame(edits: MediaEdits) throws -> GradeFrame {
        try Task.checkCancellation()
        var edits = edits
        edits.source = url
        let graded = try ColorPipeline.grade(image, edits: edits, sourceHeadroom: headroom)
        let output = try ColorPipeline.geometry(graded, edits: edits)
        let before = try ColorPipeline.geometry(image, edits: edits)
        var fullImage: CIImage?, fullBefore: CIImage?
        if let full, full !== image {
            fullImage = try ColorPipeline.geometry(try ColorPipeline.grade(full, edits: edits, sourceHeadroom: headroom), edits: edits)
            fullBefore = try ColorPipeline.geometry(full, edits: edits)
        } else if full != nil {
            fullImage = output; fullBefore = before
        }
        let fullSize = try ColorPipeline.geometrySize(width: Int(sourceSize.width.rounded()),
                                                     height: Int(sourceSize.height.rounded()), edits: edits)
        return GradeFrame(image: output, original: image, before: before,
                          headroom: edits.hasGrade ? 1 : headroom, sourceHeadroom: headroom,
                          fullImage: fullImage, fullBefore: fullBefore, fullSize: fullSize)
    }
}
