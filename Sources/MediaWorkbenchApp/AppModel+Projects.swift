import AppKit
import ImageIO
import Foundation
import MediaCore

/// Projects: a set of photos for one job (a trip, a post, a client shoot) with one shared look.
/// Opening a project shows only its photos; editing one of them edits its version in the project:
/// colour changes go to the shared look (every photo follows), exposure, crop and masks stay with
/// the photo. A photo can be in several projects; its own edits outside projects are untouched.
extension AppModel {
    var currentProject: Project? { projects.first { $0.id == currentProjectID } }

    func project(_ id: UUID) -> Project? { projects.first { $0.id == id } }

    /// The library, the grid and the open photo follow the chosen project.
    func projectScopeChanged() {
        let project = currentProject
        library.filter.members = project.map { Set($0.photoIDs) }
        thumbnails.project = project
        projectPhotoOnly = false
        guard let id = library.currentID else { return }
        if project?.contains(id) ?? true {
            // The open photo switches to its version here, without leaving Browse.
            if editor.url != nil, let entry = library.entry(id) { editor.open(entry.url, project: editContext(for: id)) }
        } else {
            editor.close()
            library.currentID = nil
            mode = .browse
        }
    }

    func editContext(for id: String) -> EditorModel.ProjectContext? {
        guard let project = currentProject, let recipe = project.recipe(for: id) else { return nil }
        return .init(id: project.id, name: project.name, count: project.photos.count, start: recipe)
    }

    /// Called by the editor when a project version is saved.
    func storeProjectEdit(_ projectID: UUID, url: URL, recipe: EditRecipe, previous: EditRecipe) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        let id = url.standardizedFileURL.path
        let lookChanged = projects[index].store(recipe, for: id, previous: previous, photoOnly: projectPhotoOnly)
        projectsChanged()
        thumbnails.invalidate(lookChanged ? projects[index].photoIDs : [id])
    }

    /// Keeps the library filter and thumbnails current, and writes the file shortly after.
    func projectsChanged() {
        let project = currentProject
        thumbnails.project = project
        let members = project.map { Set($0.photoIDs) }
        if library.filter.members != members { library.filter.members = members }
        projectSaveTask?.cancel()
        let store = projectStore, snapshot = projects
        projectSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await Task.detached(priority: .utility) { try? store.save(snapshot) }.value
        }
    }

    /// Writes the projects at once (quitting).
    func saveProjectsNow() {
        projectSaveTask?.cancel()
        try? projectStore.save(projects)
    }

    /// Photos of a project that are still in the library.
    func projectCount(_ project: Project) -> Int { project.photoIDs.filter { library.entry($0) != nil }.count }

    /// A name for a new project: the folder most of the photos come from, or a numbered one.
    func suggestedProjectName(for ids: [String]) -> String {
        let folders = ids.compactMap { library.entry($0)?.url.deletingLastPathComponent().lastPathComponent }
        let common = Dictionary(grouping: folders, by: { $0 }).max { $0.value.count < $1.value.count }?.key
        var name = common ?? L("新项目")
        var number = 2
        while projects.contains(where: { $0.name == name }) { name = (common ?? L("新项目")) + " \(number)"; number += 1 }
        return name
    }

    /// New project from these photos. They keep their crop, masks and exposure; the colour of the
    /// open photo (or the first one) becomes the project's look, so they match from the start.
    func createProject(named name: String, from ids: [String]) {
        let ids = ids.filter { library.entry($0) != nil }
        editor.flushDraft()
        // An empty project is fine too: photos can be added later from the library.
        let anchorID = library.currentID.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first ?? ""
        let urls = ids.compactMap { id in library.entry(id).map { (id, $0.url) } }
        let drafts = self.drafts
        let projectName = name.trimmingCharacters(in: .whitespaces).isEmpty ? suggestedProjectName(for: ids) : name
        Task {
            let recipes = await Task.detached(priority: .userInitiated) { () -> [String: EditRecipe] in
                var result: [String: EditRecipe] = [:]
                for (id, url) in urls { if let recipe = try? drafts.load(url) { result[id] = recipe } }
                return result
            }.value
            var project = Project(name: String(projectName.prefix(80)))
            project.add(ids) { recipes[$0] }
            if let anchor = recipes[anchorID] { project.adoptLook(from: anchor, keeping: anchorID) }
            projects.append(project)
            currentProjectID = project.id
            projectsChanged()
            let anchorName = library.entry(anchorID)?.name ?? ""
            show(ids.isEmpty ? L("已新建空项目「\(project.name)」。在「全部素材」里选中照片，右键「添加到项目」。")
                 : recipes[anchorID] == nil
                 ? L("已新建项目「\(project.name)」，共 \(ids.count) 张。在任意一张上调颜色，整个项目都会跟着变。")
                 : L("已新建项目「\(project.name)」，共 \(ids.count) 张，颜色都以「\(anchorName)」为准。"))
        }
    }

    func addToProject(_ ids: [String], projectID: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        let new = ids.filter { !projects[index].contains($0) && library.entry($0) != nil }
        guard !new.isEmpty else { show(L("所选照片已经在项目「\(projects[index].name)」里。")); return }
        editor.flushDraft()
        let drafts = self.drafts
        let urls = new.compactMap { id in library.entry(id).map { (id, $0.url) } }
        Task {
            let recipes = await Task.detached(priority: .userInitiated) { () -> [String: EditRecipe] in
                var result: [String: EditRecipe] = [:]
                for (id, url) in urls { if let recipe = try? drafts.load(url) { result[id] = recipe } }
                return result
            }.value
            guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
            projects[index].add(new) { recipes[$0] }
            projectsChanged()
            thumbnails.invalidate(new)
            show(L("已把 \(new.count) 张加入项目「\(projects[index].name)」，颜色与项目一致。"))
        }
    }

    func removeFromProject(_ ids: Set<String>) {
        guard let index = projects.firstIndex(where: { $0.id == currentProjectID }) else { return }
        editor.flushDraft()
        if let current = library.currentID, ids.contains(current) { editor.close(); library.currentID = nil; mode = .browse }
        let before = projects[index]
        projects[index].remove(ids)
        projectsChanged()
        let name = projects[index].name
        show(L("已从项目「\(name)」移除 \(ids.count) 张；照片还在素材库里，自己的编辑不受影响。"),
             actions: [.init(title: L("撤销")) { [weak self] in self?.restore(before) }])
    }

    func renameProject(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].name = String(name.prefix(80))
        projectsChanged()
        if currentProjectID == id, let current = library.currentID, editor.url != nil { editor.flushDraft(); open(current) }
    }

    func deleteProject(_ id: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = L("删除项目「\(projects[index].name)」？")
        alert.informativeText = L("只删除项目和它的调色。照片留在素材库里，它们自己的编辑和原文件都不受影响。")
        alert.addButton(withTitle: L("删除项目"))
        alert.addButton(withTitle: L("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if currentProjectID == id { editor.flushDraft(); currentProjectID = nil }
        projects.remove(at: index)
        projectsChanged()
    }

    /// Puts a project back as it was (undo for removals, evening out, a new look).
    func restore(_ project: Project) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        editor.flushDraft()
        projects[index] = project
        projectsChanged()
        thumbnails.invalidate(project.photoIDs)
        if currentProjectID == project.id, let current = library.currentID, editor.url != nil {
            if project.contains(current) { reopenInProject(current) } else { editor.close(); mode = .browse }
        }
    }

    /// The open photo again, from the project's current state (after the look changed elsewhere).
    func reopenInProject(_ id: String) {
        guard let entry = library.entry(id) else { return }
        editor.close()
        editor.open(entry.url, project: editContext(for: id))
    }

    /// Makes the open photo's colour the look of the whole project.
    func adoptLookFromCurrent() {
        guard let index = projects.firstIndex(where: { $0.id == currentProjectID }), let id = library.currentID,
              editor.isLoaded, let recipe = try? editor.currentRecipe() else { return }
        editor.flushDraft()
        let before = projects[index]
        projects[index].adoptLook(from: recipe, keeping: id)
        projectsChanged()
        thumbnails.invalidate(projects[index].photoIDs)
        reopenInProject(id)
        show(L("整个项目已改用这张照片的颜色；各自的曝光、裁剪和局部调整保持不变。"),
             actions: [.init(title: L("撤销")) { [weak self] in self?.restore(before) }])
    }

    /// Runs a fix meant for the open photo alone (Auto, a coach tip). In a project its slider
    /// changes become this photo's offsets instead of changing the shared look.
    func onlyThisPhoto(_ change: () -> Void) {
        guard editor.projectContext != nil else { change(); return }
        let previous = projectPhotoOnly
        projectPhotoOnly = true
        change()
        editor.flushDraft()
        projectPhotoOnly = previous
    }

    /// Recipes of the project versions, for exports started inside a project.
    func projectRecipes(for ids: [String]) -> [String: EditRecipe] {
        guard let project = currentProject else { return [:] }
        return Dictionary(uniqueKeysWithValues: ids.compactMap { id in project.recipe(for: id).map { (id, $0) } })
    }

    /// Exports every photo of the open project (or the picked ones when some are picked).
    func exportProject() {
        guard let project = currentProject else { return }
        editor.flushDraft()
        let entries = project.photoIDs.compactMap(library.entry)
        let picked = entries.filter { $0.flag == .pick }
        library.selection = Set((picked.isEmpty ? entries : picked).map(\.id))
        exportSelection()
    }
}

extension AppModel {
    /// Evens out brightness and white balance across the open project (one undo).
    func evenOutProject() {
        guard let project = currentProject else { return }
        editor.flushDraft()
        let photos = project.photoIDs.compactMap(library.entry).filter { !$0.isVideo }
        guard photos.count >= 2 else { show(L("项目里至少要有两张照片才能统一。")); return }
        let drafts = self.drafts
        let items = photos.map { ($0.id, $0.url) }
        show(L("正在统一 \(photos.count) 张的明暗与色温…"))
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Project in
                var images: [String: CGImage] = [:]
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 256]
                for (id, url) in items {
                    if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                       let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) { images[id] = image }
                }
                let lut = project.look.lut.flatMap { try? drafts.loadLUT($0) }
                return ProjectEvenOut.evenOut(project, images: images, lut: lut)
            }.value
            guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
            let before = projects[index]
            projects[index] = result
            projectsChanged()
            thumbnails.invalidate(result.photoIDs)
            if currentProjectID == project.id, let current = library.currentID, editor.url != nil, result.contains(current) { reopenInProject(current) }
            show(L("已统一 \(photos.count) 张的明暗与色温：每张都向整组的中间值靠拢，保留了各自的氛围。"),
                 actions: [.init(title: L("撤销")) { [weak self] in self?.restore(before) }])
        }
    }
}
