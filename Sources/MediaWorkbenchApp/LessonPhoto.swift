import CoreImage
import MediaCore
import SwiftUI

/// The open photo, prepared once for lessons: a small SDR copy, its pixels and a coarse grid of
/// blocks for the pixel animations. Renders are synchronous; at ~360 px they take a few ms.
final class LessonPhoto: @unchecked Sendable {
    struct Block { let x: Int, y: Int, r: Double, g: Double, b: Double, luma: Double }

    let image: CIImage
    let thumbnail: CGImage
    let width: Int, height: Int
    /// The rendered RGBA bytes, kept for the 3D scenes.
    let pixels: [UInt8]
    let luma: [Double]
    let blocks: [Block]
    let gridWidth: Int, gridHeight: Int
    let histogram: [Double]
    let capture: CaptureInfo?
    /// True when the user's photo was used (not the built-in sample).
    let isUsersPhoto: Bool
    private var zoneCache: [ToneZone: CGImage] = [:]
    private var reliefCache: [Int: Relief] = [:]
    private var cloudCache: [Int: [Int]] = [:]

    /// The photo averaged into a coarse grid, for the 3D relief.
    struct Relief { let columns: Int, rows: Int, luma: [Double] }

    init?(source: CIImage, headroom: Float, capture: CaptureInfo?, isUsersPhoto: Bool) {
        let extent = source.extent
        guard extent.width >= 2, extent.height >= 2 else { return nil }
        let scale = min(1, 360 / max(extent.width, extent.height))
        let sdr = ColorPipeline.toneMap(source, sourceHeadroom: headroom)
            .transformed(by: .init(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: .init(scaleX: scale, y: scale))
        let w = max(2, Int(sdr.extent.width.rounded())), h = max(2, Int(sdr.extent.height.rounded()))
        guard let rendered = Self.bytes(sdr, w, h), let cg = Self.cgImage(rendered, w, h) else { return nil }
        image = CIImage(cgImage: cg)
        thumbnail = cg; width = w; height = h
        self.capture = capture; self.isUsersPhoto = isUsersPhoto
        pixels = rendered
        luma = Self.luma(rendered)
        histogram = Self.histogram(luma)
        // About 30 blocks across: enough to read as a picture, few enough to animate.
        let columns = 30, rows = max(8, Int((Double(columns) * Double(h) / Double(w)).rounded()))
        gridWidth = columns; gridHeight = rows
        var blocks: [Block] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let x0 = column * w / columns, x1 = max(x0 + 1, (column + 1) * w / columns)
                let y0 = row * h / rows, y1 = max(y0 + 1, (row + 1) * h / rows)
                var r = 0.0, g = 0.0, b = 0.0, n = 0.0
                for y in stride(from: y0, to: y1, by: 2) {
                    for x in stride(from: x0, to: x1, by: 2) {
                        let i = (y * w + x) * 4
                        r += Double(rendered[i]); g += Double(rendered[i + 1]); b += Double(rendered[i + 2]); n += 1
                    }
                }
                r /= n * 255; g /= n * 255; b /= n * 255
                blocks.append(Block(x: column, y: row, r: r, g: g, b: b, luma: 0.2126 * r + 0.7152 * g + 0.0722 * b))
            }
        }
        self.blocks = blocks
    }

    /// The user's open photo, or a drawn sample landscape when nothing is open.
    @MainActor static func make(from editor: EditorModel) -> LessonPhoto? {
        if let frame = editor.frame,
           let photo = LessonPhoto(source: frame.before, headroom: frame.sourceHeadroom, capture: editor.captureInfo, isUsersPhoto: true) {
            return photo
        }
        return LessonPhoto(source: sample(), headroom: 1, capture: nil, isUsersPhoto: false)
    }

    /// Sky, sun, hills and a dark foreground: a full range of tones without any real photo.
    static func sample() -> CIImage {
        let size = CGRect(x: 0, y: 0, width: 600, height: 400)
        let sky = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 400), "inputColor0": CIColor(red: 0.25, green: 0.45, blue: 0.75),
            "inputPoint1": CIVector(x: 0, y: 150), "inputColor1": CIColor(red: 0.95, green: 0.82, blue: 0.62)])!.outputImage!
        let sun = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: 420, y: 190), "inputRadius0": 14, "inputRadius1": 90,
            "inputColor0": CIColor(red: 1, green: 1, blue: 0.97), "inputColor1": CIColor(red: 1, green: 0.9, blue: 0.7, alpha: 0)])!.outputImage!
        let hills = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 170), "inputColor0": CIColor(red: 0.32, green: 0.36, blue: 0.3),
            "inputPoint1": CIVector(x: 0, y: 0), "inputColor1": CIColor(red: 0.03, green: 0.04, blue: 0.03)])!.outputImage!
            .cropped(to: CGRect(x: 0, y: 0, width: 600, height: 170))
        let path = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 120), "inputColor0": CIColor(red: 0.62, green: 0.56, blue: 0.46),
            "inputPoint1": CIVector(x: 0, y: 0), "inputColor1": CIColor(red: 0.42, green: 0.36, blue: 0.3)])!.outputImage!
            .cropped(to: CGRect(x: 250, y: 0, width: 110, height: 120))
        return path.composited(over: hills).composited(over: sun.composited(over: sky)).cropped(to: size)
    }

    // MARK: 3D scenes

    /// Mean brightness per cell of a grid `columns` wide (rows follow the photo's shape).
    func relief(columns: Int) -> Relief {
        if let cached = reliefCache[columns] { return cached }
        let result = Self.grid(luma, width: width, height: height, columns: columns)
        reliefCache[columns] = result
        return result
    }

    /// The same grid for other pixel bytes (an edited copy of the photo), for scenes that reshape the relief.
    func relief(of pixels: [UInt8], columns: Int) -> Relief {
        pixels.count == width * height * 4 ? Self.grid(Self.luma(pixels), width: width, height: height, columns: columns) : relief(columns: columns)
    }

    private static func grid(_ luma: [Double], width: Int, height: Int, columns: Int) -> Relief {
        let rows = max(4, Int((Double(columns) * Double(height) / Double(width)).rounded()))
        var cells = [Double](repeating: 0, count: columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let x0 = column * width / columns, x1 = max(x0 + 1, (column + 1) * width / columns)
                let y0 = row * height / rows, y1 = max(y0 + 1, (row + 1) * height / rows)
                var sum = 0.0
                for y in y0..<y1 { for x in x0..<x1 { sum += luma[y * width + x] } }
                cells[row * columns + column] = sum / Double((x1 - x0) * (y1 - y0))
            }
        }
        return Relief(columns: columns, rows: rows, luma: cells)
    }

    /// Pixel numbers spread evenly over the photo (a fixed pick, so the same dots move when the
    /// photo is edited), for point clouds of colour.
    func cloud(_ count: Int) -> [Int] {
        if let cached = cloudCache[count] { return cached }
        let total = width * height
        guard total > count else { return Array(0..<total) }
        var seed: UInt64 = 0x2545F4914F6CDD1D
        let picked = (0..<count).map { i -> Int in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            // One random pixel inside each of `count` equal slices of the photo.
            let slice = total / count
            return i * slice + Int((seed >> 33) % UInt64(slice))
        }
        cloudCache[count] = picked
        return picked
    }

    /// Display-encoded colour (0…1) of a pixel in a byte array like `pixels`.
    static func rgb(_ pixels: [UInt8], _ index: Int) -> (r: Double, g: Double, b: Double) {
        (Double(pixels[index * 4]) / 255, Double(pixels[index * 4 + 1]) / 255, Double(pixels[index * 4 + 2]) / 255)
    }

    // MARK: Rendering

    /// The photo with these edits, plus its pixels.
    func render(_ edits: MediaEdits) -> (image: CGImage, pixels: [UInt8]) {
        guard edits.hasGrade, let graded = try? ColorPipeline.grade(image, edits: edits),
              let pixels = Self.bytes(graded, width, height), let cg = Self.cgImage(pixels, width, height) else {
            return (thumbnail, Self.bytes(image, width, height) ?? [])
        }
        return (cg, pixels)
    }

    func render(_ adjustments: BasicAdjustments) -> (image: CGImage, pixels: [UInt8]) {
        render(MediaEdits(adjustments: adjustments))
    }

    /// Only the pixels in one zone keep their colour; the rest fade to dark grey.
    func zoneMask(_ zone: ToneZone) -> CGImage {
        if let cached = zoneCache[zone] { return cached }
        guard var pixels = Self.bytes(image, width, height) else { return thumbnail }
        for i in 0..<(width * height) where !zone.range.contains(luma[i]) || (zone != .brightest && luma[i] == zone.range.upperBound) {
            let grey = UInt8(min(255, luma[i] * 255 * 0.25 + 12))
            pixels[i * 4] = grey; pixels[i * 4 + 1] = grey; pixels[i * 4 + 2] = grey
        }
        let result = Self.cgImage(pixels, width, height) ?? thumbnail
        zoneCache[zone] = result
        return result
    }

    /// Where a tone control acts: its weight per pixel shown as colour, the rest as grey.
    func influence(_ parameter: AdjustmentParameter, on pixels: [UInt8]) -> CGImage {
        var out = pixels
        for i in 0..<min(luma.count, pixels.count / 4) {
            let w = ToneResponse.weight(parameter, at: luma[i])
            let r = Double(pixels[i * 4]), g = Double(pixels[i * 4 + 1]), b = Double(pixels[i * 4 + 2])
            let grey = (0.2126 * r + 0.7152 * g + 0.0722 * b) * 0.35
            out[i * 4] = UInt8(grey + (r - grey) * w); out[i * 4 + 1] = UInt8(grey + (g - grey) * w); out[i * 4 + 2] = UInt8(grey + (b - grey) * w)
        }
        return Self.cgImage(out, width, height) ?? thumbnail
    }

    /// Pure white painted red and pure black painted blue, and their shares.
    func clipping(_ pixels: [UInt8]) -> (image: CGImage, white: Double, black: Double) {
        var out = pixels
        var white = 0, black = 0
        let count = pixels.count / 4
        for i in 0..<count {
            let r = pixels[i * 4], g = pixels[i * 4 + 1], b = pixels[i * 4 + 2]
            if max(r, g, b) >= 254 { white += 1; out[i * 4] = 235; out[i * 4 + 1] = 40; out[i * 4 + 2] = 40 }
            else if max(r, g, b) <= 2 { black += 1; out[i * 4] = 40; out[i * 4 + 1] = 90; out[i * 4 + 2] = 235 }
        }
        return (Self.cgImage(out, width, height) ?? thumbnail, Double(white) / Double(max(1, count)), Double(black) / Double(max(1, count)))
    }

    static func histogram(of pixels: [UInt8]) -> [Double] { histogram(luma(pixels)) }

    // MARK: Helpers

    static func bytes(_ image: CIImage, _ w: Int, _ h: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes {
            ColorPipeline.shared.render(image, toBitmap: $0.baseAddress!, rowBytes: w * 4,
                                        bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: ColorPipeline.outputSpace)
        }
        return bytes
    }

    static func cgImage(_ bytes: [UInt8], _ w: Int, _ h: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: ColorPipeline.outputSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    static func luma(_ pixels: [UInt8]) -> [Double] {
        (0..<(pixels.count / 4)).map { i in
            (0.2126 * Double(pixels[i * 4]) + 0.7152 * Double(pixels[i * 4 + 1]) + 0.0722 * Double(pixels[i * 4 + 2])) / 255
        }
    }

    static func histogram(_ luma: [Double]) -> [Double] {
        var bins = [Double](repeating: 0, count: 64)
        for value in luma { bins[min(63, Int(value * 64))] += 1 }
        let tallest = max(1, bins.max() ?? 1)
        return bins.map { $0 / tallest }
    }
}
