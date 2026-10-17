import CoreImage
import Foundation

/// Which pixels a control acts on. Weights mirror the grading kernels, so the
/// overlay shows what the slider really touches in this photo.
public enum InfluenceKind: Hashable, Sendable, Codable {
    case highlights, shadows, whites, blacks, midtones, brilliance
    case lift, gain
    case hue(HueBand)
    case skin, sky, neutral, saturated

    public var title: String {
        switch self {
        case .highlights: L("高光")
        case .shadows: L("阴影")
        case .whites: L("白色")
        case .blacks: L("黑色")
        case .midtones: L("中间调")
        case .brilliance: L("鲜明度")
        case .lift: L("暗部（Lift）")
        case .gain: L("亮部（Gain）")
        case .hue(let band): L("\(band.title)色系")
        case .skin: L("肤色")
        case .sky: L("天空")
        case .neutral: L("接近中性灰的区域")
        case .saturated: L("饱和度过高的区域")
        }
    }

    var mode: Float {
        switch self {
        case .highlights: 0; case .shadows: 1; case .whites: 2; case .blacks: 3; case .midtones: 4
        case .brilliance: 5; case .lift: 6; case .gain: 7; case .hue: 8; case .skin: 9; case .sky: 10
        case .neutral: 11; case .saturated: 12
        }
    }

    /// The overlay for a basic slider, when it acts on a tonal region.
    public static func forParameter(_ parameter: AdjustmentParameter) -> InfluenceKind? {
        switch parameter {
        case .highlights: .highlights
        case .shadows: .shadows
        case .whites: .whites
        case .blackPoint: .blacks
        case .brilliance: .brilliance
        default: nil
        }
    }
}

public enum InfluenceOverlay {
    private static let encodedSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private static let kernel: CIColorKernel? = {
        let code = """
        #include <CoreImage/CoreImage.h>
        using namespace metal;
        float influenceWeight(float3 c, float mode, float center) {
            float y = dot(c, float3(0.2126, 0.7152, 0.0722));
            float hi = max(c.r, max(c.g, c.b)), lo = min(c.r, min(c.g, c.b));
            float s = hi > 0.001 ? (hi - lo) / hi : 0.0;
            if (mode < 0.5) return smoothstep(0.45, 0.95, y);
            if (mode < 1.5) return 1.0 - smoothstep(0.04, 0.60, y);
            if (mode < 2.5) return smoothstep(0.70, 1.0, y);
            if (mode < 3.5) return 1.0 - smoothstep(0.0, 0.25, y);
            if (mode < 4.5) return clamp(pow(4.0 * y * (1.0 - y), 1.5), 0.0, 1.0);
            if (mode < 5.5) {
                float h = smoothstep(0.45, 0.95, y), sh = 1.0 - smoothstep(0.04, 0.60, y), bl = 1.0 - smoothstep(0.0, 0.25, y);
                return clamp(abs(0.14 * sh * (1.0 - bl) + 0.07 * (1.0 - h) - 0.12 * h) / 0.14, 0.0, 1.0);
            }
            if (mode < 6.5) return pow(clamp(1.0 - y, 0.0, 1.0), 1.5);
            if (mode < 7.5) return pow(clamp(y, 0.0, 1.0), 1.5);
            float hue = 0.0;
            float d = hi - lo;
            if (d > 0.00001) {
                if (hi == c.r) hue = fmod((c.g - c.b) / d + 6.0, 6.0);
                else if (hi == c.g) hue = (c.b - c.r) / d + 2.0;
                else hue = (c.r - c.g) / d + 4.0;
            }
            hue *= 60.0;
            if (mode < 8.5) {
                float distance = min(abs(hue - center), 360.0 - abs(hue - center));
                return max(0.0, 1.0 - distance / 35.0) * smoothstep(0.02, 0.18, s);
            }
            if (mode < 9.5) {
                float cb = (c.b - y) / 1.8556, cr = (c.r - y) / 1.5748;
                float chroma = sqrt(cb * cb + cr * cr);
                float angle = atan2(cr, cb) * 57.29578;
                float a = 1.0 - smoothstep(8.0, 16.0, abs(angle - 123.0));
                return a * smoothstep(0.015, 0.03, chroma) * (1.0 - smoothstep(0.2, 0.26, chroma)) * smoothstep(0.15, 0.25, y);
            }
            if (mode < 10.5) return (hue > 185.0 && hue < 250.0 && y > 0.35) ? smoothstep(0.1, 0.25, s) : 0.0;
            if (mode < 11.5) return (s < 0.12 && y > 0.15 && y < 0.92) ? 1.0 : 0.0;
            return (s > 0.85 && hi > 0.25) ? 1.0 : 0.0;
        }
        [[stitchable]] float4 influence(coreimage::sample_t p, float mode, float center) {
            if (p.a < 0.001) return p;
            float3 c = clamp(p.rgb, 0.0, 1.0);
            // A firmer edge reads better on screen than the raw, gradual weight.
            float w = smoothstep(0.0, 0.7, influenceWeight(c, mode, center));
            float y = dot(c, float3(0.2126, 0.7152, 0.0722));
            float3 dimmed = float3(y * 0.32 + 0.04);
            return float4(mix(dimmed, c, w), p.a);
        }
        """
        return (try? CIKernel.kernels(withMetalString: code))?.first as? CIColorKernel
    }()

    /// Keeps the affected pixels in color and dims everything else to gray
    /// (DaVinci Resolve's highlight view). Input and output are working-space images.
    public static func visualize(_ image: CIImage, kind: InfluenceKind) -> CIImage {
        var center: Float = 0
        if case .hue(let band) = kind { center = Float(band.degrees) }
        guard let kernel, let encoded = image.matchedFromWorkingSpace(to: encodedSpace),
              let output = kernel.apply(extent: image.extent, arguments: [encoded, kind.mode, center]),
              let result = output.matchedToWorkingSpace(from: encodedSpace) else { return image }
        return result
    }
}
