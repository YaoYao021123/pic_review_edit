import CoreGraphics
import Foundation
import Testing
@testable import MediaCore

struct ContentLabelsTests {
    let sunset = ["outdoor", "sky", "blue_sky", "cloudy", "sunset_sunrise", "sun", "water"]
    let dog = ["animal", "dog", "grass", "outdoor"]

    @Test func testChineseWordsFindLabels() {
        #expect(ContentLabels.matches(sunset, query: "日落"))
        #expect(ContentLabels.matches(sunset, query: "天空"))
        #expect(ContentLabels.matches(dog, query: "狗"))
        #expect(ContentLabels.matches(dog, query: "宠物"))
        #expect(!ContentLabels.matches(sunset, query: "狗"))
        #expect(ContentLabels.matches(sunset, query: "有日落的"), "a phrase containing a known word")
        #expect(!ContentLabels.matches(sunset, query: "城堡"))
    }

    @Test func testEnglishWordsMatchLabelWords() {
        #expect(ContentLabels.matches(sunset, query: "Sunset"))
        #expect(ContentLabels.matches(sunset, query: "sun"))
        #expect(ContentLabels.matches(sunset, query: "blue sky"))
        #expect(ContentLabels.matches(dog, query: "pet"))
        #expect(!ContentLabels.matches(dog, query: "cat"))
        #expect(!ContentLabels.matches([], query: "sky"))
        #expect(!ContentLabels.matches(sunset, query: "  "))
    }

    @Test func testTablesOnlyUseRealLabelsAndClassifyRuns() throws {
        let known = Set(try VNSupported.identifiers())
        let used = ContentLabels.chinese.values.reduce(into: Set<String>()) { $0.formUnion($1) }
            .union(ContentLabels.english.values.reduce(into: Set<String>()) { $0.formUnion($1) })
        #expect(used.subtracting(known).isEmpty, "unknown labels: \(used.subtracting(known).sorted())")
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: 0.3, green: 0.5, blue: 0.9, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        #expect(ContentLabels.classify(context.makeImage()!).count <= ContentLabels.maximumLabels)
    }
}

import Vision
enum VNSupported {
    static func identifiers() throws -> [String] { try VNClassifyImageRequest().supportedIdentifiers() }
}
