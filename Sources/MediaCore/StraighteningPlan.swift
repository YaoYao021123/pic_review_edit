import CoreGraphics
import Foundation

/// Coordinates are upright image pixels, with a bottom-left origin (Core Image).
/// Positive angles rotate counterclockwise. The crop preserves the input aspect
/// ratio approximately, with pixel rounding inward and a one-pixel sampling margin.
public struct StraighteningPlan: Codable, Sendable, Equatable {
    public let sourceWidth: Int
    public let sourceHeight: Int
    public let rotationRadians: Double
    public let outputWidth: Int
    public let outputHeight: Int

    public init(width: Int, height: Int, rotationRadians: Double) throws {
        guard width >= 2, height >= 2, width <= Int(Int32.max), height <= Int(Int32.max),
              rotationRadians.isFinite, abs(rotationRadians) <= .pi / 4 else {
            throw StraighteningError.invalidGeometry
        }
        sourceWidth = width
        sourceHeight = height
        self.rotationRadians = rotationRadians
        let w = Double(width), h = Double(height)
        let c = abs(cos(rotationRadians)), s = abs(sin(rotationRadians))
        // The inverse-rotated crop must satisfy both source half-plane bounds.
        let scale = min(w / (w * c + h * s), h / (w * s + h * c))
        let margin = abs(rotationRadians) > 1e-12 ? 2.0 : 0
        outputWidth = Int(floor(w * scale - margin))
        outputHeight = Int(floor(h * scale - margin))
        guard outputWidth >= 2, outputHeight >= 2 else { throw StraighteningError.invalidGeometry }
    }

    public var rotationDegrees: Double { rotationRadians * 180 / .pi }
    public var cropLossFraction: Double {
        1 - Double(outputWidth) * Double(outputHeight) / (Double(sourceWidth) * Double(sourceHeight))
    }
    public var cropRect: CGRect {
        let x = CGFloat(sourceWidth - outputWidth) / 2
        let y = CGFloat(sourceHeight - outputHeight) / 2
        return CGRect(x: x, y: y, width: CGFloat(outputWidth), height: CGFloat(outputHeight))
    }
    public var transform: CGAffineTransform {
        CGAffineTransform(translationX: -Double(sourceWidth) / 2, y: -Double(sourceHeight) / 2)
            .concatenating(CGAffineTransform(rotationAngle: rotationRadians))
            .concatenating(CGAffineTransform(translationX: Double(sourceWidth) / 2, y: Double(sourceHeight) / 2))
    }
}

public enum StraighteningError: Error, LocalizedError {
    case invalidGeometry, unreadableImage, renderFailed, pngRequired
    public var errorDescription: String? {
        switch self {
        case .invalidGeometry: return L("画幅或校正角度无效，当前支持 ±45°。")
        case .unreadableImage: return L("无法读取图片，请选择有效的图片文件。")
        case .renderFailed: return L("无法生成调正预览。")
        case .pngRequired: return L("当前导出格式为 PNG，请使用 .png 扩展名。")
        }
    }
}

/// These are conservative prototype gates, not a calibrated accuracy guarantee.
public struct StraighteningPolicy: Sendable {
    public var minimumConfidence: Float = 0.6
    public var maximumDegrees: Double = 10
    public var maximumCropLoss: Double = 0.35
    public var minimumDegrees: Double = 0.15
    public init() {}
}

public struct StraighteningAssessment: Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        case ready, alreadyLevel, noReference, reviewRequired
    }
    public let status: Status
    public let confidence: Float?
    public let proposedDegrees: Double?
    public let plan: StraighteningPlan?
    public let message: String
    public let detectorRevision: Int

    public static func evaluate(width: Int, height: Int, radians: Double?, confidence: Float?,
                                revision: Int = 1, policy: StraighteningPolicy = .init()) throws -> Self {
        guard let radians, radians.isFinite, let confidence, confidence.isFinite else {
            return Self(status: .noReference, confidence: nil, proposedDegrees: nil, plan: nil,
                        message: L("未找到可靠水平参考，可使用角度滑块手动调正。"), detectorRevision: revision)
        }
        let degrees = radians * 180 / .pi
        guard confidence >= policy.minimumConfidence, abs(degrees) <= policy.maximumDegrees else {
            return Self(status: .reviewRequired, confidence: confidence, proposedDegrees: degrees, plan: nil,
                        message: L("自动建议不够可靠，已保留当前调整；请手动确认。"), detectorRevision: revision)
        }
        let plan = try StraighteningPlan(width: width, height: height, rotationRadians: radians)
        guard plan.cropLossFraction <= policy.maximumCropLoss else {
            return Self(status: .reviewRequired, confidence: confidence, proposedDegrees: degrees, plan: nil,
                        message: L("自动调正需要裁掉较多画面，已保留当前调整；请手动确认。"), detectorRevision: revision)
        }
        if abs(degrees) < policy.minimumDegrees {
            return Self(status: .alreadyLevel, confidence: confidence, proposedDegrees: degrees, plan: nil,
                        message: L("检测结果接近水平，无需自动调整。"), detectorRevision: revision)
        }
        return Self(status: .ready, confidence: confidence, proposedDegrees: degrees, plan: plan,
                    message: L("已生成调正建议，可微调角度或恢复原片。"), detectorRevision: revision)
    }
}
