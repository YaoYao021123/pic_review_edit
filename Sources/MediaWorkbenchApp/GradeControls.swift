import AppKit
import MediaCore
import SwiftUI

// MARK: - Scopes

enum ScopeKind: String, CaseIterable {
    case histogram, waveform, parade, vectorscope
    var title: String {
        switch self { case .histogram: L("直方图"); case .waveform: L("波形"); case .parade: L("分量"); case .vectorscope: L("矢量") }
    }
    var help: String {
        switch self {
        case .histogram: L("RGB 各亮度级的像素数量。左右两端堆积表示暗部或高光溢出。")
        case .waveform: L("横向对应画面位置，纵向是亮度（0–100）。用于检查曝光与反差。")
        case .parade: L("红、绿、蓝分量波形并排显示。白平衡正确时，中性色在三栏高度一致。")
        case .vectorscope: L("色相为方向、饱和度为距离中心的远近。斜线为肤色参考线。")
        }
    }
}

struct ScopePanel: View {
    let editor: EditorModel
    var level = LearningLevel.beginner

    var body: some View {
        let kind = editor.scopeKind
        VStack(alignment: .leading, spacing: 4) {
            GlassSegmentedControl(options: ScopeKind.allCases, selection: Binding(get: { editor.scopeKind }, set: { editor.scopeKind = $0 }),
                                  title: { $0.title }, size: .small, accessibilityTitle: L("示波器"))
                .frame(maxWidth: 230)
                .help(kind.help)
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35))
                content.padding(4)
            }
            .frame(height: kind == .vectorscope ? 128 : 84)
            .overlay(alignment: .topLeading) { clipBadge(shadows: true) }
            .overlay(alignment: .topTrailing) { clipBadge(shadows: false) }
            if kind == .histogram { ZoneLabels(focus: editor.focusParameter) }
            // Plain-language reading of this diagram for this photo.
            if let analysis = editor.scopes?.analysis {
                Text(PhotoCoach.reading(scope: kind.rawValue, analysis, level: level))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(kind.help)
            }
        }
    }

    @ViewBuilder private var content: some View {
        let scopes = editor.scopes
        switch editor.scopeKind {
        case .histogram:
            ZStack {
                HistogramShape(histogram: scopes?.histogram)
                ZoneShading(focus: editor.focusParameter)
            }
        case .waveform: WaveformView(image: scopes?.waveform, sections: 1)
        case .parade: WaveformView(image: scopes?.parade, sections: 3)
        case .vectorscope: VectorscopeView(image: scopes?.vectorscope)
        }
    }

    /// Lightroom-style corner triangles; lit when clipping, click toggles the overlay (J).
    private func clipBadge(shadows: Bool) -> some View {
        let fraction = shadows ? editor.scopes?.clippedShadows ?? 0 : editor.scopes?.clippedHighlights ?? 0
        let lit = fraction > 0.001
        return Button { editor.showClipping.toggle() } label: {
            Image(systemName: "triangle.fill")
                .font(.system(size: 8))
                .rotationEffect(.degrees(shadows ? -90 : 90))
                .foregroundStyle(lit ? (shadows ? Color.blue : Color.red) : Color.secondary.opacity(0.5))
                .padding(5)
                .background(editor.showClipping ? Color.white.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .help((shadows ? L("暗部") : L("高光")) + String(format: L("溢出 %.1f%% · 点按显示溢出区域（J）"), fraction * 100))
        .padding(2)
    }
}

struct HistogramShape: View {
    let histogram: PreviewHistogram?
    var channel: Int?
    var body: some View {
        Canvas { context, size in
            guard let histogram else { return }
            let colors: [Color] = [.red, .green, .blue]
            for (index, values) in histogram.channels.enumerated() where channel == nil || channel == index {
                var area = Path()
                area.move(to: CGPoint(x: 0, y: size.height))
                for (bin, value) in values.enumerated() {
                    area.addLine(to: CGPoint(x: size.width * Double(bin) / Double(values.count - 1), y: size.height * (1 - sqrt(value) * 0.95)))
                }
                area.addLine(to: CGPoint(x: size.width, y: size.height)); area.closeSubpath()
                let color = channel == nil ? colors[index] : Color.white
                context.fill(area, with: .color(color.opacity(channel == nil ? 0.28 : 0.12)))
                if channel == nil { context.stroke(area, with: .color(color.opacity(0.65)), lineWidth: 0.7) }
            }
        }
        .accessibilityLabel("RGB 直方图")
    }
}

struct WaveformView: View {
    let image: CGImage?
    let sections: Int
    var body: some View {
        ZStack {
            Canvas { context, size in
                for level in [0.25, 0.5, 0.75] {
                    var line = Path()
                    line.move(to: CGPoint(x: 0, y: size.height * (1 - level)))
                    line.addLine(to: CGPoint(x: size.width, y: size.height * (1 - level)))
                    context.stroke(line, with: .color(.white.opacity(0.10)), lineWidth: 0.5)
                }
                for index in 1..<max(1, sections) {
                    var line = Path()
                    let x = size.width * Double(index) / Double(sections)
                    line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(line, with: .color(.white.opacity(0.18)), lineWidth: 0.5)
                }
            }
            if let image { Image(decorative: image, scale: 1).resizable().interpolation(.medium) }
        }
        .accessibilityLabel(sections == 1 ? L("亮度波形") : L("RGB 分量"))
    }
}

struct VectorscopeView: View {
    let image: CGImage?
    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                Canvas { context, size in
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    let radius = size.width / 2
                    for fraction in [0.5, 1.0] {
                        context.stroke(Path(ellipseIn: CGRect(x: center.x - radius * fraction, y: center.y - radius * fraction,
                                                              width: radius * 2 * fraction, height: radius * 2 * fraction)),
                                       with: .color(.white.opacity(0.12)), lineWidth: 0.6)
                    }
                    // 75% color targets (R, Mg, B, Cy, G, Yl) in Cb/Cr.
                    let targets: [(String, Double, Double, Color)] = [
                        ("R", 0.75, 0, .red), ("Yl", 0.75, 0.75, .yellow), ("G", 0, 0.75, .green),
                        ("Cy", 0, 0.75, .cyan), ("B", 0, 0, .blue), ("Mg", 0.75, 0, .pink)]
                    let rgb: [(Double, Double, Double)] = [(0.75, 0, 0), (0.75, 0.75, 0), (0, 0.75, 0), (0, 0.75, 0.75), (0, 0, 0.75), (0.75, 0, 0.75)]
                    for (index, target) in targets.enumerated() {
                        let (r, g, b) = rgb[index]
                        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
                        let cb = (b - y) / 1.8556, cr = (r - y) / 1.5748
                        let point = CGPoint(x: center.x + cb * 2 * radius, y: center.y - cr * 2 * radius)
                        context.stroke(Path(CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)),
                                       with: .color(target.3.opacity(0.7)), lineWidth: 0.8)
                    }
                    // Skin tone line (~123°).
                    var skin = Path()
                    skin.move(to: center)
                    let angle = 123.0 * .pi / 180
                    skin.addLine(to: CGPoint(x: center.x + cos(angle) * radius, y: center.y - sin(angle) * radius))
                    context.stroke(skin, with: .color(Color(red: 0.95, green: 0.72, blue: 0.55).opacity(0.5)), lineWidth: 0.6)
                }
                if let image { Image(decorative: image, scale: 1).resizable().interpolation(.medium) }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityLabel("矢量示波器")
    }
}

// MARK: - Color wheels

/// Resolve-style primary wheel: drag the puck (⌥ for fine control), master slider below.
struct ColorWheelControl: View, @MainActor Equatable {
    let wheel: ColorWheels.Wheel
    let value: WheelValue
    let onChange: (WheelValue) -> Void
    let onEditing: (Bool) -> Void
    var onHover: (InfluenceKind?) -> Void = { _ in }

    private var influence: InfluenceKind? {
        switch wheel { case .lift: .lift; case .gamma: .midtones; case .gain: .gain; case .offset: nil }
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.wheel == rhs.wheel && lhs.value == rhs.value }

    @UIState private var dragOrigin: WheelValue?

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 3) {
                Text(wheel.title).font(.caption.weight(.semibold))
                Text(wheel.subtitle).font(.caption2).foregroundStyle(.tertiary)
            }
            .onTapGesture(count: 2) { commit(WheelValue()) }
            .onHover { inside in if influence != nil { onHover(inside ? influence : nil) } }
            .help(L("双击复位此色轮") + (influence != nil ? L("；悬停查看它影响的亮度范围") : ""))
            GeometryReader { geometry in
                let side = min(geometry.size.width, geometry.size.height)
                let radius = side / 2
                ZStack {
                    Circle().fill(AngularGradient(colors: Self.ringColors, center: .center))
                    Circle().fill(Color(white: 0.13)).padding(5)
                    Circle().fill(RadialGradient(colors: [Color(white: 0.2), Color(white: 0.13)], center: .center,
                                                 startRadius: 0, endRadius: radius)).padding(5)
                    Path { path in
                        path.move(to: CGPoint(x: radius, y: 8)); path.addLine(to: CGPoint(x: radius, y: side - 8))
                        path.move(to: CGPoint(x: 8, y: radius)); path.addLine(to: CGPoint(x: side - 8, y: radius))
                    }.stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                    Circle()
                        .strokeBorder(Color.white, lineWidth: 1.5)
                        .background(Circle().fill(puckColor))
                        .frame(width: 11, height: 11)
                        .position(x: radius + value.x * (radius - 9), y: radius - value.y * (radius - 9))
                        .shadow(radius: 1.5)
                }
                .frame(width: side, height: side)
                .contentShape(Circle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { event in
                        if dragOrigin == nil { dragOrigin = value; onEditing(true) }
                        guard let origin = dragOrigin else { return }
                        let fine = NSEvent.modifierFlags.contains(.option) ? 0.25 : 1.0
                        let reach = max(1, radius - 9)
                        commit(WheelValue(x: origin.x + event.translation.width / reach * fine,
                                          y: origin.y - event.translation.height / reach * fine,
                                          master: value.master).sanitized, editing: true)
                    }
                    .onEnded { _ in dragOrigin = nil; onEditing(false) })
                .frame(maxWidth: .infinity)
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 112)
            .accessibilityElement()
            .accessibilityLabel("\(wheel.title)色轮")
            .accessibilityValue(String(format: L("色彩偏移 %.0f%%"), (value.x * value.x + value.y * value.y).squareRoot() * 100))
            HStack(spacing: 4) {
                Slider(value: Binding(get: { value.master }, set: { commit(WheelValue(x: value.x, y: value.y, master: $0), editing: true) }),
                       in: -1...1, onEditingChanged: { onEditing($0) })
                    .controlSize(.mini).labelsHidden().tint(WorkbenchTheme.control)
                Text(String(format: "%+.2f", value.master)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
                    .onTapGesture(count: 2) { commit(WheelValue(x: value.x, y: value.y, master: 0)) }
            }
            .help("亮度：双击数值复位")
        }
    }

    private func commit(_ next: WheelValue, editing: Bool = false) {
        if !editing { onEditing(true) }
        onChange(next)
        if !editing { onEditing(false) }
    }

    private var puckColor: Color {
        let chroma = value.chroma
        return Color(red: 0.5 + chroma.x * 0.3, green: 0.5 + chroma.y * 0.3, blue: 0.5 + chroma.z * 0.3)
    }

    /// Ring hues follow the vectorscope: the puck pushes the image toward the color under it.
    static let ringColors: [Color] = (0...36).map { step in
        let theta = -Double(step) * 10 * .pi / 180
        let cb = cos(theta), cr = sin(theta)
        let r = 0.5 + 0.32 * 1.5748 * cr, g = 0.5 + 0.32 * (-0.1873 * cb - 0.4681 * cr), b = 0.5 + 0.32 * 1.8556 * cb
        return Color(red: min(1, max(0, r)), green: min(1, max(0, g)), blue: min(1, max(0, b)))
    }
}

// MARK: - Curves

struct CurveEditor: View {
    let curves: ToneCurves
    let histogram: PreviewHistogram?
    let onChange: (ToneCurves.Channel, [CurvePoint]) -> Void
    let onEditing: (Bool) -> Void
    @AppStorage("curve.channel") private var channel = ToneCurves.Channel.master
    @UIState private var dragIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                GlassSegmentedControl(options: ToneCurves.Channel.allCases, selection: $channel, title: { $0.title },
                                      size: .small, accessibilityTitle: L("曲线通道"))
                    .frame(width: 140)
                Spacer()
                Button("复位通道") { onEditing(true); onChange(channel, ToneCurves.identity); onEditing(false) }
                    .buttonStyle(.borderless).font(.caption)
                    .disabled(curves[channel] == ToneCurves.identity)
            }
            GeometryReader { geometry in
                let size = geometry.size
                Canvas { context, size in draw(&context, size) }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { event in drag(event, size: size) }
                        .onEnded { _ in if dragIndex != nil { onEditing(false) }; dragIndex = nil })
            }
            .aspectRatio(1.45, contentMode: .fit)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.3)))
            Text("点按曲线添加控制点，拖出框外删除。").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private var tint: Color {
        switch channel { case .master: .white; case .red: .red; case .green: .green; case .blue: Color(red: 0.4, green: 0.6, blue: 1) }
    }

    private func point(_ value: CurvePoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: value.x * size.width, y: (1 - value.y) * size.height)
    }

    private func draw(_ context: inout GraphicsContext, _ size: CGSize) {
        var grid = Path()
        for fraction in [0.25, 0.5, 0.75] {
            grid.move(to: CGPoint(x: size.width * fraction, y: 0)); grid.addLine(to: CGPoint(x: size.width * fraction, y: size.height))
            grid.move(to: CGPoint(x: 0, y: size.height * fraction)); grid.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
        }
        context.stroke(grid, with: .color(.white.opacity(0.08)), lineWidth: 0.5)
        if let histogram {
            let channelIndex: Int? = switch channel { case .master: nil; case .red: 0; case .green: 1; case .blue: 2 }
            let values = channelIndex.map { histogram.channels[$0] }
                ?? zip(zip(histogram.channels[0], histogram.channels[1]), histogram.channels[2]).map { ($0.0 + $0.1 + $1) / 3 }
            var area = Path()
            area.move(to: CGPoint(x: 0, y: size.height))
            for (bin, value) in values.enumerated() {
                area.addLine(to: CGPoint(x: size.width * Double(bin) / Double(values.count - 1), y: size.height * (1 - sqrt(value) * 0.9)))
            }
            area.addLine(to: CGPoint(x: size.width, y: size.height)); area.closeSubpath()
            context.fill(area, with: .color(.white.opacity(0.07)))
        }
        var diagonal = Path()
        diagonal.move(to: CGPoint(x: 0, y: size.height)); diagonal.addLine(to: CGPoint(x: size.width, y: 0))
        context.stroke(diagonal, with: .color(.white.opacity(0.12)), style: StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
        // Show other channels faintly.
        for other in ToneCurves.Channel.allCases where other != channel && curves[other] != ToneCurves.identity {
            context.stroke(curvePath(curves[other], size), with: .color(.white.opacity(0.18)), lineWidth: 0.8)
        }
        let points = curves[channel]
        context.stroke(curvePath(points, size), with: .color(tint.opacity(0.95)), lineWidth: 1.4)
        for (index, value) in points.enumerated() {
            let center = point(value, size)
            let rect = CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)
            context.fill(Path(ellipseIn: rect), with: .color(index == dragIndex ? .white : .white.opacity(0.75)))
        }
    }

    private func curvePath(_ points: [CurvePoint], _ size: CGSize) -> Path {
        let samples = ToneCurves.sample(points, count: 96)
        var path = Path()
        for (index, value) in samples.enumerated() {
            let p = CGPoint(x: size.width * Double(index) / Double(samples.count - 1), y: (1 - value) * size.height)
            if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }

    private func drag(_ event: DragGesture.Value, size: CGSize) {
        var points = curves[channel]
        let x = min(1, max(0, event.location.x / max(1, size.width)))
        let y = min(1, max(0, 1 - event.location.y / max(1, size.height)))
        if dragIndex == nil {
            onEditing(true)
            if let near = points.indices.min(by: { distance(points[$0], event.startLocation, size) < distance(points[$1], event.startLocation, size) }),
               distance(points[near], event.startLocation, size) < 12 {
                dragIndex = near
            } else if points.count < 16 {
                let start = CGPoint(x: min(1, max(0, event.startLocation.x / max(1, size.width))),
                                    y: min(1, max(0, 1 - event.startLocation.y / max(1, size.height))))
                let insert = points.firstIndex { $0.x > start.x } ?? points.count - 1
                points.insert(CurvePoint(x: start.x, y: start.y), at: insert)
                dragIndex = insert
            } else { return }
        }
        guard let index = dragIndex, points.indices.contains(index) else { return }
        let outside = event.location.y < -24 || event.location.y > size.height + 24
        if outside, index != 0, index != points.count - 1 {
            points.remove(at: index)
            dragIndex = nil
            onChange(channel, points)
            onEditing(false)
            return
        }
        if index == 0 || index == points.count - 1 {
            points[index].y = y
        } else {
            let low = points[index - 1].x + 0.01, high = points[index + 1].x - 0.01
            points[index] = CurvePoint(x: min(high, max(low, x)), y: y)
        }
        onChange(channel, points)
    }

    private func distance(_ value: CurvePoint, _ location: CGPoint, _ size: CGSize) -> CGFloat {
        let p = point(value, size)
        return hypot(p.x - location.x, p.y - location.y)
    }
}

// MARK: - HSL

struct HSLPanel: View {
    let editor: EditorModel
    @AppStorage("hsl.band") private var bandIndex = 0

    private static let swatches: [Color] = [
        Color(red: 0.92, green: 0.25, blue: 0.22), Color(red: 0.96, green: 0.55, blue: 0.18), Color(red: 0.95, green: 0.85, blue: 0.25),
        Color(red: 0.35, green: 0.78, blue: 0.32), Color(red: 0.25, green: 0.82, blue: 0.85), Color(red: 0.25, green: 0.45, blue: 0.95),
        Color(red: 0.58, green: 0.36, blue: 0.92), Color(red: 0.90, green: 0.30, blue: 0.70)
    ]

    var body: some View {
        let hsl = editor.hsl
        let band = HueBand(rawValue: bandIndex) ?? .red
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                ForEach(HueBand.allCases, id: \.self) { item in
                    let changed = HSLAdjustments.Component.allCases.contains { hsl[item, $0] != 0 }
                    Button { bandIndex = item.rawValue } label: {
                        Circle().fill(Self.swatches[item.rawValue])
                            .frame(width: 15, height: 15)
                            .overlay(Circle().strokeBorder(Color.white, lineWidth: item == band ? 2 : 0))
                            .overlay(alignment: .bottom) {
                                if changed { Circle().fill(Color.white).frame(width: 3, height: 3).offset(y: 5) }
                            }
                            .frame(maxWidth: .infinity, minHeight: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(item.title)
                    .accessibilityLabel(item.title)
                    .accessibilityAddTraits(item == band ? .isSelected : [])
                }
            }
            ForEach(HSLAdjustments.Component.allCases, id: \.self) { component in
                ParameterRow(title: "\(band.title) · \(component.title)", value: hsl[band, component], range: -100...100,
                             labelWidth: 74, influence: .hue(band),
                             onChange: { editor.setHSL(band, component, $0) }, onEditing: editor.beginEditing,
                             onHover: { editor.hoverInfluence = $0 })
                    .equatable()
            }
        }
    }
}
