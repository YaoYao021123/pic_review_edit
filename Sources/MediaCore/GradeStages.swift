import CoreImage
import Foundation

/// The fixed processing order, shown in the inspector like a node chain.
/// Each stage can be bypassed to inspect its contribution.
public enum GradeStage: String, CaseIterable, Codable, Sendable {
    case basic, wheels, curves, hsl, lut, detail, local

    public var title: String {
        switch self {
        case .basic: L("基础")
        case .wheels: L("色轮")
        case .curves: L("曲线")
        case .hsl: "HSL"
        case .lut: "LUT"
        case .detail: L("细节")
        case .local: L("局部调整")
        }
    }
}

// MARK: - Color wheels (lift / gamma / gain / offset)

/// One wheel: `x`, `y` place the color puck inside the unit disk using the
/// vectorscope convention (x = Cb, y = Cr), `master` shifts luminance (-1...1).
public struct WheelValue: Codable, Equatable, Sendable {
    public var x = 0.0
    public var y = 0.0
    public var master = 0.0
    public init(x: Double = 0, y: Double = 0, master: Double = 0) {
        self.x = x; self.y = y; self.master = master
    }
    public var isNeutral: Bool { x == 0 && y == 0 && master == 0 }

    /// Zero-luminance RGB direction for the puck (BT.709 Cb/Cr to RGB).
    public var chroma: SIMD3<Double> {
        let clamped = sanitized
        let cb = clamped.x, cr = clamped.y
        return SIMD3(1.5748 * cr, -0.1873 * cb - 0.4681 * cr, 1.8556 * cb)
    }

    public var sanitized: Self {
        func clean(_ value: Double, _ limit: Double) -> Double { value.isFinite ? min(limit, max(-limit, value)) : 0 }
        var result = Self(x: clean(x, 1), y: clean(y, 1), master: clean(master, 1))
        let radius = (result.x * result.x + result.y * result.y).squareRoot()
        if radius > 1 { result.x /= radius; result.y /= radius }
        return result
    }
}

public struct ColorWheels: Codable, Equatable, Sendable {
    public var lift = WheelValue()
    public var gamma = WheelValue()
    public var gain = WheelValue()
    public var offset = WheelValue()
    public init() {}
    public var isNeutral: Bool { lift.isNeutral && gamma.isNeutral && gain.isNeutral && offset.isNeutral }
    public var isValid: Bool {
        [lift, gamma, gain, offset].allSatisfy {
            $0.x.isFinite && $0.y.isFinite && $0.master.isFinite && abs($0.master) <= 1
                && ($0.x * $0.x + $0.y * $0.y) <= 1.0001
        }
    }
    public var sanitized: Self {
        var result = self
        result.lift = lift.sanitized; result.gamma = gamma.sanitized
        result.gain = gain.sanitized; result.offset = offset.sanitized
        return result
    }

    public enum Wheel: String, CaseIterable, Sendable {
        case lift, gamma, gain, offset
        public var title: String {
            switch self { case .lift: L("暗部"); case .gamma: L("中间调"); case .gain: L("亮部"); case .offset: L("整体") }
        }
        public var subtitle: String {
            switch self { case .lift: "Lift"; case .gamma: "Gamma"; case .gain: "Gain"; case .offset: "Offset" }
        }
        var keyPath: WritableKeyPath<ColorWheels, WheelValue> {
            switch self { case .lift: \.lift; case .gamma: \.gamma; case .gain: \.gain; case .offset: \.offset }
        }
    }
    public subscript(wheel: Wheel) -> WheelValue {
        get { self[keyPath: wheel.keyPath] }
        set { self[keyPath: wheel.keyPath] = newValue.sanitized }
    }

    /// Per-channel coefficients used by the kernel.
    struct Coefficients {
        var lift: SIMD3<Double>
        var gain: SIMD3<Double>
        var inverseGamma: SIMD3<Double>
        var offset: SIMD3<Double>
    }
    var coefficients: Coefficients {
        let w = sanitized
        let lift = SIMD3(repeating: w.lift.master * 0.25) + w.lift.chroma * 0.08
        let gain = SIMD3(repeating: 1 + w.gain.master * 0.5) + w.gain.chroma * 0.15
        let gammaLog = SIMD3(repeating: w.gamma.master * 0.6) + w.gamma.chroma * 0.18
        let offset = SIMD3(repeating: w.offset.master * 0.15) + w.offset.chroma * 0.05
        let inverse = SIMD3(exp(gammaLog.x), exp(gammaLog.y), exp(gammaLog.z))
        return Coefficients(lift: lift, gain: SIMD3(max(0.05, gain.x), max(0.05, gain.y), max(0.05, gain.z)),
                            inverseGamma: SIMD3(1 / inverse.x, 1 / inverse.y, 1 / inverse.z), offset: offset)
    }
}

// MARK: - Tone curves

public struct CurvePoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct ToneCurves: Codable, Equatable, Sendable {
    public enum Channel: String, CaseIterable, Sendable {
        case master, red, green, blue
        public var title: String { switch self { case .master: "RGB"; case .red: "R"; case .green: "G"; case .blue: "B" } }
        var keyPath: WritableKeyPath<ToneCurves, [CurvePoint]> {
            switch self { case .master: \.master; case .red: \.red; case .green: \.green; case .blue: \.blue }
        }
    }
    public static let identity = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]
    public var master = Self.identity
    public var red = Self.identity
    public var green = Self.identity
    public var blue = Self.identity
    public init() {}

    public subscript(channel: Channel) -> [CurvePoint] {
        get { self[keyPath: channel.keyPath] }
        set { self[keyPath: channel.keyPath] = Self.normalized(newValue) }
    }
    public var isIdentity: Bool {
        Channel.allCases.allSatisfy { Self.isIdentity(self[$0]) }
    }
    public static func isIdentity(_ points: [CurvePoint]) -> Bool {
        points.allSatisfy { abs($0.x - $0.y) < 1e-6 }
    }

    /// Sorted, clamped, at most 16 points; first and last points stay at x = 0 and x = 1.
    public static func normalized(_ points: [CurvePoint]) -> [CurvePoint] {
        var clean = points.filter { $0.x.isFinite && $0.y.isFinite }
            .map { CurvePoint(x: min(1, max(0, $0.x)), y: min(1, max(0, $0.y))) }
            .sorted { $0.x < $1.x }
        var unique: [CurvePoint] = []
        for point in clean where unique.last.map({ point.x - $0.x > 0.004 }) ?? true { unique.append(point) }
        clean = Array(unique.prefix(16))
        if clean.first?.x != 0 { clean.insert(CurvePoint(x: 0, y: 0), at: 0) }
        if clean.last?.x != 1 { clean.append(CurvePoint(x: 1, y: 1)) }
        return clean
    }

    public func validate() throws {
        for channel in Channel.allCases {
            let points = self[channel]
            guard (2...16).contains(points.count), points.first?.x == 0, points.last?.x == 1,
                  points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }),
                  zip(points, points.dropFirst()).allSatisfy({ $0.x < $1.x }) else {
                throw VideoWorkError.failed(L("曲线参数无效。"))
            }
        }
    }

    /// Monotone cubic (Fritsch–Carlson) sampling of one curve.
    public static func sample(_ points: [CurvePoint], count: Int = 256) -> [Double] {
        let p = normalized(points)
        let n = p.count
        var slopes = [Double](repeating: 0, count: n)
        var deltas = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) { deltas[i] = (p[i + 1].y - p[i].y) / (p[i + 1].x - p[i].x) }
        slopes[0] = deltas[0]; slopes[n - 1] = deltas[n - 2]
        for i in 1..<(n - 1) { slopes[i] = deltas[i - 1] * deltas[i] <= 0 ? 0 : (deltas[i - 1] + deltas[i]) / 2 }
        for i in 0..<(n - 1) where deltas[i] == 0 { slopes[i] = 0; slopes[i + 1] = 0 }
        for i in 0..<(n - 1) where deltas[i] != 0 {
            let a = slopes[i] / deltas[i], b = slopes[i + 1] / deltas[i]
            let h = a * a + b * b
            if h > 9 { let t = 3 / h.squareRoot(); slopes[i] = t * a * deltas[i]; slopes[i + 1] = t * b * deltas[i] }
        }
        return (0..<count).map { index in
            let x = Double(index) / Double(count - 1)
            var segment = 0
            while segment < n - 2, x > p[segment + 1].x { segment += 1 }
            let h = p[segment + 1].x - p[segment].x
            let t = (x - p[segment].x) / h
            let t2 = t * t, t3 = t2 * t
            let y = (2 * t3 - 3 * t2 + 1) * p[segment].y + (t3 - 2 * t2 + t) * h * slopes[segment]
                + (-2 * t3 + 3 * t2) * p[segment + 1].y + (t3 - t2) * h * slopes[segment + 1]
            return min(1, max(0, y))
        }
    }

    /// Interleaved RGB table: each channel curve applied after the master curve.
    func table(count: Int = 256) -> [Float] {
        let master = Self.sample(self.master, count: count)
        let channels = [Self.sample(red, count: count), Self.sample(green, count: count), Self.sample(blue, count: count)]
        func lookup(_ curve: [Double], _ value: Double) -> Double {
            let position = value * Double(count - 1)
            let low = Int(position.rounded(.down)), high = min(count - 1, low + 1)
            let t = position - Double(low)
            return curve[low] * (1 - t) + curve[high] * t
        }
        var table = [Float](repeating: 0, count: count * 3)
        for index in 0..<count {
            for channel in 0..<3 { table[index * 3 + channel] = Float(lookup(channels[channel], master[index])) }
        }
        return table
    }
}

// MARK: - HSL color mixer

public enum HueBand: Int, CaseIterable, Codable, Sendable {
    case red, orange, yellow, green, aqua, blue, purple, magenta
    public var title: String {
        switch self {
        case .red: L("红"); case .orange: L("橙"); case .yellow: L("黄"); case .green: L("绿")
        case .aqua: L("青"); case .blue: L("蓝"); case .purple: L("紫"); case .magenta: L("洋红")
        }
    }
    /// Hue center in degrees, matching the kernel table.
    public var degrees: Double { [0, 30, 60, 120, 180, 225, 270, 315][rawValue] }
}

public struct HSLAdjustments: Codable, Equatable, Sendable {
    public var hue = [Double](repeating: 0, count: 8)
    public var saturation = [Double](repeating: 0, count: 8)
    public var luminance = [Double](repeating: 0, count: 8)
    public init() {}

    public enum Component: String, CaseIterable, Sendable {
        case hue, saturation, luminance
        public var title: String { switch self { case .hue: L("色相"); case .saturation: L("饱和度"); case .luminance: L("明亮度") } }
    }
    public subscript(band: HueBand, component: Component) -> Double {
        get {
            switch component {
            case .hue: hue[band.rawValue]
            case .saturation: saturation[band.rawValue]
            case .luminance: luminance[band.rawValue]
            }
        }
        set {
            let value = newValue.isFinite ? min(100, max(-100, newValue)) : 0
            switch component {
            case .hue: hue[band.rawValue] = value
            case .saturation: saturation[band.rawValue] = value
            case .luminance: luminance[band.rawValue] = value
            }
        }
    }
    public var isNeutral: Bool { (hue + saturation + luminance).allSatisfy { $0 == 0 } }
    public func validate() throws {
        guard hue.count == 8, saturation.count == 8, luminance.count == 8,
              (hue + saturation + luminance).allSatisfy({ $0.isFinite && (-100...100).contains($0) }) else {
            throw VideoWorkError.failed(L("HSL 参数无效。"))
        }
    }
}

// MARK: - Kernels

enum GradeKernels {
    static let encodedSpace = CGColorSpace(name: CGColorSpace.extendedSRGB)!

    private static let wheelKernel: CIColorKernel? = {
        let code = """
        #include <CoreImage/CoreImage.h>
        using namespace metal;
        [[stitchable]] float4 colorWheels(coreimage::sample_t p, float4 lift, float4 gain, float4 invGamma, float4 offset) {
            if (p.a < 0.001) return p;
            float3 c = p.rgb;
            c = c + lift.rgb * (1.0 - clamp(c, 0.0, 1.0));
            c = c * gain.rgb;
            c = sign(c) * pow(abs(c), invGamma.rgb);
            c = c + offset.rgb;
            return float4(c, p.a);
        }
        """
        return (try? CIKernel.kernels(withMetalString: code))?.first as? CIColorKernel
    }()

    private static let hslKernel: CIColorKernel? = {
        let code = """
        #include <CoreImage/CoreImage.h>
        using namespace metal;
        float3 toHSV(float3 c) {
            float maxC = max(c.r, max(c.g, c.b)), minC = min(c.r, min(c.g, c.b));
            float d = maxC - minC;
            float h = 0.0;
            if (d > 1e-5) {
                if (maxC == c.r) h = fmod((c.g - c.b) / d + 6.0, 6.0);
                else if (maxC == c.g) h = (c.b - c.r) / d + 2.0;
                else h = (c.r - c.g) / d + 4.0;
            }
            return float3(h * 60.0, maxC > 1e-5 ? d / maxC : 0.0, maxC);
        }
        float3 toRGB(float3 hsv) {
            float h = fmod(hsv.x + 360.0, 360.0) / 60.0;
            float c = hsv.z * hsv.y;
            float x = c * (1.0 - fabs(fmod(h, 2.0) - 1.0));
            float3 rgb;
            if (h < 1.0) rgb = float3(c, x, 0.0);
            else if (h < 2.0) rgb = float3(x, c, 0.0);
            else if (h < 3.0) rgb = float3(0.0, c, x);
            else if (h < 4.0) rgb = float3(0.0, x, c);
            else if (h < 5.0) rgb = float3(x, 0.0, c);
            else rgb = float3(c, 0.0, x);
            return rgb + (hsv.z - c);
        }
        float bandValue(float h, float4 a, float4 b) {
            float values[9] = { a.x, a.y, a.z, a.w, b.x, b.y, b.z, b.w, a.x };
            float centers[9] = { 0.0, 30.0, 60.0, 120.0, 180.0, 225.0, 270.0, 315.0, 360.0 };
            for (int i = 0; i < 8; i++) {
                if (h >= centers[i] && h <= centers[i + 1]) {
                    float t = (h - centers[i]) / (centers[i + 1] - centers[i]);
                    t = t * t * (3.0 - 2.0 * t);
                    return mix(values[i], values[i + 1], t);
                }
            }
            return a.x;
        }
        [[stitchable]] float4 hslMix(coreimage::sample_t p, float4 h0, float4 h1, float4 s0, float4 s1, float4 l0, float4 l1) {
            if (p.a < 0.001) return p;
            float3 rgb = max(p.rgb, float3(0.0));
            float3 hsv = toHSV(rgb);
            float weight = smoothstep(0.02, 0.18, hsv.y);
            float hueShift = bandValue(hsv.x, h0, h1) * 30.0 * weight;
            float satScale = 1.0 + bandValue(hsv.x, s0, s1) * weight;
            float lum = bandValue(hsv.x, l0, l1) * weight;
            float3 shifted = toRGB(float3(hsv.x + hueShift, clamp(hsv.y * satScale, 0.0, 1.0), hsv.z));
            shifted *= (1.0 + lum * 0.45);
            float3 overflow = p.rgb - rgb;
            return float4(shifted + overflow, p.a);
        }
        """
        return (try? CIKernel.kernels(withMetalString: code))?.first as? CIColorKernel
    }()

    private static func vector(_ value: SIMD3<Double>) -> CIVector { CIVector(x: value.x, y: value.y, z: value.z, w: 0) }

    /// Expects and returns working-space (linear) images; grades in encoded sRGB.
    static func wheels(_ image: CIImage, _ wheels: ColorWheels) throws -> CIImage {
        guard !wheels.isNeutral else { return image }
        let k = wheels.coefficients
        guard let kernel = wheelKernel, let encoded = image.matchedFromWorkingSpace(to: encodedSpace),
              let output = kernel.apply(extent: image.extent, arguments: [encoded, vector(k.lift), vector(k.gain),
                                                                          vector(k.inverseGamma), vector(k.offset)]),
              let result = output.matchedToWorkingSpace(from: encodedSpace) else {
            throw VideoWorkError.failed(L("色轮滤镜不可用。"))
        }
        return result
    }

    static func curves(_ image: CIImage, _ curves: ToneCurves) -> CIImage {
        guard !curves.isIdentity else { return image }
        let table = curves.table()
        return image.applyingFilter("CIColorCurves", parameters: [
            "inputCurvesData": table.withUnsafeBytes { Data($0) },
            "inputCurvesDomain": CIVector(x: 0, y: 1),
            "inputColorSpace": ColorPipeline.outputSpace
        ])
    }

    static func hsl(_ image: CIImage, _ hsl: HSLAdjustments) throws -> CIImage {
        guard !hsl.isNeutral else { return image }
        func pair(_ values: [Double]) -> (CIVector, CIVector) {
            let v = values.map { $0 / 100 }
            return (CIVector(x: v[0], y: v[1], z: v[2], w: v[3]), CIVector(x: v[4], y: v[5], z: v[6], w: v[7]))
        }
        let h = pair(hsl.hue), s = pair(hsl.saturation), l = pair(hsl.luminance)
        guard let kernel = hslKernel, let encoded = image.matchedFromWorkingSpace(to: encodedSpace),
              let output = kernel.apply(extent: image.extent, arguments: [encoded, h.0, h.1, s.0, s.1, l.0, l.1]),
              let result = output.matchedToWorkingSpace(from: encodedSpace) else {
            throw VideoWorkError.failed(L("HSL 滤镜不可用。"))
        }
        return result
    }
}
