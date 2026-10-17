import AppKit
import MediaCore
import SwiftUI

struct WorkbenchView: View {
    let app: AppModel
    var editor: EditorModel { app.editor }

    var body: some View {
        // System split view + inspector: on macOS 26 both side panels are
        // floating Liquid Glass; on macOS 15 they use the standard materials.
        NavigationSplitView(columnVisibility: Binding(get: { app.showSidebar ? .all : .detailOnly },
                                                      set: { app.showSidebar = $0 != .detailOnly })) {
            LibrarySidebar(app: app)
                .navigationSplitViewColumnWidth(min: 230, ideal: 262, max: 380)
        } detail: {
            VStack(spacing: 0) {
                switch app.mode {
                case .browse: BrowseGrid(app: app)
                case .edit: EditorStage(app: app)
                }
                StatusBar(app: app)
            }
            .frame(minWidth: 520)
            .inspector(isPresented: Binding(get: { app.showInspector && app.mode == .edit }, set: { app.showInspector = $0 })) {
                InspectorView(app: app)
                    .inspectorColumnWidth(min: 300, ideal: 330, max: 440)
            }
        }
        .tint(WorkbenchTheme.neutralTint)
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar { WorkbenchToolbar(app: app) }
        // Above the canvas controls and video timeline in the editor.
        .overlay(alignment: .bottom) { ToastView(app: app).padding(.bottom, app.mode == .edit ? (editor.isVideo ? 200 : 92) : 44) }
        .background { KeyMonitor { app.handleKey($0) } }
        .sheet(item: Binding(get: { app.sheet }, set: { app.sheet = $0 })) { sheet in
            SheetContent(app: app, sheet: sheet)
        }
        .alert(item: Binding(get: { app.alert }, set: { app.alert = $0 })) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("好")))
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    if let url = try? await provider.loadItem(forTypeIdentifier: "public.file-url") as? Data,
                       let file = URL(dataRepresentation: url, relativeTo: nil) { urls.append(file) }
                }
                app.importURLs(urls)
            }
            return true
        }
        .onAppear {
            DebugSnapshot.runIfRequested { command, argument in DebugSnapshot.perform(command, argument, app: app) }
        }
    }

    private var title: String {
        if app.mode == .edit, let url = editor.url { return url.lastPathComponent }
        return L("Lucet 光集")
    }

    private var subtitle: String {
        if app.mode == .edit, let index = app.library.visibleIndex(of: app.library.currentID) {
            return "\(index + 1) / \(app.library.visible.count)"
        }
        return app.library.entries.isEmpty ? L("照片 · 视频 · Live Photo") : L("素材库 · \(app.library.entries.count) 项")
    }
}

/// Drops focus from text fields so single-key shortcuts reach the app.
@MainActor func endTextEditing() {
    guard let window = NSApp.keyWindow, window.firstResponder is NSText else { return }
    window.makeFirstResponder(nil)
}

/// Shown instead of the canvas when the open item can't be read, with the way out.
struct OpenFailureView: View {
    let app: AppModel
    let id: String
    let failure: OpenFailure

    var body: some View {
        let name = app.library.entry(id)?.name ?? ""
        VStack(spacing: 10) {
            Image(systemName: failure == .missing ? "questionmark.folder" : "exclamationmark.triangle")
                .font(.system(size: 34)).foregroundStyle(.secondary)
            switch failure {
            case .missing:
                Text("找不到原文件").font(.title3.weight(.semibold))
                Text("「\(name)」可能被移动、重命名或删除了，或者它所在的移动硬盘没有连接。")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack {
                    Button("重新定位…") { app.relocate(id) }.primaryButton()
                    Button("从素材库移除") { app.removeFromLibrary(id) }.glassButton()
                }
                .padding(.top, 6)
            case .unreadable(let detail):
                Text("无法打开这个文件").font(.title3.weight(.semibold))
                Text("「\(name)」可能已损坏，或者是光集暂不支持的格式。").foregroundStyle(.secondary).multilineTextAlignment(.center)
                Text(detail).font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center).textSelection(.enabled)
                HStack {
                    Button("在 Finder 中显示") { app.revealSelection() }.glassButton()
                    Button("从素材库移除") { app.removeFromLibrary(id) }.glassButton()
                }
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: 420)
        .padding(24)
    }
}

/// Canvas (image or video) plus the video timeline.
struct EditorStage: View {
    let app: AppModel
    var editor: EditorModel { app.editor }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                WorkbenchTheme.canvas
                if let player = editor.player {
                    VideoCanvas(player: player)
                } else if let frame = editor.frame {
                    ImageCanvas(editor: editor, frame: frame, documentID: editor.documentID, compare: editor.compareMode,
                                split: editor.splitPosition, clipping: editor.showClipping, grid: editor.showGrid,
                                hdr: editor.hdrPreview, influence: editor.influence)
                    if editor.cropEditing, editor.frameIsUncropped {
                        CropOverlay(editor: editor, pixelSize: frame.fullSize)
                    } else if app.inspectorTab == .color, editor.zoomPercent == nil, editor.compareMode == .off,
                              let layer = editor.selectedLocal, let source = editor.sourcePixelSize,
                              let mapping = try? GeometryMapping(source: source, edits: editor.edits) {
                        LocalMaskOverlay(editor: editor, layer: layer, mapping: mapping)
                    }
                } else if editor.isLoading {
                    ProgressView("正在读取…").controlSize(.regular)
                } else if let failure = editor.openFailure, let id = app.library.currentID {
                    OpenFailureView(app: app, id: id, failure: failure)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "photo").font(.system(size: 36)).foregroundStyle(.tertiary)
                        Text("在左侧素材库选择一项开始编辑").foregroundStyle(.secondary)
                    }
                }
                CanvasHUD(editor: editor)
                if !app.showSidebar, !app.showInspector {
                    // Tab hides both panels; make the way back visible.
                    VStack {
                        HStack {
                            Button { app.showSidebar = true; app.showInspector = true } label: {
                                Label("显示面板（Tab）", systemImage: "sidebar.squares.leading")
                            }
                            .glassButton().controlSize(.small)
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(12)
                }
            }
            if editor.isVideo, editor.isLoaded { MediaTimeline(app: app) }
        }
    }
}

private struct CanvasHUD: View {
    let editor: EditorModel
    var body: some View {
        if editor.isLoaded {
            VStack {
                HStack(alignment: .top) {
                    if editor.compareMode == .split { label(L("原片")) }
                    Spacer()
                    let text = editor.compareMode == .split ? L("调整后") : editor.previewLabel
                    if !text.isEmpty { label(text) }
                }
                Spacer()
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        if let influence = editor.influence, !editor.isVideo { label(L("彩色部分 = 「\(influence.title)」影响的区域")) }
                        if editor.isLoadingFullResolution { label(L("正在载入原尺寸…")) }
                        if editor.showClipping { label(L("溢出：红 = 高光  蓝 = 暗部")) }
                    }
                    Spacer()
                }
                .overlay(alignment: .bottom) { CanvasControls(editor: editor) }
            }
            .padding(14)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.caption.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 5)
            .hudBackground().allowsHitTesting(false)
    }
}

/// Floating Liquid Glass control bar: zoom, compare, clipping and grid.
private struct CanvasControls: View {
    let editor: EditorModel
    var body: some View {
        HStack(spacing: 2) {
            if !editor.isVideo {
                control(editor.zoomPercent.map { "\($0)%" } ?? L("适合"), help: L("适合窗口 ↔ 100%（Z 或双击画面）")) { editor.toggleZoom() }
                    .monospacedDigit()
                icon("minus.magnifyingglass", help: L("缩小（⌘−）")) { editor.zoom(by: 1 / 1.5) }
                icon("plus.magnifyingglass", help: L("放大（⌘+）")) { editor.zoom(by: 1.5) }
                Divider().frame(height: 16).padding(.horizontal, 4)
                icon("square.split.2x1", active: editor.compareMode == .split, help: L("左右分屏对比（Y）")) {
                    editor.compareMode = editor.compareMode == .split ? .off : .split
                }
            }
            icon("circle.lefthalf.filled", active: editor.compareMode == .original, help: L("查看原片（\\ 或 M）")) {
                editor.compareMode = editor.compareMode == .original ? .off : .original
            }
            if !editor.isVideo {
                icon("exclamationmark.triangle", active: editor.showClipping, help: L("高光 / 暗部溢出（J）")) { editor.showClipping.toggle() }
            }
            icon("grid", active: editor.showGrid, help: L("三分网格")) { editor.showGrid.toggle() }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .hudBackground()
    }

    private func icon(_ name: String, active: Bool = false, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? WorkbenchTheme.accent : .primary)
                .frame(width: 28, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(help)
    }

    private func control(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.caption.weight(.semibold)).frame(minWidth: 44, minHeight: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
    }
}

private struct StatusBar: View {
    let app: AppModel
    var body: some View {
        HStack(spacing: 10) {
            if app.editor.isLoading { ProgressView().controlSize(.small) }
            Text(app.editor.status).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                .help(app.editor.status)
            Spacer(minLength: 8)
            if let job = app.exports.runningJob {
                Text(job.title).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                if let progress = job.progress {
                    ProgressView(value: progress).frame(width: 90).controlSize(.small)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(WorkbenchTheme.panel)
        .overlay(alignment: .top) { WorkbenchTheme.hairline.frame(height: 1) }
    }
}

private struct ToastView: View {
    let app: AppModel
    var body: some View {
        if let toast = app.toast {
            HStack(spacing: 12) {
                Text(toast.message).font(.callout).lineLimit(2)
                ForEach(toast.actions) { action in
                    Button(action.title) { action.perform(); app.dismissToast() }.buttonStyle(.borderless).font(.callout.weight(.semibold))
                }
                Button { app.dismissToast() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .hudBackground()
            .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
            .frame(maxWidth: 640)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(toast.id)
        }
    }
}

struct WorkbenchToolbar: ToolbarContent {
    let app: AppModel
    var editor: EditorModel { app.editor }

    private var modeSwitch: some View {
        GlassSegmentedControl(options: WorkspaceMode.allCases,
                              selection: Binding(get: { app.mode }, set: { mode in
                                  if mode == .edit, !editor.isLoaded { app.openSelection() } else { app.mode = mode }
                              }),
                              title: { $0 == .browse ? L("浏览") : L("编辑") }, accessibilityTitle: L("视图"))
            .frame(width: 140)
            .help("浏览（G） / 编辑（E）")
    }

    var body: some ToolbarContent {
        // Just the two words and a sliding glass highlight: no toolbar platter, no track.
        if #available(macOS 26, *) {
            ToolbarItem(placement: .principal) { modeSwitch }.sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .principal) { modeSwitch }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if app.mode == .edit {
                Button(action: editor.undo) { Image(systemName: "arrow.uturn.backward") }
                    .help("撤销（⌘Z）").disabled(!editor.canUndo)
                Button(action: editor.redo) { Image(systemName: "arrow.uturn.forward") }
                    .help("重做（⇧⌘Z）").disabled(!editor.canRedo)
                HistoryButton(editor: editor)
                Menu {
                    Button("关闭对比") { editor.compareMode = .off }
                    Button("原片（\\ 或 M）") { editor.compareMode = .original }
                    if !editor.isVideo { Button("左右分屏（Y）") { editor.compareMode = .split } }
                } label: {
                    Image(systemName: editor.compareMode == .off ? "square.split.2x1" : "square.split.2x1.fill")
                } primaryAction: {
                    editor.compareMode = editor.compareMode == .off ? (editor.isVideo ? .original : .split) : .off
                }
                .help("对比前后：点按切换分屏，按住选择方式")
                .disabled(!editor.isLoaded)
            }
            Menu {
                Button("导出当前…") { app.exportCurrent() }.disabled(!editor.isLoaded)
                Button("共享…") { app.shareCurrent() }.disabled(!editor.isLoaded)
                Button("导出所选…") { app.exportSelection() }.disabled(app.library.actionTargets.isEmpty)
                if editor.isVideo { Button("制作 Live Photo…", action: app.makeLive) }
                Button("拼图 Live…", action: app.openCollage)
            } label: { Label("导出", systemImage: "square.and.arrow.up") }
                .help("导出副本，原片从不修改")
            if !app.exports.jobs.isEmpty {
                ExportJobsButton(exports: app.exports)
            }
            if app.mode == .edit {
                Button { withAnimation(.snappy(duration: 0.2)) { app.showInspector.toggle() } } label: { Image(systemName: "sidebar.trailing") }
                    .help("显示或隐藏检查器（⌘⌥I）")
            }
        }
    }
}

private struct ExportJobsButton: View {
    let exports: ExportQueue
    @UIState private var showing = false
    var body: some View {
        Button { showing.toggle() } label: {
            ZStack {
                if let progress = exports.runningJob?.progress {
                    ProgressView(value: progress).progressViewStyle(.circular).controlSize(.small)
                } else if exports.activeCount > 0 {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "tray.full")
                }
            }
            .frame(width: 20)
        }
        .help(exports.activeCount > 0 ? L("\(exports.activeCount) 项导出进行中") : L("导出记录"))
        .popover(isPresented: $showing, arrowEdge: .bottom) { ExportJobsList(exports: exports) }
    }
}

private struct ExportJobsList: View {
    let exports: ExportQueue
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("导出").font(.headline)
                Spacer()
                Button("清除已完成", action: exports.clearFinished).buttonStyle(.borderless)
            }
            .padding(12)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(exports.jobs) { job in
                        HStack(spacing: 10) {
                            icon(job)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(job.title).lineLimit(1)
                                Text(detail(job)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                if job.state == .running, let progress = job.progress { ProgressView(value: progress).controlSize(.small) }
                            }
                            Spacer()
                            if job.isActive {
                                Button("取消") { exports.cancel(job.id) }.buttonStyle(.borderless)
                            } else if job.state == .finished {
                                Button { exports.reveal(job) } label: { Image(systemName: "magnifyingglass") }
                                    .buttonStyle(.borderless).help("在 Finder 中显示")
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 360)
    }

    @ViewBuilder private func icon(_ job: ExportQueue.Job) -> some View {
        switch job.state {
        case .waiting: Image(systemName: "clock").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.small)
        case .finished: Image(systemName: "checkmark.circle.fill").foregroundStyle(WorkbenchTheme.pick)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .cancelled: Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        }
    }

    private func detail(_ job: ExportQueue.Job) -> String {
        switch job.state {
        case .waiting: L("等待中")
        case .running: job.detail.isEmpty ? L("进行中") : job.detail
        case .finished: job.detail
        case .failed(let message): message
        case .cancelled: L("已取消")
        }
    }
}

/// Window-level single-key shortcuts that never steal keys from text fields or sheets.
struct KeyMonitor: NSViewRepresentable {
    let handler: (NSEvent) -> Bool

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.handler = handler
        return view
    }
    func updateNSView(_ view: MonitorView, context: Context) { view.handler = handler }

    final class MonitorView: NSView {
        var handler: ((NSEvent) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            // Do not start with the search field focused, or single-key shortcuts would type into it.
            DispatchQueue.main.async { [weak self] in
                if let window = self?.window, window.firstResponder is NSText { window.makeFirstResponder(nil) }
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window, window.isKeyWindow,
                      window.attachedSheet == nil, !(window.firstResponder is NSText),
                      let handler = self.handler else { return event }
                return handler(event) ? nil : event
            }
        }
    }
}
