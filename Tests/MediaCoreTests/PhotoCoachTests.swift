import CoreImage
import Foundation
import Testing
@testable import MediaCore

struct PhotoCoachTests {
    private func balanced() -> PhotoAnalysis {
        var a = PhotoAnalysis()
        a.p1 = 0.03; a.p5 = 0.08; a.p50 = 0.45; a.p95 = 0.9; a.p99 = 0.96
        a.meanSaturation = 0.3
        a.neutralRGB = [0.5, 0.5, 0.5]; a.neutralFraction = 0.1
        a.channelMeans = [0.45, 0.45, 0.45]
        return a
    }

    @Test func balancedPhotoHasNoUrgentTips() {
        let tips = PhotoCoach.insights(for: balanced(), edits: MediaEdits(), profile: LearnerProfile())
        #expect(tips.allSatisfy { $0.severity < 0.3 })
    }

    @Test func darkPhotoSuggestsPositiveExposure() throws {
        var a = balanced(); a.p50 = 0.15; a.p95 = 0.6; a.p99 = 0.7
        let tip = try #require(PhotoCoach.insights(for: a, edits: MediaEdits(), profile: LearnerProfile()).first { $0.id == "underexposed" })
        let ev = try #require(tip.suggestion?.deltas[.exposure])
        #expect(ev > 0.5 && ev <= 1.5)
    }

    @Test func highKeyAndNightPhotosAreNotCalledBadExposure() {
        // A latte on a white table: bright mid-tones but real blacks and no clipping.
        var highKey = balanced(); highKey.p1 = 0.02; highKey.p5 = 0.05; highKey.p50 = 0.81; highKey.p95 = 0.89; highKey.p99 = 0.9
        // A night street: dark overall, but lamps are bright.
        var night = balanced(); night.p50 = 0.15; night.p95 = 0.85
        for a in [highKey, night] {
            let ids = PhotoCoach.insights(for: a, edits: MediaEdits(), profile: LearnerProfile()).map(\.id)
            #expect(!ids.contains("overexposed") && !ids.contains("underexposed"))
        }
    }

    @Test func washedOutPhotoSuggestsModestNegativeExposure() throws {
        var a = balanced(); a.p1 = 0.3; a.p5 = 0.38; a.p50 = 0.82; a.p95 = 0.95
        let tip = try #require(PhotoCoach.insights(for: a, edits: MediaEdits(), profile: LearnerProfile()).first { $0.id == "overexposed" })
        let ev = try #require(tip.suggestion?.deltas[.exposure])
        #expect(ev < 0 && ev >= -1.0)
    }

    @Test func clippedHighlightsTeachRecoveryOrLoss() throws {
        var a = balanced(); a.clippedHighlights = 0.03; a.brightCenter = [0.5, 0.15]
        let tips = PhotoCoach.insights(for: a, edits: MediaEdits(), profile: LearnerProfile())
        let clip = try #require(tips.first { $0.id == "highlights-clipped" })
        #expect(clip.showsClipping && (clip.suggestion?.deltas[.highlights] ?? 0) < 0)
        #expect(clip.observation.contains("上方"))
        // Already pulled down hard and the source itself is clipped: explain, don't suggest.
        var pulled = MediaEdits(); pulled.adjustments.highlights = -80
        let lost = PhotoCoach.insights(for: a, original: a, edits: pulled, profile: LearnerProfile())
        #expect(lost.contains { $0.id == "highlights-lost" && $0.suggestion == nil })
    }

    @Test func skinAdviceNeedsFaces() {
        var a = balanced(); a.skinFraction = 0.3; a.skinAngle = 140
        let landscape = PhotoCoach.insights(for: a, edits: MediaEdits(), profile: LearnerProfile())
        #expect(!landscape.contains { $0.concept == .skinTone })
        var face = PhotoAnalysis(); face.skinFraction = 0.6; face.skinAngle = 112
        let portrait = PhotoCoach.insights(for: a, faces: face, edits: MediaEdits(), profile: LearnerProfile())
        let tip = portrait.first { $0.id == "skin" }
        #expect(tip?.title == "肤色偏红")
        #expect((tip?.suggestion?.hsl.first?.delta ?? 0) > 0)
    }

    @Test func logFootageComesFirstAndSuppressesToneAdvice() {
        var a = balanced(); a.meanSaturation = 0.08; a.p5 = 0.2; a.p50 = 0.25; a.p95 = 0.6
        let tips = PhotoCoach.insights(for: a, edits: MediaEdits(), profile: LearnerProfile())
        #expect(tips.first?.id == "log")
        #expect(!tips.contains { $0.id == "flat" || $0.id == "underexposed" })
        #expect(!PhotoCoach.insights(for: a, edits: MediaEdits(lut: .warm), profile: LearnerProfile()).contains { $0.id == "log" })
    }

    @Test func profileShapesRankingAndMuting() {
        var a = balanced(); a.skyFraction = 0.3; a.saturatedFraction = 0.06
        var profile = LearnerProfile(); profile.topics = [.landscape]
        #expect(PhotoCoach.insights(for: a, edits: MediaEdits(), profile: profile).first?.id == "sky")
        profile.update(.sky) { $0.muted = true }
        #expect(!PhotoCoach.insights(for: a, edits: MediaEdits(), profile: profile).contains { $0.id == "sky" })
        // Beginners get the contrast slider for flat photos; others get an S-curve.
        var flat = balanced(); flat.p5 = 0.3; flat.p95 = 0.65
        #expect(PhotoCoach.insights(for: flat, edits: MediaEdits(), profile: LearnerProfile()).first { $0.id == "flat" }?.concept == .contrast)
        var pro = LearnerProfile(); pro.level = .advanced
        #expect(PhotoCoach.insights(for: flat, edits: MediaEdits(), profile: pro).first { $0.id == "flat" }?.suggestion?.masterCurve != nil)
    }

    @Test func colorCastSuggestsOppositeWhiteBalance() throws {
        var a = balanced(); a.neutralRGB = [0.45, 0.5, 0.58]
        let tip = try #require(PhotoCoach.insights(for: a, edits: MediaEdits(), profile: LearnerProfile()).first { $0.id == "cast" })
        #expect((tip.suggestion?.deltas[.warmth] ?? 0) > 0)
        #expect(tip.title.contains("偏蓝"))
    }

    @Test func smallTiltsAreHedgedForShotsWithoutAHorizon() throws {
        let small = try #require(PhotoCoach.insights(for: balanced(), edits: MediaEdits(), profile: LearnerProfile(), tilt: 1.0)
            .first { $0.id == "tilt" })
        #expect(small.title.hasPrefix("可能") && small.severity < 0.3 && small.observation.contains("俯拍"))
        let clear = try #require(PhotoCoach.insights(for: balanced(), edits: MediaEdits(), profile: LearnerProfile(), tilt: -2.4)
            .first { $0.id == "tilt" })
        #expect(clear.title.hasPrefix("地平线倾斜") && clear.severity >= 0.5)
        #expect(!PhotoCoach.insights(for: balanced(), edits: MediaEdits(), profile: LearnerProfile(), tilt: 0.4).contains { $0.id == "tilt" })
        // Questions the user asks about a concept raise its rank like a chosen topic.
        var profile = LearnerProfile(); profile.topics = []
        profile.update(.straighten) { $0.asked = 3 }
        #expect(profile.interest(.straighten) == 1 && profile.interest(.curves) == 0)
    }

    @Test func suggestionsAddClampAndTrackUsage() {
        var edits = MediaEdits(); edits.adjustments.highlights = -90
        let suggestion = CoachSuggestion(label: "x", deltas: [.highlights: -35, .exposure: 0.3],
                                         hsl: [HSLChange(band: .blue, component: .luminance, delta: -20)])
        let next = suggestion.applied(to: edits)
        #expect(next.adjustments.highlights == -100 && abs(next.adjustments.exposure - 0.3) < 1e-9)
        #expect(next.hsl[.blue, .luminance] == -20)
        #expect(Concept.changed(from: edits, to: next) == [.highlights, .exposure, .hsl])
    }

    @Test func learnerProfilePathProgressAndPersistence() throws {
        var profile = LearnerProfile(); profile.topics = [.exposure, .scopes]
        #expect(Set(profile.path).count == profile.path.count)
        #expect(profile.path.first == .histogram)
        profile.update(.histogram) { $0.tried += 1 }
        profile.update(.exposure) { $0.used = 5 }
        #expect(profile.learnedInPath == 2)
        #expect(profile.nextConcepts.first == .highlights)
        let decoded = try JSONDecoder().decode(LearnerProfile.self, from: JSONEncoder().encode(profile))
        #expect(decoded == profile)
    }

    @Test func analysisReportsWhereTheBrightPartIs() throws {
        // Core Image y grows upward: the white half is the top of the photo.
        let top = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 50, width: 100, height: 50))
        let bottom = CIImage(color: CIColor(red: 0.05, green: 0.05, blue: 0.05)).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 50))
        let data = try #require(ScopeAnalyzer.analyze(top.composited(over: bottom)))
        let bright = try #require(data.analysis.brightCenter)
        #expect(bright[1] < 0.5)
        #expect(abs(data.analysis.brightFraction - 0.5) < 0.05)
    }

    @Test func influenceOverlayKeepsAffectedPixelsInColor() {
        func sample(_ values: [Float], _ kind: InfluenceKind) -> [Float] {
            let pixel = CIImage(bitmapData: values.withUnsafeBytes { Data($0) }, bytesPerRow: 16, size: CGSize(width: 1, height: 1),
                                format: .RGBAf, colorSpace: ColorPipeline.outputSpace)
            var out = [Float](repeating: 0, count: 4)
            out.withUnsafeMutableBytes {
                ColorPipeline.shared.render(InfluenceOverlay.visualize(pixel, kind: kind), toBitmap: $0.baseAddress!, rowBytes: 16,
                    bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: ColorPipeline.outputSpace)
            }
            return out
        }
        let brightRed = sample([0.95, 0.3, 0.3, 1], .highlights)
        #expect(brightRed[0] < 0.6) // luma is mid: partly dimmed
        let white = sample([0.97, 0.97, 0.97, 1], .highlights)
        #expect(white[0] > 0.9)
        let darkBlue = sample([0.1, 0.15, 0.6, 1], .hue(.blue))
        #expect(darkBlue[2] > 0.5 && darkBlue[0] < 0.2)
        let redInBlueMode = sample([0.8, 0.1, 0.1, 1], .hue(.blue))
        #expect(abs(redInBlueMode[0] - redInBlueMode[2]) < 0.02) // turned gray
    }
}

struct AdjustmentSectionTests {
    @Test func sectionsCoverEveryParameterExactlyOnce() {
        let all = AdjustmentSection.allCases.flatMap(\.parameters)
        #expect(all.count == AdjustmentParameter.allCases.count)
        #expect(Set(all) == Set(AdjustmentParameter.allCases))
        #expect(AdjustmentParameter.highlights.section == .tone && AdjustmentParameter.tint.section == .whiteBalance)
    }

    @Test func syncCopiesOnlyTheChosenConcepts() {
        var source = EditRecipe()
        source.adjustments.exposure = 1; source.adjustments.contrast = 30; source.adjustments.warmth = 25; source.adjustments.tint = -10
        var target = EditRecipe(); target.adjustments.exposure = -0.5; target.adjustments.contrast = -5
        let result = target.applying(from: source, sections: [.whiteBalance], includeLUT: false)
        #expect(result.adjustments.warmth == 25 && result.adjustments.tint == -10)
        #expect(result.adjustments.exposure == -0.5 && result.adjustments.contrast == -5)
    }
}

struct AutoEnhanceTests {
    private func photo(p1: Double = 0.03, p5: Double = 0.07, p50: Double = 0.46, p95: Double = 0.88, p99: Double = 0.93) -> PhotoAnalysis {
        var a = PhotoAnalysis()
        a.p1 = p1; a.p5 = p5; a.p50 = p50; a.p95 = p95; a.p99 = p99
        a.meanSaturation = 0.32; a.neutralRGB = [0.5, 0.5, 0.5]; a.neutralFraction = 0.1
        return a
    }

    @Test func wellExposedPhotoIsLeftNearlyAlone() {
        let auto = AutoEnhance.adjustments(for: photo())
        #expect(auto.exposure == 0 && auto.brightness == 0 && auto.contrast == 0 && auto.warmth == 0 && auto.vibrance == 0)
    }

    @Test func darkPhotoBrightensWithoutClippingItsHighlights() {
        let auto = AutoEnhance.adjustments(for: photo(p5: 0.03, p50: 0.18, p95: 0.6, p99: 0.85))
        #expect(auto.exposure >= 0.4 && auto.brightness > 0 && auto.shadows > 0)
        // Never more than the highlight headroom of the brightest 1%.
        #expect(auto.exposure <= log2(pow(0.97 / 0.85, 2.2)) + 0.001)
    }

    @Test func highKeyAndNightKeepTheirMood() {
        let highKey = AutoEnhance.adjustments(for: photo(p1: 0.02, p5: 0.05, p50: 0.8, p95: 0.9, p99: 0.92))
        #expect(highKey.exposure == 0 && highKey.brightness == 0)
        let night = AutoEnhance.adjustments(for: photo(p5: 0.02, p50: 0.15, p95: 0.85, p99: 0.95))
        #expect(night.exposure == 0 && night.brightness == 0)
    }

    @Test func hazyPhotoGetsDepthAndBlueCastIsWarmedHalfway() {
        var a = photo(p1: 0.2, p5: 0.28, p50: 0.55, p95: 0.78, p99: 0.84)
        a.neutralRGB = [0.42, 0.5, 0.58]
        let auto = AutoEnhance.adjustments(for: a)
        #expect(auto.contrast > 0 && auto.blackPoint > 0 && auto.whites > 0)
        #expect(auto.warmth > 5 && auto.warmth <= 20)
    }

    @Test func vividPhotoGetsNoExtraColor() {
        var a = photo(); a.meanSaturation = 0.2; a.saturatedFraction = 0.12
        #expect(AutoEnhance.adjustments(for: a).vibrance == 0)
    }
}
