import CoreImage
import Foundation
import Testing
@testable import MediaCore

struct AdaptiveLUTTests {
    /// The same synthetic picture as the plain-Python reference (red across, green down, a blue ramp).
    private func synthetic() -> [Float] {
        let n = 256
        var planar = [Float](repeating: 0, count: 3 * n * n)
        for y in 0..<n { for x in 0..<n {
            planar[y * n + x] = Float(x) / 255
            planar[n * n + y * n + x] = Float(y) / 255
            planar[2 * n * n + y * n + x] = Float((x * 7 + y * 3) % 256) / 255
        } }
        return planar
    }

    @Test func testNetworkMatchesTheReferenceImplementation() throws {
        let model = try #require(AdaptiveLUT.shared, "assets/models/adaptive-lut.bin should load")
        let weights = model.weights(planar: synthetic())
        // Computed by an independent plain-Python forward pass over the original .pth weights.
        let expected = SIMD3<Float>(1.363316, 0.748972, -1.235996)
        #expect(abs(weights.x - expected.x) < 1e-3 && abs(weights.y - expected.y) < 1e-3 && abs(weights.z - expected.z) < 1e-3, "\(weights)")

        let cube = model.lut(weights: expected, title: "test")
        func at(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Float> {
            let i = (b * 33 * 33 + g * 33 + r) * 3
            return SIMD3(cube.rgb[i], cube.rgb[i + 1], cube.rgb[i + 2])
        }
        for (point, value) in [((0, 0, 0), SIMD3<Float>(0, 0, 0)), ((32, 32, 32), SIMD3(0.98306, 0.986442, 0.988784)),
                               ((16, 8, 24), SIMD3(0.563279, 0.18556, 0.769706)), ((5, 20, 30), SIMD3(0.274709, 0.607921, 0.837683))] {
            let got = at(point.0, point.1, point.2)
            #expect(abs(got.x - value.x) < 1e-4 && abs(got.y - value.y) < 1e-4 && abs(got.z - value.z) < 1e-4, "\(point): \(got)")
        }
    }

    @Test func testPreparesPhotosAndMakesAUsableGrade() throws {
        let model = try #require(AdaptiveLUT.shared)
        // Any picture is squeezed to 256 × 256 sRGB, planar red, green, blue.
        let photo = CIImage(color: CIColor(red: 0.35, green: 0.4, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 400))
        let input = try #require(AdaptiveLUT.input(photo))
        #expect(input.count == 3 * 256 * 256)
        let area = 256 * 256
        let means = (0..<3).map { c in input[(c * area)..<((c + 1) * area)].reduce(0, +) / Float(area) }
        // CIColor(red:green:blue:) is already in sRGB, so the values come back as they were.
        #expect(abs(means[0] - 0.35) < 0.01 && abs(means[1] - 0.40) < 0.01 && abs(means[2] - 0.50) < 0.01, "\(means)")

        let cube = model.lut(weights: SIMD3(1.363316, 0.748972, -1.235996), title: "AI")
        #expect(cube.dimension == 33 && cube.rgb.count == 33 * 33 * 33 * 3)
        #expect(cube.rgb.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
        // A grade, not a scramble: brighter inputs stay brighter along the gray axis.
        let grays = (0..<33).map { i -> Float in let j = (i * 33 * 33 + i * 33 + i) * 3; return cube.rgb[j] + cube.rgb[j + 1] + cube.rgb[j + 2] }
        #expect(zip(grays, grays.dropFirst()).allSatisfy { $0 <= $1 + 0.02 })
    }

    @Test func testRefusesADamagedFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("broken-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("A3DL\u{1}\0\0\0".utf8).write(to: url)
        #expect(throws: (any Error).self) { try AdaptiveLUT(contentsOf: url) }
    }
}
