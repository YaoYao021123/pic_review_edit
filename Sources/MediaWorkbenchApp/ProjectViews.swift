import AppKit
import MediaCore
import SwiftUI

// Projects in the interface: the sidebar list, the bar above a project's photos, the line at the
// top of the inspector while editing a project version, and the new / rename sheets.

/// Sidebar: the whole library, then each project.
struct SidebarProjects: View {
    let app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            row(title: L("全部素材"), symbol: "photo.on.rectangle", count: app.library.entries.count, selected: app.currentProjectID == nil) {
                app.currentProjectID = nil
            }
            HStack {
                Text("项目").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { app.sheet = .newProject(Array(app.library.selection)) } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("新建项目：把所选照片放在一起，用同一套颜色")
            }
            .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 2)
            if app.projects.isEmpty {
                Text("为一次旅行、一篇帖子或一组客片建一个项目，里面的照片共用一套颜色。")
                    .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8).padding(.bottom, 4)
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(app.projects) { project in
                            row(title: project.name, symbol: "folder", count: app.projectCount(project), selected: app.currentProjectID == project.id) {
                                app.currentProjectID = project.id
                            }
                            .contextMenu { ProjectMenu(app: app, project: project) }
                            .dropDestination(for: String.self) { ids, _ in
                                // Dragging one of the selected photos brings the whole selection.
                                let selection = app.library.selection
                                app.addToProject(ids.count == 1 && selection.contains(ids[0]) ? Array(selection) : ids, projectID: project.id)
                                return true
                            }
                        }
                    }
                }
                // Only as tall as the projects need, up to about five rows.
                .frame(height: min(168, CGFloat(app.projects.count) * 30))
            }
        }
        .padding(.horizontal, 8)
    }

    private func row(title: String, symbol: String, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 16).foregroundStyle(.secondary)
                Text(title).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.callout)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? WorkbenchTheme.selection : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Actions on one project (context menu and the bar's "…" menu).
struct ProjectMenu: View {
    let app: AppModel
    let project: Project

    var body: some View {
        Button("打开项目") { app.currentProjectID = project.id }
        Button("重命名…") { app.sheet = .renameProject(project.id) }
        if app.currentProjectID == project.id {
            Button("用当前照片的颜色作为项目调色") { app.adoptLookFromCurrent() }.disabled(!app.editor.isLoaded)
            Button("统一明暗与色温") { app.evenOutProject() }.disabled(project.photos.count < 2)
            Button("导出项目…") { app.exportProject() }.disabled(project.photos.isEmpty)
        }
        Divider()
        Button("删除项目…") { app.deleteProject(project.id) }
    }
}

/// Above the grid while a project is open: its name, what's in it, and the project actions.
struct ProjectBar: View {
    let app: AppModel
    let project: Project

    var body: some View {
        let entries = project.photoIDs.compactMap(app.library.entry)
        let picked = entries.filter { $0.flag == .pick }.count
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name).font(.headline).lineLimit(1)
                Text(picked > 0 ? L("\(entries.count) 张 · 已选用 \(picked) 张") : L("\(entries.count) 张"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { app.evenOutProject() } label: { Label("统一明暗与色温", systemImage: "slider.horizontal.below.square.and.square.filled") }
                .glassButton().controlSize(.small).disabled(entries.count < 2)
                .help("让项目里每张照片的亮度和冷暖向整组的中间值靠拢，看起来像同一时间拍的一组")
            Button { app.exportProject() } label: { Label("导出项目…", systemImage: "square.and.arrow.up") }
                .glassButton().controlSize(.small).disabled(entries.isEmpty)
                .help(picked > 0 ? L("导出已选用的 \(picked) 张（项目里的版本）") : L("导出项目里的全部照片（项目里的版本）"))
            Menu { ProjectMenu(app: app, project: project) } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
    }
}

/// Where edits on a project photo go, chosen at the top of the inspector.
enum ProjectEditScope: Hashable, CaseIterable {
    case project, photo
    var title: String { self == .project ? L("整个项目") : L("只这张") }
}

/// The inspector's first line while editing a project version.
struct ProjectEditBar: View {
    let app: AppModel
    let context: EditorModel.ProjectContext

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(L("项目「\(context.name)」里的版本")).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
            }
            // Where slider changes go: the shared look, or only this photo.
            GlassSegmentedControl(options: ProjectEditScope.allCases,
                                  selection: Binding(get: { app.projectPhotoOnly ? .photo : .project },
                                                     set: { app.projectPhotoOnly = $0 == .photo }),
                                  title: { $0.title }, size: .small, accessibilityTitle: L("调整范围"))
            Text(app.projectPhotoOnly
                 ? L("滑块只改这一张。曲线、色轮、HSL 和 LUT 仍对整个项目生效。")
                 : L("颜色改动对项目里的 \(context.count) 张都生效；曝光、裁剪和局部调整只改这一张。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .overlay(alignment: .bottom) { WorkbenchTheme.hairline.frame(height: 1) }
    }
}

struct NewProjectSheet: View {
    let app: AppModel
    let ids: [String]
    @UIState private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: L("新建项目"), subtitle: ids.isEmpty
                        ? L("先建一个空项目；之后在「全部素材」里选中照片，右键「添加到项目」。")
                        : L("把所选的 \(ids.count) 张放进一个项目。它们会共用一套颜色：以当前打开的照片（或第一张）为准；曝光、裁剪和局部调整各自保留。"))
            TextField("项目名称", text: $name, prompt: Text(app.suggestedProjectName(for: ids)))
                .textFieldStyle(.roundedBorder)
            Text("照片可以同时在几个项目里，每个项目里是各自的版本；照片在素材库里自己的编辑不会改变。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("取消") { app.sheet = nil }.keyboardShortcut(.cancelAction)
                Button("新建项目") {
                    app.sheet = nil
                    app.createProject(named: name, from: ids)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 440)
    }
}

struct RenameProjectSheet: View {
    let app: AppModel
    let projectID: UUID
    @UIState private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: L("重命名项目"))
            TextField("项目名称", text: $name).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") { app.sheet = nil }.keyboardShortcut(.cancelAction)
                Button("重命名") { app.sheet = nil; app.renameProject(projectID, to: name) }
                    .keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22).frame(width: 380)
        .onAppear { name = app.project(projectID)?.name ?? "" }
    }
}
