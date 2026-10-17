import AppKit
import MediaCore
import SwiftUI

// 局部调整: the inspector section (layers and their sliders) and the canvas handles.

extension EditorModel {
    var selectedLocal: LocalAdjustment? { locals.first { $0.id == selectedLocalID } }

    /// The picture's size before rotation and crop (any scale), for mapping mask handles.
    var sourcePixelSize: CGSize? { frame?.original.extent.size }

    func addLocal(_ shape: LocalAdjustment.Shape) {
        guard locals.count < LocalAdjustment.maximumLayers else {
            status = L("最多 \(LocalAdjustment.maximumLayers) 个局部调整。"); return
        }
        if shape == .subject { addSubject(); return }
        let layer = LocalAdjustment(shape: shape)
        locals.append(layer)
        selectedLocalID = layer.id
        // A fresh brush layer has no strokes yet; the red tint shows where you paint.
        showMask = shape.isPainted
        status = shape == .remove ? L("在要去掉的东西上涂抹，松开后用周围的画面填补；按住 ⌥ 擦除。")
            : shape == .brush ? L("在画面上涂抹要调整的地方；按住 ⌥ 擦除。")
            : L("已添加\(shape.title)。拖动画面上的控制点调整范围。")
    }

    /// Finds the subject first (a moment the first time), then adds the layer with its mask shown.
    private func addSubject() {
        guard let source = mediaURL, !isVideo else { return }
        let document = documentID
        status = L("正在识别主体…")
        Task {
            let found = await Task.detached(priority: .userInitiated) { SubjectMask.mask(for: source) != nil }.value
            guard document == documentID, mediaURL == source else { return }
            guard found else { status = L("没有找到明显的主体（人物、动物或前景物体）。可以改用画笔或椭圆。"); return }
            let layer = LocalAdjustment(shape: .subject)
            locals.append(layer)
            selectedLocalID = layer.id
            showMask = true
            status = L("已选中主体，红色是调整的范围。用反转按钮改为调整背景。")
        }
    }

    func updateLocal(_ id: UUID, _ change: (inout LocalAdjustment) -> Void) {
        guard let index = locals.firstIndex(where: { $0.id == id }) else { return }
        var next = locals
        change(&next[index])
        locals = next
    }

    func removeLocal(_ id: UUID) {
        locals.removeAll { $0.id == id }
        if selectedLocalID == id { selectedLocalID = locals.last?.id }
        if locals.isEmpty { showMask = false }
    }
}

struct LocalAdjustmentSection: View {
    let editor: EditorModel
    var number: Int?
    var isOn: Binding<Bool>?

    var body: some View {
        InspectorSection(L("局部调整"), number: number, isOn: isOn,
                         help: L("只调整画面的一部分：渐变适合压暗天空，椭圆适合提亮主体，画笔可以涂出任何地方。"),
                         onReset: editor.locals.isEmpty ? nil : { editor.resetStage(.local) }) {
            VStack(alignment: .leading, spacing: 8) {
                // One row of icons and words when it fits, else words alone, else two rows.
                ViewThatFits(in: .horizontal) {
                    shapeButtons(shapes, .titleAndIcon)
                    shapeButtons(shapes, .titleOnly)
                    VStack(spacing: 6) {
                        shapeButtons(Array(shapes.prefix(3)), .titleAndIcon)
                        shapeButtons(Array(shapes.dropFirst(3)), .titleAndIcon)
                    }
                }
                if editor.locals.isEmpty {
                    Text("只调整画面的一部分：比如用渐变压暗天空、用椭圆提亮人物，或者用画笔涂出要改的地方。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 2) {
                        ForEach(Array(editor.locals.enumerated()), id: \.element.id) { index, layer in
                            row(layer, number: index + 1)
                        }
                    }
                }
                if let layer = editor.selectedLocal {
                    LocalLayerControls(editor: editor, layer: layer)
                }
            }
        }
    }

    /// Subject and Remove work on photos only.
    private var shapes: [LocalAdjustment.Shape] {
        LocalAdjustment.Shape.allCases.filter { !editor.isVideo || ($0 != .subject && $0 != .remove) }
    }

    private func shapeButtons<S: LabelStyle>(_ shapes: [LocalAdjustment.Shape], _ style: S) -> some View {
        HStack(spacing: 6) {
            ForEach(shapes, id: \.self) { shape in
                Button { editor.addLocal(shape) } label: {
                    Label(shape.title, systemImage: shape.symbol).labelStyle(style).lineLimit(1).fixedSize().frame(maxWidth: .infinity)
                }
                .glassButton().controlSize(.small)
                .help(Self.hint(shape))
            }
        }
    }

    static func hint(_ shape: LocalAdjustment.Shape) -> String {
        switch shape {
        case .linear: L("渐变：从一条线开始逐渐过渡到另一条线，常用来压暗天空。")
        case .radial: L("椭圆：调整椭圆里面（或外面）的部分，常用来提亮主体、压暗四周。")
        case .brush: L("画笔：涂到哪里就调整哪里；按住 ⌥ 擦除。")
        case .subject: L("主体：自动找出人物、动物或前景物体，只调整它们；反转后调整背景。")
        case .remove: L("去除：涂抹电线、路人、垃圾或灰尘，用周围的画面自动填补。")
        }
    }

    private func row(_ layer: LocalAdjustment, number: Int) -> some View {
        let selected = layer.id == editor.selectedLocalID
        return HStack(spacing: 8) {
            Image(systemName: layer.shape.symbol).frame(width: 16).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: "\(layer.title) \(number)").font(.callout.weight(selected ? .semibold : .regular))
                Text(summary(layer)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if selected {
                // Mask options live on the row instead of taking two lines of checkboxes below it.
                Button { editor.showMask.toggle() } label: {
                    Image(systemName: editor.showMask ? "circle.lefthalf.filled" : "circle.lefthalf.striped.horizontal")
                }
                .buttonStyle(.borderless).foregroundStyle(editor.showMask ? .primary : .secondary)
                .help(editor.showMask ? L("隐藏蒙版") : L("把这一层作用的范围标成红色"))
                .accessibilityLabel(L("显示蒙版"))
                if layer.shape != .remove {
                    Button { editor.updateLocal(layer.id) { $0.invert.toggle() } } label: {
                        Image(systemName: "arrow.left.arrow.right.circle" + (layer.invert ? ".fill" : ""))
                    }
                    .buttonStyle(.borderless).foregroundStyle(layer.invert ? .primary : .secondary)
                    .help(layer.invert ? L("已反转：调整范围之外的部分") : L("改为调整范围之外的部分"))
                    .accessibilityLabel(L("反转"))
                }
            }
            Button { editor.updateLocal(layer.id) { $0.enabled.toggle() } } label: {
                Image(systemName: layer.enabled ? "eye" : "eye.slash")
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            .help(layer.enabled ? L("隐藏此局部调整以比较") : L("显示此局部调整"))
            Button { editor.removeLocal(layer.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("删除")
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? WorkbenchTheme.selection : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { editor.selectedLocalID = selected ? nil : layer.id }
        .opacity(layer.enabled ? 1 : 0.55)
    }

    private func summary(_ layer: LocalAdjustment) -> String {
        let changed = LocalAdjustment.parameters.filter { layer.adjustments[$0] != 0 }.prefix(2).map { p in
            p == .exposure ? String(format: "%@ %+.2f", p.title, layer.adjustments[p]) : String(format: "%@ %+.0f", p.title, layer.adjustments[p])
        }
        if layer.shape.isPainted, layer.strokes.isEmpty { return L("还没有涂抹") }
        if layer.shape == .remove { return L("用周围的画面填补") }
        return changed.isEmpty ? L("未调整") : changed.joined(separator: " · ")
    }
}

/// The selected layer's sliders, grouped like the global controls: light, color, detail.
/// Groups the layer uses are open; the rest stay closed with a one-line summary.
private struct LocalLayerControls: View {
    let editor: EditorModel
    let layer: LocalAdjustment
    /// nil until the user opens or closes a group: then the defaults stop applying.
    @UIState private var opened: Set<Group>?

    enum Group: CaseIterable, Hashable {
        case light, color, detail
        var title: String {
            switch self { case .light: L("光线"); case .color: L("色彩"); case .detail: L("细节") }
        }
        var parameters: [AdjustmentParameter] {
            switch self {
            case .light: [.exposure, .contrast, .highlights, .shadows, .whites, .blackPoint]
            case .color: [.warmth, .tint, .saturation, .vibrance]
            case .detail: [.dehaze, .definition, .sharpness, .noiseReduction]
            }
        }
    }

    private func changed(_ group: Group) -> [AdjustmentParameter] { group.parameters.filter { layer.adjustments[$0] != 0 } }

    private var open: Set<Group> {
        if let opened { return opened }
        let used = Set(Group.allCases.filter { !changed($0).isEmpty })
        return used.isEmpty ? [.light] : used
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(hint).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                .help(detailedHint)
                .padding(.top, 2)
            if layer.shape.isPainted {
                HStack(spacing: 8) {
                    Picker("", selection: Binding(get: { editor.brushErase }, set: { editor.brushErase = $0 })) {
                        Text("涂抹").tag(false)
                        Text("擦除").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
                    Spacer(minLength: 0)
                    if !layer.strokes.isEmpty {
                        Button("清除笔触") { editor.updateLocal(layer.id) { $0.strokes = [] } }.buttonStyle(.borderless).font(.caption)
                    }
                }
                ParameterRow(title: L("画笔大小"), value: (editor.brushRadius * 200).rounded(), range: 1...50, neutral: 8,
                             onChange: { editor.brushRadius = $0 / 200 })
            }
            if layer.shape != .linear, layer.shape != .remove {
                ParameterRow(title: L("羽化"), value: (layer.feather * 100).rounded(), range: 0...100, suffix: "%", neutral: 35,
                             onChange: { value in editor.updateLocal(layer.id) { $0.feather = value / 100 } }, onEditing: editor.beginEditing)
            }
            ForEach(layer.shape == .remove ? [] : Group.allCases, id: \.self) { group in
                groupHeader(group)
                if open.contains(group) {
                    VStack(spacing: 1) {
                        ForEach(group.parameters) { parameter in
                            ParameterRow(title: parameter.title, value: layer.adjustments[parameter], range: parameter.range,
                                         step: parameter == .exposure ? 0.05 : 1, decimals: parameter == .exposure ? 2 : 0,
                                         suffix: parameter == .exposure ? "EV" : "", help: parameter.explanation,
                                         onChange: { value in editor.updateLocal(layer.id) { $0.adjustments[parameter] = value } },
                                         onEditing: editor.beginEditing)
                        }
                    }
                    .padding(.leading, 4)
                }
            }
        }
        .padding(.top, 2)
    }

    private func groupHeader(_ group: Group) -> some View {
        let isOpen = open.contains(group)
        let values = changed(group).map { p in
            p == .exposure ? String(format: "%@ %+.2f", p.title, layer.adjustments[p]) : String(format: "%@ %+.0f", p.title, layer.adjustments[p])
        }
        return Button {
            var next = open
            if isOpen { next.remove(group) } else { next.insert(group) }
            withAnimation(.snappy(duration: 0.18)) { opened = next }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                Text(group.title).font(.caption.weight(.semibold)).foregroundStyle(values.isEmpty ? .secondary : .primary)
                Text(values.isEmpty ? L("未调整") : values.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }

    private var hint: String {
        switch layer.shape {
        case .linear: L("拖动画面上的圆点，放好渐变。")
        case .radial: L("拖动中心和边上的点，放好椭圆。")
        case .brush: L("在画面上涂抹；按住 ⌥ 擦除。")
        case .subject: L(layer.invert ? "正在调整背景（主体以外）。" : "已自动选中主体；反转可改为背景。")
        case .remove: L("涂抹要去掉的东西，松开后自动填补；按住 ⌥ 擦除。")
        }
    }

    private var detailedHint: String {
        switch layer.shape {
        case .linear: L("在画面上拖动两个圆点：实线一侧完全生效，虚线一侧不受影响；拖中间的点整体移动。")
        case .radial: L("拖动中心移动椭圆，拖边上的点改变大小；羽化让边缘过渡更柔和。")
        case .brush: L("在画面上涂抹；按住 ⌥ 临时擦除。")
        case .subject: L("用 macOS 的主体识别（和「照片」里抠出主体相同）找出前景里的人物、动物和物体。羽化让边缘更柔和；反转按钮改为调整背景，比如压暗背景、突出人物。")
        case .remove: L("把要去掉的东西完整涂满，边缘多涂一点。光集会在周围找相似的纹理来填补（PatchMatch，在这台 Mac 上计算）。适合电线、路人、垃圾、灰尘这类较小的东西；涂得太大时效果会变差，可以分几次去除。")
        }
    }
}

// MARK: - Canvas handles

/// Draws the selected layer's handles over the fitted canvas and edits them by dragging.
struct LocalMaskOverlay: View {
    let editor: EditorModel
    let layer: LocalAdjustment
    let mapping: GeometryMapping

    @UIState private var dragBase: LocalAdjustment?
    @UIState private var painting: [CGPoint] = []
    @UIState private var paintingErase = false
    @UIState private var pointer: CGPoint?

    private enum Handle { case start, end, middle, center, radiusX, radiusY }

    var body: some View {
        GeometryReader { proxy in
            let shown = displayRect(in: proxy.size)
            ZStack(alignment: .topLeading) {
                switch layer.shape {
                case .linear: linear(shown, size: proxy.size)
                case .radial: radial(shown)
                case .brush, .remove: brush(shown)
                case .subject: EmptyView()
                }
            }
        }
    }

    // MARK: Coordinates

    /// Where the canvas draws the picture when fitted (it keeps a 12 pt margin on each side).
    private func displayRect(in size: CGSize) -> CGRect {
        let pixels = mapping.outputSize
        let scale = max(0.001, min((size.width - 24) / max(1, pixels.width), (size.height - 24) / max(1, pixels.height)))
        let shown = CGSize(width: pixels.width * scale, height: pixels.height * scale)
        return CGRect(x: (size.width - shown.width) / 2, y: (size.height - shown.height) / 2, width: shown.width, height: shown.height)
    }

    private func view(_ p: CGPoint, _ shown: CGRect) -> CGPoint {
        let o = mapping.toOutput(p)
        return CGPoint(x: shown.minX + o.x * shown.width, y: shown.minY + o.y * shown.height)
    }

    private func source(_ v: CGPoint, _ shown: CGRect) -> CGPoint {
        mapping.toSource(CGPoint(x: (v.x - shown.minX) / shown.width, y: (v.y - shown.minY) / shown.height))
    }

    private func handle(_ symbol: String = "circle.fill", size: CGFloat = 14) -> some View {
        Circle().fill(Color.white).frame(width: size, height: size)
            .overlay(Circle().strokeBorder(Color.black.opacity(0.5), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 2)
            .frame(width: 30, height: 30).contentShape(Circle())
    }

    private func drag(_ which: Handle, _ shown: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragBase == nil { dragBase = layer; editor.beginEditing(true) }
                guard let base = dragBase else { return }
                let id = layer.id
                switch which {
                case .start:
                    let p = source(view(base.start, shown) + value.translation, shown)
                    editor.updateLocal(id) { $0.start = p }
                case .end:
                    let p = source(view(base.end, shown) + value.translation, shown)
                    editor.updateLocal(id) { $0.end = p }
                case .middle:
                    let s = source(view(base.start, shown) + value.translation, shown)
                    let e = source(view(base.end, shown) + value.translation, shown)
                    editor.updateLocal(id) { $0.start = s; $0.end = e }
                case .center:
                    let c = source(view(base.center, shown) + value.translation, shown)
                    editor.updateLocal(id) { $0.center = c }
                case .radiusX, .radiusY:
                    let edge = which == .radiusX ? CGPoint(x: base.center.x + base.radii.width, y: base.center.y)
                                                 : CGPoint(x: base.center.x, y: base.center.y - base.radii.height)
                    let p = source(view(edge, shown) + value.translation, shown)
                    editor.updateLocal(id) {
                        if which == .radiusX { $0.radii.width = min(2, max(0.01, abs(p.x - base.center.x))) }
                        else { $0.radii.height = min(2, max(0.01, abs(p.y - base.center.y))) }
                    }
                }
            }
            .onEnded { _ in dragBase = nil; editor.beginEditing(false) }
    }

    // MARK: Linear

    private func linear(_ shown: CGRect, size: CGSize) -> some View {
        let s = view(layer.start, shown), e = view(layer.end, shown)
        let dx = e.x - s.x, dy = e.y - s.y, length = max(1, hypot(dx, dy))
        let normal = CGPoint(x: -dy / length * 3000, y: dx / length * 3000)
        let middle = CGPoint(x: (s.x + e.x) / 2, y: (s.y + e.y) / 2)
        return ZStack(alignment: .topLeading) {
            Group {
                Path { path in path.move(to: s - normal); path.addLine(to: s + normal) }
                    .stroke(Color.white, lineWidth: 1.5)
                Path { path in path.move(to: e - normal); path.addLine(to: e + normal) }
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                Path { path in path.move(to: s); path.addLine(to: e) }
                    .stroke(Color.white.opacity(0.7), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.6), radius: 1.5)
            .mask(Rectangle().frame(width: shown.width, height: shown.height).position(x: shown.midX, y: shown.midY))
            .allowsHitTesting(false)
            handle().position(s).gesture(drag(.start, shown)).help("完全生效的一侧")
            handle().position(e).gesture(drag(.end, shown)).help("过渡结束的一侧")
            handle(size: 10).position(middle).gesture(drag(.middle, shown)).help("整体移动")
        }
    }

    // MARK: Radial

    private func radial(_ shown: CGRect) -> some View {
        func ellipse(_ scale: Double) -> Path {
            Path { path in
                for step in 0...72 {
                    let t = Double(step) / 72 * 2 * .pi
                    let p = view(CGPoint(x: layer.center.x + layer.radii.width * scale * cos(t),
                                         y: layer.center.y + layer.radii.height * scale * sin(t)), shown)
                    if step == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
            }
        }
        let center = view(layer.center, shown)
        let right = view(CGPoint(x: layer.center.x + layer.radii.width, y: layer.center.y), shown)
        let top = view(CGPoint(x: layer.center.x, y: layer.center.y - layer.radii.height), shown)
        return ZStack(alignment: .topLeading) {
            Group {
                ellipse(1).stroke(Color.white, lineWidth: 1.5)
                if layer.feather > 0.02 {
                    ellipse(max(0.02, 1 - layer.feather)).stroke(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                }
            }
            .shadow(color: .black.opacity(0.6), radius: 1.5)
            .allowsHitTesting(false)
            handle().position(center).gesture(drag(.center, shown)).help("移动")
            handle(size: 10).position(right).gesture(drag(.radiusX, shown)).help("改变宽度")
            handle(size: 10).position(top).gesture(drag(.radiusY, shown)).help("改变高度")
        }
    }

    // MARK: Brush

    private func brush(_ shown: CGRect) -> some View {
        let source = mapping.sourceSize
        let viewPerSource = shown.width / max(1, mapping.outputSize.width) * mapping.scale
        let radius = CGFloat(editor.brushRadius) * min(source.width, source.height) * viewPerSource
        return ZStack(alignment: .topLeading) {
            if painting.count > 0 {
                Path { path in
                    let points = painting.map { view($0, shown) }
                    path.move(to: points[0])
                    for p in points.dropFirst() { path.addLine(to: p) }
                    if points.count == 1 { path.addLine(to: points[0]) }
                }
                .stroke(paintingErase ? Color.black.opacity(0.45) : Color.red.opacity(0.45),
                        style: StrokeStyle(lineWidth: radius * 2, lineCap: .round, lineJoin: .round))
                .allowsHitTesting(false)
            }
            if let pointer {
                Circle().strokeBorder(Color.white, lineWidth: 1.2)
                    .background(Circle().strokeBorder(Color.black.opacity(0.5), lineWidth: 2.5))
                    .frame(width: radius * 2, height: radius * 2)
                    .position(pointer)
                    .allowsHitTesting(false)
            }
            Rectangle().fill(Color.clear)
                .frame(width: shown.width, height: shown.height)
                .contentShape(Rectangle())
                .position(x: shown.midX, y: shown.midY)
                .onContinuousHover { phase in
                    if case .active(let location) = phase {
                        pointer = CGPoint(x: location.x + shown.minX, y: location.y + shown.minY)
                        NSCursor.crosshair.set()
                    } else { pointer = nil; NSCursor.arrow.set() }
                }
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let location = CGPoint(x: value.location.x + shown.minX, y: value.location.y + shown.minY)
                        pointer = location
                        if painting.isEmpty { paintingErase = editor.brushErase || NSEvent.modifierFlags.contains(.option) }
                        let point = self.source(location, shown)
                        // Skip points closer than a quarter of the brush, so long strokes stay small.
                        if let last = painting.last, hypot(view(last, shown).x - location.x, view(last, shown).y - location.y) < max(1.5, radius / 4) { return }
                        if painting.count < 1024 { painting.append(point) }
                    }
                    .onEnded { _ in
                        let points = painting, erase = paintingErase, radius = editor.brushRadius
                        painting = []
                        guard !points.isEmpty else { return }
                        editor.updateLocal(layer.id) { layer in
                            let used = layer.strokes.reduce(0) { $0 + $1.points.count }
                            guard used + points.count <= LocalAdjustment.maximumPoints else { return }
                            layer.strokes.append(BrushStroke(points: points, radius: radius, erase: erase))
                        }
                    })
        }
    }
}

private func + (a: CGPoint, b: CGSize) -> CGPoint { CGPoint(x: a.x + b.width, y: a.y + b.height) }
private func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
private func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
