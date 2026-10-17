import Foundation
import Testing
@testable import MediaCore

struct EditRecipeTests {
    @Test func groupedDragUndoesOnceAndNewEditDiscardsRedo() {
        var history = EditHistory(0)
        history.beginGroup()
        for n in 1...30 { history.record(n) }
        history.endGroup()
        #expect(history.undo() == 0)
        #expect(history.canUndo == false)
        #expect(history.redo() == 30)
        #expect(history.undo() == 0)
        history.record(5)
        #expect(history.canRedo == false)
    }
    @Test func namedSnapshotPersistsAndRefusesReplacedSource() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.jpg")
        try Data([1,2,3]).write(to: source)
        let store = DraftStore(root: folder.appendingPathComponent("store"))
        var recipe = EditRecipe(); recipe.adjustments.warmth = 25; recipe.geometry.aspectRatio = 1
        let saved = try store.saveSnapshot(recipe, name: "暖调", source: SourceStamp(source))
        #expect(store.snapshots(for: source).first?.id == saved.id)
        #expect(try store.restoreSnapshot(saved, for: source) == recipe)
        try Data([4,5,6,7]).write(to: source)
        #expect(throws: (any Error).self) { try store.restoreSnapshot(saved, for: source) }
    }
    @Test func relocatedFileKeepsEditsAndVersionsButNotForADifferentFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("moved"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("IMG_1.jpg")
        try Data([1, 2, 3]).write(to: source)
        let store = DraftStore(root: folder.appendingPathComponent("store"))
        var recipe = EditRecipe(); recipe.adjustments.exposure = 0.5
        try store.save(recipe, source: SourceStamp(source))
        try store.saveSnapshot(recipe, name: "亮一点", source: SourceStamp(source))

        // Renamed and moved in Finder: same bytes, same modification date.
        let moved = folder.appendingPathComponent("moved/海边.jpg")
        try FileManager.default.moveItem(at: source, to: moved)
        #expect(try store.relocate(from: source, to: moved) == .moved)
        #expect(try store.load(moved) == recipe)
        #expect(store.snapshots(for: moved).count == 1)
        #expect(try store.restoreSnapshot(store.snapshots(for: moved)[0], for: moved) == recipe)
        #expect(!FileManager.default.fileExists(atPath: store.location(for: source).path))
        #expect(try store.relocate(from: source, to: moved) == .nothingSaved)

        // A different picture chosen by mistake does not receive the edits.
        let other = folder.appendingPathComponent("other.jpg")
        try Data([9, 9, 9, 9]).write(to: other)
        #expect(try store.relocate(from: moved, to: other) == .differentFile)
        #expect(try store.load(other) == nil)
        #expect(try store.load(moved) == recipe)
    }

    @Test func selectiveSyncPreservesOtherParametersRangeSoundAndHDR() {
        var target = EditRecipe(); target.adjustments.exposure = -0.5; target.adjustments.warmth = -20
        target.degrees = 3; target.hdrEffect = true
        target.clip = .init(start: 2, end: 8, cover: 5, originalVolume: 0.3, speed: 2)
        var source = EditRecipe(); source.adjustments.exposure = 1; source.adjustments.warmth = 40; source.strength = 0.4
        let result = target.applying(from: source, groups: [.color], includeLUT: false)
        #expect(result.adjustments.warmth == 40 && result.adjustments.exposure == -0.5)
        #expect(result.degrees == 3 && result.clip == target.clip && result.hdrEffect)
        #expect(result.strength == target.strength)
    }
    @Test func atomicDraftRestoresRecipeAndRefusesChangedSourceOrMissingLiveCompanion() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("original.jpg"), movie = folder.appendingPathComponent("original.mov")
        try Data([1, 2, 3]).write(to: source); try Data([4, 5]).write(to: movie)
        let store = DraftStore(root: folder.appendingPathComponent("store"))
        var recipe = EditRecipe(); recipe.adjustments.exposure = 0.5; recipe.lut = try store.storeLUT(.warm)
        try store.save(recipe, source: SourceStamp(source), companion: SourceStamp(movie))
        #expect(try store.load(source) == recipe)
        let reopened = try store.loadLUT(#require(recipe.lut))
        #expect(reopened.cube.rgb == CreativeLUT.warm.cube.rgb && reopened.encoding == .sRGB)
        #expect(try Data(contentsOf: source) == Data([1,2,3]))
        try Data([1,2,3,4]).write(to: source)
        #expect(throws: (any Error).self) { try store.load(source) }
        try store.save(recipe, source: SourceStamp(source), companion: SourceStamp(movie))
        try FileManager.default.removeItem(at: movie)
        #expect(throws: (any Error).self) { try store.load(source) }
    }
}
