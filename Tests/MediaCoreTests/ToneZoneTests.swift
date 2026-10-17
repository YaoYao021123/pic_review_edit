import CoreImage
import Foundation
import Testing
@testable import MediaCore

struct ToneZoneTests {
    /// Renders a grey ramp through the real tone stage and returns the output brightness per input.
    private func rendered(_ adjustments: BasicAdjustments) throws -> [(Double, Double)] {
        let width = 64
        var pixels = [UInt8](repeating: 255, count: width * 4)
        for x in 0..<width { let v = UInt8(Double(x) / Double(width - 1) * 255); pixels[x * 4] = v; pixels[x * 4 + 1] = v; pixels[x * 4 + 2] = v }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let ramp = CGImage(width: width, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                           space: ColorPipeline.outputSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let output = try BasicColorPipeline.tone(CIImage(cgImage: ramp), adjustments: adjustments)
        var out = [UInt8](repeating: 0, count: width * 4)
        out.withUnsafeMutableBytes {
            ColorPipeline.shared.render(output, toBitmap: $0.baseAddress!, rowBytes: width * 4,
                                        bounds: CGRect(x: 0, y: 0, width: width, height: 1), format: .RGBA8, colorSpace: ColorPipeline.outputSpace)
        }
        return (0..<width).map { (Double(pixels[$0 * 4]) / 255, Double(out[$0 * 4 + 1]) / 255) }
    }

    @Test func diagramModelMatchesTheRealToneStage() throws {
        var cases: [BasicAdjustments] = []
        var a = BasicAdjustments(); a.highlights = -60; cases.append(a)
        a = BasicAdjustments(); a.shadows = 50; a.contrast = 30; cases.append(a)
        a = BasicAdjustments(); a.exposure = 0.7; a.whites = 20; a.blackPoint = 25; cases.append(a)
        for adjustments in cases {
            for (input, output) in try rendered(adjustments) {
                #expect(abs(ToneResponse.map(input, adjustments) - output) < 0.025, "input \(input) \(adjustments)")
            }
        }
    }

    @Test func eachControlActsOnItsZone() {
        #expect(ToneResponse.weight(.highlights, at: 0.85) > 0.7 && ToneResponse.weight(.highlights, at: 0.2) == 0)
        #expect(ToneResponse.weight(.shadows, at: 0.15) > 0.7 && ToneResponse.weight(.shadows, at: 0.8) == 0)
        #expect(ToneResponse.weight(.whites, at: 0.5) == 0 && ToneResponse.weight(.blackPoint, at: 0.05) > 0.8)
        #expect(ToneZone.zone(of: 0.05) == .deepShadows && ToneZone.zone(of: 0.5) == .midtones && ToneZone.zone(of: 0.97) == .brightest)
        var bins = [Double](repeating: 0, count: 20); bins[0] = 1; bins[19] = 1
        let shares = ToneZone.shares(bins)
        #expect(abs((shares[.deepShadows] ?? 0) - 0.5) < 1e-9 && abs((shares[.brightest] ?? 0) - 0.5) < 1e-9)
    }
}

struct LessonCatalogTests {
    @Test func catalogIsConsistent() {
        let ids = Lesson.catalog.map(\.id)
        #expect(Set(ids).count == ids.count)
        for lesson in Lesson.catalog {
            #expect(!lesson.steps.isEmpty && !lesson.title.isEmpty && !lesson.hook.isEmpty)
            for step in lesson.steps {
                guard let question = step.question else { continue }
                switch question.answer {
                case .option(let index): #expect(question.options.indices.contains(index), "\(lesson.id)")
                case .mainZone: #expect(question.options == ToneZone.allCases.map(\.title), "\(lesson.id)")
                }
            }
        }
        // Every scene the app draws is used by some lesson, so none is dead code.
        let used = Set(Lesson.catalog.flatMap { $0.steps.map(\.scene) })
        #expect(used == Set(LessonScene.allCases))
    }

    @Test func everyLessonEndsWithACheckQuestion() {
        for lesson in Lesson.catalog { #expect(lesson.steps.last?.question != nil, "\(lesson.id)") }
    }

    @Test func histogramLessonGoesFromPixelsToReliefToPile() throws {
        let scenes = try #require(Lesson.lesson("pixels-histogram")).steps.map(\.scene)
        #expect(scenes == [.pixelGrid, .brightnessOnly, .brightnessRelief, .histogramBuild, .histogramRead])
    }

    @Test func zoneQuestionAnswersFromThePhoto() throws {
        let question = try #require(Lesson.lesson("pixels-histogram")?.steps.last?.question)
        #expect(question.correctIndex(zoneShares: [.midtones: 0.6, .shadows: 0.3]) == 2)
        #expect(question.correctIndex(zoneShares: [.brightest: 0.5, .highlights: 0.4]) == 4)
    }
}
