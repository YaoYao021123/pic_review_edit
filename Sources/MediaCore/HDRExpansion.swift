import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A deliberately modest SDR-derived look, not recovered camera highlights.
/// Scale RGB together using luminance, preserving hue and midtone exposure.
public enum HDRExpansion {
    private static let kernel: CIColorKernel? = {
        let source = """
        #include <CoreImage/CoreImage.h>
        using namespace metal;
        [[stitchable]] float4 expandHighlight(coreimage::sample_t pixel) {
            float luma = dot(pixel.rgb, float3(0.2126, 0.7152, 0.0722));
            float t = smoothstep(0.55, 1.0, luma);
            return float4(pixel.rgb * (1.0 + t * t), pixel.a);
        }
        """
        return (try? CIKernel.kernels(withMetalString: source))?.first as? CIColorKernel
    }()
    public static func image(_ sdr: CIImage) throws -> CIImage {
        guard let kernel, let result = kernel.apply(extent: sdr.extent, arguments: [sdr]) else {
            throw VideoWorkError.failed(L("HDR 高光扩展不可用"))
        }
        return result
    }
    /// HEIC with an SDR base and generated gain map, plus Apple's Live pairing ID.
    public static func writeCover(_ hdr: CIImage, identifier: String, to url: URL) throws {
        let headroom = max(1, hdr.contentHeadroom)
        let base = ColorPipeline.toneMap(hdr, sourceHeadroom: headroom)
        let context = ColorPipeline.context()
        guard let data = context.heifRepresentation(of: base, format: .RGBA8, colorSpace: ColorPipeline.outputSpace,
                  options: [.hdrImage: hdr]),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            throw StraighteningError.renderFailed
        }
        CGImageDestinationAddImageFromSource(destination, source, 0, [
            kCGImagePropertyMakerAppleDictionary: ["17": identifier],
            kCGImagePropertyOrientation: 1
        ] as CFDictionary)
        var copied = false
        for type in [kCGImageAuxiliaryDataTypeHDRGainMap, kCGImageAuxiliaryDataTypeISOGainMap] {
            if let auxiliary = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) {
                CGImageDestinationAddAuxiliaryDataInfo(destination, type, auxiliary)
                copied = true
            }
        }
        guard copied, CGImageDestinationFinalize(destination) else {
            throw VideoWorkError.failed(L("HDR 封面增益图写入失败"))
        }
        let decoded = try ImageGradeSession.decode(url)
        guard decoded.contentHeadroom > 1 else { throw VideoWorkError.failed(L("HDR 封面未保留亮度范围")) }
    }
}

/// Keeps an HDR photo's extra brightness through an export.
public enum HDRGain {
    private static let kernel: CIColorKernel? = {
        let source = """
        #include <CoreImage/CoreImage.h>
        using namespace metal;
        [[stitchable]] float4 restoreGain(coreimage::sample_t graded, coreimage::sample_t hdr, coreimage::sample_t sdr, float limit) {
            float3 w = float3(0.2126, 0.7152, 0.0722);
            float gain = clamp(dot(hdr.rgb, w) / max(dot(sdr.rgb, w), 0.0001), 1.0, limit);
            return float4(graded.rgb * gain, graded.a);
        }
        """
        return (try? CIKernel.kernels(withMetalString: source))?.first as? CIColorKernel
    }()

    /// The edited picture with the original's brightness ratio between its HDR and tone-mapped
    /// versions applied again: highlights that went past SDR white in the original do so again.
    /// All three images share the extent of the original, before rotation and crop.
    public static func restore(_ graded: CIImage, original: CIImage, headroom: Float) -> CIImage {
        let sdr = ColorPipeline.toneMap(original, sourceHeadroom: headroom)
        guard let kernel, let result = kernel.apply(extent: graded.extent, arguments: [graded, original, sdr, max(1, headroom)]) else { return graded }
        return result
    }

    /// JPEG or HEIC data with `base` as the SDR picture and a gain map toward `hdr`; nil if the
    /// system can't write one (the export then stays SDR).
    public static func encode(base: CIImage, hdr: CIImage, format: ImageExportOptions.Format, quality: Double) -> Data? {
        let options: [CIImageRepresentationOption: Any] = [
            .hdrImage: hdr,
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): min(1, max(0.1, quality))
        ]
        let context = ColorPipeline.context()
        switch format {
        case .heic: return context.heifRepresentation(of: base, format: .RGBA8, colorSpace: ColorPipeline.outputSpace, options: options)
        case .jpeg: return context.jpegRepresentation(of: base, colorSpace: ColorPipeline.outputSpace, options: options)
        case .png: return nil
        }
    }
}
