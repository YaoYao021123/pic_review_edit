import Foundation

/// Facts about the displayed frame that the coach turns into explanations.
/// Computed from the same small SDR rendition as the scopes (sRGB-encoded values).
public struct PhotoAnalysis: Sendable, Equatable {
    /// Luma percentiles (0...1, BT.709 on encoded values).
    public var p1 = 0.0, p5 = 0.0, p50 = 0.0, p95 = 0.0, p99 = 0.0
    public var meanLuma = 0.0
    public var clippedHighlights = 0.0
    public var clippedShadows = 0.0
    /// Average HSV saturation and the share of nearly fully saturated pixels.
    public var meanSaturation = 0.0
    public var saturatedFraction = 0.0
    /// Average encoded RGB of near-neutral pixels (for color cast), and their share.
    public var neutralRGB: [Double] = [0, 0, 0]
    public var neutralFraction = 0.0
    /// Pixels near the vectorscope skin-tone line, and their mean angle in degrees.
    public var skinFraction = 0.0
    public var skinAngle = 0.0
    /// Blue, bright pixels in the upper part of the frame.
    public var skyFraction = 0.0
    /// Share of colorful pixels per hue band (sums to ~1).
    public var hueShare = [Double](repeating: 0, count: 8)
    /// Mean encoded value per channel (for parade readings).
    public var channelMeans: [Double] = [0, 0, 0]
    /// Centroid of bright (luma > 0.85) and dark (luma < 0.12) pixels, normalized, y = 0 at the top.
    public var brightCenter: [Double]?
    public var darkCenter: [Double]?
    public var brightFraction = 0.0
    public var darkFraction = 0.0
    /// Share of pixels per brightness step (64 steps, tallest = 1), for zone diagrams and lessons.
    public var lumaHistogram: [Double] = []

    public init() {}

    public var contrastSpan: Double { p95 - p5 }
    /// Flat, low-saturation footage that typically needs a camera Log conversion.
    public var looksLikeLog: Bool { meanSaturation < 0.13 && contrastSpan < 0.5 && p5 > 0.07 && p95 < 0.85 }

    /// Accumulates statistics pixel by pixel (8-bit RGBA rows, top row first).
    struct Builder {
        var lumaHistogram = [Int](repeating: 0, count: 256)
        var count = 0, white = 0, black = 0, saturated = 0
        var saturationSum = 0.0
        var neutral = [0.0, 0.0, 0.0], neutralCount = 0
        var skinCount = 0, skinAngleSum = 0.0
        var sky = 0
        var hue = [Double](repeating: 0, count: 8), colorful = 0
        var channels = [0.0, 0.0, 0.0]
        var bright = [0.0, 0.0], brightCount = 0
        var dark = [0.0, 0.0], darkCount = 0
        let width: Int, height: Int

        init(width: Int, height: Int) { self.width = width; self.height = height }

        mutating func add(r: Int, g: Int, b: Int, x: Int, y: Int) {
            count += 1
            let rf = Double(r) / 255, gf = Double(g) / 255, bf = Double(b) / 255
            let luma = 0.2126 * rf + 0.7152 * gf + 0.0722 * bf
            lumaHistogram[min(255, Int(luma * 255 + 0.5))] += 1
            channels[0] += rf; channels[1] += gf; channels[2] += bf
            let high = max(rf, gf, bf), low = min(rf, gf, bf)
            if max(r, g, b) >= 254 { white += 1 }
            if max(r, g, b) <= 1 { black += 1 }
            let saturation = high > 0.001 ? (high - low) / high : 0
            saturationSum += saturation
            if saturation > 0.85, high > 0.25 { saturated += 1 }
            let nx = (Double(x) + 0.5) / Double(width), ny = (Double(y) + 0.5) / Double(height)
            if luma > 0.85 { bright[0] += nx; bright[1] += ny; brightCount += 1 }
            if luma < 0.12 { dark[0] += nx; dark[1] += ny; darkCount += 1 }
            if saturation < 0.12, luma > 0.15, luma < 0.92 {
                neutral[0] += rf; neutral[1] += gf; neutral[2] += bf; neutralCount += 1
            }
            let cb = (bf - luma) / 1.8556, cr = (rf - luma) / 1.5748
            let chroma = (cb * cb + cr * cr).squareRoot()
            if chroma > 0.02, chroma < 0.22, luma > 0.2, luma < 0.9 {
                let angle = atan2(cr, cb) * 180 / .pi
                if abs(angle - 123) < 15 { skinCount += 1; skinAngleSum += angle }
            }
            guard saturation > 0.2, high > 0.15 else { return }
            colorful += 1
            var degrees = 0.0
            let delta = high - low
            if high == rf { degrees = 60 * (((gf - bf) / delta).truncatingRemainder(dividingBy: 6)) }
            else if high == gf { degrees = 60 * ((bf - rf) / delta + 2) }
            else { degrees = 60 * ((rf - gf) / delta + 4) }
            if degrees < 0 { degrees += 360 }
            hue[Self.band(degrees)] += 1
            if degrees > 185, degrees < 250, luma > 0.35, ny < 0.5 { sky += 1 }
        }

        static func band(_ degrees: Double) -> Int {
            let centers = HueBand.allCases.map(\.degrees)
            var best = 0, distance = 360.0
            for (index, center) in centers.enumerated() {
                let d = min(abs(degrees - center), 360 - abs(degrees - center))
                if d < distance { distance = d; best = index }
            }
            return best
        }

        func build() -> PhotoAnalysis {
            var a = PhotoAnalysis()
            guard count > 0 else { return a }
            let total = Double(count)
            func percentile(_ fraction: Double) -> Double {
                let target = Int(fraction * total)
                var running = 0
                for (index, value) in lumaHistogram.enumerated() {
                    running += value
                    if running > target { return Double(index) / 255 }
                }
                return 1
            }
            a.p1 = percentile(0.01); a.p5 = percentile(0.05); a.p50 = percentile(0.5)
            a.p95 = percentile(0.95); a.p99 = percentile(0.99)
            var steps = [Double](repeating: 0, count: 64)
            for (index, value) in lumaHistogram.enumerated() { steps[index / 4] += Double(value) }
            let tallest = max(1, steps.max() ?? 1)
            a.lumaHistogram = steps.map { $0 / tallest }
            a.meanLuma = lumaHistogram.enumerated().reduce(0.0) { $0 + Double($1.offset) * Double($1.element) } / 255 / total
            a.clippedHighlights = Double(white) / total
            a.clippedShadows = Double(black) / total
            a.meanSaturation = saturationSum / total
            a.saturatedFraction = Double(saturated) / total
            a.neutralFraction = Double(neutralCount) / total
            if neutralCount > 0 { a.neutralRGB = neutral.map { $0 / Double(neutralCount) } }
            a.skinFraction = Double(skinCount) / total
            a.skinAngle = skinCount > 0 ? skinAngleSum / Double(skinCount) : 123
            a.skyFraction = Double(sky) / total
            a.hueShare = colorful > 0 ? hue.map { $0 / Double(colorful) } : hue
            a.channelMeans = channels.map { $0 / total }
            a.brightFraction = Double(brightCount) / total
            a.darkFraction = Double(darkCount) / total
            if brightCount > 0 { a.brightCenter = bright.map { $0 / Double(brightCount) } }
            if darkCount > 0 { a.darkCenter = dark.map { $0 / Double(darkCount) } }
            return a
        }
    }
}
