import CoreImage
import Foundation
import Testing
@testable import MediaCore

struct LocalAdjustmentTests {
    private let extent = CGRect(x: 0, y: 0, width: 200, height: 100)

    /// Mask value at a normalized point (origin top left).
    private func value(_ mask: CIImage, _ x: CGFloat, _ y: CGFloat, in extent: CGRect) -> Float {
        let px = extent.minX + x * (extent.width - 1), py = extent.maxY - 1 - y * (extent.height - 1)
        var pixel = [Float](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes {
            ColorPipeline.shared.render(mask, toBitmap: $0.baseAddress!, rowBytes: 16, bounds: CGRect(x: px.rounded(.down), y: py.rounded(.down), width: 1, height: 1),
                                        format: .RGBAf, colorSpace: nil)
        }
        return pixel[0]
    }

    @Test func testLinearGradientIsFullAtStartAndNoneAtEnd() {
        var layer = LocalAdjustment(shape: .linear)
        layer.start = CGPoint(x: 0.5, y: 0.1); layer.end = CGPoint(x: 0.5, y: 0.6)
        let mask = LocalMask.image(layer, extent: extent)
        #expect(value(mask, 0.5, 0.02, in: extent) > 0.98)
        #expect(value(mask, 0.5, 0.9, in: extent) < 0.02)
        let middle = value(mask, 0.5, 0.35, in: extent)
        #expect(middle > 0.3 && middle < 0.7)
        layer.invert = true
        #expect(value(LocalMask.image(layer, extent: extent), 0.5, 0.9, in: extent) > 0.98)
    }

    @Test func testRadialMaskFeathersFromCenter() {
        var layer = LocalAdjustment(shape: .radial)
        layer.center = CGPoint(x: 0.5, y: 0.5); layer.radii = CGSize(width: 0.3, height: 0.4); layer.feather = 0.5
        let mask = LocalMask.image(layer, extent: extent)
        #expect(value(mask, 0.5, 0.5, in: extent) > 0.98)
        #expect(value(mask, 0.62, 0.5, in: extent) > 0.95)        // inside the solid core
        #expect(value(mask, 0.95, 0.5, in: extent) < 0.02)        // outside the ellipse
        let edge = value(mask, 0.72, 0.5, in: extent)             // in the soft edge
        #expect(edge > 0.05 && edge < 0.95)
    }

    @Test func testBrushPaintsAndErases() {
        var layer = LocalAdjustment(shape: .brush)
        layer.feather = 0
        layer.strokes = [BrushStroke(points: [CGPoint(x: 0.2, y: 0.5), CGPoint(x: 0.8, y: 0.5)], radius: 0.1)]
        var mask = LocalMask.image(layer, extent: extent)
        #expect(value(mask, 0.5, 0.5, in: extent) > 0.98)
        #expect(value(mask, 0.5, 0.05, in: extent) < 0.02)
        layer.strokes.append(BrushStroke(points: [CGPoint(x: 0.5, y: 0.5)], radius: 0.08, erase: true))
        mask = LocalMask.image(layer, extent: extent)
        #expect(value(mask, 0.5, 0.5, in: extent) < 0.02)
        #expect(value(mask, 0.3, 0.5, in: extent) > 0.98)
    }

    @Test func testLocalExposureOnlyChangesTheMaskedPart() throws {
        let gray = CIImage(color: CIColor(red: 0.25, green: 0.25, blue: 0.25)).cropped(to: extent)
        var layer = LocalAdjustment(shape: .linear)
        layer.adjustments.exposure = -1
        layer.start = CGPoint(x: 0.5, y: 0); layer.end = CGPoint(x: 0.5, y: 0.4)
        let graded = try ColorPipeline.grade(gray, edits: MediaEdits(locals: [layer]))
        let top = value(graded, 0.5, 0.0, in: extent), bottom = value(graded, 0.5, 0.95, in: extent)
        let untouched = value(try ColorPipeline.grade(gray, edits: MediaEdits(adjustments: { var a = BasicAdjustments(); a.contrast = 0.0001; return a }())), 0.5, 0.95, in: extent)
        #expect(top < bottom * 0.7, "top \(top) bottom \(bottom)")
        #expect(abs(bottom - untouched) < 0.01 || abs(bottom - 0.25) < 0.02)
        // Switched off or bypassed: no change at all.
        layer.enabled = false
        #expect(!MediaEdits(locals: [layer]).hasGrade)
        layer.enabled = true
        #expect(!MediaEdits(bypass: [.local], locals: [layer]).hasGrade)
    }

    @Test func testRecipeKeepsLayersAndRejectsBadOnes() throws {
        var recipe = EditRecipe()
        var layer = LocalAdjustment(shape: .brush)
        layer.strokes = [BrushStroke(points: [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.3, y: 0.4)], radius: 0.05, erase: false)]
        recipe.locals = [layer, LocalAdjustment(shape: .radial)]
        let data = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(EditRecipe.self, from: data)
        #expect(decoded.locals == recipe.locals)
        try decoded.validate()
        #expect(MediaEdits(recipe: decoded, lut: nil).locals.count == 2)
        // Older recipes without the field still load.
        var old = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        old.removeValue(forKey: "locals")
        #expect(try JSONDecoder().decode(EditRecipe.self, from: JSONSerialization.data(withJSONObject: old)).locals.isEmpty)
        var bad = recipe
        bad.locals[1].radii = CGSize(width: 0, height: 0.2)
        #expect(throws: (any Error).self) { try bad.validate() }
    }

    /// The mapping must agree with the real geometry pipeline: a bright dot placed in the
    /// source shows up where `toOutput` says.
    @Test func testGeometryMappingMatchesTheRenderedImage() throws {
        let size = CGSize(width: 400, height: 300)
        let point = CGPoint(x: 0.62, y: 0.37)
        let dot = CIImage(color: .white).cropped(to: CGRect(x: point.x * size.width - 3, y: (1 - point.y) * size.height - 3, width: 6, height: 6))
        let source = dot.composited(over: CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size)))
        for (turns, mirrored, degrees, crop) in [(0, false, 0.0, 1.0), (1, false, 0.0, 1.0), (2, true, 0.0, 0.8), (3, false, 4.0, 0.7), (0, true, -6.0, 0.9)] {
            var edits = MediaEdits(degrees: degrees)
            edits.geometry.quarterTurns = turns; edits.geometry.mirrored = mirrored; edits.geometry.cropScale = crop
            let mapping = try GeometryMapping(source: size, edits: edits)
            let output = try ColorPipeline.geometry(source, edits: edits)
            #expect(abs(output.extent.width - mapping.outputSize.width) < 2 && abs(output.extent.height - mapping.outputSize.height) < 2)
            // Find the dot.
            let width = Int(output.extent.width), height = Int(output.extent.height)
            var pixels = [Float](repeating: 0, count: width * height * 4)
            pixels.withUnsafeMutableBytes {
                ColorPipeline.shared.render(output, toBitmap: $0.baseAddress!, rowBytes: width * 16, bounds: output.extent, format: .RGBAf, colorSpace: nil)
            }
            var sum = CGPoint.zero, count = 0.0
            for y in 0..<height { for x in 0..<width where pixels[(y * width + x) * 4] > 0.5 { sum.x += CGFloat(x); sum.y += CGFloat(y); count += 1 } }
            try #require(count > 0)
            // Rendered rows run top to bottom, so y here is already "down".
            let found = CGPoint(x: (sum.x / count + 0.5) / CGFloat(width), y: (sum.y / count + 0.5) / CGFloat(height))
            let predicted = mapping.toOutput(point)
            #expect(abs(found.x - predicted.x) < 0.02 && abs(found.y - predicted.y) < 0.02, "turns \(turns) mirror \(mirrored) degrees \(degrees): \(found) vs \(predicted)")
            let back = mapping.toSource(predicted)
            #expect(abs(back.x - point.x) < 1e-6 && abs(back.y - point.y) < 1e-6)
        }
    }
}
