import Foundation

/// The five brightness zones every lesson, slider hint and diagram uses, so a beginner
/// learns one vocabulary: 最暗部 · 暗部 · 中间调 · 亮部 · 最亮部 (sRGB-encoded luma, 0…1).
public enum ToneZone: Int, CaseIterable, Sendable {
    case deepShadows, shadows, midtones, highlights, brightest

    public var title: String {
        switch self {
        case .deepShadows: L("最暗部"); case .shadows: L("暗部"); case .midtones: L("中间调")
        case .highlights: L("亮部"); case .brightest: L("最亮部")
        }
    }
    public var range: ClosedRange<Double> {
        switch self {
        case .deepShadows: 0...0.1; case .shadows: 0.1...0.35; case .midtones: 0.35...0.65
        case .highlights: 0.65...0.9; case .brightest: 0.9...1
        }
    }
    public var example: String {
        switch self {
        case .deepShadows: L("头发、黑衣服、夜空")
        case .shadows: L("树荫、背光的脸")
        case .midtones: L("草地、皮肤、灰墙")
        case .highlights: L("天空、白墙、亮处的脸")
        case .brightest: L("太阳、灯、反光")
        }
    }
    public static func zone(of luma: Double) -> ToneZone {
        allCases.first { luma < $0.range.upperBound } ?? .brightest
    }
    /// Share of the picture in each zone, from a luma histogram of any length.
    public static func shares(_ histogram: [Double]) -> [ToneZone: Double] {
        guard !histogram.isEmpty else { return [:] }
        let total = max(1e-9, histogram.reduce(0, +))
        var result: [ToneZone: Double] = [:]
        for (index, value) in histogram.enumerated() {
            let luma = (Double(index) + 0.5) / Double(histogram.count)
            result[zone(of: luma), default: 0] += value / total
        }
        return result
    }
}

/// What the basic tone controls do to a brightness value — the same formulas as the Metal
/// kernel in `BasicColorPipeline`, so diagrams show the app's real behaviour, not an illustration.
public enum ToneResponse {
    static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }
    static func decode(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    static func encode(_ v: Double) -> Double { v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }

    /// How strongly a control acts at this brightness (0…1): the area to shade on a histogram.
    public static func weight(_ parameter: AdjustmentParameter, at y: Double) -> Double {
        let hi = smoothstep(0.45, 0.95, y), sh = 1 - smoothstep(0.04, 0.60, y)
        let white = smoothstep(0.70, 1, y), black = 1 - smoothstep(0, 0.25, y)
        switch parameter {
        case .highlights: return hi
        case .shadows: return sh
        case .whites: return white
        case .blackPoint: return black
        case .contrast: return min(1, abs(y - 0.5) * 2)
        case .brightness: return 1
        case .exposure:
            // Exposure multiplies light, so brighter tones move further (until they clip).
            let moved = encode(min(1, decode(y) * 2)) - y
            return min(1, moved / 0.3)
        case .brilliance:
            return min(1, abs(0.14 * sh * (1 - black) + 0.07 * (1 - hi) - 0.12 * hi) / 0.14)
        default: return 0
        }
    }

    /// Output brightness for an input brightness (0…1) with these adjustments.
    public static func map(_ y: Double, _ a: BasicAdjustments) -> Double {
        var v = y
        if a.exposure != 0 { v = encode(min(64, decode(v) * pow(2, a.exposure))) }
        let hi = smoothstep(0.45, 0.95, v), sh = 1 - smoothstep(0.04, 0.60, v)
        let white = smoothstep(0.70, 1, v), black = 1 - smoothstep(0, 0.25, v)
        let brilliance = a.brilliance / 100 * (0.14 * sh * (1 - black) + 0.07 * (1 - hi) - 0.12 * hi)
        var target = v + brilliance + a.brightness / 100 * 0.20 + a.highlights / 100 * 0.22 * hi + a.shadows / 100 * 0.22 * sh
            + a.whites / 100 * 0.16 * white - a.blackPoint / 100 * 0.12 * black
        target = (target - 0.5) * (1 + a.contrast / 100 * 0.65) + 0.5
        return min(1, max(0, target))
    }

    /// The histogram after the adjustments (each step's pixels moved to where they land).
    public static func moved(_ histogram: [Double], _ a: BasicAdjustments) -> [Double] {
        var result = [Double](repeating: 0, count: histogram.count)
        let n = Double(histogram.count)
        for (index, value) in histogram.enumerated() where value > 0 {
            let out = map((Double(index) + 0.5) / n, a)
            result[min(histogram.count - 1, Int(out * n))] += value
        }
        let tallest = max(1e-9, result.max() ?? 1)
        return result.map { $0 / tallest }
    }
}
