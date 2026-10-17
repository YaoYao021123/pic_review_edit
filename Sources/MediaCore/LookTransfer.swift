import CoreGraphics
import CoreImage
import Foundation

// Two ways of turning a look into a 3D LUT, adapted from the Lucet web edition
// (Apache-2.0, `engine.bake_lut` and `engine.transfer_lut`):
// export the current grade for other apps, and match the colors of a reference photo.

extension CubeLUT {
    /// A table from values already in .cube order (red fastest), domain 0...1.
    init(title: String?, dimension: Int, rgb: [Float]) {
        self.title = title; self.dimension = dimension
        domainMin = [0, 0, 0]; domainMax = [1, 1, 1]; self.rgb = rgb
    }

    /// Every lattice point as display-encoded RGB in 0...1, red fastest, then green, then blue.
    static func lattice(_ size: Int) -> [SIMD3<Float>] {
        let step = 1 / Float(size - 1)
        var points: [SIMD3<Float>] = []
        points.reserveCapacity(size * size * size)
        for b in 0..<size { for g in 0..<size { for r in 0..<size {
            points.append(SIMD3(Float(r) * step, Float(g) * step, Float(b) * step))
        } } }
        return points
    }
}

public enum LUTBaker {
    /// Bakes the per-pixel part of a grade (basic light and color, wheels, curves, HSL, LUT)
    /// into a .cube with sRGB / Rec.709 display encoding in and out, for use in other apps.
    /// Noise reduction, dehaze, clarity, sharpening, vignette and grain depend on neighbouring
    /// pixels or position, so they cannot live in a LUT and are left out; fade and black and
    /// white are per pixel and stay in.
    public static func bake(_ edits: MediaEdits, size: Int = 33, title: String) throws -> CubeLUT {
        precondition((2...65).contains(size))
        var colorOnly = edits
        colorOnly.adjustments = edits.adjustments.withoutSpatial
        colorOnly.locals = []
        colorOnly.degrees = 0
        colorOnly.geometry = .init()
        let points = CubeLUT.lattice(size)
        var pixels = [Float](repeating: 1, count: points.count * 4)
        for (index, point) in points.enumerated() {
            pixels[index * 4] = point.x; pixels[index * 4 + 1] = point.y; pixels[index * 4 + 2] = point.z
        }
        // One row per (green, blue) pair; Core Image reads and writes rows in the same order.
        let width = size, height = size * size, rowBytes = width * 16
        let input = CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: rowBytes,
                            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: ColorPipeline.outputSpace)
        let graded = try ColorPipeline.grade(input, edits: colorOnly)
        var output = [Float](repeating: 0, count: pixels.count)
        output.withUnsafeMutableBytes { buffer in
            ColorPipeline.shared.render(graded, toBitmap: buffer.baseAddress!, rowBytes: rowBytes,
                                        bounds: CGRect(x: 0, y: 0, width: width, height: height),
                                        format: .RGBAf, colorSpace: ColorPipeline.outputSpace)
        }
        var rgb: [Float] = []
        rgb.reserveCapacity(points.count * 3)
        for index in 0..<points.count {
            for channel in 0..<3 { rgb.append(min(1, max(0, output[index * 4 + channel]))) }
        }
        return CubeLUT(title: title, dimension: size, rgb: rgb)
    }
}

/// Matches one photo's colors to another's: the source's mean and spread in CIE Lab are moved
/// toward the reference's (Reinhard et al. 2001), then baked into a LUT so the result can be
/// blended with the LUT strength slider and reused on other photos.
public enum LookMatch {
    public struct LabStatistics: Sendable, Equatable {
        public var mean: SIMD3<Double>
        public var deviation: SIMD3<Double>
    }

    /// Mean and standard deviation in Lab of an sRGB image (sampled at most 256 px on the long edge).
    public static func statistics(_ image: CGImage) -> LabStatistics? {
        let longEdge = max(image.width, image.height)
        guard longEdge > 0 else { return nil }
        let scale = min(1, 256 / Double(longEdge))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: ColorPipeline.outputSpace,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var sum = SIMD3<Double>(repeating: 0), squares = SIMD3<Double>(repeating: 0)
        let count = Double(width * height)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let lab = Self.lab(SIMD3(Double(bytes[index]), Double(bytes[index + 1]), Double(bytes[index + 2])) / 255)
            sum += lab; squares += lab * lab
        }
        let mean = sum / count
        let variance = squares / count - mean * mean
        return LabStatistics(mean: mean, deviation: SIMD3(variance.x.squareRoot(), variance.y.squareRoot(), variance.z.squareRoot()))
    }

    /// A LUT that moves `source` statistics onto `reference`. Spread ratios are limited
    /// (the web edition uses 0.5–2; here 0.67–1.5) so a very colorful or flat reference
    /// can't push colors into clipping.
    public static func lut(from source: LabStatistics, to reference: LabStatistics, size: Int = 33, title: String) -> CubeLUT {
        func ratio(_ to: Double, _ from: Double) -> Double { min(1.5, max(1 / 1.5, to / max(from, 1e-3))) }
        let ratio = SIMD3(ratio(reference.deviation.x, source.deviation.x),
                          ratio(reference.deviation.y, source.deviation.y),
                          ratio(reference.deviation.z, source.deviation.z))
        var rgb: [Float] = []
        rgb.reserveCapacity(size * size * size * 3)
        for point in CubeLUT.lattice(size) {
            let lab = (Self.lab(SIMD3(Double(point.x), Double(point.y), Double(point.z))) - source.mean) * ratio + reference.mean
            let out = Self.rgb(lab)
            rgb += [Float(out.x), Float(out.y), Float(out.z)].map { min(1, max(0, $0)) }
        }
        return CubeLUT(title: title, dimension: size, rgb: rgb)
    }

    // MARK: sRGB ⇄ CIE Lab (D65)

    static func lab(_ srgb: SIMD3<Double>) -> SIMD3<Double> {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let r = linear(srgb.x), g = linear(srgb.y), b = linear(srgb.z)
        let x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047
        let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        let z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883
        func f(_ t: Double) -> Double { t > 216.0 / 24389 ? cbrt(t) : (24389.0 / 27 * t + 16) / 116 }
        let fx = f(x), fy = f(y), fz = f(z)
        return SIMD3(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    static func rgb(_ lab: SIMD3<Double>) -> SIMD3<Double> {
        let fy = (lab.x + 16) / 116, fx = fy + lab.y / 500, fz = fy - lab.z / 200
        func inverse(_ t: Double) -> Double { t * t * t > 216.0 / 24389 ? t * t * t : (116 * t - 16) / (24389.0 / 27) }
        let x = inverse(fx) * 0.95047, y = inverse(fy), z = inverse(fz) * 1.08883
        let r = 3.2404542 * x - 1.5371385 * y - 0.4985314 * z
        let g = -0.9692660 * x + 1.8760108 * y + 0.0415560 * z
        let b = 0.0556434 * x - 0.2040259 * y + 1.0572252 * z
        func encode(_ c: Double) -> Double {
            let c = max(0, c)
            return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
        }
        return SIMD3(encode(r), encode(g), encode(b))
    }
}
