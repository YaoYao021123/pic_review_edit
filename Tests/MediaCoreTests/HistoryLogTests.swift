import Foundation
import Testing
@testable import MediaCore

struct HistoryLogTests {
    private func recipe(_ change: (inout EditRecipe) -> Void) -> EditRecipe {
        var recipe = EditRecipe()
        change(&recipe)
        return recipe
    }

    @Test func testStepsGetShortNames() {
        let base = EditRecipe()
        #expect(HistoryLog.label(from: base, to: recipe { $0.adjustments.exposure = 0.3 }) == "曝光 +0.30")
        #expect(HistoryLog.label(from: base, to: recipe { $0.adjustments.contrast = -12 }) == "对比度 -12")
        #expect(HistoryLog.label(from: base, to: recipe { $0.adjustments.contrast = 5; $0.adjustments.warmth = 5 }) == "对比度、色温")
        #expect(HistoryLog.label(from: base, to: recipe { $0.locals = [LocalAdjustment(shape: .subject)] }) == "添加主体")
        #expect(HistoryLog.label(from: base, to: recipe { $0.curves.master = [CurvePoint(x: 0, y: 0.1), CurvePoint(x: 1, y: 1)] }) == "曲线")
        #expect(HistoryLog.label(from: recipe { $0.adjustments.exposure = 1 }, to: base) == "复位全部")
        let many = recipe { $0.adjustments.exposure = 1; $0.curves.master = [CurvePoint(x: 0, y: 0.1), CurvePoint(x: 1, y: 1)]; $0.degrees = 2 }
        #expect(HistoryLog.label(from: base, to: many) == "曝光 +1.00、曲线 等")
    }

    @Test func testUndoRedoAndJumpingBackThenEditing() {
        let a = recipe { $0.adjustments.exposure = 0.3 }
        let b = recipe { $0.adjustments.exposure = 0.3; $0.adjustments.contrast = 10 }
        let c = recipe { $0.adjustments.exposure = 0.3; $0.adjustments.contrast = 10; $0.adjustments.saturation = 20 }
        var log = HistoryLog(opening: EditRecipe())
        #expect(log.label(0) == "原图")
        let added = [log.record(a), log.record(b), log.record(c)]
        #expect(added == [true, true, true])
        let again = log.record(c)
        #expect(!again, "the same state twice is one step")
        #expect(log.steps.count == 4 && log.position == 3)

        // Undo moves the marker back; redo forward.
        log.record(b, navigating: true)
        #expect(log.position == 2)
        log.record(c, navigating: true)
        #expect(log.position == 3)
        // Jumping back keeps the later steps until something new is done.
        let jumped = log.jump(to: 1)
        #expect(jumped == a && log.steps.count == 4)
        log.record(c, navigating: true)
        #expect(log.position == 3, "undoing a jump returns to where you were")
        _ = log.jump(to: 1)
        let d = recipe { $0.adjustments.exposure = 0.3; $0.adjustments.vibrance = 15 }
        log.record(d)
        #expect(log.steps.map(\.recipe) == [EditRecipe(), a, d] && log.position == 2)
        #expect(log.label(2) == "自然饱和度 +15", "named against the step it followed")
        // A normal edit that happens to equal an older state is still a new step.
        log.record(a)
        #expect(log.steps.count == 4 && log.position == 3)
    }

    @Test func testKeepsTheFirstAndLatestSteps() {
        var log = HistoryLog(opening: EditRecipe())
        for step in 1...120 { log.record(recipe { $0.adjustments.contrast = Double(step % 100) - 50 + (step > 100 ? 0.5 : 0) }) }
        #expect(log.steps.count == HistoryLog.maximumSteps)
        #expect(log.steps[0].recipe == EditRecipe())
        #expect(log.position == log.steps.count - 1)
        log.clear()
        #expect(log.steps.count == 1 && log.position == 0 && log.label(0) == "清除历史时的编辑")
    }

    @Test func testSavedHistoryBelongsToTheExactFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appendingPathComponent("a.jpg")
        try Data([1, 2, 3]).write(to: photo)
        let store = DraftStore(root: folder.appendingPathComponent("data"))
        var log = HistoryLog(opening: EditRecipe(), source: try SourceStamp(photo))
        log.record(recipe { $0.adjustments.exposure = 0.5 })
        try store.saveHistory(log)
        #expect(store.loadHistory(for: photo) == log)
        // The file changed: its old history no longer applies.
        try Data([1, 2, 3, 4]).write(to: photo)
        #expect(store.loadHistory(for: photo) == nil)
    }
}
