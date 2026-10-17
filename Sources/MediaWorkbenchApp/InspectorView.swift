import AppKit
import MediaCore
import SwiftUI

enum InspectorTab: String, CaseIterable {
    case color, geometry, audio, learn, info
    var title: String {
        switch self { case .color: L("调色"); case .geometry: L("构图"); case .audio: L("声音"); case .learn: L("学习"); case .info: L("信息") }
    }
}

struct InspectorView: View {
    let app: AppModel
    var editor: EditorModel { app.editor }

    var body: some View {
        let tabs = InspectorTab.allCases.filter { editor.isVideo || $0 != .audio }
        let tab = app.inspectorTab
        VStack(spacing: 0) {
            GlassSegmentedControl(options: tabs, selection: Binding(get: { tabs.contains(tab) ? tab : .color }, set: { app.inspectorTab = $0 }),
                                  title: { $0.title }, accessibilityTitle: L("检查器"))
                .padding(.horizontal, 12).padding(.vertical, 8)
            WorkbenchTheme.hairline.frame(height: 1)
            if editor.isLoaded, let context = editor.projectContext {
                ProjectEditBar(app: app, context: context)
            }
            if editor.isLoaded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        switch tabs.contains(tab) ? tab : .color {
                        case .color: ColorPanel(app: app)
                        case .geometry: GeometryPanel(editor: editor)
                        case .audio: AudioPanel(app: app)
                        case .learn: LearnPanel(app: app)
                        case .info: InfoPanel(app: app)
                        }
                    }
                    .padding(.horizontal, 12).padding(.bottom, 12)
                }
                .scrollIndicators(.automatic)
                footer
            } else {
                VStack(spacing: 8) {
                    Spacer()
                    if editor.isLoading { ProgressView().controlSize(.small) }
                    Text(editor.isLoading ? L("正在读取…") : L("打开一张照片或一段视频后，在这里调色。"))
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Spacer()
                }
                .padding(24)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Label(editor.draftStatus, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
                .help("编辑自动保存为配方，原片从不修改。")
            Spacer()
            Button("复位全部", action: editor.resetAll).buttonStyle(.borderless).font(.caption).help(L("恢复原片画面（可撤销）"))
        }
        .padding(.horizontal, 12).frame(height: 30)
        .overlay(alignment: .top) { WorkbenchTheme.hairline.frame(height: 1) }
    }
}

// MARK: - Color

struct ColorPanel: View {
    let app: AppModel
    var editor: EditorModel { app.editor }

    private func stage(_ stage: GradeStage) -> Binding<Bool> {
        Binding(get: { editor.isStageOn(stage) }, set: { editor.setStage(stage, on: $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if app.colorMode == .simple { simple } else { full }
        }
    }

    /// 自动 for everyone, plus the 简单 / 完整 switch.
    private var header: some View {
        HStack(spacing: 10) {
            Button { app.autoEnhance() } label: {
                Label("自动", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
            }
            .glassButton()
            .help("根据这张照片自动调整曝光、影调、白平衡和色彩（A）。可撤销。")
            GlassSegmentedControl(options: ColorMode.allCases, selection: Binding(get: { app.colorMode }, set: { app.colorMode = $0 }),
                                  title: { $0.title }, size: .small, accessibilityTitle: L("调色模式"))
                .frame(width: 112)
                .help("简单：几个常用滑块。完整：示波器、色轮、曲线、HSL、LUT 等全部工具。")
        }
        .padding(.top, 10).padding(.bottom, 6)
    }

    /// A few plain-language controls; everything else lives in 完整.
    private var simple: some View {
        VStack(alignment: .leading, spacing: 0) {
            InsightStrip(app: app)
            PresetStrip(app: app)
            InspectorSection(L("调整"), help: L("最常用的几项。需要更多控制时切换到「完整」。"), onReset: { editor.resetStage(.basic) }) {
                let values = editor.adjustments
                ZoneHistogramFeed(editor: editor).padding(.bottom, 6)
                VStack(spacing: 2) {
                    ForEach(SimpleControl.all, id: \.parameter) { control in
                        ParameterRow(title: control.title, value: values[control.parameter], range: control.parameter.range,
                                     step: control.parameter == .exposure ? 0.05 : 1, decimals: control.parameter == .exposure ? 1 : 0,
                                     help: control.hint + "\n\n" + control.parameter.explanation,
                                     influence: app.learner.hoverHints ? InfluenceKind.forParameter(control.parameter) : nil,
                                     onChange: { editor.setAdjustment(control.parameter, $0) }, onEditing: editor.beginEditing,
                                     onHover: { editor.hoverInfluence = $0 }, onFocus: { editor.focus(control.parameter, $0) })
                            .equatable()
                    }
                }
            }
            if !editor.isVideo {
                LocalAdjustmentSection(editor: editor)
            }
            if editor.edits.usesAdvancedTools {
                Label("这张照片还用了曲线、色轮、HSL 或 LUT 等调整，切换到「完整」可以查看。", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
            }
        }
    }

    private var full: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScopePanel(editor: editor, level: app.learner.level).padding(.top, 4).padding(.bottom, 4)
            InsightStrip(app: app)
            PresetStrip(app: app)
            InspectorSection(L("基础"), number: 1, isOn: stage(.basic), help: L("曝光、影调、白平衡与色彩"), onReset: { editor.resetStage(.basic) }) {
                VStack(spacing: 6) {
                    ForEach([AdjustmentSection.exposure, .tone, .whiteBalance, .color], id: \.self) { section in
                        AdjustmentRows(editor: editor, section: section, hints: app.learner.hoverHints)
                    }
                }
            }
            InspectorSection(L("色轮"), number: 2, isOn: stage(.wheels),
                             help: L("DaVinci 式一级校色：暗部 / 中间调 / 亮部 / 整体。拖动色点偏色，下方滑块调亮度；按住 ⌥ 精细拖动。"),
                             startsCollapsed: true, onReset: { editor.resetStage(.wheels) }) {
                WheelGrid(editor: editor)
            }
            InspectorSection(L("曲线"), number: 3, isOn: stage(.curves), help: L("RGB 主曲线与红绿蓝单通道曲线。"),
                             startsCollapsed: true, onReset: { editor.resetStage(.curves) }) {
                CurveSection(editor: editor)
            }
            InspectorSection(L("HSL 色彩混合"), number: 4, isOn: stage(.hsl), help: L("分别调整 8 个色系的色相、饱和度与明亮度。"),
                             startsCollapsed: true, onReset: { editor.resetStage(.hsl) }) {
                HSLPanel(editor: editor)
            }
            InspectorSection(L("风格 LUT"), number: 5, isOn: stage(.lut),
                             help: L("LUT 把颜色映射为另一种风格。相机 Log 素材需先套用对应的转换 LUT。"), onReset: { editor.resetStage(.lut) }) {
                LUTControls(app: app)
            }
            InspectorSection(L("细节"), number: 6, isOn: stage(.detail), help: L("降噪和去雾在调色之前，黑白在 HSL 之后；锐化、褪色、暗角和颗粒最后进行。"),
                             startsCollapsed: true, onReset: { editor.resetStage(.detail) }) {
                VStack(spacing: 6) {
                    AdjustmentRows(editor: editor, section: .detail, hints: app.learner.hoverHints)
                    AdjustmentRows(editor: editor, section: .effects, hints: app.learner.hoverHints)
                }
            }
            if !editor.isVideo {
                LocalAdjustmentSection(editor: editor, number: 7, isOn: stage(.local))
            }
            HDRSection(editor: editor)
        }
    }
}

/// The 简单 mode's controls, named the way people describe photos.
struct SimpleControl {
    let parameter: AdjustmentParameter
    let title: String
    let hint: String
    static let all = [
        SimpleControl(parameter: .exposure, title: L("亮度"), hint: L("整张照片变亮或变暗。")),
        SimpleControl(parameter: .contrast, title: L("对比度"), hint: L("亮的更亮、暗的更暗，画面更有力；往左更柔和。")),
        SimpleControl(parameter: .highlights, title: L("亮部"), hint: L("往左压暗最亮的地方，比如找回天空和云的层次。")),
        SimpleControl(parameter: .shadows, title: L("暗部"), hint: L("往右提亮阴影里的细节，比如逆光的人脸。")),
        SimpleControl(parameter: .warmth, title: L("冷暖"), hint: L("往右更暖（偏黄），往左更冷（偏蓝）。")),
        SimpleControl(parameter: .vibrance, title: L("鲜艳度"), hint: L("让颜色更鲜艳，优先增强偏淡的颜色，肤色不易过艳。")),
    ]
}

extension MediaEdits {
    /// Edits the 简单 mode doesn't show.
    var usesAdvancedTools: Bool {
        (lut != nil) || !wheels.isNeutral || !curves.isIdentity || !hsl.isNeutral
    }
}

/// Reads curves and scopes in its own body so scope refreshes don't redraw the whole panel.
struct CurveSection: View {
    let editor: EditorModel
    var body: some View {
        CurveEditor(curves: editor.curves, histogram: editor.scopes?.histogram,
                    onChange: { editor.setCurve($0, $1) }, onEditing: editor.beginEditing)
    }
}

/// One photographic group (影调, 白平衡…): a small heading with its definition as a
/// tooltip, a reset that appears only when something in the group changed, then the rows.
struct AdjustmentRows: View {
    let editor: EditorModel
    let section: AdjustmentSection
    var hints = true
    var body: some View {
        let values = editor.adjustments
        let changed = section.parameters.contains { values[$0] != 0 }
        VStack(spacing: 1) {
            HStack(spacing: 4) {
                Text(section.title).font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    .help(section.summary)
                Spacer()
                if changed {
                    Button { editor.resetSection(section) } label: { Image(systemName: "arrow.counterclockwise").font(.caption2) }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .help("复位\(section.title)").accessibilityLabel(L("复位\(section.title)"))
                }
            }
            .frame(height: 16)
            ForEach(section.parameters) { parameter in
                ParameterRow(title: parameter.title, value: values[parameter], range: parameter.range,
                             step: parameter == .exposure ? 0.05 : 1, decimals: parameter == .exposure ? 2 : 0,
                             suffix: parameter == .exposure ? "EV" : "", help: parameter.explanation,
                             influence: hints ? InfluenceKind.forParameter(parameter) : nil,
                             onChange: { editor.setAdjustment(parameter, $0) }, onEditing: editor.beginEditing,
                             onHover: { editor.hoverInfluence = $0 }, onFocus: { editor.focus(parameter, $0) })
                    .equatable()
            }
        }
    }
}

struct WheelGrid: View {
    let editor: EditorModel
    var body: some View {
        let wheels = editor.wheels
        Grid(horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                wheel(.lift, wheels); wheel(.gamma, wheels)
            }
            GridRow {
                wheel(.gain, wheels); wheel(.offset, wheels)
            }
        }
        .padding(.top, 2)
    }

    private func wheel(_ kind: ColorWheels.Wheel, _ wheels: ColorWheels) -> some View {
        ColorWheelControl(wheel: kind, value: wheels[kind], onChange: { editor.setWheel(kind, $0) }, onEditing: editor.beginEditing,
                          onHover: { editor.hoverInfluence = $0 })
            .equatable()
            .frame(maxWidth: .infinity)
    }
}

struct PresetStrip: View {
    let app: AppModel
    var editor: EditorModel { app.editor }
    @UIState private var previews: [UUID: CGImage] = [:]
    @UIState private var original: CGImage?
    /// The AI Look made for this photo, and how it looks.
    @UIState private var aiLook: CreativeLUT?
    @UIState private var aiPreview: CGImage?

    var body: some View {
        InspectorSection(L("预设"), help: L("一键套用整套调色（不影响裁切、片段与声音）。可把当前调色存为自己的预设。")) {
            if let frame = editor.frame {
                // Each look shown on this photo, so choosing is seeing (Lightroom / Photos style).
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64, maximum: 90), spacing: 6)], spacing: 8) {
                    tile(L("原图"), image: original, selected: !editor.edits.hasGrade) {
                        editor.applyLook(EditRecipe(), lut: nil, name: L("原图"))
                    }
                    if !editor.isVideo, AdaptiveLUT.shared != nil {
                        tile(L("AI 调色"), image: aiPreview, selected: editor.edits.lut?.name == L("AI 调色") && editor.edits.adjustments.isNeutral) {
                            app.aiLook(aiLook)
                        }
                        .help("为这张照片生成的调色：一个小型神经网络看过整张照片后，混合三张学来的 LUT（Image-Adaptive-3DLUT，在这台 Mac 上计算）")
                    }
                    ForEach(app.presets) { preset in
                        tile(preset.name, image: previews[preset.id], selected: matches(preset)) { app.applyPreset(preset) }
                            .contextMenu {
                                if !preset.builtIn { Button("删除预设「\(preset.name)」") { app.deletePreset(preset) } }
                            }
                    }
                    Button { app.sheet = .savePreset } label: {
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3]))
                                .overlay(Image(systemName: "plus").foregroundStyle(.secondary))
                                .aspectRatio(4 / 3, contentMode: .fit)
                            Text("存为预设").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain).help("把当前调色存为自己的预设")
                    if !editor.isVideo, !app.matchCandidates.isEmpty {
                        Button { app.sheet = .matchLook } label: {
                            VStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3]))
                                    .overlay(Image(systemName: "eyedropper.halffull").foregroundStyle(.secondary))
                                    .aspectRatio(4 / 3, contentMode: .fit)
                                Text("匹配色调").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain).help("让这张照片的整体色调向另一张靠拢")
                    }
                }
                .task(id: renderKey(frame)) { await render(frame) }
            } else {
                FlowLayout(spacing: 4) {
                    ForEach(app.presets) { preset in
                        Button(preset.name) { app.applyPreset(preset) }.glassButton().controlSize(.mini)
                    }
                    Button { app.sheet = .savePreset } label: { Label("存为预设", systemImage: "plus") }
                        .buttonStyle(.borderless).controlSize(.mini)
                }
            }
        }
    }

    private func tile(_ name: String, image: CGImage?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                // The tile's shape is fixed first; the picture fills it and is clipped.
                WorkbenchTheme.well
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .overlay {
                        if let image { Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.white.opacity(0.9) : .clear, lineWidth: 1.5))
                Text(name).font(.caption2).foregroundStyle(selected ? .primary : .secondary).lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("套用「\(name)」（可撤销）")
    }

    private func matches(_ preset: GradePreset) -> Bool {
        let r = preset.recipe, e = editor.edits
        return r.adjustments == e.adjustments && r.wheels == e.wheels && r.curves == e.curves && r.hsl == e.hsl
            && (r.lut == nil) == (e.lut == nil)
    }

    private func renderKey(_ frame: GradeFrame) -> String {
        let g = editor.geometry
        return "\(editor.documentID)|\(app.presets.map(\.id))|\(editor.degrees)|\(g.quarterTurns)\(g.mirrored)\(g.aspectRatio)\(g.cropScale)\(g.horizontal)\(g.vertical)"
    }

    private func render(_ frame: GradeFrame) async {
        let source = frame.original, headroom = frame.sourceHeadroom
        let presets = app.presets, drafts = app.drafts, video = editor.isVideo
        let shape = MediaEdits(degrees: editor.degrees, geometry: editor.geometry)
        let result = await Task.detached(priority: .utility) { () -> (CGImage?, [UUID: CGImage], CreativeLUT?, CGImage?) in
            let scale = min(1, 160 / max(source.extent.width, source.extent.height))
            let small = source.transformed(by: .init(scaleX: scale, y: scale))
            func draw(_ edits: MediaEdits) -> CGImage? {
                guard let graded = try? ColorPipeline.grade(small, edits: edits, sourceHeadroom: headroom),
                      let shaped = try? ColorPipeline.geometry(graded, edits: shape) else { return nil }
                let output = edits.hasGrade ? shaped : ColorPipeline.toneMap(shaped, sourceHeadroom: headroom)
                return ColorPipeline.shared.createCGImage(output, from: output.extent.integral, format: .RGBA8, colorSpace: ColorPipeline.outputSpace)
            }
            var images: [UUID: CGImage] = [:]
            for preset in presets {
                if Task.isCancelled { break }
                let r = preset.recipe
                let lut = r.lut.flatMap { try? drafts.loadLUT($0) }
                let edits = MediaEdits(lut: lut, strength: r.strength, adjustments: r.adjustments, wheels: r.wheels,
                                       curves: r.curves, hsl: r.hsl, bypass: r.bypass)
                images[preset.id] = draw(edits)
            }
            // The AI Look is worked out from the full preview (the network looks at 256 × 256).
            var ai: CreativeLUT?, aiImage: CGImage?
            if !video, !Task.isCancelled, let model = AdaptiveLUT.shared,
               let cube = model.lut(for: source, headroom: headroom, title: "AI Look") {
                ai = CreativeLUT(cube: cube, name: L("AI 调色"))
                aiImage = draw(MediaEdits(lut: ai, strength: 0.75))
            }
            return (draw(MediaEdits()), images, ai, aiImage)
        }.value
        guard !Task.isCancelled else { return }
        original = result.0
        previews = result.1
        aiLook = result.2
        aiPreview = result.3
    }
}

struct LUTControls: View {
    let app: AppModel
    var editor: EditorModel { app.editor }
    var body: some View {
        let lut = editor.selectedLUT
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Menu {
                    Button("无") { editor.selectLUT(nil) }
                    Section("内置") {
                        Button(CreativeLUT.warm.name) { editor.selectLUT(.warm) }
                        Button(CreativeLUT.soft.name) { editor.selectLUT(.soft) }
                    }
                    if !app.lutLibrary.isEmpty {
                        Section("已导入") {
                            ForEach(app.lutLibrary, id: \.file) { reference in
                                Button(reference.name + (reference.encoding == .rec709 ? " · 709" : "")) { app.selectLUT(reference) }
                            }
                        }
                    }
                    Divider()
                    Button("导入 .cube LUT…", action: app.importLUT)
                    Button("匹配另一张照片的色调…") { app.sheet = .matchLook }.disabled(editor.isVideo)
                    if AdaptiveLUT.shared != nil { Button("AI 调色（为这张照片生成）") { app.aiLook() }.disabled(editor.isVideo) }
                    Divider()
                    Button("把当前调色导出为 .cube…", action: app.exportGradeLUT)
                } label: {
                    Text(lut?.name ?? L("无")).lineLimit(1)
                }
                .help("选择或导入创意 LUT")
                Spacer(minLength: 0)
            }
            ParameterRow(title: L("强度"), value: (editor.strength * 100).rounded(), range: 0...100, suffix: "%", neutral: 100,
                         onChange: { editor.strength = $0 / 100 }, onEditing: editor.beginEditing)
                .equatable()
                .disabled(lut == nil)
            if let lut, !lut.isBuiltIn {
                HStack {
                    Text("输入色彩空间").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Picker("输入色彩空间", selection: Binding(get: { lut.encoding }, set: { app.setLUTEncoding($0) })) {
                        ForEach(LUTEncoding.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 140)
                }
                .help("按 LUT 作者说明选择。DJI 等相机的 Rec.709 创意 LUT 选 Rec.709。")
            }
        }
    }
}

struct HDRSection: View {
    let editor: EditorModel
    var body: some View {
        InspectorSection("HDR", help: L("HDR 原片按显示器能力显示。调色后的画面以 SDR 输出。"), startsCollapsed: true) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("以 HDR 显示原片", isOn: Binding(get: { editor.hdrPreview }, set: { editor.hdrPreview = $0 }))
                    .disabled(!editor.sourceIsHDR)
                if editor.isVideo {
                    Toggle("HDR 高光扩展（实验）", isOn: Binding(get: { editor.hdrEffect }, set: { editor.hdrEffect = $0 }))
                        .help("扩展 SDR 高光，导出 10-bit HLG 视频与增益图 Live 封面；无法找回拍摄时已丢失的高光。")
                }
                Text(editor.sourceIsHDR ? L("当前素材为 HDR。") : L("当前素材为 SDR。")).font(.caption).foregroundStyle(.secondary)
            }
            .toggleStyle(.switch).controlSize(.small)
        }
    }
}

// MARK: - Geometry

struct GeometryPanel: View {
    let editor: EditorModel
    private static let ratios: [(String, Double)] = [(L("原始比例"), 0), ("1:1", 1), ("4:5", 0.8), ("4:3", 4.0 / 3), ("3:2", 1.5),
                                                     ("16:9", 16.0 / 9), ("9:16", 9.0 / 16), ("2:3", 2.0 / 3)]
    var body: some View {
        let geometry = editor.geometry
        VStack(alignment: .leading, spacing: 0) {
            if !editor.isVideo {
                Label("在画面上拖动方框移动裁剪，拖四个角缩放。", systemImage: "crop")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 10)
            }
            InspectorSection(L("拉直"), help: L("旋转后自动裁掉边缘，避免黑边。")) {
                VStack(alignment: .leading, spacing: 8) {
                    ParameterRow(title: L("角度"), value: editor.degrees, range: -10...10, step: 0.05, decimals: 2, suffix: "°",
                                 onChange: { editor.degrees = $0 }, onEditing: { editing in
                                     editor.beginEditing(editing); editor.showGrid = editing
                                 })
                        .equatable()
                    if !editor.isVideo {
                        Button("自动拉直", action: editor.autoStraighten).glassButton().help(L("识别地平线并建议角度"))
                    }
                }
            }
            InspectorSection(L("旋转与翻转")) {
                HStack(spacing: 8) {
                    Button { editor.rotate(clockwise: false) } label: { Label("向左", systemImage: "rotate.left") }
                    Button { editor.rotate(clockwise: true) } label: { Label("向右", systemImage: "rotate.right") }
                    Button { editor.geometry.mirrored.toggle() } label: { Label("镜像", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                }
                .glassButton()
                .controlSize(.small)
            }
            InspectorSection(L("裁剪"), onReset: { editor.group { editor.geometry.aspectRatio = 0; editor.geometry.cropScale = 1; editor.geometry.horizontal = 0; editor.geometry.vertical = 0 } }) {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("画幅", selection: Binding(get: { geometry.aspectRatio }, set: { editor.geometry.aspectRatio = $0 })) {
                        ForEach(Self.ratios, id: \.1) { Text($0.0).tag($0.1) }
                    }
                    ParameterRow(title: L("保留范围"), value: (geometry.cropScale * 100).rounded(), range: 25...100, suffix: "%", neutral: 100,
                                 onChange: { editor.geometry.cropScale = $0 / 100 }, onEditing: editor.beginEditing)
                        .equatable()
                    ParameterRow(title: L("横向位置"), value: geometry.horizontal, range: -100...100,
                                 onChange: { editor.geometry.horizontal = $0 }, onEditing: editor.beginEditing)
                        .equatable()
                    ParameterRow(title: L("纵向位置"), value: geometry.vertical, range: -100...100,
                                 onChange: { editor.geometry.vertical = $0 }, onEditing: editor.beginEditing)
                        .equatable()
                }
            }
            InspectorSection(L("参考线")) {
                Toggle("三分网格", isOn: Binding(get: { editor.showGrid }, set: { editor.showGrid = $0 }))
                    .toggleStyle(.switch).controlSize(.small)
            }
        }
        .onAppear { editor.cropEditing = !editor.isVideo }
        .onDisappear { editor.cropEditing = false }
        .onChange(of: editor.isVideo) { _, video in editor.cropEditing = !video }
    }
}

// MARK: - Audio

struct AudioPanel: View {
    let app: AppModel
    var editor: EditorModel { app.editor }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InspectorSection(L("原声")) {
                ParameterRow(title: L("音量"), value: (Double(editor.originalVolume) * 100).rounded(), range: 0...100, suffix: "%", neutral: 100,
                             onChange: { editor.originalVolume = Float($0 / 100) }, onEditing: editor.beginEditing)
                    .equatable()
            }
            InspectorSection(L("背景音乐"), help: L("音乐从片段开头播放并按输出长度截取，保持原节奏。")) {
                VStack(alignment: .leading, spacing: 8) {
                    if let music = editor.musicURL {
                        HStack {
                            Image(systemName: "music.note").foregroundStyle(.secondary)
                            Text(music.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            IconButton(title: L("移除背景音乐"), icon: "xmark.circle") { editor.musicURL = nil }
                        }
                        ParameterRow(title: L("音量"), value: (Double(editor.musicVolume) * 100).rounded(), range: 0...100, suffix: "%", neutral: 50,
                                     onChange: { editor.musicVolume = Float($0 / 100) }, onEditing: editor.beginEditing)
                            .equatable()
                        Button("更换音乐…", action: app.chooseMusic).glassButton()
                    } else {
                        Button { app.chooseMusic() } label: { Label("添加音乐…", systemImage: "plus") }.glassButton()
                    }
                }
            }
        }
    }
}

// MARK: - Info

struct InfoPanel: View {
    let app: AppModel
    var editor: EditorModel { app.editor }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let url = editor.url { header(url) }
            if let entry = app.currentEntry {
                InspectorSection(L("评级与标记")) {
                    HStack(spacing: 2) {
                        ForEach(1...5, id: \.self) { value in
                            Button { app.rate(entry.rating == value ? 0 : value) } label: {
                                Image(systemName: value <= entry.rating ? "star.fill" : "star")
                                    .foregroundStyle(value <= entry.rating ? WorkbenchTheme.star : .secondary)
                            }
                            .buttonStyle(.plain).help("\(value) 星（数字键 \(value)）")
                        }
                        Spacer()
                        Button { app.flag(entry.flag == .pick ? .none : .pick) } label: {
                            Image(systemName: entry.flag == .pick ? "flag.fill" : "flag")
                        }
                        .buttonStyle(.plain).foregroundStyle(entry.flag == .pick ? WorkbenchTheme.pick : .secondary).help("选用（P）")
                        Button { app.flag(entry.flag == .reject ? .none : .reject) } label: {
                            Image(systemName: entry.flag == .reject ? "xmark.circle.fill" : "xmark.circle")
                        }
                        .buttonStyle(.plain).foregroundStyle(entry.flag == .reject ? WorkbenchTheme.reject : .secondary).help("排除（X）")
                    }
                    .font(.system(size: 15))
                }
            }
            if let details = editor.details {
                ForEach(details.groups) { group in
                    InspectorSection(group.title) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(group.rows) { row($0.title, $0.value) }
                            if group.kind == .capture, details.hasExposure {
                                HStack(spacing: 12) {
                                    Button("光圈是什么？") { app.openLesson("aperture") }
                                    Button("快门和 ISO？") { app.openLesson("exposure-triangle") }
                                }
                                .buttonStyle(.borderless).font(.callout).padding(.top, 2)
                            }
                            if group.kind == .location, let coordinate = details.coordinate {
                                Button("在地图中打开") { openMap(coordinate) }
                                    .buttonStyle(.borderless).font(.callout).padding(.top, 2)
                                Text("导出时默认移除位置信息。").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else if editor.url != nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在读取信息…").font(.callout).foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }
            if let id = editor.url?.standardizedFileURL.path, let labels = app.content.labels[id], !labels.isEmpty {
                InspectorSection(L("画面内容"), help: L("在这台 Mac 上识别，用于在素材库里按内容搜索。")) {
                    Text(labels.prefix(8).map(ContentLabels.displayName).joined(separator: L("、")))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            InspectorSection(L("编辑记录")) {
                VStack(alignment: .leading, spacing: 4) {
                    let summary = editor.editSummary
                    if summary.isEmpty {
                        Text("尚未编辑。").font(.callout).foregroundStyle(.secondary)
                    } else {
                        ForEach(summary) { row($0.title, $0.value) }
                    }
                    Text("编辑以配方自动保存，原片从不修改。").font(.caption).foregroundStyle(.secondary).padding(.top, 2)
                    Button("快照与版本…") { app.sheet = .snapshots }.glassButton().padding(.top, 2)
                }
            }
        }
    }

    /// File name, a one-line summary and file actions.
    private func header(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(url.lastPathComponent)
                .font(.system(size: 13, weight: .semibold)).lineLimit(2).textSelection(.enabled)
            Text(subtitle(url)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 12) {
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("拷贝信息") { copyInfo(url) }.disabled(editor.details == nil)
            }
            .buttonStyle(.borderless).font(.callout).padding(.top, 2)
        }
        .padding(.vertical, 8)
    }

    private func subtitle(_ url: URL) -> String {
        var parts = [editor.isLiveInput ? "Live Photo" : editor.isVideo ? L("视频") : L("照片"), url.pathExtension.uppercased()]
        if let info = editor.metadata { parts.append("\(info.displayWidth) × \(info.displayHeight)") }
        if editor.isVideo { parts.append(timeLabel(editor.duration)) }
        if editor.sourceIsHDR { parts.append("HDR") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85).frame(width: .label(56), alignment: .leading)
            Text(value).textSelection(.enabled).lineLimit(3).truncationMode(.middle).help(value)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }

    private func copyInfo(_ url: URL) {
        var text = url.lastPathComponent
        if let details = editor.details { text += "\n\n" + details.text }
        let summary = editor.editSummary
        if !summary.isEmpty { text += L("\n\n编辑记录\n") + summary.map { L("\($0.title)：\($0.value)") }.joined(separator: "\n") }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        app.show(L("已拷贝信息"), seconds: 2)
    }

    private func openMap(_ coordinate: (latitude: Double, longitude: Double)) {
        var components = URLComponents(string: "maps://")!
        let ll = "\(coordinate.latitude),\(coordinate.longitude)"
        components.queryItems = [URLQueryItem(name: "ll", value: ll), URLQueryItem(name: "q", value: editor.url?.lastPathComponent ?? ll)]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }
}

/// Wraps chips onto multiple lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? 300, subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(bounds.width, subviews)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }
    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var points: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing; line = max(line, size.height); widest = max(widest, x)
        }
        return (CGSize(width: min(width, widest), height: y + line), points)
    }
}

/// Reads scopes and focus in its own body so slider drags don't redraw the whole panel.
struct ZoneHistogramFeed: View {
    let editor: EditorModel
    var height: CGFloat = 56
    var body: some View {
        ZoneHistogram(histogram: editor.scopes?.analysis.lumaHistogram ?? [], focus: editor.focusParameter, height: height)
    }
}

extension EditorModel {
    func focus(_ parameter: AdjustmentParameter, _ on: Bool) {
        if on { if focusParameter != parameter { focusParameter = parameter } }
        else if focusParameter == parameter { focusParameter = nil }
    }
}
