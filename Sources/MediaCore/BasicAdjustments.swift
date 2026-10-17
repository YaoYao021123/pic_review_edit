import CoreImage
import Foundation

public enum AdjustmentGroup: String, CaseIterable, Codable, Sendable {
    case light = "光线", color = "色彩", detail = "细节" // loc:ignore (stored identifiers, never shown)
}

/// How photographers think about the basic controls (Lightroom's Basic panel order):
/// exposure, tonality (影调), white balance, color, then detail and effects.
/// Used for the inspector's sub-groups and for choosing what to sync.
public enum AdjustmentSection: String, CaseIterable, Codable, Sendable {
    case exposure, tone, whiteBalance, color, detail, effects

    public var title: String {
        switch self {
        case .exposure: L("曝光"); case .tone: L("影调"); case .whiteBalance: L("白平衡")
        case .color: L("色彩"); case .detail: L("细节"); case .effects: L("效果")
        }
    }

    /// One-line definition, shown as a tooltip on the group heading.
    public var summary: String {
        switch self {
        case .exposure: L("整体有多亮。曝光按光线倍数改变亮度，亮度更温和地调整中间调。")
        case .tone: L("明暗如何分布：对比度、高光、阴影、白色与黑色决定画面从暗到亮的层次。")
        case .whiteBalance: L("让白色看起来是白的：色温调冷暖（蓝–黄），色调调绿–洋红。")
        case .color: L("颜色有多浓：自然饱和度优先增强偏灰的颜色，饱和度同等增强所有颜色。")
        case .detail: L("边缘与纹理：清晰度增强大范围反差，锐度增强细小边缘，降噪抹平颗粒。")
        case .effects: L("整体风格：去雾让远景更通透，褪色和颗粒像胶片，黑白去掉颜色，暗角压暗边缘。")
        }
    }

    public var parameters: [AdjustmentParameter] {
        switch self {
        case .exposure: [.exposure, .brightness]
        case .tone: [.contrast, .highlights, .shadows, .whites, .blackPoint, .brilliance]
        case .whiteBalance: [.warmth, .tint]
        case .color: [.vibrance, .saturation]
        case .detail: [.definition, .sharpness, .noiseReduction]
        case .effects: [.dehaze, .fade, .grain, .monochrome, .vignette]
        }
    }
}

/// Relative controls for rendered images/video, not RAW sensor development.
public struct BasicAdjustments: Codable, Equatable, Sendable {
    public var exposure = 0.0
    public var brilliance = 0.0
    public var highlights = 0.0
    public var shadows = 0.0
    public var brightness = 0.0
    public var contrast = 0.0
    public var whites = 0.0
    public var blackPoint = 0.0
    public var warmth = 0.0
    public var tint = 0.0
    public var saturation = 0.0
    public var vibrance = 0.0
    public var definition = 0.0
    public var sharpness = 0.0
    public var noiseReduction = 0.0
    public var vignette = 0.0
    public var dehaze = 0.0
    public var fade = 0.0
    public var grain = 0.0
    public var monochrome = 0.0
    public init() {}
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
    /// Missing keys default to 0, so recipes survive parameters added later.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Key.self)
        for parameter in AdjustmentParameter.allCases {
            self[keyPath: parameter.keyPath] = try values.decodeIfPresent(Double.self, forKey: Key(stringValue: parameter.rawValue)) ?? 0
        }
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: Key.self)
        for parameter in AdjustmentParameter.allCases {
            try values.encode(self[keyPath: parameter.keyPath], forKey: Key(stringValue: parameter.rawValue))
        }
    }
    public subscript(parameter: AdjustmentParameter) -> Double {
        get { self[keyPath: parameter.keyPath] }
        set { self[keyPath: parameter.keyPath] = newValue.isFinite ? min(parameter.range.upperBound, max(parameter.range.lowerBound, newValue)) : 0 }
    }
    public var sanitized: Self {
        var result = self
        for p in AdjustmentParameter.allCases { result[p] = self[p] }
        return result
    }
    public var isNeutral: Bool { self == Self() }
    public var isDetailNeutral: Bool {
        definition == 0 && sharpness == 0 && noiseReduction == 0 && vignette == 0 && dehaze == 0 && fade == 0 && grain == 0 && monochrome == 0
    }
    /// Settings that depend on neighbouring pixels or position, so a LUT can't hold them.
    public var withoutSpatial: Self {
        var result = self
        for p in [AdjustmentParameter.definition, .sharpness, .noiseReduction, .vignette, .dehaze, .grain] { result[p] = 0 }
        return result
    }
    public var isToneNeutral: Bool { exposure == 0 && isKernelNeutral }
    var isKernelNeutral: Bool {
        brilliance == 0 && highlights == 0 && shadows == 0 && brightness == 0 && contrast == 0 && whites == 0
            && blackPoint == 0 && warmth == 0 && tint == 0 && saturation == 0 && vibrance == 0
    }
    public var dictionary: [String: Double] {
        Dictionary(uniqueKeysWithValues: AdjustmentParameter.allCases.map { ($0.rawValue, sanitized[$0]) })
    }
}

public enum AdjustmentParameter: String, CaseIterable, Codable, Sendable, Identifiable {
    case exposure, brilliance, highlights, shadows, brightness, contrast, whites, blackPoint
    case warmth, tint, saturation, vibrance, definition, sharpness, noiseReduction, vignette
    case dehaze, fade, grain, monochrome
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .exposure: L("曝光"); case .brilliance: L("鲜明度"); case .highlights: L("高光"); case .shadows: L("阴影")
        case .brightness: L("亮度"); case .contrast: L("对比度"); case .whites: L("白色"); case .blackPoint: L("黑色")
        case .warmth: L("色温"); case .tint: L("色调"); case .saturation: L("饱和度"); case .vibrance: L("自然饱和度")
        case .definition: L("清晰度"); case .sharpness: L("锐度"); case .noiseReduction: L("降噪"); case .vignette: L("暗角")
        case .dehaze: L("去雾"); case .fade: L("褪色"); case .grain: L("颗粒"); case .monochrome: L("黑白")
        }
    }
    public var group: AdjustmentGroup {
        switch self {
        case .exposure, .brilliance, .highlights, .shadows, .brightness, .contrast, .whites, .blackPoint: .light
        case .warmth, .tint, .saturation, .vibrance: .color
        default: .detail
        }
    }
    public var range: ClosedRange<Double> { self == .exposure ? -4...4 : self == .dehaze ? -100...100 : group == .detail ? 0...100 : -100...100 }
    public var section: AdjustmentSection {
        AdjustmentSection.allCases.first { $0.parameters.contains(self) } ?? .tone
    }
    public var keyPath: WritableKeyPath<BasicAdjustments, Double> {
        switch self {
        case .exposure: \.exposure; case .brilliance: \.brilliance; case .highlights: \.highlights; case .shadows: \.shadows
        case .brightness: \.brightness; case .contrast: \.contrast; case .whites: \.whites; case .blackPoint: \.blackPoint
        case .warmth: \.warmth; case .tint: \.tint; case .saturation: \.saturation; case .vibrance: \.vibrance
        case .definition: \.definition; case .sharpness: \.sharpness; case .noiseReduction: \.noiseReduction; case .vignette: \.vignette
        case .dehaze: \.dehaze; case .fade: \.fade; case .grain: \.grain; case .monochrome: \.monochrome
        }
    }
    public var explanation: String {
        switch self {
        case .exposure: L("整体增加或减少曝光，以 EV 表示；+1 EV 将线性亮度加倍。过曝丢失的细节无法靠此恢复。")
        case .brilliance: L("平衡暗部、中间调与亮部。正值提亮暗部并收住高光；这是本地算法，不等同于苹果的空间自适应鲜明度。")
        case .highlights: L("调整较亮区域；负值压低高光，尽量减少对暗部的影响。")
        case .shadows: L("调整较暗区域；正值提亮阴影，可能同时显露噪点。")
        case .brightness: L("调整整体显示亮度。与按倍数改变线性亮度的曝光不同。")
        case .contrast: L("拉开或收拢明暗差距。过高会损失暗部与亮部层次。")
        case .whites: L("调整接近白色的区域；正值提高白色端，负值压低白色端。")
        case .blackPoint: L("调整黑色端；正值加深黑色，负值抬起黑色。")
        case .warmth: L("相对白平衡：正值偏暖，负值偏冷。这里是处理后素材的相对偏移，不是相机拍摄 Kelvin 值。")
        case .tint: L("相对白平衡：正值偏洋红，负值偏绿色，用于校正或创作色偏。")
        case .saturation: L("整体颜色强度。-100 变为灰度；过高容易造成颜色溢出。")
        case .vibrance: L("优先增强较不鲜艳的颜色，减少对已经鲜艳颜色的影响；不包含专用肤色保护模型。")
        case .definition: L("增强较大范围的局部反差；过高可能出现边缘光晕。")
        case .sharpness: L("增强细小边缘反差，不能恢复失焦时丢失的真实细节。")
        case .noiseReduction: L("使用单帧降噪；数值越大画面越平滑。视频不使用时序降噪，强度过大可能丢失纹理。")
        case .vignette: L("逐渐压暗画面边缘，引导注意力到中央。")
        case .dehaze: L("往右减少雾气、霾和远处的灰白，远景更清楚、颜色更浓；往左增加朦胧感。用暗通道估计每个区域的雾有多重。")
        case .fade: L("抬起最暗处、压低最亮处，像褪色的胶片，画面更柔和。")
        case .grain: L("加入胶片颗粒，中间调最明显。颗粒大小随照片尺寸变化，预览和导出一致。")
        case .monochrome: L("往右逐渐去掉颜色，100 为完全黑白。HSL 里各颜色的明亮度仍会影响黑白的深浅。")
        }
    }
}

public enum BasicColorPipeline {
    private static let encodedSpace = CGColorSpace(name: CGColorSpace.extendedSRGB)!
    private static let kernel: CIColorKernel? = {
        let code = """
        #include <CoreImage/CoreImage.h>
        using namespace metal;
        [[stitchable]] float4 adjustColor(coreimage::sample_t pixel, float4 light, float4 ends, float4 color) {
            float3 rgb = pixel.rgb;
            float y = dot(rgb, float3(0.2126, 0.7152, 0.0722));
            float hi = smoothstep(0.45, 0.95, y);
            float sh = 1.0 - smoothstep(0.04, 0.60, y);
            float white = smoothstep(0.70, 1.0, y);
            float black = 1.0 - smoothstep(0.0, 0.25, y);
            float brilliance = light.x * (0.14 * sh * (1.0 - black) + 0.07 * (1.0 - hi) - 0.12 * hi);
            float target = y + brilliance + light.y * 0.20 + ends.x * 0.22 * hi + ends.y * 0.22 * sh
                + ends.z * 0.16 * white - ends.w * 0.12 * black;
            target = (target - 0.5) * (1.0 + light.z * 0.65) + 0.5;
            target = clamp(target, 0.0, 1.0);
            rgb = y > 0.0001 ? rgb * (target / y) : float3(target);
            rgb *= float3(1.0 + color.x * 0.16 + color.y * 0.04, 1.0 - color.y * 0.12,
                          1.0 - color.x * 0.16 + color.y * 0.04);
            float luma = dot(rgb, float3(0.2126, 0.7152, 0.0722));
            float chroma = max(rgb.r, max(rgb.g, rgb.b)) - min(rgb.r, min(rgb.g, rgb.b));
            float saturation = max(0.0, 1.0 + color.z + color.w * (1.0 - smoothstep(0.15, 0.80, chroma)) * 0.7);
            rgb = float3(luma) + (rgb - float3(luma)) * saturation;
            return float4(max(rgb, float3(0.0)), pixel.a);
        }
        """
        return (try? CIKernel.kernels(withMetalString: code))?.first as? CIColorKernel
    }()
    /// Full basic stage in its historical order (tone, then detail, then vignette).
    public static func image(_ source: CIImage, adjustments: BasicAdjustments) throws -> CIImage {
        let a = adjustments.sanitized
        guard !a.isNeutral else { return source }
        var result = dehaze(source, a, reference: source.extent)
        result = try tone(result, adjustments: a)
        result = denoise(result, a, reference: source.extent)
        result = monochrome(result, a)
        result = sharpen(result, a, reference: source.extent)
        result = fade(result, a)
        result = vignette(result, a, reference: source.extent)
        result = grain(result, a, reference: source.extent)
        return result.cropped(to: source.extent)
    }

    /// Exposure, tone regions, white balance and saturation.
    public static func tone(_ source: CIImage, adjustments: BasicAdjustments) throws -> CIImage {
        let a = adjustments.sanitized
        guard !a.isToneNeutral else { return source }
        var input = source
        if a.exposure != 0 { input = input.applyingFilter("CIExposureAdjust", parameters: ["inputEV": a.exposure]) }
        // The tone kernel also bounds luminance to display white, so it runs even for exposure-only edits.
        guard let encoded = input.matchedFromWorkingSpace(to: encodedSpace), let kernel,
              let tuned = kernel.apply(extent: input.extent, arguments: [encoded,
                CIVector(x: a.brilliance / 100, y: a.brightness / 100, z: a.contrast / 100, w: 0),
                CIVector(x: a.highlights / 100, y: a.shadows / 100, z: a.whites / 100, w: a.blackPoint / 100),
                CIVector(x: a.warmth / 100, y: a.tint / 100, z: a.saturation / 100, w: a.vibrance / 100)]),
              let result = tuned.matchedToWorkingSpace(from: encodedSpace) else {
            throw VideoWorkError.failed(L("基础调色滤镜不可用，未应用调整。"))
        }
        return result.cropped(to: source.extent)
    }

    /// Radii follow the image size so a 2560 px preview and a full export look alike.
    private static func scale(_ reference: CGRect) -> CGFloat { max(reference.width, reference.height) / 1600 }

    public static func denoise(_ image: CIImage, _ a: BasicAdjustments, reference: CGRect? = nil) -> CIImage {
        guard a.noiseReduction > 0 else { return image }
        return image.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": a.noiseReduction / 100 * 0.06, "inputSharpness": 0])
            .cropped(to: reference ?? image.extent)
    }

    public static func sharpen(_ image: CIImage, _ a: BasicAdjustments, reference: CGRect) -> CIImage {
        var result = image
        let scale = scale(reference)
        if a.definition > 0 {
            result = result.clampedToExtent().applyingFilter("CIUnsharpMask", parameters: ["inputRadius": max(1, 8 * scale), "inputIntensity": a.definition / 100 * 0.7]).cropped(to: reference)
        }
        if a.sharpness > 0 {
            result = result.clampedToExtent().applyingFilter("CIUnsharpMask", parameters: ["inputRadius": max(0.5, 1.2 * scale), "inputIntensity": a.sharpness / 100 * 1.2]).cropped(to: reference)
        }
        return result
    }

    public static func vignette(_ image: CIImage, _ a: BasicAdjustments, reference: CGRect) -> CIImage {
        guard a.vignette > 0 else { return image }
        return image.applyingFilter("CIVignetteEffect", parameters: ["inputCenter": CIVector(x: reference.midX, y: reference.midY),
            "inputRadius": min(reference.width, reference.height) * 0.55, "inputIntensity": a.vignette / 100 * 1.5, "inputFalloff": 1])
            .cropped(to: reference)
    }
}
