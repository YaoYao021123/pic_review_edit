import CryptoKit
import Foundation

public struct LUTReference: Codable, Equatable, Sendable {
    public let file: String
    public let name: String
    public let encoding: LUTEncoding
}

public struct EditRecipe: Codable, Equatable, Sendable {
    public static let currentVersion = 2
    public var version = EditRecipe.currentVersion
    public var adjustments = BasicAdjustments()
    public var degrees = 0.0
    public var geometry = GeometryAdjustments()
    public var strength = 1.0
    public var hdrEffect = false
    public var hdrPreview = true
    public var lut: LUTReference?
    public var clip: ClipSettings?
    public var wheels = ColorWheels()
    public var curves = ToneCurves()
    public var hsl = HSLAdjustments()
    public var bypass: Set<GradeStage> = []
    public var locals: [LocalAdjustment] = []
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case version, adjustments, degrees, geometry, strength, hdrEffect, hdrPreview, lut, clip, wheels, curves, hsl, bypass, locals
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        wheels = try values.decodeIfPresent(ColorWheels.self, forKey: .wheels) ?? .init()
        curves = try values.decodeIfPresent(ToneCurves.self, forKey: .curves) ?? .init()
        hsl = try values.decodeIfPresent(HSLAdjustments.self, forKey: .hsl) ?? .init()
        bypass = try values.decodeIfPresent(Set<GradeStage>.self, forKey: .bypass) ?? []
        adjustments = try values.decodeIfPresent(BasicAdjustments.self, forKey: .adjustments) ?? .init()
        geometry = try values.decodeIfPresent(GeometryAdjustments.self, forKey: .geometry) ?? .init()
        degrees = try values.decodeIfPresent(Double.self, forKey: .degrees) ?? 0
        strength = try values.decodeIfPresent(Double.self, forKey: .strength) ?? 1
        hdrEffect = try values.decodeIfPresent(Bool.self, forKey: .hdrEffect) ?? false
        hdrPreview = try values.decodeIfPresent(Bool.self, forKey: .hdrPreview) ?? true
        lut = try values.decodeIfPresent(LUTReference.self, forKey: .lut)
        clip = try values.decodeIfPresent(ClipSettings.self, forKey: .clip)
        locals = try values.decodeIfPresent([LocalAdjustment].self, forKey: .locals) ?? []
    }
    public func validate() throws {
        guard (1...Self.currentVersion).contains(version), adjustments == adjustments.sanitized, wheels.isValid, degrees.isFinite, (-10...10).contains(degrees),
              strength.isFinite, (0...1).contains(strength) else { throw VideoWorkError.failed(L("配方参数无效或版本不支持。")) }
        try geometry.validate()
        try curves.validate()
        try hsl.validate()
        guard locals.count <= LocalAdjustment.maximumLayers else { throw VideoWorkError.failed(L("局部调整的参数无效。")) }
        for layer in locals { try layer.validate() }
        if let clip { try clip.validate(duration: clip.end) }
        if let lut {
            guard lut.file.count == 69, lut.file.hasSuffix(".cube"),
                  lut.file.dropLast(5).allSatisfy({ $0.isHexDigit }) else { throw VideoWorkError.failed(L("LUT 引用无效。")) }
        }
    }
    /// Copy chosen color groups only. Geometry, sound, range and HDR remain local.
    public func applying(from source: Self, groups: Set<AdjustmentGroup>, includeLUT: Bool,
                         stages: Set<GradeStage> = []) -> Self {
        var result = self
        for p in AdjustmentParameter.allCases where groups.contains(p.group) { result.adjustments[p] = source.adjustments[p] }
        if includeLUT { result.lut = source.lut; result.strength = source.strength }
        if stages.contains(.wheels) { result.wheels = source.wheels }
        if stages.contains(.curves) { result.curves = source.curves }
        if stages.contains(.hsl) { result.hsl = source.hsl }
        result.version = Self.currentVersion
        return result
    }

    /// Sync by photographic concept (e.g. white balance only), like Lightroom's sync dialog.
    public func applying(from source: Self, sections: Set<AdjustmentSection>, includeLUT: Bool,
                         stages: Set<GradeStage> = []) -> Self {
        var result = applying(from: source, groups: [], includeLUT: includeLUT, stages: stages)
        for section in sections {
            for parameter in section.parameters { result.adjustments[parameter] = source.adjustments[parameter] }
        }
        return result
    }

    /// Everything that defines the look, without geometry, timing or sound.
    public func applyingLook(from source: Self) -> Self {
        var result = applying(from: source, groups: Set(AdjustmentGroup.allCases), includeLUT: true,
                              stages: [.wheels, .curves, .hsl])
        result.bypass = source.bypass
        return result
    }
}

public struct SourceStamp: Codable, Equatable, Sendable {
    public let path: String
    public let bytes: Int
    public let modified: Date
    public init(_ url: URL) throws {
        // URL resource values can remain cached across an external file change.
        // Read a fresh stat for every identity check, including Live companions.
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        guard values[.type] as? FileAttributeType == .typeRegular,
              let bytes = (values[.size] as? NSNumber)?.intValue, let modified = values[.modificationDate] as? Date else {
            throw VideoWorkError.failed(L("无法读取原件身份信息。"))
        }
        path = url.standardizedFileURL.path; self.bytes = bytes; self.modified = modified
    }
}

public struct DraftRecord: Codable, Sendable {
    public let source: SourceStamp
    public let companion: SourceStamp?
    public let recipe: EditRecipe
    public let savedAt: Date
}

/// Small atomic JSON recipes, with shared LUT files. Never writes to source media.
public struct DraftStore: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }
    public static func digest(_ text: String) -> String { digest(Data(text.utf8)) }
    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public func location(for source: URL) -> URL {
        root.appendingPathComponent("drafts").appendingPathComponent(Self.digest(source.standardizedFileURL.path) + ".json")
    }
    public func storeLUT(_ lut: CreativeLUT) throws -> LUTReference {
        if let cached = LUTCache.shared.reference(for: lut.id) { return cached }
        let text = lut.cube.textRepresentation()
        let file = Self.digest(text) + ".cube"
        let folder = root.appendingPathComponent("luts")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(file)
        if !FileManager.default.fileExists(atPath: target.path) { try Data(text.utf8).write(to: target, options: .atomic) }
        let reference = LUTReference(file: file, name: lut.name, encoding: lut.encoding)
        LUTCache.shared.remember(lut, as: reference)
        return reference
    }
    /// Cached: reopening files that share a LUT never re-reads or re-parses it.
    public func loadLUT(_ reference: LUTReference) throws -> CreativeLUT {
        if let cached = LUTCache.shared.lut(for: reference) { return cached }
        var recipe = EditRecipe(); recipe.lut = reference; try recipe.validate()
        let url = root.appendingPathComponent("luts").appendingPathComponent(reference.file)
        let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard bytes < 100_000_000 else { throw VideoWorkError.failed(L("保存的 LUT 过大。")) }
        let data = try Data(contentsOf: url)
        guard Self.digest(data) + ".cube" == reference.file else { throw VideoWorkError.failed(L("保存的 LUT 校验失败。")) }
        let lut = CreativeLUT(cube: try CubeLUT(data: data), name: reference.name, encoding: reference.encoding)
        LUTCache.shared.remember(lut, as: reference)
        return lut
    }
    public func save(_ recipe: EditRecipe, source: SourceStamp, companion: SourceStamp? = nil) throws {
        try recipe.validate()
        guard try SourceStamp(URL(fileURLWithPath: source.path)) == source,
              try companion.map({ try SourceStamp(URL(fileURLWithPath: $0.path)) == $0 }) ?? true else {
            throw VideoWorkError.failed(L("原件已变化，配方未自动覆盖；请重新打开素材。"))
        }
        let target = location(for: URL(fileURLWithPath: source.path))
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(DraftRecord(source: source, companion: companion, recipe: recipe, savedAt: Date())).write(to: target, options: .atomic)
    }
    public func load(_ source: URL) throws -> EditRecipe? { try loadRecord(source)?.recipe }
    public func loadRecord(_ source: URL) throws -> DraftRecord? {
        let target = location(for: source)
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        let bytes = try target.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard bytes < 1_000_000 else { throw VideoWorkError.failed(L("配方文件过大。")) }
        let record = try JSONDecoder().decode(DraftRecord.self, from: Data(contentsOf: target))
        guard record.source == (try SourceStamp(source)),
              try record.companion.map({ try SourceStamp(URL(fileURLWithPath: $0.path)) == $0 }) ?? true else {
            throw VideoWorkError.failed(L("原件或 Live 动态部分已变化，未套用旧配方。"))
        }
        try record.recipe.validate()
        return record
    }
}

extension DraftStore {
    public enum RelocateResult: Equatable, Sendable {
        /// Saved edits and named versions now follow the file at its new place.
        case moved
        /// Nothing was saved for the old place.
        case nothingSaved
        /// The chosen file isn't the one that was edited (different size or date); edits were left alone.
        case differentFile
    }

    /// Carries a file's autosaved recipe and named versions to where it was moved or renamed.
    /// The file must be the same one: equal size and modification date (a move keeps both).
    public func relocate(from old: URL, to new: URL) throws -> RelocateResult {
        let fm = FileManager.default
        // Path standardization drops a "/private" prefix (/tmp, /var) only while the file exists,
        // so a file that is gone may have been saved under either spelling.
        let path = old.standardizedFileURL.path
        let spellings = [path, path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : "/private" + path]
            .map { URL(fileURLWithPath: $0) }
        let oldURL = spellings.first { fm.fileExists(atPath: location(for: $0).path) || fm.fileExists(atPath: snapshotFolder($0).path) } ?? old
        let oldDraft = location(for: oldURL), oldSnapshots = snapshotFolder(oldURL)
        let record = (try? Data(contentsOf: oldDraft)).flatMap { try? JSONDecoder().decode(DraftRecord.self, from: $0) }
        let snapshotFiles = (try? fm.contentsOfDirectory(at: oldSnapshots, includingPropertiesForKeys: nil)) ?? []
        let snapshots = snapshotFiles.compactMap { file in
            (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(SavedSnapshot.self, from: $0) }
        }
        guard let reference = record?.source ?? snapshots.first?.record.source else { return .nothingSaved }
        let stamp = try SourceStamp(new)
        guard stamp.bytes == reference.bytes, abs(stamp.modified.timeIntervalSince(reference.modified)) < 1 else { return .differentFile }
        // A Live Photo's motion file moves with its still under the same name.
        func companion(_ old: SourceStamp?) -> SourceStamp? {
            guard let old else { return nil }
            let candidate = new.deletingLastPathComponent().appendingPathComponent(URL(fileURLWithPath: old.path).lastPathComponent)
            let renamed = new.deletingPathExtension().appendingPathExtension(URL(fileURLWithPath: old.path).pathExtension)
            return [renamed, candidate].lazy.compactMap { try? SourceStamp($0) }.first { $0.bytes == old.bytes }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let record {
            let target = location(for: new)
            if !fm.fileExists(atPath: target.path) {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try encoder.encode(DraftRecord(source: stamp, companion: companion(record.companion), recipe: record.recipe,
                                               savedAt: record.savedAt)).write(to: target, options: .atomic)
            }
            try? fm.removeItem(at: oldDraft)
        }
        if !snapshots.isEmpty {
            let folder = snapshotFolder(new)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            for snapshot in snapshots {
                let moved = SavedSnapshot(id: snapshot.id, name: snapshot.name,
                    record: DraftRecord(source: stamp, companion: companion(snapshot.record.companion),
                                        recipe: snapshot.record.recipe, savedAt: snapshot.record.savedAt))
                try JSONEncoder().encode(moved).write(to: folder.appendingPathComponent(snapshot.id.uuidString + ".json"), options: .atomic)
            }
            try? fm.removeItem(at: oldSnapshots)
        }
        return .moved
    }
}

public struct EditHistory<Value: Equatable & Sendable>: Sendable {
    public private(set) var current: Value
    private var past: [Value] = []
    private var future: [Value] = []
    private var groupStart: Value?
    public init(_ value: Value) { current = value }
    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }
    public mutating func beginGroup() { if groupStart == nil { groupStart = current } }
    public mutating func endGroup() {
        if let before = groupStart, before != current { appendPast(before); future = [] }
        groupStart = nil
    }
    public mutating func record(_ value: Value) {
        guard value != current else { return }
        if groupStart == nil { appendPast(current); future = [] }
        current = value
    }
    private mutating func appendPast(_ value: Value) {
        past.append(value); if past.count > 100 { past.removeFirst(past.count - 100) }
    }
    public mutating func undo() -> Value? {
        endGroup(); guard let previous = past.popLast() else { return nil }
        future.append(current); current = previous; return previous
    }
    public mutating func redo() -> Value? {
        guard let next = future.popLast() else { return nil }
        past.append(current); current = next; return next
    }
}

public struct SavedSnapshot: Codable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let record: DraftRecord
}

extension DraftStore {
    func snapshotFolder(_ source: URL) -> URL { root.appendingPathComponent("snapshots").appendingPathComponent(Self.digest(source.standardizedFileURL.path)) }
    @discardableResult public func saveSnapshot(_ recipe: EditRecipe, name: String, source: SourceStamp,
                                               companion: SourceStamp? = nil) throws -> SavedSnapshot {
        // The same identity checks as autosave apply to named versions.
        try save(recipe, source: source, companion: companion)
        let value = SavedSnapshot(id: UUID(), name: String(name.prefix(100)),
            record: DraftRecord(source: source, companion: companion, recipe: recipe, savedAt: Date()))
        let folder = snapshotFolder(URL(fileURLWithPath: source.path))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: folder.appendingPathComponent(value.id.uuidString + ".json"), options: .atomic)
        return value
    }
    public func snapshots(for source: URL) -> [SavedSnapshot] {
        let folder = snapshotFolder(source)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.compactMap { file in
            guard file.pathExtension == "json", (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 1_000_001 <= 1_000_000,
                  let data = try? Data(contentsOf: file), let value = try? JSONDecoder().decode(SavedSnapshot.self, from: data) else { return nil }
            return value
        }.sorted { $0.record.savedAt > $1.record.savedAt }.prefix(50).map { $0 }
    }
    public func restoreSnapshot(_ snapshot: SavedSnapshot, for source: URL) throws -> EditRecipe {
        guard try SourceStamp(source) == snapshot.record.source,
              try snapshot.record.companion.map({ try SourceStamp(URL(fileURLWithPath: $0.path)) == $0 }) ?? true else {
            throw VideoWorkError.failed(L("原件或 Live 动态部分已变化，未恢复快照。"))
        }
        try snapshot.record.recipe.validate()
        return snapshot.record.recipe
    }
}

/// Process-wide LUT cache keyed by stored file and declared encoding.
/// The same reference always yields the same `CreativeLUT` identity.
public final class LUTCache: @unchecked Sendable {
    public static let shared = LUTCache()
    private let lock = NSLock()
    private var luts: [String: CreativeLUT] = [:]
    private var references: [UUID: LUTReference] = [:]
    private var order: [String] = []

    private func key(_ reference: LUTReference) -> String { reference.file + "|" + reference.encoding.rawValue }

    public func lut(for reference: LUTReference) -> CreativeLUT? {
        lock.lock(); defer { lock.unlock() }
        return luts[key(reference)]
    }
    public func reference(for id: UUID) -> LUTReference? {
        lock.lock(); defer { lock.unlock() }
        return references[id]
    }
    public func remember(_ lut: CreativeLUT, as reference: LUTReference) {
        lock.lock(); defer { lock.unlock() }
        let key = key(reference)
        if luts[key] == nil { order.append(key) }
        luts[key] = lut
        references[lut.id] = reference
        // A 65³ table is ~4 MB; keep a bounded working set.
        while order.count > 24 {
            let evicted = order.removeFirst()
            if let old = luts.removeValue(forKey: evicted) { references.removeValue(forKey: old.id) }
        }
    }
}

// MARK: - Presets (cross-file looks, like Lightroom presets / Resolve PowerGrades)

public struct GradePreset: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var recipe: EditRecipe
    public var createdAt: Date
    public var builtIn: Bool
    public init(id: UUID = UUID(), name: String, recipe: EditRecipe, createdAt: Date = Date(), builtIn: Bool = false) {
        self.id = id; self.name = name; self.recipe = recipe; self.createdAt = createdAt; self.builtIn = builtIn
    }

    public static let builtIns: [GradePreset] = {
        func preset(_ id: String, _ name: String, _ configure: (inout EditRecipe) -> Void) -> GradePreset {
            var recipe = EditRecipe(); configure(&recipe)
            return GradePreset(id: UUID(uuidString: id)!, name: name, recipe: recipe, createdAt: .distantPast, builtIn: true)
        }
        return [
            preset("6C1D0001-0000-4000-8000-000000000001", L("自然增强")) {
                $0.adjustments.vibrance = 25; $0.adjustments.contrast = 10; $0.adjustments.shadows = 15
                $0.adjustments.highlights = -15; $0.adjustments.definition = 15
            },
            preset("6C1D0001-0000-4000-8000-000000000002", L("青橙电影")) {
                $0.adjustments.contrast = 15; $0.adjustments.saturation = -5
                $0.wheels.lift = WheelValue(x: 0.35, y: -0.25, master: 0)
                $0.wheels.gain = WheelValue(x: -0.3, y: 0.25, master: 0)
                $0.hsl[.orange, .saturation] = 12; $0.hsl[.blue, .hue] = -15
            },
            preset("6C1D0001-0000-4000-8000-000000000003", L("柔和胶片")) {
                $0.curves.master = [CurvePoint(x: 0, y: 0.06), CurvePoint(x: 0.25, y: 0.24),
                                    CurvePoint(x: 0.75, y: 0.78), CurvePoint(x: 1, y: 0.95)]
                $0.adjustments.saturation = -12; $0.adjustments.warmth = 8
            },
            preset("6C1D0001-0000-4000-8000-000000000004", L("黑白")) {
                $0.adjustments.saturation = -100; $0.adjustments.contrast = 20; $0.adjustments.definition = 20
            }
        ]
    }()
}

extension DraftStore {
    private var presetFolder: URL { root.appendingPathComponent("presets") }

    public func presets() -> [GradePreset] {
        let files = (try? FileManager.default.contentsOfDirectory(at: presetFolder, includingPropertiesForKeys: nil)) ?? []
        let saved = files.compactMap { file -> GradePreset? in
            guard file.pathExtension == "json", let data = try? Data(contentsOf: file),
                  let preset = try? JSONDecoder().decode(GradePreset.self, from: data),
                  (try? preset.recipe.validate()) != nil else { return nil }
            return preset
        }.sorted { $0.createdAt < $1.createdAt }
        return GradePreset.builtIns + saved
    }

    public func savePreset(_ preset: GradePreset) throws {
        try preset.recipe.validate()
        try FileManager.default.createDirectory(at: presetFolder, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(preset).write(to: presetFolder.appendingPathComponent(preset.id.uuidString + ".json"), options: .atomic)
    }

    public func deletePreset(_ preset: GradePreset) throws {
        guard !preset.builtIn else { return }
        let file = presetFolder.appendingPathComponent(preset.id.uuidString + ".json")
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }

    /// Imported LUTs, remembered across launches.
    private var lutIndex: URL { root.appendingPathComponent("luts").appendingPathComponent("index.json") }
    public func importedLUTs() -> [LUTReference] {
        guard let data = try? Data(contentsOf: lutIndex),
              let list = try? JSONDecoder().decode([LUTReference].self, from: data) else { return [] }
        return list.filter { FileManager.default.fileExists(atPath: root.appendingPathComponent("luts").appendingPathComponent($0.file).path) }
    }
    public func rememberImportedLUT(_ reference: LUTReference) throws {
        var list = importedLUTs().filter { $0.file != reference.file }
        list.insert(reference, at: 0)
        try FileManager.default.createDirectory(at: lutIndex.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Array(list.prefix(40))).write(to: lutIndex, options: .atomic)
    }
}
