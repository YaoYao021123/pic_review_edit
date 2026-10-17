import CoreImage
import Foundation

public struct GeometryAdjustments: Codable, Equatable, Sendable {
    public var quarterTurns = 0
    public var mirrored = false
    public var aspectRatio = 0.0
    public var cropScale = 1.0
    public var horizontal = 0.0
    public var vertical = 0.0
    public init() {}
    public var hasChanges: Bool { self != Self() }
    public func validate() throws {
        guard (0...3).contains(quarterTurns), aspectRatio.isFinite,
              aspectRatio == 0 || (0.25...4).contains(aspectRatio), cropScale.isFinite, (0.25...1).contains(cropScale),
              horizontal.isFinite, vertical.isFinite, (-100...100).contains(horizontal), (-100...100).contains(vertical) else {
            throw StraighteningError.invalidGeometry
        }
    }
    public func cropRect(in size: CGSize) -> CGRect {
        let ratio = aspectRatio == 0 ? size.width / size.height : aspectRatio
        let width = max(2, floor(min(size.width, size.height * ratio) * cropScale))
        let height = max(2, floor(min(size.height, size.width / ratio) * cropScale))
        let x = floor((size.width - width) * (horizontal / 100 + 1) / 2)
        let y = floor((size.height - height) * (vertical / 100 + 1) / 2)
        return CGRect(x: max(0, x), y: max(0, y), width: min(width, size.width), height: min(height, size.height))
    }
}

extension ColorPipeline {
    public static func geometrySize(width: Int, height: Int, edits: MediaEdits) throws -> CGSize {
        try edits.geometry.validate()
        let swapped = edits.geometry.quarterTurns % 2 != 0
        let plan = try StraighteningPlan(width: swapped ? height : width, height: swapped ? width : height,
                                        rotationRadians: edits.degrees * .pi / 180)
        return edits.geometry.cropRect(in: CGSize(width: plan.outputWidth, height: plan.outputHeight)).size
    }
    public static func geometry(_ image: CIImage, edits: MediaEdits) throws -> CIImage {
        let g = edits.geometry
        try g.validate()
        var input = image.transformed(by: .init(translationX: -image.extent.minX, y: -image.extent.minY))
        let w = input.extent.width, h = input.extent.height
        switch g.quarterTurns {
        case 1: input = input.transformed(by: .init(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0))
        case 2: input = input.transformed(by: .init(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h))
        case 3: input = input.transformed(by: .init(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w))
        default: break
        }
        if g.mirrored { input = input.transformed(by: .init(a: -1, b: 0, c: 0, d: 1, tx: input.extent.width, ty: 0)) }
        let straight = try geometry(input, degrees: edits.degrees)
        let rect = g.cropRect(in: straight.extent.size)
        return straight.cropped(to: rect).transformed(by: .init(translationX: -rect.minX, y: -rect.minY))
    }
}

/// Turns drags on the canvas crop frame into crop values (scale and offsets), so dragging and
/// the 裁剪 sliders edit the same thing. Pixel deltas are in Core Image orientation (y up).
public enum CropMath {
    /// Moves the kept area, stopping at the picture's edges.
    public static func move(_ g: GeometryAdjustments, size: CGSize, dx: Double, dy: Double) -> GeometryAdjustments {
        let rect = g.cropRect(in: size)
        return place(g, rect: CGRect(x: rect.minX + dx, y: rect.minY + dy, width: rect.width, height: rect.height), size: size)
    }

    /// Resizes from a corner (`handle`: +1 right/top, −1 left/bottom) keeping the ratio;
    /// the opposite corner stays put.
    public static func resize(_ g: GeometryAdjustments, size: CGSize, handle: (Int, Int), dx: Double, dy: Double) -> GeometryAdjustments {
        let ratio = g.aspectRatio == 0 ? size.width / size.height : g.aspectRatio
        let maxWidth = min(size.width, size.height * ratio)
        let rect = g.cropRect(in: size)
        let (sx, sy) = (Double(handle.0), Double(handle.1))
        let fromX = sx * dx, fromY = sy * dy * ratio
        let grow = abs(fromX) >= abs(fromY) ? fromX : fromY
        let width = min(maxWidth, max(maxWidth * 0.25, rect.width + grow))
        let height = width / ratio
        let x = sx > 0 ? rect.minX : rect.maxX - width
        let y = sy > 0 ? rect.minY : rect.maxY - height
        var result = g
        result.cropScale = min(1, max(0.25, width / maxWidth))
        return place(result, rect: CGRect(x: x, y: y, width: width, height: height), size: size)
    }

    /// Converts a rectangle's position back into the −100…100 offsets `cropRect` uses.
    private static func place(_ g: GeometryAdjustments, rect: CGRect, size: CGSize) -> GeometryAdjustments {
        var result = g
        let spareX = size.width - rect.width, spareY = size.height - rect.height
        let x = min(max(0, rect.minX), max(0, spareX)), y = min(max(0, rect.minY), max(0, spareY))
        result.horizontal = spareX > 0.5 ? min(100, max(-100, (2 * x / spareX - 1) * 100)) : 0
        result.vertical = spareY > 0.5 ? min(100, max(-100, (2 * y / spareY - 1) * 100)) : 0
        return result
    }
}
