import CoreImage
import Foundation

// Effects suggested by the Lucet web edition (engine.render: dehaze, fade, grain, black and
// white). Fade, grain and black and white follow its formulas; dehaze uses the dark-channel
// prior (He, Sun and Tang 2009) instead of its simple contrast lift.

extension BasicColorPipeline {
    private static let encoded = CGColorSpace(name: CGColorSpace.extendedSRGB)!
    private static func size(_ reference: CGRect) -> CGFloat { max(reference.width, reference.height) / 1600 }

    private static let kernels: [String: CIKernel] = {
        let code = """
        #include <CoreImage/CoreImage.h>
        using namespace metal;
        [[stitchable]] float4 darkChannel(coreimage::sample_t p, float3 air) {
            float3 n = p.rgb / max(air, float3(0.02));
            float d = min(n.r, min(n.g, n.b));
            return float4(d, d, d, 1.0);
        }
        [[stitchable]] float4 dehazeRecover(coreimage::sample_t p, coreimage::sample_t t, float3 air, float amount) {
            float3 clear = (p.rgb - air) / max(t.r, 0.12) + air;
            return float4(max(mix(p.rgb, clear, amount), float3(0.0)), p.a);
        }
        [[stitchable]] float4 addHaze(coreimage::sample_t p, float3 air, float amount) {
            float y = dot(p.rgb, float3(0.2126, 0.7152, 0.0722));
            // Haze lifts dark areas most and leaves bright ones close to the air color.
            float k = amount * (0.45 - 0.2 * y);
            return float4(mix(p.rgb, air, clamp(k, 0.0, 1.0)), p.a);
        }
        [[stitchable]] float4 filmGrain(coreimage::sample_t p, coreimage::sample_t n, float amount) {
            float y = dot(p.rgb, float3(0.2126, 0.7152, 0.0722));
            float w = 0.35 + 2.6 * y * (1.0 - y);
            return float4(max(p.rgb + (n.r - 0.5) * amount * w, float3(0.0)), p.a);
        }
        """
        let list = (try? CIKernel.kernels(withMetalString: code)) ?? []
        return Dictionary(uniqueKeysWithValues: list.map { ($0.name, $0) })
    }()

    /// Removes (positive) or adds (negative) atmospheric haze. Works in linear light, where the
    /// haze model I = J·t + A·(1 − t) holds: A is the haze color, t how much scene light survives.
    public static func dehaze(_ image: CIImage, _ a: BasicAdjustments, reference: CGRect) -> CIImage {
        guard a.dehaze != 0, let dark = kernels["darkChannel"] as? CIColorKernel,
              let recover = kernels["dehazeRecover"] as? CIColorKernel, let haze = kernels["addHaze"] as? CIColorKernel else { return image }
        let amount = a.dehaze / 100
        // Estimates run on a small copy: the haze field is smooth, and this keeps it cheap.
        let scale = min(1, 360 / max(reference.width, reference.height, 1))
        let small = image.transformed(by: CGAffineTransform(translationX: -reference.minX, y: -reference.minY).scaledBy(x: scale, y: scale))
        let smallExtent = CGRect(x: 0, y: 0, width: (reference.width * scale).rounded(.down), height: (reference.height * scale).rounded(.down))
        let air = airLight(small.cropped(to: smallExtent), dark: dark)
        let airVector = CIVector(x: air.x, y: air.y, z: air.z)
        if amount < 0 {
            return haze.apply(extent: image.extent, arguments: [image, airVector, -amount])?.cropped(to: reference) ?? image
        }
        guard let darkSmall = dark.apply(extent: smallExtent, arguments: [small, airVector]) else { return image }
        let patch = darkSmall.clampedToExtent()
            .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 4])
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 6])
            .cropped(to: smallExtent)
        // t = 1 − ω·dark(I / A), ω = 0.95 keeps a trace of haze so distance still reads.
        let transmission = patch.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: -0.95, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: -0.95, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: -0.95, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0)
        ])
        let full = transmission.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale).concatenating(.init(translationX: reference.minX, y: reference.minY)))
            .cropped(to: reference)
        return recover.apply(extent: reference, arguments: [image, full, airVector, amount])?.cropped(to: reference) ?? image
    }

    /// The haze color: the average of the pixels with the haziest (brightest) dark channel.
    private static func airLight(_ small: CIImage, dark: CIColorKernel) -> SIMD3<Double> {
        let extent = small.extent
        guard extent.width >= 4, extent.height >= 4,
              let channel = dark.apply(extent: extent, arguments: [small, CIVector(x: 1, y: 1, z: 1)])?
                .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 4]).cropped(to: extent) else {
            return SIMD3(0.9, 0.9, 0.9)
        }
        let width = Int(extent.width), height = Int(extent.height)
        var colors = [Float](repeating: 0, count: width * height * 4)
        var darks = colors
        colors.withUnsafeMutableBytes {
            ColorPipeline.shared.render(small, toBitmap: $0.baseAddress!, rowBytes: width * 16, bounds: extent, format: .RGBAf, colorSpace: nil)
        }
        darks.withUnsafeMutableBytes {
            ColorPipeline.shared.render(channel, toBitmap: $0.baseAddress!, rowBytes: width * 16, bounds: extent, format: .RGBAf, colorSpace: nil)
        }
        // The haziest 0.2%: find the cut-off with a histogram rather than sorting every pixel.
        let count = width * height, bins = 1024
        var histogram = [Int](repeating: 0, count: bins)
        func bin(_ value: Float) -> Int { min(bins - 1, max(0, Int(value / 1.5 * Float(bins)))) }
        for index in 0..<count { histogram[bin(darks[index * 4])] += 1 }
        var cut = bins - 1, seen = 0
        while cut > 0, seen + histogram[cut] < max(1, count / 500) { seen += histogram[cut]; cut -= 1 }
        var sum = SIMD3<Double>(repeating: 0), taken = 0
        for index in 0..<count where bin(darks[index * 4]) >= cut {
            sum += SIMD3(Double(colors[index * 4]), Double(colors[index * 4 + 1]), Double(colors[index * 4 + 2]))
            taken += 1
        }
        let air = sum / Double(max(1, taken))
        return SIMD3(min(1.5, max(0.05, air.x)), min(1.5, max(0.05, air.y)), min(1.5, max(0.05, air.z)))
    }

    /// Faded film: lifts the blacks and softens the whites, in display values.
    public static func fade(_ image: CIImage, _ a: BasicAdjustments) -> CIImage {
        guard a.fade > 0, let display = image.matchedFromWorkingSpace(to: encoded) else { return image }
        let f = a.fade / 100, scale = 1 - 0.22 * f, lift = 0.13 * f
        let faded = display.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0), "inputBiasVector": CIVector(x: lift, y: lift, z: lift, w: 0)
        ])
        return faded.matchedToWorkingSpace(from: encoded)?.cropped(to: image.extent) ?? image
    }

    /// Monochrome film grain, strongest in the midtones. Its size follows the picture size, so a
    /// preview and a full-size export look alike.
    public static func grain(_ image: CIImage, _ a: BasicAdjustments, reference: CGRect) -> CIImage {
        guard a.grain > 0, let kernel = kernels["filmGrain"] as? CIColorKernel,
              let display = image.matchedFromWorkingSpace(to: encoded),
              let random = CIFilter(name: "CIRandomGenerator")?.outputImage else { return image }
        let s = max(1, size(reference))
        let noise = random
            .transformed(by: CGAffineTransform(scaleX: s, y: s).concatenating(.init(translationX: reference.minX, y: reference.minY)))
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.5 * s])
            .cropped(to: reference)
        let amount = a.grain / 100 * 0.16
        guard let grained = kernel.apply(extent: reference, arguments: [display, noise, amount]) else { return image }
        return grained.matchedToWorkingSpace(from: encoded)?.cropped(to: reference) ?? image
    }

    /// Black and white: blends toward luminance (100 = fully monochrome).
    public static func monochrome(_ image: CIImage, _ a: BasicAdjustments) -> CIImage {
        guard a.monochrome > 0 else { return image }
        let m = a.monochrome / 100, keep = 1 - m
        let r = 0.2126 * m, g = 0.7152 * m, b = 0.0722 * m
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: keep + r, y: g, z: b, w: 0),
            "inputGVector": CIVector(x: r, y: keep + g, z: b, w: 0),
            "inputBVector": CIVector(x: r, y: g, z: keep + b, w: 0)
        ]).cropped(to: image.extent)
    }
}
