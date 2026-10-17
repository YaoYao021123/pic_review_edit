import CoreImage
import Foundation
import Testing
@testable import MediaCore

struct ProjectTests {
    private func edited(_ change: (inout EditRecipe) -> Void) -> EditRecipe {
        var recipe = EditRecipe(); change(&recipe); return recipe
    }

    @Test func testPhotosShareTheLookAndKeepTheirOwnExposureAndCrop() throws {
        var project = Project(name: "Trip")
        let a = edited { $0.adjustments.exposure = 0.5; $0.adjustments.warmth = 30; $0.degrees = 2 }
        let b = edited { $0.adjustments.exposure = -0.3; $0.adjustments.saturation = -40 }
        project.add(["a", "b"]) { $0 == "a" ? a : b }
        project.adoptLook(from: a, keeping: "a")
        let ra = try #require(project.recipe(for: "a")), rb = try #require(project.recipe(for: "b"))
        #expect(ra.adjustments.warmth == 30 && rb.adjustments.warmth == 30, "colour is shared")
        #expect(rb.adjustments.saturation == 0, "b's own colour gave way to the look")
        #expect(ra.adjustments.exposure == 0.5 && rb.adjustments.exposure == -0.3, "exposure stays per photo")
        #expect(ra.degrees == 2 && rb.degrees == 0, "crop stays per photo")
        #expect(project.recipe(for: "c") == nil)
    }

    @Test func testEditsGoToTheRightLayer() throws {
        var project = Project(name: "Post")
        project.add(["a", "b"])
        // Warmth on photo a changes the look, so b changes too.
        let start = try #require(project.recipe(for: "a"))
        var next = start; next.adjustments.warmth = 20; next.adjustments.exposure = 0.7; next.degrees = 3
        next.curves.master = [CurvePoint(x: 0, y: 0.05), CurvePoint(x: 1, y: 1)]
        let lookChanged = project.store(next, for: "a", previous: start, photoOnly: false)
        #expect(lookChanged)
        let b = try #require(project.recipe(for: "b"))
        #expect(b.adjustments.warmth == 20 && b.curves.master == next.curves.master)
        #expect(b.adjustments.exposure == 0 && b.degrees == 0, "exposure and crop stayed with a")
        #expect(project.recipe(for: "a") == next)

        // "This photo only": b gets cooler without touching a.
        let bStart = b
        var cooler = b; cooler.adjustments.warmth = -10
        let lookChangedAgain = project.store(cooler, for: "b", previous: bStart, photoOnly: true)
        #expect(!lookChangedAgain, "the look didn't change")
        #expect(project.recipe(for: "b")?.adjustments.warmth == -10)
        #expect(project.recipe(for: "a")?.adjustments.warmth == 20)
        // Later look changes still reach b, on top of its own offset.
        let aStart = try #require(project.recipe(for: "a"))
        var warmer = aStart; warmer.adjustments.warmth = 40
        project.store(warmer, for: "a", previous: aStart, photoOnly: false)
        #expect(project.recipe(for: "b")?.adjustments.warmth == 10)
    }

    @Test func testUntouchedSlidersDontDriftWhenClamped() throws {
        var project = Project(name: "Clamp")
        project.add(["a", "b"])
        project.look.adjustments.warmth = 80
        project.photos[0].setOffset(.warmth, 40) // a shows 100 (clamped)
        let start = try #require(project.recipe(for: "a"))
        #expect(start.adjustments.warmth == 100)
        var next = start; next.adjustments.contrast = 10
        project.store(next, for: "a", previous: start, photoOnly: false)
        #expect(project.look.adjustments.warmth == 80, "warmth wasn't touched, so the look keeps 80")
        #expect(project.recipe(for: "b")?.adjustments.warmth == 80)
    }

    @Test func testSavesAndLoads() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("projects-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var project = Project(name: "草原之行")
        project.add(["/a.jpg"])
        project.look.adjustments.vibrance = 15
        project.photos[0].setOffset(.exposure, 0.4)
        let store = ProjectStore(root: root)
        try store.save([project])
        #expect(store.load() == [project])
        let old = try JSONDecoder().decode(Project.self, from: Data(#"{"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","name":"x","created":0,"look":{},"photos":[{"id":"/b.jpg"}]}"#.utf8))
        #expect(old.recipe(for: "/b.jpg") == EditRecipe())
    }
}

struct ProjectEvenOutTests {
    /// A textured patch (so it isn't one flat colour) at a given brightness and cast.
    private func photo(level: Double, warm: Double) -> CGImage {
        let context = CGContext(data: nil, width: 96, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for y in 0..<64 { for x in 0..<96 {
            let v = level * (0.8 + 0.4 * Double((x * 7 + y * 13) % 17) / 17)
            context.setFillColor(red: min(1, v + warm), green: min(1, v), blue: max(0, min(1, v - warm)), alpha: 1)
            context.fill(CGRect(x: x, y: y, width: 1, height: 1))
        } }
        return context.makeImage()!
    }

    private func mean(_ project: Project, _ id: String, _ image: CGImage) -> SIMD3<Double> {
        let edits = MediaEdits(recipe: project.recipe(for: id)!, lut: nil)
        let graded = try! ColorPipeline.grade(CIImage(cgImage: image), edits: edits)
        return LookMatch.statistics(try! ColorPipeline.sdrBitmap(graded))!.mean
    }

    @Test func testEvenOutBringsBrightnessAndCastCloser() {
        var project = Project(name: "Set")
        project.add(["dark", "mid", "warm"])
        let images = ["dark": photo(level: 0.22, warm: 0), "mid": photo(level: 0.45, warm: 0), "warm": photo(level: 0.42, warm: 0.12)]
        func spread(_ p: Project) -> (light: Double, cast: Double) {
            let means = images.map { mean(p, $0.key, $0.value) }
            let l = means.map(\.x), b = means.map(\.z)
            return (l.max()! - l.min()!, b.max()! - b.min()!)
        }
        let before = spread(project)
        let after = spread(ProjectEvenOut.evenOut(project, images: images, lut: nil))
        #expect(after.light < before.light * 0.6, "brightness spread \(before.light) → \(after.light)")
        #expect(after.cast < before.cast * 0.7, "cast spread \(before.cast) → \(after.cast)")
        // Only the per-photo part changed; the shared look is untouched.
        #expect(ProjectEvenOut.evenOut(project, images: images, lut: nil).look == project.look)
    }
}
