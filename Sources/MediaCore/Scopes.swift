import CoreGraphics
import CoreImage
import Foundation

/// Video scopes computed from a small SDR rendition of the displayed frame:
/// RGB histogram, luma waveform, RGB parade and a BT.709 vectorscope.
public struct ScopeData: Sendable {
    public let histogram: PreviewHistogram
    public let waveform: CGImage?
    public let parade: CGImage?
    public let vectorscope: CGImage?
    /// Fractions of pixels at pure white / pure black (any channel), for clipping badges.
    public let clippedHighlights: Double
    public let clippedShadows: Double
    /// Photo facts for the coach, from the same pixels.
    public let analysis: PhotoAnalysis
}

public enum ScopeAnalyzer {
    static let levels = 128

    public static func analyze(_ image: CIImage, headroom: Float = 1, width: Int = 256) -> ScopeData? {
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1, !extent.isInfinite else { return nil }
        let scale = min(1, CGFloat(width) / extent.width)
        let small = ColorPipeline.toneMap(image, sourceHeadroom: headroom)
            .transformed(by: .init(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: .init(scaleX: scale, y: scale))
        let w = max(1, Int(small.extent.width.rounded())), h = max(1, Int(min(small.extent.height.rounded(), 512)))
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes {
            ColorPipeline.shared.render(small, toBitmap: $0.baseAddress!, rowBytes: w * 4,
                bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: ColorPipeline.outputSpace)
        }
        return analyze(rgba: bytes, width: w, height: h)
    }

    /// Pure computation over 8-bit RGBA rows; exposed for tests.
    public static func analyze(rgba bytes: [UInt8], width w: Int, height h: Int) -> ScopeData {
        let levels = Self.levels
        var histogram = [[Double]](repeating: [Double](repeating: 0, count: 64), count: 3)
        var luma = [UInt32](repeating: 0, count: w * levels)
        var parade = [UInt32](repeating: 0, count: 3 * w * levels)
        let vectorSize = 128
        var vector = [UInt32](repeating: 0, count: vectorSize * vectorSize)
        var vectorColor = [SIMD3<Float>](repeating: .zero, count: vectorSize * vectorSize)
        var white = 0, black = 0, counted = 0
        var facts = PhotoAnalysis.Builder(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                let index = (y * w + x) * 4
                guard bytes[index + 3] > 0 else { continue }
                counted += 1
                let r = Int(bytes[index]), g = Int(bytes[index + 1]), b = Int(bytes[index + 2])
                facts.add(r: r, g: g, b: b, x: x, y: y)
                histogram[0][r / 4] += 1; histogram[1][g / 4] += 1; histogram[2][b / 4] += 1
                if max(r, g, b) >= 254 { white += 1 }
                if max(r, g, b) <= 1 { black += 1 }
                let rf = Float(r) / 255, gf = Float(g) / 255, bf = Float(b) / 255
                let yv = 0.2126 * rf + 0.7152 * gf + 0.0722 * bf
                luma[x * levels + min(levels - 1, Int(yv * Float(levels - 1) + 0.5))] += 1
                parade[(0 * w + x) * levels + r * (levels - 1) / 255] += 1
                parade[(1 * w + x) * levels + g * (levels - 1) / 255] += 1
                parade[(2 * w + x) * levels + b * (levels - 1) / 255] += 1
                let cb = (bf - yv) / 1.8556, cr = (rf - yv) / 1.5748
                let vx = min(vectorSize - 1, max(0, Int((cb + 0.5) * Float(vectorSize - 1) + 0.5)))
                let vy = min(vectorSize - 1, max(0, Int((0.5 - cr) * Float(vectorSize - 1) + 0.5)))
                vector[vy * vectorSize + vx] += 1
                vectorColor[vy * vectorSize + vx] += SIMD3(rf, gf, bf)
            }
        }
        let peak = max(1, histogram.flatMap { $0 }.max() ?? 1)
        let normalized = PreviewHistogram(channels: histogram.map { $0.map { $0 / peak } })
        let total = Double(max(1, counted))
        return ScopeData(histogram: normalized,
                         waveform: densityImage(luma, columns: w, rows: levels, tints: [SIMD3(0.75, 1, 0.8)]),
                         parade: densityImage(parade, columns: w, rows: levels, tints: [SIMD3(1, 0.35, 0.3), SIMD3(0.35, 1, 0.45), SIMD3(0.4, 0.6, 1)]),
                         vectorscope: vectorImage(vector, colors: vectorColor, size: vectorSize),
                         clippedHighlights: Double(white) / total, clippedShadows: Double(black) / total,
                         analysis: facts.build())
    }

    /// Columns of level counts → an image with level 0 at the bottom. Several
    /// tint groups are laid out side by side (the RGB parade).
    private static func densityImage(_ counts: [UInt32], columns: Int, rows: Int, tints: [SIMD3<Float>]) -> CGImage? {
        let groups = tints.count
        let width = columns * groups, height = rows
        let expected = Float(max(1, counts.reduce(0) { $0 + Int($1) })) / Float(max(1, columns * groups)) / Float(rows) * 6
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for group in 0..<groups {
            for column in 0..<columns {
                for level in 0..<rows {
                    let count = counts[(group * columns + column) * rows + level]
                    guard count > 0 else { continue }
                    let intensity = min(1, 0.08 + 0.92 * log1p(Float(count)) / log1p(expected))
                    let row = rows - 1 - level
                    let offset = (row * width + group * columns + column) * 4
                    let tint = tints[group] * intensity
                    pixels[offset] = UInt8(min(255, tint.x * 255))
                    pixels[offset + 1] = UInt8(min(255, tint.y * 255))
                    pixels[offset + 2] = UInt8(min(255, tint.z * 255))
                    pixels[offset + 3] = UInt8(min(255, intensity * 255))
                }
            }
        }
        return makeImage(pixels, width: width, height: height)
    }

    private static func vectorImage(_ counts: [UInt32], colors: [SIMD3<Float>], size: Int) -> CGImage? {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let expected = Float(max(1, counts.max() ?? 1))
        for index in 0..<(size * size) where counts[index] > 0 {
            let count = Float(counts[index])
            let average = colors[index] / count
            let maxChannel = max(0.001, max(average.x, max(average.y, average.z)))
            let intensity = min(1, 0.35 + log1p(count) / log1p(expected) * 0.75)
            let color = average / maxChannel * intensity
            pixels[index * 4] = UInt8(min(255, color.x * 255))
            pixels[index * 4 + 1] = UInt8(min(255, color.y * 255))
            pixels[index * 4 + 2] = UInt8(min(255, color.z * 255))
            pixels[index * 4 + 3] = UInt8(min(255, intensity * 255))
        }
        return makeImage(pixels, width: size, height: size)
    }

    private static func makeImage(_ pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: ColorPipeline.outputSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
