import AppKit
import MediaCore
import Photos
import SwiftUI

struct SheetContent: View {
    let app: AppModel
    let sheet: ActiveSheet
    var body: some View {
        content.tint(WorkbenchTheme.accent)
    }
    @ViewBuilder private var content: some View {
        switch sheet {
        case .export(let target): ExportOptionsSheet(app: app, target: target)
        case .sync: SyncSheet(app: app)
        case .snapshots: SnapshotSheet(app: app)
        case .collage: CollageSheet(app: app)
        case .savePreset: SavePresetSheet(app: app)
        case .shortcuts: ShortcutsSheet(app: app)
        case .tutorSettings: TutorSettingsSheet(tutor: app.tutor)
        case .lesson(let id): if let lesson = Lesson.lesson(id) { LessonPlayer(app: app, lesson: lesson) }
        case .livePreview(let resources): LivePreviewSheet(app: app, resources: resources)
        case .matchLook: MatchLookSheet(app: app)
        case .photosImport: PhotosImportSheet(app: app)
        case .compare(let ids): CullingSheet(app: app, ids: ids)
        case .newProject(let ids): NewProjectSheet(app: app, ids: ids)
        case .renameProject(let id): RenameProjectSheet(app: app, projectID: id)
        }
    }
}

struct SheetHeader: View {
    let title: String
    var subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title3.weight(.semibold))
            if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

// MARK: - Export options

struct ExportOptionsSheet: View {
    let app: AppModel
    let target: ExportTarget
    @UIState private var settings = ExportSettings()
    @UIState private var exampleDay = ""
    @UIState private var naming = false
    @UIState private var presetName = ""
    /// The watermark text, kept while the watermark is switched off and on again.
    @AppStorage("export.watermarkText") private var watermarkText = ""

    private var entries: [LibraryEntry] { target == .current ? app.currentEntry.map { [$0] } ?? [] : app.library.actionTargets }
    private var hasImages: Bool { target == .current ? !app.editor.isVideo : entries.contains { !$0.isVideo } }
    private var hasVideos: Bool { target == .current ? app.editor.isVideo : entries.contains { $0.isVideo || $0.hasLiveCompanion } }
    private var presets: [ExportPreset] { ExportPreset.builtIns + app.exportPresets }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                SheetHeader(title: target == .current ? L("导出副本") : L("导出 \(entries.count) 项"),
                            subtitle: L("导出会在后台进行，你可以继续浏览和编辑。原片从不修改。"))
                Spacer()
                presetMenu
            }
            Form {
                Section {
                    Picker("保存到", selection: $settings.destination) {
                        ForEach(ExportDestination.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(settings.destination == .photos
                         ? "直接存入 Mac 的「照片」，开启 iCloud 照片后会同步到 iPhone。Live 片段会存为真正的 Live Photo。"
                         : "存为文件，可以选择位置。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if hasImages { photoSection }
                if hasVideos {
                    Section("视频") {
                        Picker("编码", selection: $settings.codec) {
                            ForEach(VideoCodecChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        if target == .selection {
                            Toggle("只导出有效的 Live 片段（0.5–3 秒）", isOn: $settings.liveOnly)
                        }
                    }
                }
                namingSection
                if hasImages { watermarkSection }
            }
            .formStyle(.grouped)
            .frame(maxHeight: 560)
            HStack {
                Spacer()
                Button("取消") { app.sheet = nil }.keyboardShortcut(.cancelAction)
                Button(settings.destination == .photos ? L("存到「照片」") : target == .current ? L("选择位置…") : L("选择文件夹…")) {
                    if let mark = settings.image.watermark, mark.cleanedText.isEmpty { settings.image.watermark = nil }
                    app.exportSettings = settings
                    app.confirmExport(target)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(entries.isEmpty || ExportNaming.problem(settings.naming) != nil)
            }
        }
        .padding(22)
        .frame(width: 500)
        .onAppear {
            settings = app.exportSettings
            if let first = entries.first { exampleDay = ExportNaming.day(of: first.url) }
        }
        .alert("存为导出预设", isPresented: $naming) {
            TextField("预设名称", text: $presetName)
            Button("取消", role: .cancel) {}
            Button("存储") { savePreset() }.disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
        } message: {
            Text("保存照片格式、尺寸、分辨率、文件名规则和水印。")
        }
    }

    private var presetMenu: some View {
        Menu {
            ForEach(presets) { preset in
                Button { settings = preset.applied(to: settings) } label: {
                    if preset.matches(settings) { Label(preset.name, systemImage: "checkmark") } else { Text(preset.name) }
                }
            }
            Divider()
            Button("存为预设…") { presetName = ""; naming = true }
            if !app.exportPresets.isEmpty {
                Menu("删除预设") {
                    ForEach(app.exportPresets) { preset in
                        Button(preset.name) { app.exportPresets.removeAll { $0.id == preset.id } }
                    }
                }
            }
        } label: {
            Text(presets.first { $0.matches(settings) }?.name ?? L("预设"))
        }
        .menuStyle(.button).fixedSize()
        .help("一键套用常用的导出设置，或把现在的设置存成预设")
    }

    private var photoSection: some View {
        Section("照片") {
            Picker("格式", selection: $settings.image.format) {
                ForEach(ImageExportOptions.Format.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if settings.image.format.isLossy {
                LabeledContent("质量") {
                    HStack {
                        Slider(value: $settings.image.quality, in: 0.5...1)
                        Text("\(Int((settings.image.quality * 100).rounded()))").monospacedDigit().frame(width: 30)
                    }
                }
            }
            Picker("尺寸", selection: Binding(get: { settings.image.maxLongEdge ?? 0 }, set: { settings.image.maxLongEdge = $0 == 0 ? nil : $0 })) {
                Text("原始尺寸").tag(0)
                Text("长边 4096 px").tag(4096)
                Text("长边 2048 px").tag(2048)
                Text("长边 1080 px（社交平台）").tag(1080)
            }
            Picker("打印分辨率", selection: Binding(get: { settings.image.dpi ?? 72 }, set: { settings.image.dpi = $0 == 72 ? nil : $0 })) {
                Text("72 dpi（屏幕）").tag(72)
                Text("150 dpi").tag(150)
                Text("300 dpi（打印）").tag(300)
            }
            .help("只写入文件信息，告诉打印软件每英寸放多少像素；不改变像素数量")
            if target == .selection || app.editor.sourceIsHDR {
                Toggle(isOn: $settings.image.keepHDR) {
                    Text("保留 HDR")
                    Text(settings.image.format == .png ? L("PNG 不支持 HDR，会导出普通亮度。")
                         : L("HDR 照片带增益图导出：在 HDR 屏幕上高光更亮，其他设备显示普通版本。调色也会保留。"))
                }
                .disabled(settings.image.format == .png)
            }
            Toggle("保留拍摄信息（时间、相机、镜头）", isOn: $settings.image.keepMetadata)
            Toggle("移除位置信息", isOn: $settings.image.removeLocation).disabled(!settings.image.keepMetadata)
        }
    }

    private var namingSection: some View {
        Section {
            LabeledContent("文件名") {
                HStack(spacing: 6) {
                    TextField("文件名", text: $settings.naming, prompt: Text(ExportNaming.defaultPattern)).labelsHidden()
                    Menu("插入") {
                        Button("原文件名 {name}") { insert("name") }
                        Button("拍摄日期 {date}") { insert("date") }
                        Button("序号 {seq}") { insert("seq") }
                        Button("宽度 {width}") { insert("width") }
                        Button("高度 {height}") { insert("height") }
                    }
                    .menuStyle(.button).fixedSize()
                }
            }
        } footer: {
            if let problem = ExportNaming.problem(settings.naming) {
                Text(problem).font(.caption).foregroundStyle(.red)
            } else {
                Text(L("例如：\(example)")).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    /// The first file's name under the current pattern (the capture day is read once, on appear).
    private var example: String {
        let first = entries.first
        let stem = first?.url.deletingPathExtension().lastPathComponent ?? "DJI_0001"
        let size: CGSize? = target == .current ? app.editor.metadata.map { CGSize(width: $0.displayWidth, height: $0.displayHeight) } : nil
        let named = target == .current && settings.destination == .folder && settings.naming == ExportNaming.defaultPattern
            ? stem + L("-编辑")
            : ExportNaming.name(settings.naming, .init(name: stem, day: exampleDay.isEmpty ? "20261016" : exampleDay, sequence: 1,
                                                       total: max(1, entries.count), width: size.map { Int($0.width) }, height: size.map { Int($0.height) }))
        return named + "." + (first?.isVideo ?? false ? "mov" : settings.image.format.fileExtension)
    }

    private func insert(_ token: String) {
        let separator = settings.naming.isEmpty || settings.naming.hasSuffix("-") || settings.naming.hasSuffix("_") ? "" : "-"
        settings.naming += separator + "{\(token)}"
    }

    private var watermark: Binding<Watermark> {
        Binding(get: { settings.image.watermark ?? Watermark(text: watermarkText) },
                set: { settings.image.watermark = $0; watermarkText = $0.text })
    }

    private var watermarkSection: some View {
        Section {
            Toggle("添加文字水印", isOn: Binding(get: { settings.image.watermark != nil },
                                              set: { settings.image.watermark = $0 ? Watermark(text: watermarkText) : nil }))
            if settings.image.watermark != nil {
                TextField("文字", text: watermark.text, prompt: Text("© 你的名字"), axis: .vertical).lineLimit(1...2)
                Picker("位置", selection: watermark.position) {
                    ForEach(Watermark.Position.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("颜色", selection: watermark.ink) {
                    ForEach(Watermark.Ink.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("大小") {
                    HStack {
                        Slider(value: watermark.size, in: 1...8)
                        Text(String(format: "%.1f%%", watermark.wrappedValue.size)).monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
                LabeledContent("不透明度") {
                    HStack {
                        Slider(value: watermark.opacity, in: 0.05...1)
                        Text("\(Int((watermark.wrappedValue.opacity * 100).rounded()))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
                Toggle("阴影（在明亮或杂乱的背景上更清楚）", isOn: watermark.shadow)
            }
        } header: {
            Text("水印")
        } footer: {
            if settings.image.watermark != nil {
                Text("大小按照片短边的百分比计算，所以不同尺寸的导出看起来一样。水印只加在照片上。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func savePreset() {
        let name = presetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        var image = settings.image
        if let mark = image.watermark, mark.cleanedText.isEmpty { image.watermark = nil }
        let preset = ExportPreset(id: UUID().uuidString, name: name, image: image, naming: settings.naming)
        app.exportPresets.removeAll { $0.name == name }
        app.exportPresets.append(preset)
    }
}

// MARK: - Sync

struct SyncSheet: View {
    let app: AppModel
    /// Exposure usually differs shot to shot, so it starts unchecked (as do detail and effects).
    @UIState private var sections: Set<AdjustmentSection> = [.tone, .whiteBalance, .color]
    @UIState private var stages: Set<GradeStage> = [.wheels, .curves, .hsl]
    @UIState private var includeLUT = true

    var body: some View {
        let count = app.library.selection.subtracting([app.library.currentID ?? ""]).count
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: L("同步调色"), subtitle: L("把当前素材的所选调色复制到另外 \(count) 项。曝光默认不同步（每张往往不同）；裁切、片段、封面、速度与声音保持各自设置。"))
            VStack(alignment: .leading, spacing: 8) {
                ForEach(AdjustmentSection.allCases, id: \.self) { section in
                    Toggle(isOn: Binding(get: { sections.contains(section) }, set: { if $0 { sections.insert(section) } else { sections.remove(section) } })) {
                        HStack(spacing: 6) {
                            Text(section.title)
                            Text(section.parameters.map(\.title).joined(separator: L("、"))).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .help(section.summary)
                }
                ForEach([GradeStage.wheels, .curves, .hsl], id: \.self) { stage in
                    Toggle(stage == .hsl ? L("HSL 色彩混合") : stage.title, isOn: Binding(get: { stages.contains(stage) }, set: { if $0 { stages.insert(stage) } else { stages.remove(stage) } }))
                }
                Toggle("风格 LUT 与强度", isOn: $includeLUT)
            }
            .toggleStyle(.checkbox)
            Text("离线或已被修改的原片会跳过并计数。同步后可在提示中一键撤回。").font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { app.sheet = nil }.keyboardShortcut(.cancelAction)
                Button("应用到 \(count) 项") {
                    app.sheet = nil
                    app.synchronize(sections: sections, includeLUT: includeLUT, stages: stages)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(count == 0 || (sections.isEmpty && stages.isEmpty && !includeLUT))
            }
        }
        .padding(22).frame(width: 440)
    }
}

// MARK: - Snapshots

struct SnapshotSheet: View {
    let app: AppModel
    @UIState private var name = ""
    @UIState private var snapshots: [SavedSnapshot] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: L("快照与版本"), subtitle: L("快照保存一个命名版本，重启后仍可恢复。只保存参数，不复制原片。"))
            HStack {
                TextField("版本名称，例如：自然暖调", text: $name).textFieldStyle(.roundedBorder)
                Button("保存当前版本") { app.editor.saveSnapshot(named: name); name = ""; snapshots = app.editor.snapshots() }
            }
            List(snapshots) { value in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(value.name)
                        Text(value.record.savedAt.formatted(date: .numeric, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("恢复") { app.editor.restoreSnapshot(value); app.sheet = nil }
                }
            }
            .frame(height: 220)
            .overlay { if snapshots.isEmpty { Text("尚未保存快照").foregroundStyle(.secondary) } }
            HStack { Spacer(); Button("完成") { app.sheet = nil }.keyboardShortcut(.defaultAction) }
        }
        .padding(22).frame(width: 480)
        .onAppear { snapshots = app.editor.snapshots() }
    }
}

// MARK: - Presets

struct SavePresetSheet: View {
    let app: AppModel
    @UIState private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: L("存为预设"), subtitle: L("保存当前的基础调整、色轮、曲线、HSL 与 LUT，可套用到任意照片或视频。"))
            TextField("预设名称", text: $name).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") { app.sheet = nil }.keyboardShortcut(.cancelAction)
                Button("保存") { app.savePreset(named: name); app.sheet = nil }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 400)
    }
}

// MARK: - Shortcuts

struct ShortcutsSheet: View {
    let app: AppModel
    private let groups: [(String, [(String, String)])] = [
        (L("浏览"), [("G / E", L("浏览网格 / 编辑")), ("↑ ↓ ← →", L("上一项 / 下一项")), (L("⏎ 或 空格"), L("打开所选")),
                 ("0 – 5", L("评级")), ("P / X / U", L("选用 / 排除 / 取消标记")), (L("⌘ / ⇧ 点按"), L("多选")), ("⌘A", L("全选")), ("Tab", L("隐藏 / 显示两侧面板")),
                 ("⌥⌘C", L("并排比较所选"))]),
        (L("编辑"), [("A", L("自动调整")), (L("\\ 或 M"), L("对比原片")), ("Y", L("左右分屏对比")), ("J", L("显示高光 / 暗部溢出")), (L("Z 或 空格"), L("适合窗口 ↔ 100%")),
                 ("⌘0 / ⌘1 / ⌘+ / ⌘−", L("适合 / 实际像素 / 放大 / 缩小")), ("⌘Z / ⇧⌘Z", L("撤销 / 重做")),
                 ("⇧⌘C / ⇧⌘V", L("拷贝 / 粘贴调色设置")), (L("双击参数名"), L("恢复默认"))]),
        (L("视频"), [(L("空格"), L("播放 / 暂停")), ("← →", L("逐帧")), ("I / O", L("设置入点 / 出点")), ("C", L("把播放头设为封面"))]),
        (L("其他"), [("⌘E / ⇧⌘E", L("导出当前 / 导出所选")), ("⌘S", L("立即保存配方")), ("?", L("显示本页"))])
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: L("键盘快捷键"))
            HStack(alignment: .top, spacing: 28) {
                ForEach(0..<2, id: \.self) { column in
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(groups.indices.filter { $0 % 2 == column }, id: \.self) { index in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(groups[index].0).font(.headline)
                                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                                    ForEach(groups[index].1, id: \.0) { item in
                                        GridRow {
                                            Text(item.0).font(.callout.monospaced()).fixedSize()
                                            Text(item.1).font(.callout).foregroundStyle(.secondary).fixedSize()
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            HStack { Spacer(); Button("完成") { app.sheet = nil }.keyboardShortcut(.defaultAction) }
        }
        .padding(24)
    }
}

// MARK: - Live preview

struct LivePreviewSheet: View {
    let app: AppModel
    let resources: LivePhotoResources
    @UIState private var photo: PHLivePhoto?
    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Live Photo").font(.headline)
                Spacer()
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([resources.imageURL]) }
                Button("完成") { app.sheet = nil }.keyboardShortcut(.defaultAction)
            }
            ZStack {
                Color.black
                if let photo { LiveCanvas(photo: photo) } else { ProgressView() }
            }
            .frame(minWidth: 640, minHeight: 420)
            Text("按住画面播放").font(.callout).foregroundStyle(.secondary)
        }
        .padding(22)
        .task { photo = try? await LivePhotoPipeline.load(imageURL: resources.imageURL, videoURL: resources.videoURL) }
    }
}

// MARK: - Ask settings

struct TutorSettingsSheet: View {
    let tutor: TutorModel
    @UIState private var keyInput = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("问问这张照片 · 设置").font(.title3.weight(.semibold))
                Text("由 Anthropic 的 Claude 模型回答关于照片的问题，讲解会结合画面、参数和你的学习水平。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Form {
                Section {
                    Toggle("启用 AI 提问", isOn: Binding(get: { tutor.settings.enabled }, set: { tutor.settings.enabled = $0 }))
                }
                Section("发送的内容") {
                    Toggle("附带预览图（最长边 1024 px 的 JPEG，不含拍摄与位置信息）",
                           isOn: Binding(get: { tutor.settings.sendPreview }, set: { tutor.settings.sendPreview = $0 }))
                    Text("每次提问还会发送：画面统计、当前调色参数、你选择的水平与兴趣。原片不会上传；只有你点「提问」时才会发送。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Section("API 密钥") {
                    if tutor.hasKey {
                        HStack {
                            Label("已保存在钥匙串中", systemImage: "key.fill")
                            Spacer()
                            Button("移除", role: .destructive, action: tutor.removeKey)
                        }
                    } else {
                        HStack {
                            SecureField("sk-ant-…", text: $keyInput)
                            Button("保存") { tutor.saveKey(keyInput); keyInput = "" }
                                .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    Text("在 console.anthropic.com 创建密钥。费用按你的 Anthropic 账户计费；中国大陆网络可能无法直接访问。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Section("模型") {
                    Picker("模型", selection: Binding(get: { tutor.settings.model }, set: { tutor.settings.model = $0 })) {
                        ForEach(ClaudePhotoTutor.models) { Text($0.title).tag($0.id) }
                    }
                    if let option = ClaudePhotoTutor.models.first(where: { $0.id == tutor.settings.model }) {
                        Text(option.note).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(22)
        .frame(width: 520)
    }
}

// MARK: - Match look

/// Pick a photo whose colors you like; the current photo moves toward them as a LUT.
struct MatchLookSheet: View {
    let app: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: L("匹配另一张照片的色调"),
                        subtitle: L("选一张你喜欢它颜色的照片（按它现在调好的样子）。这张照片的整体明暗和颜色会向它靠拢，结果是一个 LUT，可以用强度调整，也可以撤销。"))
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 10)], spacing: 12) {
                    ForEach(app.matchCandidates) { entry in
                        Button { app.matchLook(to: entry.id) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                ThumbnailImage(entry: entry, store: app.thumbnails)
                                    .aspectRatio(4 / 3, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                Text(entry.url.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 360)
            HStack {
                Text("方法：在 Lab 色彩空间里对齐两张照片的平均值和分布（Reinhard 色彩迁移）。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { app.sheet = nil }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(22).frame(width: 640)
    }
}
