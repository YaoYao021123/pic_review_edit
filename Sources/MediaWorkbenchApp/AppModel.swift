import AppKit
import Foundation
import MediaCore
import Observation
import UniformTypeIdentifiers

enum ColorMode: String, CaseIterable {
    case simple, full
    var title: String { self == .simple ? L("简单") : L("完整") }
}

enum WorkspaceMode: String, CaseIterable, Sendable {
    case browse, edit
}

enum ExportTarget: String, Sendable {
    case current, selection
}

enum ActiveSheet: Identifiable {
    case export(ExportTarget)
    case sync
    case snapshots
    case collage
    case savePreset
    case shortcuts
    case tutorSettings
    case livePreview(LivePhotoResources)
    case lesson(String)
    case matchLook
    case compare([String])
    case photosImport
    case newProject([String])
    case renameProject(UUID)

    var id: String {
        switch self {
        case .export(let target): "export-\(target.rawValue)"
        case .sync: "sync"
        case .snapshots: "snapshots"
        case .collage: "collage"
        case .savePreset: "preset"
        case .shortcuts: "shortcuts"
        case .tutorSettings: "tutor"
        case .livePreview(let resources): "live-\(resources.identifier)"
        case .lesson(let id): "lesson-\(id)"
        case .matchLook: "match-look"
        case .newProject: "new-project"
        case .renameProject(let id): "rename-project-\(id)"
        case .photosImport: "photos-import"
        case .compare(let ids): "compare-\(ids.joined(separator: "|").hashValue)"
        }
    }
}

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct Toast: Identifiable {
    struct Action: Identifiable {
        let id = UUID()
        let title: String
        let perform: @MainActor () -> Void
    }
    let id = UUID()
    let message: String
    var actions: [Action] = []
}

enum ExportDestination: String, Codable, CaseIterable {
    case photos, folder
    var title: String { self == .photos ? L("「照片」") : L("文件夹") }
}

struct ExportSettings: Codable, Equatable {
    var image = ImageExportOptions()
    var codec = VideoCodecChoice.h264
    var liveOnly = false
    /// Casual users want results in Photos (and on their phone), not in a folder.
    var destination = ExportDestination.photos
    /// File-name pattern, see ExportNaming.
    var naming = ExportNaming.defaultPattern

    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        image = try values.decodeIfPresent(ImageExportOptions.self, forKey: .image) ?? .init()
        codec = try values.decodeIfPresent(VideoCodecChoice.self, forKey: .codec) ?? .h264
        liveOnly = try values.decodeIfPresent(Bool.self, forKey: .liveOnly) ?? false
        destination = try values.decodeIfPresent(ExportDestination.self, forKey: .destination) ?? .photos
        naming = try values.decodeIfPresent(String.self, forKey: .naming) ?? ExportNaming.defaultPattern
    }
}

enum AppPaths {
    /// `GUANGJI_DATA_DIR` keeps development runs away from the user's library.
    static var dataRoot: URL {
        if let custom = ProcessInfo.processInfo.environment["GUANGJI_DATA_DIR"] { return URL(fileURLWithPath: custom, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Guangji")
    }
}

/// Coordinates the library, the open editor and background exports.
@MainActor
@Observable
final class AppModel {
    let drafts: DraftStore
    let library: LibraryModel
    let thumbnails: ThumbnailStore
    let editor: EditorModel
    let similar: SimilarityIndex
    let content: ContentIndex
    /// Projects: photos gathered for one job, each project with one shared look.
    var projects: [Project] = []
    /// The project the library shows; nil for the whole library.
    var currentProjectID: UUID? {
        didSet { if currentProjectID != oldValue { projectScopeChanged() } }
    }
    /// While editing inside a project: slider changes stay with this photo instead of going to the shared look.
    var projectPhotoOnly = false {
        // Edits made so far still belong where they were made.
        willSet { if newValue != projectPhotoOnly { editor.flushDraft() } }
    }
    @ObservationIgnored let projectStore: ProjectStore
    @ObservationIgnored var projectSaveTask: Task<Void, Never>?
    /// Browse view shows only groups of similar shots and bursts.
    var showGroups = false {
        didSet { if showGroups { similar.refresh(library.entries, missing: library.missing) } }
    }
    let exports: ExportQueue
    let tutor = TutorModel()

    var mode = WorkspaceMode.browse
    var showSidebar = true
    var showInspector = true
    var inspectorTab = InspectorTab(rawValue: UserDefaults.standard.string(forKey: "inspector.tab") ?? "") ?? .color {
        didSet { UserDefaults.standard.set(inspectorTab.rawValue, forKey: "inspector.tab") }
    }
    var sheet: ActiveSheet?
    var alert: AppAlert?
    private(set) var toast: Toast?
    private(set) var presets: [GradePreset] = []
    private(set) var lutLibrary: [LUTReference] = []
    private(set) var hasClipboard = false
    private(set) var lastBatch: [BatchChange] = []
    private(set) var isImporting = false
    var collageDrafts: [CollageDraftPane] = []
    var exportSettings: ExportSettings {
        didSet { if let data = try? JSONEncoder().encode(exportSettings) { UserDefaults.standard.set(data, forKey: "guangji.export") } }
    }
    /// Export presets the user saved (built-in ones are in ExportPreset.builtIns).
    var exportPresets = ExportPresetStore.load() {
        didSet { ExportPresetStore.save(exportPresets) }
    }

    /// What this user knows and wants to learn; drives the coach.
    var learner = LearnerProfile() { didSet { if learner != oldValue { scheduleLearnerSave() } } }
    /// 简单 shows a few plain controls; 完整 shows every grading stage. Beginners start simple.
    var colorMode = ColorMode.simple { didSet { UserDefaults.standard.set(colorMode.rawValue, forKey: "color.mode") } }
    @ObservationIgnored private var learnerSave: Task<Void, Never>?
    @ObservationIgnored private let learnerFile: URL
    @ObservationIgnored private var clipboard: (EditRecipe, CreativeLUT?)?
    @ObservationIgnored private var panelOpen = false
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    /// Export jobs whose result opens the share sheet.
    @ObservationIgnored private var shareJobs: Set<UUID> = []

    /// The single app model, for the app delegate (quit confirmation).
    nonisolated(unsafe) static weak var current: AppModel?

    init() {
        let root = AppPaths.dataRoot
        learnerFile = root.appendingPathComponent("learning.json")
        drafts = DraftStore(root: root)
        library = LibraryModel(root: root)
        thumbnails = ThumbnailStore(drafts: drafts)
        editor = EditorModel(drafts: drafts)
        similar = SimilarityIndex(root: root)
        content = ContentIndex(root: root)
        projectStore = ProjectStore(root: root)
        projects = projectStore.load()
        exports = ExportQueue()
        if let data = UserDefaults.standard.data(forKey: "guangji.export"),
           let settings = try? JSONDecoder().decode(ExportSettings.self, from: data) {
            exportSettings = settings
        } else {
            exportSettings = ExportSettings()
        }
        presets = drafts.presets()
        lutLibrary = drafts.importedLUTs()
        if let data = try? Data(contentsOf: learnerFile), let profile = try? JSONDecoder().decode(LearnerProfile.self, from: data) {
            learner = profile
        }
        colorMode = ColorMode(rawValue: UserDefaults.standard.string(forKey: "color.mode") ?? "")
            ?? (learner.level == .beginner ? .simple : .full)
        editor.onConceptsUsed = { [weak self] concepts in
            for concept in concepts { self?.learner.update(concept) { $0.used += 1 } }
        }
        editor.onNotice = { [weak self] notice in self?.alert = AppAlert(title: notice.title, message: notice.message) }
        editor.onRecipeSaved = { [weak self] url in self?.thumbnails.invalidate(url.standardizedFileURL.path) }
        editor.onOpenFailed = { [weak self] url, missing in self?.library.markMissing(url.standardizedFileURL.path, missing) }
        // Files can be moved or renamed in Finder while the app is in the background.
        Task { [weak self] in await self?.library.checkMissing() }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { Task { await self?.library.checkMissing() } }
        }
        exports.onFinish = { [weak self] job in self?.exportFinished(job) }
        editor.onProjectSave = { [weak self] project, url, recipe, previous in
            self?.storeProjectEdit(project, url: url, recipe: recipe, previous: previous)
        }
        library.contentLabels = content.labels
        content.onChange = { [weak self] labels in self?.library.contentLabels = labels }
        Self.current = self
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                                     object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.editor.flushDraft()
                self?.library.saveNow()
                self?.saveProjectsNow()
            }
        }
    }

    var currentEntry: LibraryEntry? { library.entry(library.currentID) }

    /// The library search box: file names, and what photos show (labelled on first use).
    func search(_ text: String) {
        library.filter.search = text
        if !text.trimmingCharacters(in: .whitespaces).isEmpty { content.refresh(library.entries, missing: library.missing) }
    }

    // MARK: Messages

    func show(_ message: String, actions: [Toast.Action] = [], seconds: Double = 5) {
        toast = Toast(message: message, actions: actions)
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    func dismissToast() { toastTask?.cancel(); toast = nil }

    func fail(_ title: String, _ error: Error) {
        alert = AppAlert(title: title, message: error.localizedDescription)
    }

    // MARK: Panels

    /// Window-attached panels; repeated clicks while one is open are ignored.
    func present(_ panel: NSSavePanel, completion: @escaping @MainActor ([URL]) -> Void) {
        guard !panelOpen else { return }
        panelOpen = true
        NSApplication.shared.activate()
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self, panel] response in
            self?.panelOpen = false
            guard response == .OK else { return }
            if let open = panel as? NSOpenPanel { completion(open.urls) } else if let url = panel.url { completion([url]) }
        }
        if let window = NSApplication.shared.mainWindow ?? NSApplication.shared.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

    // MARK: Library

    func importMedia(folders: Bool = false) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = !folders
        panel.allowedContentTypes = folders ? [] : [.image, .movie, .mpeg4Movie, .quickTimeMovie]
        // Third-party players can register nonconforming types for standard video extensions.
        panel.allowsOtherFileTypes = true
        panel.message = folders ? L("选择包含照片或视频的文件夹") : L("选择照片、视频或文件夹")
        present(panel) { [weak self] urls in self?.importURLs(urls) }
    }

    func importURLs(_ urls: [URL]) {
        guard !urls.isEmpty, !isImporting else { return }
        isImporting = true
        Task {
            defer { isImporting = false }
            do {
                let collected = try await Task.detached(priority: .userInitiated) { try LibraryFiles.collect(urls) }.value
                guard !collected.files.isEmpty else { show(L("没有找到支持的照片或视频。")); return }
                let ids = library.add(collected.files, liveCompanions: collected.liveStills)
                // Imported while a project is open: they join it.
                if let project = currentProjectID { addToProject(ids, projectID: project) }
                if collected.files.count == 1, let id = ids.first {
                    open(id)
                } else {
                    library.filter = LibraryFilter()
                    if let first = ids.first { library.select(first) }
                    mode = .browse
                    show(L("已添加 \(collected.files.count) 项") + (collected.truncated ? L("（已达上限，仅读取部分）") : "") + L("。按 ↑↓←→ 浏览，⏎ 进入编辑。"))
                }
            } catch { fail(L("导入失败"), error) }
        }
    }

    func open(_ id: String) {
        guard let entry = library.entry(id) else { return }
        if id != library.currentID { tutor.reset() }
        library.currentID = id
        if !library.selection.contains(id) || library.selection.count > 1 { library.select(id) }
        mode = .edit
        editor.open(entry.url, project: editContext(for: id))
    }

    func openSelection() {
        let id = library.anchorID.flatMap { library.selection.contains($0) ? $0 : nil } ?? library.selection.first
        if let id { open(id) }
    }

    /// ↑/↓ in the editor, arrows in the grid.
    func step(_ offset: Int) {
        switch mode {
        case .edit:
            if let next = library.neighbor(of: library.currentID, offset: offset), next != library.currentID { open(next) }
        case .browse:
            let anchor = library.anchorID ?? library.selection.first
            if let next = library.neighbor(of: anchor, offset: offset) { library.select(next) }
        }
    }

    var ratingTargets: [String] {
        mode == .browse ? Array(library.selection) : library.currentID.map { [$0] } ?? []
    }

    func rate(_ rating: Int) {
        let ids = ratingTargets
        guard !ids.isEmpty else { return }
        library.setRating(rating, for: ids)
        editor.status = rating == 0 ? L("已清除评级") : L("评级 ") + String(repeating: "★", count: rating)
    }

    func flag(_ flag: LibraryFlag) {
        let ids = ratingTargets
        guard !ids.isEmpty else { return }
        library.setFlag(flag, for: ids)
        editor.status = flag == .pick ? L("已选用") : flag == .reject ? L("已排除") : L("已取消标记")
    }

    func removeSelectionFromLibrary() {
        let ids = library.selection
        guard !ids.isEmpty else { return }
        if let current = library.currentID, ids.contains(current) { editor.close(); mode = .browse }
        library.remove(ids)
        show(L("已从素材库移除 \(ids.count) 项；原文件未改动。"))
    }

    /// ⌘A: every item currently listed (respects the search and filter).
    func selectAll() {
        guard !library.visible.isEmpty else { return }
        if mode == .edit { mode = .browse }
        library.selectAll()
        show(L("已选中 \(library.selection.count) 项。"), seconds: 2)
    }

    /// Empties the library list only. Original files, Photos and saved edits stay where they are.
    func clearLibrary() {
        let ids = Set(library.entries.map(\.id))
        guard !ids.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = L("清空素材库？")
        alert.informativeText = L("将从光集移除全部 \(ids.count) 项。原文件、「照片」里的图片和已保存的编辑都不会被删除，之后可以重新添加。")
        alert.addButton(withTitle: L("清空"))
        alert.addButton(withTitle: L("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        editor.close()
        mode = .browse
        library.filter = LibraryFilter()
        library.remove(ids)
        show(L("素材库已清空；原文件未改动。"))
    }

    func removeFromLibrary(_ id: String) {
        library.select(id)
        removeSelectionFromLibrary()
    }

    /// Lightroom-style "find missing file": the user points at the moved file; its rating,
    /// edits and versions follow, and other missing items from the same folder are found too.
    func relocate(_ id: String) {
        guard let entry = library.entry(id) else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image, .movie]
        panel.message = L("找到「\(entry.name)」现在的位置（它可能被移动或重命名了）")
        panel.prompt = L("选择")
        var folder = entry.url.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: folder.path), folder.pathComponents.count > 1 { folder.deleteLastPathComponent() }
        panel.directoryURL = folder
        present(panel) { [weak self] urls in
            if let url = urls.first { self?.relocate(id, to: url) }
        }
    }

    func relocate(_ id: String, to url: URL) {
        guard let entry = library.entry(id) else { return }
        let reopen = library.currentID == id
        let result = (try? drafts.relocate(from: entry.url, to: url)) ?? .nothingSaved
        guard let newID = library.relink(id, to: url) else { return }
        thumbnails.invalidate(newID)
        // Whole folders usually move together: look for the other missing items next to the chosen file.
        let oldFolder = entry.url.deletingLastPathComponent().standardizedFileURL.path
        var found = 0
        for other in library.entries where library.missing.contains(other.id)
            && other.url.deletingLastPathComponent().standardizedFileURL.path == oldFolder {
            let candidate = url.deletingLastPathComponent().appendingPathComponent(other.name)
            guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
            _ = try? drafts.relocate(from: other.url, to: candidate)
            if let moved = library.relink(other.id, to: candidate) { thumbnails.invalidate(moved); found += 1 }
        }
        if reopen { open(newID) }
        var message = result == .differentFile
            ? L("已重新关联。这和之前编辑的不是同一个文件，旧的编辑没有套用。")
            : L("已找到「\(url.lastPathComponent)」\(result == .moved ? L("，编辑和版本都已保留") : "")。")
        if found > 0 { message += L("同一文件夹里另外 \(found) 项也一并找回。") }
        show(message)
    }

    func revealSelection() {
        let urls = library.actionTargets.map(\.url)
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    // MARK: LUTs and presets

    func importLUT() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .plainText]
        panel.message = L("选择 .cube 创意 LUT")
        present(panel) { [weak self] urls in
            guard let self, let url = urls.first else { return }
            let drafts = self.drafts
            Task {
                do {
                    let lut = try await Task.detached(priority: .userInitiated) { () -> CreativeLUT in
                        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
                        guard size <= 100_000_000 else { throw VideoWorkError.failed(L("LUT 超过 100 MB")) }
                        let cube = try CubeLUT(data: Data(contentsOf: url))
                        let lut = CreativeLUT(cube: cube, name: cube.title ?? url.deletingPathExtension().lastPathComponent)
                        let reference = try drafts.storeLUT(lut)
                        try drafts.rememberImportedLUT(reference)
                        return lut
                    }.value
                    self.lutLibrary = drafts.importedLUTs()
                    self.editor.selectLUT(lut)
                    self.show(L("已导入 \(lut.name)。相机 Log 素材请先套用对应的转换 LUT。"))
                } catch { self.fail(L("无法导入 LUT"), error) }
            }
        }
    }

    func selectLUT(_ reference: LUTReference) {
        let drafts = self.drafts
        Task {
            do {
                let lut = try await Task.detached(priority: .userInitiated) { try drafts.loadLUT(reference) }.value
                editor.selectLUT(lut)
            } catch { fail(L("无法载入 LUT"), error) }
        }
    }

    func setLUTEncoding(_ encoding: LUTEncoding) {
        guard let lut = editor.selectedLUT, !lut.isBuiltIn, lut.encoding != encoding else { return }
        let drafts = self.drafts
        Task {
            do {
                let next = lut.with(encoding: encoding)
                let reference = try await Task.detached(priority: .userInitiated) { try drafts.storeLUT(next) }.value
                try drafts.rememberImportedLUT(reference)
                lutLibrary = drafts.importedLUTs()
                editor.selectLUT(next)
            } catch { fail(L("无法切换 LUT 色彩空间"), error) }
        }
    }

    func openLesson(_ id: String) { sheet = .lesson(id) }

    /// A finished lesson counts as having tried its concept, so the learning path ticks it.
    func completeLesson(_ lesson: Lesson) {
        learner.lessonsDone.insert(lesson.id)
        if let concept = lesson.concept { learner.update(concept) { $0.tried += 1 } }
        show(L("完成「\(lesson.title)」。"), seconds: 3)
    }

    func autoEnhance() {
        guard editor.isLoaded else { return }
        let simple = colorMode == .simple
        var result: String?
        // Auto fixes this photo; in a project it must not move everyone's look.
        onlyThisPhoto {
            result = editor.applyAuto(title: { parameter in
                simple ? SimpleControl.all.first { $0.parameter == parameter }?.title ?? parameter.title : parameter.title
            })
        }
        guard let summary = result else { show(L("正在分析画面，请稍后再试。"), seconds: 2); return }
        show(summary, actions: [
            .init(title: L("对比")) { [weak self] in self?.editor.compareMode = self?.editor.isVideo == true ? .original : .split },
            .init(title: L("撤销")) { [weak self] in self?.editor.undo() }
        ])
    }

    func applyPreset(_ preset: GradePreset) {
        guard editor.isLoaded else { return }
        let drafts = self.drafts
        Task {
            do {
                let lut = try await Task.detached { try preset.recipe.lut.map { try drafts.loadLUT($0) } }.value
                editor.applyLook(preset.recipe, lut: lut, name: L("预设「\(preset.name)」"))
            } catch { fail(L("无法应用预设"), error) }
        }
    }

    func savePreset(named name: String) {
        do {
            var recipe = EditRecipe().applyingLook(from: try editor.currentRecipe())
            recipe.hdrPreview = true
            let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
            try drafts.savePreset(GradePreset(name: title.isEmpty ? L("我的预设") : String(title.prefix(40)), recipe: recipe))
            presets = drafts.presets()
            show(L("已存为预设，可在任意照片或视频上一键套用。"))
        } catch { fail(L("预设未保存"), error) }
    }

    func deletePreset(_ preset: GradePreset) {
        do { try drafts.deletePreset(preset); presets = drafts.presets() } catch { fail(L("无法删除预设"), error) }
    }

    // MARK: Copy / paste / sync

    func copySettings() {
        guard editor.isLoaded else { return }
        do {
            clipboard = (try editor.currentRecipe(), editor.selectedLUT)
            hasClipboard = true
            show(L("已拷贝调色设置（不含裁切、片段与声音）。⇧⌘V 粘贴到当前或所选素材。"))
        } catch { fail(L("无法拷贝设置"), error) }
    }

    func pasteSettings() {
        guard let (recipe, lut) = clipboard else { return }
        let others = library.selection.subtracting([library.currentID ?? ""])
        // In a project the others already share the look; pasting changes the open photo only.
        if mode == .edit || others.isEmpty || currentProject != nil {
            if editor.isLoaded { editor.applyLook(recipe, lut: lut, name: L("粘贴的设置")) }
            return
        }
        writeLook(recipe, to: library.entries.filter { others.contains($0.id) }, label: L("粘贴"))
        if let current = library.currentID, library.selection.contains(current), editor.isLoaded {
            editor.applyLook(recipe, lut: lut, name: L("粘贴的设置"))
        }
    }

    func synchronize(sections: Set<AdjustmentSection>, includeLUT: Bool, stages: Set<GradeStage>) {
        guard editor.isLoaded else { return }
        editor.flushDraft()
        do {
            let source = try editor.currentRecipe()
            let targets = library.selectedEntries.filter { $0.id != library.currentID }
            writeLook(source, to: targets, label: L("同步")) { before in
                before.applying(from: source, sections: sections, includeLUT: includeLUT, stages: stages)
            }
        } catch { fail(L("无法同步"), error) }
    }

    /// Writes recipes for other files in the background, remembering the batch for undo.
    private func writeLook(_ source: EditRecipe, to targets: [LibraryEntry], label: String,
                           transform: (@Sendable (EditRecipe) -> EditRecipe)? = nil) {
        guard !targets.isEmpty else { return }
        let store = drafts
        let change = transform ?? { $0.applyingLook(from: source) }
        Task {
            let (changes, skipped) = await Task.detached(priority: .utility) { () -> ([BatchChange], Int) in
                var changes: [BatchChange] = [], skipped = 0
                for target in targets {
                    do {
                        let stamp = try SourceStamp(target.url)
                        let record = try store.loadRecord(target.url)
                        let before = record?.recipe ?? EditRecipe()
                        let after = change(before)
                        try store.save(after, source: stamp, companion: record?.companion)
                        changes.append(BatchChange(stamp: stamp, companion: record?.companion, before: before, after: after))
                    } catch { skipped += 1 }
                }
                return (changes, skipped)
            }.value
            lastBatch = changes
            for item in changes { thumbnails.invalidate(item.stamp.path) }
            let suffix = skipped > 0 ? L("；\(skipped) 项离线或已变化，已跳过") : ""
            show(L("已\(label)到 \(changes.count) 项\(suffix)。"), actions: [Toast.Action(title: L("撤回")) { self.undoBatch() }], seconds: 8)
        }
    }

    func undoBatch() {
        guard !lastBatch.isEmpty else { return }
        editor.flushDraft()
        let batch = lastBatch, store = drafts, active = editor.url
        lastBatch = []
        Task {
            let (count, restored) = await Task.detached(priority: .utility) { () -> (Int, EditRecipe?) in
                var count = 0
                var restored: EditRecipe?
                for change in batch {
                    let file = URL(fileURLWithPath: change.stamp.path)
                    guard (try? store.load(file)) == change.after else { continue }
                    guard (try? store.save(change.before, source: change.stamp, companion: change.companion)) != nil else { continue }
                    count += 1
                    if file == active { restored = change.before }
                }
                return (count, restored)
            }.value
            for change in batch { thumbnails.invalidate(change.stamp.path) }
            if let restored {
                let lut = try? restored.lut.map { try drafts.loadLUT($0) }
                editor.restoreRecipe(restored, lut: lut ?? nil)
            }
            show(L("已撤回 \(count) 项；之后又单独修改过的素材保持不变。"))
        }
    }

    // MARK: Export

    func exportCurrent() {
        guard editor.isLoaded else { return }
        sheet = .export(.current)
    }

    func exportSelection() {
        guard !library.actionTargets.isEmpty else { return }
        sheet = .export(.selection)
    }

    func confirmExport(_ target: ExportTarget) {
        sheet = nil
        // Let the options sheet close before presenting the next panel.
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            switch (target, exportSettings.destination) {
            case (.current, .photos): exportCurrentStaged()
            case (.selection, .photos): exportSelectionToPhotos()
            case (.current, .folder): exportCurrentNow()
            case (.selection, .folder): exportSelectionNow()
            }
        }
    }

    /// Renders the current item into a private folder, then adds it to Photos — or, when sharing,
    /// hands the file to the system share sheet.
    private func exportCurrentStaged(share: Bool = false) {
        guard let source = editor.url, let input = editor.mediaURL, editor.isLoaded else { return }
        let settings = exportSettings
        let edits = editor.edits, clip = editor.clip, video = editor.isVideo
        let size = videoOutputSize
        let title = source.deletingPathExtension().lastPathComponent + "." + (video ? "mov" : settings.image.format.fileExtension)
        let id = exports.enqueue(share ? L("共享 \(title)") : L("存到「照片」· \(title)")) { report in
            let folder = try PhotosSaver.stagingFolder()
            var output = folder
            if video {
                output = folder.appendingPathComponent(Self.exportName(source, settings: settings, index: 0, total: 1, size: size) + ".mov")
                try await VideoPipeline.export(input, to: output, clip: clip, edits: edits, codec: settings.codec) { report($0, nil) }
            } else {
                report(nil, L("正在渲染…"))
                output = try await Task.detached(priority: .userInitiated) {
                    let rendered = try ImageExporter.render(input, edits: edits, options: settings.image)
                    let name = Self.exportName(source, settings: settings, index: 0, total: 1, size: CGSize(width: rendered.width, height: rendered.height))
                    let output = folder.appendingPathComponent(name + "." + settings.image.format.fileExtension)
                    try ImageExporter.write(rendered, to: output, source: input)
                    return output
                }.value
            }
            if share { return ExportQueue.Result(outputs: [output], live: nil, summary: L("已准备好共享")) }
            defer { try? FileManager.default.removeItem(at: folder) }
            report(nil, L("正在存入「照片」…"))
            try await PhotosSaver.save([video ? .video(output) : .photo(output)])
            return ExportQueue.Result(outputs: [], live: nil, summary: L("已存到「照片」"), inPhotos: true)
        }
        if share { shareJobs.insert(id) }
    }

    func shareCurrent() {
        guard editor.isLoaded else { return }
        editor.flushDraft()
        exportCurrentStaged(share: true)
    }

    private func exportSelectionToPhotos() {
        let entries = library.actionTargets
        guard !entries.isEmpty else { return }
        editor.flushDraft()
        let settings = exportSettings, store = drafts
        // Inside a project, its photos are exported as the project shows them.
        let recipes = projectRecipes(for: entries.map(\.id))
        exports.enqueue(L("存到「照片」· \(entries.count) 项")) { report in
            let folder = try PhotosSaver.stagingFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let batch = folder.appendingPathComponent("export")
            let result = try await Self.runBatchExport(entries, to: batch, settings: settings, store: store, recipes: recipes, report: report)
            let items = PhotosSaver.items(in: batch)
            report(nil, L("正在存入「照片」…"))
            try await PhotosSaver.save(items)
            return ExportQueue.Result(outputs: [], live: nil,
                                      summary: result.summary.replacingOccurrences(of: L("（见导出记录）"), with: "") + L("，已存到「照片」"), inPhotos: true)
        }
    }

    private func exportCurrentNow() {
        guard let source = editor.url, editor.isLoaded else { return }
        let settings = exportSettings
        let video = editor.isVideo
        let panel = NSSavePanel()
        // Next to the original, the plain name gets "-编辑" so it can't be mistaken for it.
        let stem = settings.naming == ExportNaming.defaultPattern
            ? source.deletingPathExtension().lastPathComponent + L("-编辑")
            : Self.exportName(source, settings: settings, index: 0, total: 1, size: video ? videoOutputSize : imageOutputSize)
        if video {
            panel.allowedContentTypes = [.quickTimeMovie]
            panel.nameFieldStringValue = stem + ".mov"
        } else {
            panel.allowedContentTypes = [settings.image.format.type]
            panel.nameFieldStringValue = stem + "." + settings.image.format.fileExtension
        }
        panel.message = L("另存编辑副本；原片不会被修改。")
        present(panel) { [weak self] urls in
            if let output = urls.first { self?.enqueueCurrentExport(to: output) }
        }
    }

    /// Output size of the open photo with its edits and export size, for {width} and {height}.
    private var imageOutputSize: CGSize? {
        guard let metadata = editor.metadata else { return nil }
        return ImageExporter.outputSize(source: CGSize(width: metadata.displayWidth, height: metadata.displayHeight),
                                        edits: editor.edits, options: exportSettings.image)
    }

    /// Videos keep their size apart from rotation and crop.
    private var videoOutputSize: CGSize? {
        guard let metadata = editor.metadata else { return nil }
        var options = ImageExportOptions(); options.maxLongEdge = nil
        return ImageExporter.outputSize(source: CGSize(width: metadata.displayWidth, height: metadata.displayHeight), edits: editor.edits, options: options)
    }

    /// A file name (without extension) from the naming pattern.
    nonisolated static func exportName(_ source: URL, settings: ExportSettings, index: Int, total: Int, size: CGSize?) -> String {
        ExportNaming.name(settings.naming, .init(name: source.deletingPathExtension().lastPathComponent, day: ExportNaming.day(of: source),
                                                 sequence: index + 1, total: total,
                                                 width: size.map { Int($0.width.rounded()) }, height: size.map { Int($0.height.rounded()) }))
    }

    /// Queues an export of the open document with its current edits, captured now.
    func enqueueCurrentExport(to output: URL) {
        guard let input = editor.mediaURL, editor.isLoaded else { return }
        let settings = exportSettings
        let edits = editor.edits, clip = editor.clip, video = editor.isVideo
        exports.enqueue(L("导出 \(output.lastPathComponent)")) { report in
            if video {
                try await Self.exportVideo(input, to: output, clip: clip, edits: edits, codec: settings.codec, report: report)
            } else {
                report(nil, L("正在渲染…"))
                try await Task.detached(priority: .userInitiated) {
                    try ImageExporter.export(input, to: output, edits: edits, options: settings.image, allowReplacing: true)
                }.value
            }
            return ExportQueue.Result(outputs: [output], live: nil, summary: L("已保存"))
        }
    }

    /// Video export that honours a confirmed replacement in the save panel.
    private nonisolated static func exportVideo(_ input: URL, to output: URL, clip: ClipSettings, edits: MediaEdits,
                                                codec: VideoCodecChoice, report: @escaping ExportQueue.Report) async throws {
        guard output.standardizedFileURL != input.standardizedFileURL else { throw VideoWorkError.outputExists }
        let replacing = FileManager.default.fileExists(atPath: output.path)
        let target = replacing ? output.deletingLastPathComponent().appendingPathComponent(".guangji-\(UUID().uuidString).mov") : output
        try await VideoPipeline.export(input, to: target, clip: clip, edits: edits, codec: codec) { report($0, nil) }
        if replacing { _ = try FileManager.default.replaceItemAt(output, withItemAt: target) }
    }

    /// The system share sheet (AirDrop, Messages, Mail, WeChat…) for finished files.
    func presentShare(_ urls: [URL]) {
        guard !urls.isEmpty, let view = NSApp.keyWindow?.contentView ?? NSApp.mainWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: urls)
        let anchor = NSRect(x: view.bounds.maxX - 120, y: view.isFlipped ? 4 : view.bounds.maxY - 4, width: 1, height: 1)
        picker.show(relativeTo: anchor, of: view, preferredEdge: view.isFlipped ? .maxY : .minY)
    }

    func makeLive() {
        guard let source = editor.url, editor.isVideo else { return }
        guard editor.liveIsValid else {
            // Offer the fix instead of only explaining the rule.
            let seconds = editor.clip.outputDuration
            let alert = NSAlert()
            alert.messageText = L("Live Photo 最长 3 秒")
            alert.informativeText = String(format: L("现在选中的片段是 %.1f 秒。可以只取播放头附近的 3 秒，或者把整段加速到 3 秒。"), seconds)
            alert.addButton(withTitle: L("选取播放头附近 3 秒"))
            alert.addButton(withTitle: L("整段加速到 3 秒"))
            alert.addButton(withTitle: L("取消"))
            switch alert.runModal() {
            case .alertFirstButtonReturn: editor.selectLiveRange()
            case .alertSecondButtonReturn: editor.fitLiveSpeed()
            default: return
            }
            guard editor.liveIsValid else { return }
            show(L("已调整为 \(String(format: "%.1f", editor.clip.outputDuration)) 秒，再点一次「制作 Live」即可。"), seconds: 4)
            return
        }
        if exportSettings.destination == .photos {
            guard let input = editor.mediaURL else { return }
            let edits = editor.edits, clip = editor.clip
            let name = source.deletingPathExtension().lastPathComponent + "-Live"
            exports.enqueue(L("制作 Live · 存到「照片」")) { report in
                let folder = try PhotosSaver.stagingFolder()
                defer { try? FileManager.default.removeItem(at: folder) }
                let resources = try await LivePhotoPipeline.export(input, to: folder.appendingPathComponent(name), clip: clip, edits: edits) { report($0, nil) }
                _ = try await LivePhotoPipeline.load(imageURL: resources.imageURL, videoURL: resources.videoURL)
                report(nil, L("正在存入「照片」…"))
                try await PhotosSaver.save([.live(image: resources.imageURL, video: resources.videoURL)])
                return ExportQueue.Result(outputs: [], live: nil, summary: L("已作为 Live Photo 存到「照片」，会随 iCloud 同步到 iPhone"), inPhotos: true)
            }
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + "-Live"
        panel.message = editor.hdrEffect ? L("新建 Live 文件夹：HEIC 增益图封面 + 10-bit HLG 视频 + 参数记录。") : L("新建 Live 文件夹：封面 JPEG + 配对 MOV + 参数记录。")
        present(panel) { [weak self] urls in
            if let output = urls.first { self?.enqueueLive(to: output) }
        }
    }

    func enqueueLive(to output: URL) {
        guard let input = editor.mediaURL, editor.isVideo, editor.liveIsValid else { return }
        let edits = editor.edits, clip = editor.clip
        exports.enqueue(L("制作 Live · \(output.lastPathComponent)")) { report in
            let resources = try await LivePhotoPipeline.export(input, to: output, clip: clip, edits: edits) { report($0, nil) }
            _ = try await LivePhotoPipeline.load(imageURL: resources.imageURL, videoURL: resources.videoURL)
            return ExportQueue.Result(outputs: [output], live: resources, summary: L("系统配对检查通过"))
        }
    }


    private func exportSelectionNow() {
        let entries = library.actionTargets
        guard !entries.isEmpty else { return }
        editor.flushDraft()
        let settings = exportSettings, store = drafts
        let recipes = projectRecipes(for: entries.map(\.id))
        let prefix = currentProject.map { ExportNaming.safeName($0.name) + "-" } ?? L("光集导出-")
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = L("导出到这里")
        panel.message = L("将新建一个文件夹保存 \(entries.count) 项副本；原片不会被修改。")
        present(panel) { [weak self] urls in
            guard let self, let directory = urls.first else { return }
            let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "")
            let destination = directory.appendingPathComponent(prefix + stamp)
            self.exports.enqueue(L("导出 \(entries.count) 项")) { report in
                try await Self.runBatchExport(entries, to: destination, settings: settings, store: store, recipes: recipes, report: report)
            }
        }
    }

    private nonisolated static func runBatchExport(_ entries: [LibraryEntry], to destination: URL, settings: ExportSettings,
                                                   store: DraftStore, recipes: [String: EditRecipe] = [:],
                                                   report: @escaping ExportQueue.Report) async throws -> ExportQueue.Result {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        var completed = 0, skipped = 0
        var log = [L("光集批量导出记录"), L("原片保留；下列路径仅记录本次结果。"), ""]
        var luts: [String: CreativeLUT] = [:]
        defer {
            log.append(L("完成 \(completed) 项；跳过或失败 \(skipped) 项。"))
            try? log.joined(separator: "\n").write(to: destination.appendingPathComponent(L("导出记录.txt")), atomically: true, encoding: .utf8)
        }
        for (index, entry) in entries.enumerated() {
            try Task.checkCancellation()
            report(Double(index) / Double(entries.count), "\(index + 1)/\(entries.count) · \(entry.name)")
            do {
                let recipe = try recipes[entry.id] ?? store.load(entry.url) ?? EditRecipe()
                var lut: CreativeLUT?
                if let reference = recipe.lut {
                    let key = reference.file + reference.encoding.rawValue
                    if let cached = luts[key] { lut = cached } else { let loaded = try store.loadLUT(reference); luts[key] = loaded; lut = loaded }
                }
                var info = try await MediaInspector.inspect(entry.url)
                var input = entry.url
                var liveInput = false
                if info.kind == .image, let movie = try await LivePhotoPipeline.pairedMovie(for: entry.url) {
                    _ = try await LivePhotoPipeline.load(imageURL: entry.url, videoURL: movie)
                    input = movie; info = try await MediaInspector.inspect(movie); liveInput = true
                }
                let edits = MediaEdits(recipe: recipe, lut: lut, isVideo: info.kind == .video)
                var videoSize = CGSize(width: info.displayWidth, height: info.displayHeight)
                if info.kind == .video {
                    var plain = ImageExportOptions(); plain.maxLongEdge = nil
                    videoSize = ImageExporter.outputSize(source: videoSize, edits: edits, options: plain)
                }
                let stem = exportName(entry.url, settings: settings, index: index, total: entries.count, size: videoSize)
                var name = stem
                if info.kind == .video {
                    let duration = info.durationSeconds ?? 0
                    let range = recipe.clip ?? ClipSettings(start: 0, end: duration, cover: min(duration / 2, max(0, duration - 0.05)))
                    try range.validate(duration: duration, live: settings.liveOnly || liveInput)
                    if settings.liveOnly || liveInput {
                        name = unique(stem + "-Live", in: destination)
                        _ = try await LivePhotoPipeline.export(input, to: destination.appendingPathComponent(name), clip: range, edits: edits)
                    } else {
                        name = unique(stem, ext: "mov", in: destination)
                        try await VideoPipeline.export(input, to: destination.appendingPathComponent(name), clip: range, edits: edits, codec: settings.codec)
                    }
                } else if !settings.liveOnly {
                    let rendered = try ImageExporter.render(input, edits: edits, options: settings.image)
                    let named = exportName(entry.url, settings: settings, index: index, total: entries.count,
                                           size: CGSize(width: rendered.width, height: rendered.height))
                    name = unique(named, ext: settings.image.format.fileExtension, in: destination)
                    try ImageExporter.write(rendered, to: destination.appendingPathComponent(name), source: input)
                } else {
                    skipped += 1
                    log.append(L("跳过 · \(entry.name) · 静态照片没有动态片段"))
                    continue
                }
                completed += 1
                log.append(L("完成 · \(entry.name) → \(name)"))
            } catch {
                if Task.isCancelled { throw CancellationError() }
                skipped += 1
                log.append(L("失败 · \(entry.name) · \(error.localizedDescription)"))
            }
        }
        return ExportQueue.Result(outputs: [destination], live: nil,
                                  summary: L("完成 \(completed) 项") + (skipped > 0 ? L("，跳过 \(skipped) 项（见导出记录）") : ""))
    }

    private nonisolated static func unique(_ stem: String, ext: String? = nil, in folder: URL) -> String {
        func name(_ suffix: String) -> String { stem + suffix + (ext.map { "." + $0 } ?? "") }
        var candidate = name(""), counter = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).path) {
            candidate = name("-\(counter)"); counter += 1
        }
        return candidate
    }

    private func exportFinished(_ job: ExportQueue.Job) {
        let sharing = shareJobs.remove(job.id) != nil
        switch job.state {
        case .finished where sharing:
            presentShare(job.outputs)
        case .finished where job.inPhotos:
            show("\(job.title) · \(job.detail)", actions: [.init(title: L("打开「照片」")) { PhotosSaver.openPhotos() }], seconds: 8)
        case .finished:
            var actions = [Toast.Action(title: L("在 Finder 中显示")) { [weak self] in self?.exports.reveal(job) },
                           Toast.Action(title: L("共享…")) { [weak self] in self?.presentShare(job.live.map { [$0.imageURL] } ?? job.outputs) }]
            if let live = job.live {
                actions.insert(Toast.Action(title: L("预览 Live")) { [weak self] in self?.sheet = .livePreview(live) }, at: 0)
            }
            show("\(job.title) · \(job.detail)", actions: actions, seconds: 8)
        case .failed(let message):
            alert = AppAlert(title: L("\(job.title) 失败"), message: message)
        default: break
        }
    }

    // MARK: Collage

    func openCollage() {
        editor.flushDraft()
        let entries = library.actionTargets
        guard (1...3).contains(entries.count) else {
            alert = AppAlert(title: L("拼图 Live"), message: L("请先在素材库选择 1–3 个视频或 Live Photo。"))
            return
        }
        let store = drafts
        Task {
            do {
                var items: [CollageDraftPane] = []
                for entry in entries {
                    var input = entry.url
                    var info = try await MediaInspector.inspect(input)
                    if info.kind == .image, let movie = try await LivePhotoPipeline.pairedMovie(for: input) {
                        input = movie; info = try await MediaInspector.inspect(movie)
                    }
                    guard info.kind == .video, let duration = info.durationSeconds, duration >= 1.5 else {
                        throw VideoWorkError.failed(L("\(entry.name)：拼图需要至少 1.5 秒的视频或 Live 动态资源。"))
                    }
                    let recipe = try store.load(entry.url) ?? EditRecipe()
                    let lut = try recipe.lut.map { try store.loadLUT($0) }
                    let edits = MediaEdits(recipe: recipe, lut: lut)
                    let speed = min(recipe.clip?.speed ?? 1, duration / 3)
                    let start = min(max(0, recipe.clip?.start ?? 0), max(0, duration - 3 * speed))
                    items.append(.init(url: input, duration: duration, start: start, speed: speed, edits: edits))
                }
                collageDrafts = items
                sheet = .collage
            } catch { fail(L("无法准备拼图"), error) }
        }
    }

    func exportCollage(_ items: [CollageDraftPane]) {
        let panes = items.map {
            LiveCollagePane(url: $0.url, clip: .init(start: $0.start, end: $0.start + 3 * $0.speed, cover: $0.start + 1.5 * $0.speed,
                                                      originalVolume: 0, speed: $0.speed), edits: $0.edits)
        }
        do { _ = try LiveCollagePipeline.validate(panes) } catch { fail(L("拼图设置无效"), error); return }
        sheet = nil
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            let panel = NSSavePanel()
            panel.nameFieldStringValue = L("光集-\(panes.count)画面-Live")
            panel.message = L("新建 Live 文件夹：静音 SDR，3 秒，各画面独立调色与变速。")
            present(panel) { urls in
                guard let output = urls.first else { return }
                self.exports.enqueue(L("拼图 Live · \(panes.count) 画面")) { report in
                    let resources = try await LiveCollagePipeline.export(panes, to: output) { report($0, nil) }
                    _ = try await LivePhotoPipeline.load(imageURL: resources.imageURL, videoURL: resources.videoURL)
                    return ExportQueue.Result(outputs: [output], live: resources, summary: L("系统配对检查通过"))
                }
            }
        }
    }

    // MARK: Sound

    func chooseMusic() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        present(panel) { [weak self] urls in
            if let url = urls.first { self?.editor.musicURL = url }
        }
    }

    // MARK: Learning

    private func scheduleLearnerSave() {
        learnerSave?.cancel()
        let profile = learner, file = learnerFile
        learnerSave = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(profile).write(to: file, options: .atomic)
        }
    }

    enum CoachFeedback { case helpful, known, mute }

    func feedback(_ feedback: CoachFeedback, on concept: Concept) {
        learner.update(concept) { state in
            switch feedback {
            case .helpful: state.helpful += 1
            case .known: state.known = true
            case .mute: state.muted = true
            }
        }
        switch feedback {
        case .helpful: show(L("谢谢！以后会多讲「\(concept.title)」相关的内容。"))
        case .known: show(L("已标记为已了解：「\(concept.title)」会讲得更简短。"))
        case .mute: show(L("不再提示「\(concept.title)」。可在「学习」页底部恢复。"))
        }
    }

    func unmuteAll() {
        for concept in Concept.allCases where learner.state(concept).muted { learner.update(concept) { $0.muted = false } }
    }

    func markShown(_ insights: [CoachInsight]) {
        for insight in insights { learner.update(insight.concept) { $0.shown += 1 } }
    }

    /// Applies a tip or a concept demo: edits as one undo step, plus any view actions.
    func trySuggestion(_ suggestion: CoachSuggestion, concept: Concept) {
        guard editor.isLoaded else { return }
        learner.update(concept) { $0.tried += 1 }
        onlyThisPhoto { editor.applySuggestion(suggestion) }
        for action in suggestion.actions {
            switch action {
            case .straighten: editor.autoStraighten()
            case .importLUT: importLUT()
            case .builtInLUT: editor.group { editor.selectLUT(.warm) }; if !editor.isVideo { editor.compareMode = .split }
            case .showClipping: editor.showClipping = true
            case .zoomToActual: editor.zoomToActualPixels()
            case .cropFourFive: editor.group { editor.geometry.aspectRatio = 0.8 }
            case .showScope(let name):
                editor.scopeKind = ScopeKind(rawValue: name) ?? .histogram
                inspectorTab = .color
            }
        }
    }

    /// Sends a question about the open photo; the answer's concepts count as interest.
    func askTutor(_ question: String) {
        let tips = CoachState(app: self).insights.prefix(4).map(\.title)
        tutor.ask(question, editor: editor, profile: learner, coachTips: Array(tips)) { [weak self] answer in
            guard let self else { return }
            for concept in answer.concepts { self.learner.update(concept) { $0.asked += 1; $0.shown += 1 } }
        }
    }

    func tryTutorSuggestion(_ item: TutorSuggestion) {
        if let concept = item.concept { trySuggestion(item.suggestion, concept: concept) }
        else { onlyThisPhoto { editor.applySuggestion(item.suggestion) } }
    }

    // MARK: Keyboard (single-key shortcuts, like Lightroom / Resolve)

    /// Called for key-downs in the workbench window when no text field is editing.
    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // ⌘A: the monitor skips text fields, so this never steals Select All from typing.
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "a" { selectAll(); return true }
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) { return false }
        let editing = mode == .edit && editor.isLoaded
        switch event.keyCode {
        case 123, 124: // ← →
            let direction = event.keyCode == 123 ? -1 : 1
            if mode == .browse { step(direction) }
            else if editor.isVideo { editor.stepFrame(Double(direction)) }
            else { step(direction) }
            return true
        case 125, 126: // ↓ ↑
            let direction = event.keyCode == 126 ? -1 : 1
            step(mode == .browse ? direction * gridColumns : direction)
            return true
        case 36, 76: // return
            if mode == .browse { openSelection(); return true }
            return false
        case 49: // space
            if mode == .browse { openSelection() }
            else if editor.isVideo { editor.togglePlayback() }
            else if editing { editor.toggleZoom() }
            return true
        case 48: // tab
            let hide = showSidebar || showInspector
            showSidebar = !hide
            showInspector = !hide
            return true
        case 53: // escape
            if editing, editor.canvas?.isZoomed == true { editor.zoomToFit() }
            else if mode == .edit { mode = .browse }
            return true
        default: break
        }
        guard let key = event.charactersIgnoringModifiers?.lowercased(), key.count == 1 else { return false }
        switch key {
        case "0", "1", "2", "3", "4", "5": rate(Int(key) ?? 0)
        case "p": flag(.pick)
        case "x": flag(.reject)
        case "u": flag(.none)
        case "g": mode = .browse
        case "a": if editing { autoEnhance() }
        case "e": if mode == .browse { openSelection() }
        case "\\", "m": if editing { editor.compareMode = editor.compareMode == .original ? .off : .original }
        case "y": if editing, !editor.isVideo { editor.compareMode = editor.compareMode == .split ? .off : .split }
        case "j": if editing { editor.showClipping.toggle() }
        case "z": if editing, !editor.isVideo { editor.toggleZoom() }
        case "i": if editing, editor.isVideo { editor.setInPoint() }
        case "o": if editing, editor.isVideo { editor.setOutPoint() }
        case "c": if editing, editor.isVideo { editor.setCoverAtPlayhead() }
        case "?", "/": sheet = .shortcuts
        default: return false
        }
        return true
    }

    /// Columns in the browse grid, reported by the grid for ↑/↓ navigation.
    @ObservationIgnored var gridColumns = 4
}
