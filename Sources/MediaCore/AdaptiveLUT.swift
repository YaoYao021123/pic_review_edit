import Accelerate
import CoreGraphics
import CoreImage
import Foundation

/// "AI look": a colour grade made for this photo by Image-Adaptive-3DLUT (Zeng et al., "Learning
/// Image-adaptive 3D Lookup Tables for High Performance Photo Enhancement in Real-time", TPAMI
/// 2020; Apache-2.0, trained on the MIT-Adobe FiveK sRGB set). A small network looks at the photo
/// at 256 × 256 and mixes three learned 33³ LUTs; the mix is the grade. Runs on the Mac.
/// Weights: assets/models/adaptive-lut.bin, made by scripts/convert-adaptive-lut.py.
public final class AdaptiveLUT: Sendable {
    public static let dimension = 33
    static let inputSize = 256

    private struct Conv: Sendable {
        let input: Int, output: Int, kernel: Int
        let weight: [Float]   // [output][input][kernel][kernel]
        let bias: [Float]
        let normScale: [Float]?
        let normShift: [Float]?
    }
    private let blocks: [Conv]
    private let final: Conv
    /// Three tables, each [channel][blue][green][red].
    private let basis: [[Float]]

    /// The bundled model, or nil if the app was built without it.
    public static let shared: AdaptiveLUT? = {
        let name = "adaptive-lut.bin"
        var places: [URL] = []
        if let url = Bundle.main.url(forResource: "adaptive-lut", withExtension: "bin") { places.append(url) }
        // Unbundled builds (dev runs, the probe) keep it next to the executable.
        if let executable = Bundle.main.executableURL { places.append(executable.deletingLastPathComponent().appendingPathComponent(name)) }
        // Tests and `swift run` from the repository.
        places.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../assets/models/\(name)").standardized)
        for place in places where FileManager.default.fileExists(atPath: place.path) {
            if let model = try? AdaptiveLUT(contentsOf: place) { return model }
        }
        return nil
    }()

    public init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        var cursor = 0
        func uint32() throws -> Int {
            guard cursor + 4 <= data.count else { throw VideoWorkError.failed(L("AI 调色模型文件已损坏。")) }
            let value = data[cursor..<(cursor + 4)].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            cursor += 4
            return Int(UInt32(littleEndian: value))
        }
        guard data.count > 12, data.prefix(4) == Data("A3DL".utf8) else { throw VideoWorkError.failed(L("AI 调色模型文件已损坏。")) }
        cursor = 4
        guard try uint32() == 1, try uint32() == 23 else { throw VideoWorkError.failed(L("AI 调色模型文件已损坏。")) }
        var tensors: [[Float]] = []
        for _ in 0..<23 {
            let count = try uint32()
            guard count > 0, cursor + count * 4 <= data.count else { throw VideoWorkError.failed(L("AI 调色模型文件已损坏。")) }
            // Little-endian float32, the same as Apple silicon: copy the bytes straight in.
            var values = [Float](repeating: 0, count: count)
            values.withUnsafeMutableBytes { _ = data.copyBytes(to: $0, from: cursor..<(cursor + count * 4)) }
            tensors.append(values)
            cursor += count * 4
        }
        guard cursor == data.count else { throw VideoWorkError.failed(L("AI 调色模型文件已损坏。")) }
        // conv(3→16), norm, conv(16→32), norm, conv(32→64), norm, conv(64→128), norm, conv(128→128), conv(128→3, 8×8).
        let channels = [(3, 16), (16, 32), (32, 64), (64, 128), (128, 128)]
        var blocks: [Conv] = []
        var index = 0
        for (layer, (input, output)) in channels.enumerated() {
            let hasNorm = layer < 4
            let conv = Conv(input: input, output: output, kernel: 3, weight: tensors[index], bias: tensors[index + 1],
                            normScale: hasNorm ? tensors[index + 2] : nil, normShift: hasNorm ? tensors[index + 3] : nil)
            guard conv.weight.count == output * input * 9, conv.bias.count == output,
                  !hasNorm || (conv.normScale?.count == output && conv.normShift?.count == output) else {
                throw VideoWorkError.failed(L("AI 调色模型文件已损坏。"))
            }
            blocks.append(conv)
            index += hasNorm ? 4 : 2
        }
        final = Conv(input: 128, output: 3, kernel: 8, weight: tensors[index], bias: tensors[index + 1], normScale: nil, normShift: nil)
        guard final.weight.count == 3 * 128 * 64, final.bias.count == 3 else { throw VideoWorkError.failed(L("AI 调色模型文件已损坏。")) }
        let size = 3 * Self.dimension * Self.dimension * Self.dimension
        basis = Array(tensors[(index + 2)...])
        guard basis.count == 3, basis.allSatisfy({ $0.count == size }) else { throw VideoWorkError.failed(L("AI 调色模型文件已损坏。")) }
        self.blocks = blocks
    }

    // MARK: Network

    /// The three mixing weights for an sRGB image already scaled to 256 × 256, planar
    /// [red plane, green plane, blue plane] with values 0...1.
    public func weights(planar input: [Float]) -> SIMD3<Float> {
        precondition(input.count == 3 * Self.inputSize * Self.inputSize)
        var x = input, size = Self.inputSize
        for block in blocks {
            x = convolve(x, size: size, block)
            size /= 2
            // LeakyReLU(0.2): the larger of x and 0.2·x.
            var scaled = [Float](repeating: 0, count: x.count)
            var slope: Float = 0.2
            vDSP_vsmul(x, 1, &slope, &scaled, 1, vDSP_Length(x.count))
            vDSP_vmax(x, 1, scaled, 1, &x, 1, vDSP_Length(x.count))
            if let scale = block.normScale, let shift = block.normShift {
                // InstanceNorm2d: each channel to zero mean and unit variance over the image, then scaled.
                let area = size * size
                x.withUnsafeMutableBufferPointer { values in
                    for c in 0..<block.output {
                        let channel = values.baseAddress! + c * area
                        var mean: Float = 0, deviation: Float = 0
                        // vDSP's deviation divides by n, like PyTorch's instance norm.
                        vDSP_normalize(channel, 1, nil, 1, &mean, &deviation, vDSP_Length(area))
                        var factor = scale[c] / (deviation * deviation + 1e-5).squareRoot()
                        var offset = shift[c] - mean * factor
                        vDSP_vsmsa(channel, 1, &factor, &offset, channel, 1, vDSP_Length(area))
                    }
                }
            }
        }
        // Dropout is off when predicting; the last 8 × 8 convolution leaves one value per output.
        var out = SIMD3<Float>(final.bias[0], final.bias[1], final.bias[2])
        for o in 0..<3 {
            var dot: Float = 0
            final.weight.withUnsafeBufferPointer { w in
                x.withUnsafeBufferPointer { v in vDSP_dotpr(w.baseAddress! + o * x.count, 1, v.baseAddress!, 1, &dot, vDSP_Length(x.count)) }
            }
            out[o] += dot
        }
        return out
    }

    /// 3 × 3, stride 2, padding 1, as one matrix product (im2col + sgemm).
    private func convolve(_ x: [Float], size: Int, _ conv: Conv) -> [Float] {
        let out = size / 2, columns = out * out, rows = conv.input * 9
        var matrix = [Float](repeating: 0, count: rows * columns)
        x.withUnsafeBufferPointer { src in
            matrix.withUnsafeMutableBufferPointer { m in
                for c in 0..<conv.input { for ky in 0..<3 { for kx in 0..<3 {
                    let row = (c * 9 + ky * 3 + kx) * columns
                    for oy in 0..<out {
                        let iy = oy * 2 - 1 + ky
                        guard iy >= 0, iy < size else { continue }
                        // Every other input pixel along the row; only the first can fall in the padding.
                        let first = kx == 0 ? 1 : 0
                        cblas_scopy(Int32(out - first), src.baseAddress! + c * size * size + iy * size + 2 * first - 1 + kx, 2,
                                    m.baseAddress! + row + oy * out + first, 1)
                    }
                } } }
            }
        }
        var result = [Float](repeating: 0, count: conv.output * columns)
        for o in 0..<conv.output { for i in 0..<columns { result[o * columns + i] = conv.bias[o] } }
        conv.weight.withUnsafeBufferPointer { w in
            matrix.withUnsafeBufferPointer { m in
                result.withUnsafeMutableBufferPointer { r in
                    cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(conv.output), Int32(columns), Int32(rows),
                                1, w.baseAddress!, Int32(rows), m.baseAddress!, Int32(columns), 1, r.baseAddress!, Int32(columns))
                }
            }
        }
        return result
    }

    // MARK: Photos

    /// The photo squeezed to 256 × 256 in sRGB, as the network expects.
    public static func input(_ image: CIImage, headroom: Float = 1) -> [Float]? {
        let extent = image.extent
        guard extent.width >= 8, extent.height >= 8, !extent.isInfinite else { return nil }
        let size = CGFloat(inputSize)
        let display = ColorPipeline.toneMap(image, sourceHeadroom: headroom)
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: size / extent.height, kCIInputAspectRatioKey: extent.height / extent.width])
            .clampedToExtent().cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
        var rgba = [UInt8](repeating: 0, count: inputSize * inputSize * 4)
        rgba.withUnsafeMutableBytes {
            ColorPipeline.shared.render(display, toBitmap: $0.baseAddress!, rowBytes: inputSize * 4,
                                        bounds: CGRect(x: 0, y: 0, width: size, height: size), format: .RGBA8, colorSpace: ColorPipeline.outputSpace)
        }
        let area = inputSize * inputSize
        var planar = [Float](repeating: 0, count: 3 * area)
        for i in 0..<area { for c in 0..<3 { planar[c * area + i] = Float(rgba[i * 4 + c]) / 255 } }
        return planar
    }

    /// The grade for these mixing weights, clipped to 0...1, as a LUT with sRGB values in and out.
    public func lut(weights: SIMD3<Float>, title: String) -> CubeLUT {
        let n = Self.dimension, count = n * n * n
        var rgb = [Float](repeating: 0, count: count * 3)
        for i in 0..<count {
            // i runs red fastest, then green, then blue: the .cube order and the basis layout.
            for c in 0..<3 {
                let value = weights.x * basis[0][c * count + i] + weights.y * basis[1][c * count + i] + weights.z * basis[2][c * count + i]
                rgb[i * 3 + c] = min(1, max(0, value))
            }
        }
        return CubeLUT(title: title, dimension: n, rgb: rgb)
    }

    /// The grade made for this picture.
    public func lut(for image: CIImage, headroom: Float = 1, title: String) -> CubeLUT? {
        guard let planar = Self.input(image, headroom: headroom) else { return nil }
        return lut(weights: weights(planar: planar), title: title)
    }
}
