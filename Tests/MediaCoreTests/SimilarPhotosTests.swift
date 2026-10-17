import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MediaCore

struct SimilarPhotosTests {
    /// A scene with a sky gradient, a "hill" and a sun; `shift` moves the sun, `light` brightens.
    private func scene(width: Int = 320, height: Int = 240, shift: CGFloat = 0, light: CGFloat = 0, other: Bool = false) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let w = CGFloat(width), h = CGFloat(height)
        if other {
            // A completely different picture: vertical stripes.
            for i in 0..<8 {
                context.setFillColor(red: i % 2 == 0 ? 0.9 : 0.1, green: 0.3, blue: i % 2 == 0 ? 0.2 : 0.8, alpha: 1)
                context.fill(CGRect(x: CGFloat(i) * w / 8, y: 0, width: w / 8, height: h))
            }
            return context.makeImage()!
        }
        context.setFillColor(red: 0.35 + light, green: 0.55 + light, blue: 0.85 + light, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.setFillColor(red: 0.2 + light, green: 0.45 + light, blue: 0.15 + light, alpha: 1)
        context.fillEllipse(in: CGRect(x: -w * 0.2, y: -h * 0.6, width: w * 1.4, height: h))
        context.setFillColor(red: 1, green: 0.85, blue: 0.3, alpha: 1)
        context.fillEllipse(in: CGRect(x: w * 0.65 + shift, y: h * 0.62, width: w * 0.16, height: w * 0.16))
        return context.makeImage()!
    }

    private func print(_ image: CGImage) throws -> PhotoFingerprint { try #require(PhotoFingerprint.fingerprint(of: image)) }

    @Test func testNearDuplicatesAreCloseAndDifferentPicturesAreNot() throws {
        let a = try print(scene()), b = try print(scene(shift: 3, light: 0.02)), c = try print(scene(other: true))
        #expect(SimilarPhotos.distance(a.hash, a.hash) == 0)
        #expect(SimilarPhotos.distance(a.hash, b.hash) <= 6)
        #expect(SimilarPhotos.close(a, b))
        #expect(!SimilarPhotos.close(a, c))
        #expect(SimilarPhotos.distance(a.hash, c.hash) > 12)
        // Same picture, different framing (crop to square) is not a duplicate.
        let square = try print(scene(width: 240, height: 240))
        #expect(!SimilarPhotos.close(a, square))
    }

    @Test func testSimilarGroupsUseAnchors() throws {
        let base = try print(scene()), near = try print(scene(shift: 2)), different = try print(scene(other: true))
        let items = [("a", base), ("b", near), ("c", different), ("d", base)].map { SimilarPhotos.Item(id: $0.0, folder: "/x", print: $0.1) }
        #expect(SimilarPhotos.similarGroups(items) == [["a", "b", "d"]])
    }

    @Test func testBurstsSplitOnGapsSpanAndCamera() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func shot(_ id: String, _ seconds: Double, camera: String = "X100", folder: String = "/a") -> SimilarPhotos.Item {
            // Different pictures: bursts are found from time alone.
            SimilarPhotos.Item(id: id, folder: folder, print: PhotoFingerprint(hash: UInt64(id.hashValue & 0xffff), color: [0, 0, 0], aspect: 1.5,
                                                                              captured: start.addingTimeInterval(seconds), camera: camera))
        }
        let items = [shot("1", 0), shot("2", 0.4), shot("3", 1.9), shot("4", 6), shot("5", 6.5, camera: "Other"),
                     shot("6", 20), shot("7", 21.5), shot("8", 23), shot("9", 24.5), shot("10", 26), shot("11", 27.5),
                     shot("12", 29), shot("13", 30.5), shot("14", 32), shot("15", 33.5), shot("16", 35), shot("17", 36.5)]
        let groups = SimilarPhotos.burstGroups(items).sorted { $0[0].count == $1[0].count ? $0[0] < $1[0] : $0[0].count < $1[0].count }
        #expect(groups.contains(["1", "2", "3"]))
        #expect(!groups.contains { $0.contains("4") || $0.contains("5") })
        // 20 s … 36.5 s runs past the 15 s span, so it splits.
        #expect(groups.contains { $0.first == "6" && $0.count == 11 })
        #expect(groups.contains(["17"]) == false)
    }

    @Test func testGroupsMergeOverlappingSimilarAndBurst() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var a = try print(scene()), b = try print(scene(shift: 2))
        var c = try print(scene(other: true))
        a.captured = start; b.captured = start.addingTimeInterval(30); c.captured = start.addingTimeInterval(31)
        a.camera = "Q"; b.camera = "Q"; c.camera = "Q"
        let items = [("a", a), ("b", b), ("c", c)].map { SimilarPhotos.Item(id: $0.0, folder: "/f", print: $0.1) }
        let groups = SimilarPhotos.groups(items)
        #expect(groups == [PhotoGroup(kind: .similar, ids: ["a", "b", "c"])])
    }

    @Test func testReadsCaptureTimeAndCameraFromAFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, scene(), [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:09:28 11:55:48",
                                             kCGImagePropertyExifSubsecTimeOriginal: "25"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "X100VI"]
        ] as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        let read = try #require(PhotoFingerprint.read(url))
        #expect(read.camera == "X100VI")
        #expect(abs(read.aspect - 320.0 / 240) < 0.02)
        let expected = PhotoFingerprint.captureDate("2026:09:28 11:55:48", subsecond: nil)!.addingTimeInterval(0.25)
        #expect(abs(try #require(read.captured).timeIntervalSince(expected)) < 0.001)
        #expect(SimilarPhotos.close(read, try print(scene())))
    }
}
