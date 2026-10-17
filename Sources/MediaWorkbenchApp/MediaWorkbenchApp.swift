import AppKit
import MediaCore
import SwiftUI

@main
struct MediaWorkbenchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @UIState private var app = AppModel()

    init() {
        // Snapshot runs (development only) must not take keyboard focus from the user.
        NSApplication.shared.setActivationPolicy(DebugSnapshot.directory == nil ? .regular : .accessory)
        if let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let image = NSImage(contentsOf: icon) {
            NSApplication.shared.applicationIconImage = image
        }
    }

    var body: some Scene {
        Window("Lucet 光集", id: "workbench") {
            WorkbenchView(app: app)
                .frame(minWidth: 1080, minHeight: 700)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1440, height: 900)
        .windowToolbarStyle(.unified)
        .commands {
            WorkbenchCommands(app: app)
            LanguageCommands()
        }
    }
}

/// Quitting mid-export would lose the export and leave a hidden unfinished file next to it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let app = AppModel.current, app.exports.activeCount > 0, DebugSnapshot.directory == nil else { return .terminateNow }
            let count = app.exports.activeCount
            let alert = NSAlert()
            alert.messageText = L("还有 \(count) 个导出没有完成")
            alert.informativeText = L("现在退出会中断导出。可以等它们完成后自动退出，你的原片不受影响。")
            alert.addButton(withTitle: L("完成后退出"))
            alert.addButton(withTitle: L("继续使用"))
            alert.addButton(withTitle: L("停止导出并退出"))
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                app.exports.onIdle = { NSApp.terminate(nil) }
                app.show(L("导出完成后光集会自动退出。"), actions: [.init(title: L("不退出")) { app.exports.onIdle = nil }], seconds: 8)
            case .alertThirdButtonReturn:
                app.exports.onIdle = { NSApp.terminate(nil) }
                app.exports.cancelAll()
            default: break
            }
            return .terminateCancel
        }
    }
}

/// Menus read only rarely-changing state, so editing never rebuilds the menu bar.
struct WorkbenchCommands: Commands {
    let app: AppModel
    var editor: EditorModel { app.editor }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("添加照片或视频…") { app.importMedia() }.keyboardShortcut("o")
            Button("导入文件夹…") { app.importMedia(folders: true) }.keyboardShortcut("o", modifiers: [.command, .shift])
            Button("从「照片」导入…") { app.sheet = .photosImport }.keyboardShortcut("i", modifiers: [.command, .shift])
            Divider()
            Button("导入 LUT…", action: app.importLUT)
        }
        CommandGroup(replacing: .saveItem) {
            Button("保存配方") { editor.flushDraft(); editor.status = L("已保存 · 原片保留") }
                .keyboardShortcut("s").disabled(!editor.isLoaded)
            Button("快照与版本…") { app.sheet = .snapshots }.disabled(!editor.isLoaded || editor.projectContext != nil)
            Divider()
            Button("导出当前…", action: app.exportCurrent).keyboardShortcut("e").disabled(!editor.isLoaded)
            Button("导出所选…", action: app.exportSelection).keyboardShortcut("e", modifiers: [.command, .shift])
            Button("制作 Live Photo…", action: app.makeLive).keyboardShortcut("l").disabled(!editor.isVideo)
            Button("拼图 Live…", action: app.openCollage)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("撤销", action: editor.undo).keyboardShortcut("z").disabled(!editor.canUndo)
            Button("重做", action: editor.redo).keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!editor.canRedo)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("拷贝调色设置", action: app.copySettings).keyboardShortcut("c", modifiers: [.command, .shift]).disabled(!editor.isLoaded)
            Button("粘贴调色设置", action: app.pasteSettings).keyboardShortcut("v", modifiers: [.command, .shift]).disabled(!app.hasClipboard)
            // Inside a project the colour is already shared; Sync would write the photos' own edits.
            Button("同步调色到所选…") { app.sheet = .sync }.disabled(!editor.isLoaded || app.currentProject != nil)
            Button("存为预设…") { app.sheet = .savePreset }.disabled(!editor.isLoaded)
            Button("匹配另一张照片的色调…") { app.sheet = .matchLook }.disabled(!editor.isLoaded || editor.isVideo)
            Button("AI 调色") { app.aiLook() }.disabled(!editor.isLoaded || editor.isVideo || AdaptiveLUT.shared == nil)
            Button("导出调色为 LUT…", action: app.exportGradeLUT).disabled(!editor.isLoaded)
            Button("撤回上次同步", action: app.undoBatch).disabled(app.lastBatch.isEmpty)
        }
        CommandMenu("项目") {
            Button("新建项目（所选照片）…") { app.sheet = .newProject(Array(app.library.selection)) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("显示全部素材") { app.currentProjectID = nil }.disabled(app.currentProjectID == nil)
            if !app.projects.isEmpty {
                Menu("打开项目") {
                    ForEach(app.projects) { project in Button(project.name) { app.currentProjectID = project.id } }
                }
            }
            Divider()
            Button("用当前照片的颜色作为项目调色") { app.adoptLookFromCurrent() }.disabled(app.currentProject == nil || !editor.isLoaded)
            Button("统一明暗与色温") { app.evenOutProject() }.disabled((app.currentProject?.photos.count ?? 0) < 2)
            Button("导出项目…") { app.exportProject() }.disabled(app.currentProject?.photos.isEmpty ?? true)
            Divider()
            Button("重命名项目…") { if let id = app.currentProjectID { app.sheet = .renameProject(id) } }.disabled(app.currentProject == nil)
            Button("删除项目…") { if let id = app.currentProjectID { app.deleteProject(id) } }.disabled(app.currentProject == nil)
        }
        CommandMenu("照片") {
            Button("上一项") { app.step(-1) }.keyboardShortcut(.upArrow, modifiers: [.command])
            Button("下一项") { app.step(1) }.keyboardShortcut(.downArrow, modifiers: [.command])
            Divider()
            Menu("评级") {
                ForEach(0...5, id: \.self) { value in
                    Button(value == 0 ? L("无评级") : String(repeating: "★", count: value)) { app.rate(value) }
                }
            }
            Button("选用") { app.flag(.pick) }
            Button("排除") { app.flag(.reject) }
            Button("取消标记") { app.flag(.none) }
            Divider()
            Button("向左旋转") { editor.rotate(clockwise: false) }.keyboardShortcut("[", modifiers: [.command]).disabled(!editor.isLoaded)
            Button("向右旋转") { editor.rotate(clockwise: true) }.keyboardShortcut("]", modifiers: [.command]).disabled(!editor.isLoaded)
            Button("自动拉直", action: editor.autoStraighten).disabled(!editor.isLoaded || editor.isVideo)
            Divider()
            Button("并排比较所选") { app.sheet = .compare(app.compareSelection) }
                .keyboardShortcut("c", modifiers: [.command, .option]).disabled(app.compareSelection.count < 2)
            Toggle("显示重复与相似", isOn: Binding(get: { app.showGroups }, set: { app.showGroups = $0; if $0 { app.mode = .browse } }))
            Button("复位全部编辑", action: editor.resetAll).disabled(!editor.isLoaded)
            Divider()
            Button("在 Finder 中显示", action: app.revealSelection).keyboardShortcut("r", modifiers: [.command, .shift])
            Button("从素材库移除", action: app.removeSelectionFromLibrary)
            Button("全选", action: app.selectAll)
            Button("清空素材库…", action: app.clearLibrary)
        }
        CommandGroup(before: .toolbar) {
            Button("浏览网格") { app.mode = .browse }.keyboardShortcut("1", modifiers: [.command, .option])
            Button("编辑") { app.openSelection() }.keyboardShortcut("2", modifiers: [.command, .option])
            Divider()
            Button("适合窗口", action: editor.zoomToFit).keyboardShortcut("0").disabled(editor.isVideo)
            Button("实际像素 (100%)", action: editor.zoomToActualPixels).keyboardShortcut("1").disabled(editor.isVideo)
            Button("放大") { editor.zoom(by: 1.5) }.keyboardShortcut("=").disabled(editor.isVideo)
            Button("缩小") { editor.zoom(by: 1 / 1.5) }.keyboardShortcut("-").disabled(editor.isVideo)
            Divider()
            Button("显示或隐藏素材库") { app.showSidebar.toggle() }.keyboardShortcut("s", modifiers: [.command, .option])
            Button("显示或隐藏检查器") { app.showInspector.toggle() }.keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
        }
        CommandMenu("学习") {
            // Lessons are static content, so this menu never needs rebuilding.
            ForEach(LessonUnit.allCases, id: \.self) { unit in
                Section(unit.title) {
                    ForEach(Lesson.catalog.filter { $0.unit == unit }) { lesson in
                        Button(lesson.title) { app.openLesson(lesson.id) }
                    }
                }
            }
        }
        CommandGroup(replacing: .help) {
            Button("键盘快捷键") { app.sheet = .shortcuts }.keyboardShortcut("/", modifiers: [.command])
        }
    }
}
