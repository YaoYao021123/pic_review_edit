import Foundation

/// One settled state of a photo's edits. Its name is worked out when shown (`HistoryLog.label`),
/// so it follows the interface language.
public struct HistoryStep: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var date: Date
    public var recipe: EditRecipe
    public init(date: Date, recipe: EditRecipe) { self.date = date; self.recipe = recipe }
}

/// The edit history of one file, kept on disk so it survives quitting (Lightroom's History
/// panel). Undo and redo move the current step; a new edit after going back drops the steps
/// that came after it.
public struct HistoryLog: Codable, Equatable, Sendable {
    public static let maximumSteps = 80
    /// How the first step came about.
    public enum Start: String, Codable, Sendable { case opened, cleared }
    public var source: SourceStamp?
    /// Set for a photo's version inside a project, so each version keeps its own history.
    public var variant: String?
    public private(set) var steps: [HistoryStep]
    public private(set) var position: Int
    public private(set) var start = Start.opened

    public init(opening recipe: EditRecipe, source: SourceStamp? = nil, date: Date = Date()) {
        self.source = source
        steps = [HistoryStep(date: date, recipe: recipe)]
        position = 0
    }

    public var current: HistoryStep { steps[position] }

    /// The name of a step: what changed from the step before it.
    public func label(_ index: Int) -> String {
        guard steps.indices.contains(index) else { return "" }
        guard index > 0 else {
            return steps[0].recipe.isUnedited ? L("原图") : start == .cleared ? L("清除历史时的编辑") : L("打开时的编辑")
        }
        return Self.label(from: steps[index - 1].recipe, to: steps[index].recipe)
    }

    /// Notes a settled state. `navigating` is set after undo or redo: the state is then looked
    /// for among the steps (nearest first) instead of becoming a new one. Returns true when the
    /// log changed.
    @discardableResult
    public mutating func record(_ recipe: EditRecipe, navigating: Bool = false, date: Date = Date()) -> Bool {
        if recipe == steps[position].recipe { return false }
        if navigating, let match = steps.indices.filter({ steps[$0].recipe == recipe }).min(by: { abs($0 - position) < abs($1 - position) }) {
            position = match
            return true
        }
        steps.removeSubrange((position + 1)...)
        steps.append(HistoryStep(date: date, recipe: recipe))
        // Keep the first step (how the file was opened) and the most recent ones.
        if steps.count > Self.maximumSteps { steps.removeSubrange(1...(steps.count - Self.maximumSteps)) }
        position = steps.count - 1
        return true
    }

    /// Moves to a step and returns its recipe.
    public mutating func jump(to index: Int) -> EditRecipe? {
        guard steps.indices.contains(index) else { return nil }
        position = index
        return steps[index].recipe
    }

    /// Forgets every step but the current one.
    public mutating func clear() {
        steps = [steps[position]]
        position = 0
        start = .cleared
    }

    /// What changed between two recipes, in a few words.
    public static func label(from old: EditRecipe, to new: EditRecipe) -> String {
        if new.isUnedited { return L("复位全部") }
        var parts: [String] = []
        let changed = AdjustmentParameter.allCases.filter { old.adjustments[$0] != new.adjustments[$0] }
        if changed.count == 1, let p = changed.first {
            let value = new.adjustments[p]
            parts.append(p == .exposure ? String(format: "%@ %+.2f", p.title, value) : String(format: "%@ %+.0f", p.title, value))
        } else if changed.count == 2 {
            parts.append(changed.map(\.title).joined(separator: L("、")))
        } else if changed.count > 2 {
            parts.append(L("基础调整 \(changed.count) 项"))
        }
        if old.wheels != new.wheels { parts.append(L("色轮")) }
        if old.curves != new.curves { parts.append(L("曲线")) }
        if old.hsl != new.hsl { parts.append("HSL") }
        if old.lut != new.lut {
            parts.append(new.lut.map { L("LUT：\($0.name)") } ?? L("移除 LUT"))
        } else if old.strength != new.strength {
            parts.append(L("LUT 强度 \(Int((new.strength * 100).rounded()))%"))
        }
        if old.degrees != new.degrees || old.geometry != new.geometry { parts.append(L("裁剪与拉直")) }
        if old.locals != new.locals {
            if new.locals.count > old.locals.count, let added = new.locals.last {
                parts.append(L("添加\(added.shape.title)"))
            } else if new.locals.count < old.locals.count {
                parts.append(L("删除局部调整"))
            } else {
                parts.append(L("局部调整"))
            }
        }
        if old.bypass != new.bypass { parts.append(L("开关调整")) }
        if old.clip != new.clip { parts.append(L("视频片段")) }
        if old.hdrEffect != new.hdrEffect || old.hdrPreview != new.hdrPreview { parts.append("HDR") }
        if parts.isEmpty { return L("修改") }
        return parts.count > 2 ? parts.prefix(2).joined(separator: L("、")) + L(" 等") : parts.joined(separator: L("、"))
    }
}

extension EditRecipe {
    /// No edits at all (the version number aside).
    public var isUnedited: Bool {
        var plain = EditRecipe()
        plain.version = version
        plain.clip = clip
        return self == plain
    }
}

extension DraftStore {
    func historyLocation(for source: URL, variant: String? = nil) -> URL {
        let key = source.standardizedFileURL.path + (variant.map { "#" + $0 } ?? "")
        return root.appendingPathComponent("history").appendingPathComponent(Self.digest(key) + ".json")
    }

    /// The saved history, if it belongs to this exact file (same size and date).
    public func loadHistory(for source: URL, variant: String? = nil) -> HistoryLog? {
        let file = historyLocation(for: source, variant: variant)
        guard let bytes = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes < 16_000_000,
              let data = try? Data(contentsOf: file), let log = try? JSONDecoder().decode(HistoryLog.self, from: data),
              !log.steps.isEmpty, log.steps.indices.contains(log.position),
              log.variant == variant, let stamp = log.source, (try? SourceStamp(source)) == stamp else { return nil }
        return log
    }

    public func saveHistory(_ log: HistoryLog) throws {
        guard let stamp = log.source else { return }
        let file = historyLocation(for: URL(fileURLWithPath: stamp.path), variant: log.variant)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(log).write(to: file, options: .atomic)
    }
}
