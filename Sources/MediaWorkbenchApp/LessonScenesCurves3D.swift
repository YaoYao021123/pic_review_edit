import MediaCore
import SwiftUI

private let amber = Color(red: 1, green: 0.82, blue: 0.4)
private let amberRgb = Rgb(1, 0.82, 0.4)

private func ease(_ t: Double) -> Double { let x = min(1, max(0, t)); return x * x * (3 - 2 * x) }

// MARK: - Curves: the photo's relief, reshaped

/// The photo as the brightness relief from the first lesson, beside the tone curve standing up like a bent
/// ribbon. Both use one height scale: each column's new height is what the curve says for its old brightness.
struct CurveScene: View {
    let photo: LessonPhoto
    let started: Date
    /// The second step: shapes to pick; otherwise the middle point is dragged.
    let shapes: Bool
    @UIState private var points: [CurvePoint] = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.5), CurvePoint(x: 1, y: 1)]
    @UIState private var shape = 0
    @UIState private var glide: Glide?

    /// The relief and curve before a shape was picked, and when (seconds since the scene began).
    private struct Glide { var heights: [Double]; var curve: [Double]; var at: Double }

    /// World height of a pure-white column, which is also the side of the chart.
    private static let rise = 9.0

    private static let presets: [(String, [CurvePoint])] = [
        (L("原样"), [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]),
        (L("变亮"), [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.63), CurvePoint(x: 1, y: 1)]),
        (L("变暗"), [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.37), CurvePoint(x: 1, y: 1)]),
        (L("S 形：对比更强"), [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.25, y: 0.17), CurvePoint(x: 0.75, y: 0.83), CurvePoint(x: 1, y: 1)]),
        (L("反 S：更柔和"), [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.25, y: 0.33), CurvePoint(x: 0.75, y: 0.67), CurvePoint(x: 1, y: 1)]),
    ]

    var body: some View {
        var curves = ToneCurves(); curves.master = points
        let r = photo.render(MediaEdits(curves: curves))
        let columns = photo.width >= photo.height ? 24 : max(12, Int((18 * Double(photo.width) / Double(photo.height)).rounded()))
        let before = photo.relief(columns: columns), after = photo.relief(of: r.pixels, columns: columns)
        let curve = ToneCurves.sample(points, count: 101)
        let marker = shapes || points.count != 3 ? nil : points[1]
        return VStack(spacing: 10) {
            Orbit3D(started: started, yaw: -0.5, pitch: 0.5, pitchRange: -0.2...1.4, distance: 120, fit: 21.5, wide: true,
                    target: V3(-7, 3, 0), motion: .sway(0.3)) { scene, t in
                draw(&scene, t, before: before, after: after, curve: curve, marker: marker)
            }
            .frame(height: shapes ? 340 : 310)
            HStack(alignment: .center, spacing: 14) {
                if !shapes { editor.frame(width: 150, height: 150) }
                LessonImage(image: r.image).frame(maxWidth: shapes ? 210 : 170)
                VStack(alignment: .leading, spacing: 8) {
                    ZoneHistogram(histogram: LessonPhoto.histogram(of: r.pixels), height: 56, showsCaption: false)
                    if let marker {
                        Text("原来 \(Int(marker.x * 100)) → 现在 \(Int(marker.y * 100))：比它暗的和比它亮的，都跟着平滑变化。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text("拖动圆点。立体图里发暖色的格子，是原来的亮度和这个点最接近的地方，它们升高或降低得最多。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(height: shapes ? 130 : 160)
            if shapes {
                HStack(spacing: 6) {
                    ForEach(Self.presets.indices, id: \.self) { i in
                        Button(Self.presets[i].0) { choose(i, current: after.luma, curve: curve) }
                            .buttonStyle(.plain).font(.callout)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(shape == i ? WorkbenchTheme.selection : WorkbenchTheme.well))
                    }
                }
            }
        }
    }

    private func choose(_ index: Int, current: [Double], curve: [Double]) {
        glide = Glide(heights: current, curve: curve, at: Date().timeIntervalSince(started))
        shape = index
        points = Self.presets[index].1
    }

    // MARK: 3D

    private func draw(_ scene: inout Scene3D, _ t: Double, before: LessonPhoto.Relief, after: LessonPhoto.Relief, curve: [Double], marker: CurvePoint?) {
        let columns = before.columns, rows = before.rows
        let n = Double(columns), m = Double(rows), height = Self.rise, side = Self.rise
        // After a shape is picked the relief and the ribbon move to it together.
        let mix = glide.map { ease((t - $0.at) / 0.55) } ?? 1
        let fromHeights = glide?.heights.count == after.luma.count ? glide!.heights : after.luma
        let ribbon = glide.map { zip($0.curve, curve).map { $0 + ($1 - $0) * mix } } ?? curve

        scene.underlay { s in
            s.face([V3(-n / 2, 0, m / 2), V3(n / 2, 0, m / 2), V3(n / 2, 0, -m / 2), V3(-n / 2, 0, -m / 2)], V3(0, 1, 0), Rgb(white: 0.15), twoSided: true, flat: true)
        }
        // The relief: every cell as tall as its brightness is now.
        for row in 0..<rows {
            for column in 0..<columns {
                let i = row * columns + column
                let luma = fromHeights[i] + (after.luma[i] - fromHeights[i]) * mix
                let up = ease((t - 0.2 - Double(column) / n * 0.6) / 0.8)
                let h = max(0.12, luma * height * up)
                let x = Double(column) - n / 2 + 0.5, z = m / 2 - Double(row) - 0.5
                var shade = 0.1 + 0.9 * luma
                var rgb = Rgb(white: shade)
                if let marker, abs(before.luma[i] - marker.x) < 0.07 { shade = max(0.25, shade); rgb = Rgb(min(1, shade * 1.15), shade * 0.95, shade * 0.55) }
                scene.box(V3(x, h / 2, z), V3(0.94, h, 0.94), rgb, sortAt: V3(x, 0, z))
            }
        }
        scene.label(Text("柱子的高度 = 这一格现在的亮度").font(.caption2).foregroundStyle(.secondary), at: V3(0, 0, -m / 2), dy: 24)

        // The chart: old brightness along the bottom, new brightness up the side, on the same scale as the columns.
        let x1 = -n / 2 - 3.5, x0 = x1 - side, front = -0.5, back = 0.5
        let panel = [V3(x0, 0, back), V3(x1, 0, back), V3(x1, side, back), V3(x0, side, back)]
        scene.underlay { s in
            s.face(panel, V3(0, 0, -1), Rgb(white: 1), opacity: 0.05, twoSided: true, flat: true)
            for edge in [0.1, 0.35, 0.65, 0.9] {
                s.line(V3(x0 + side * edge, 0, back), V3(x0 + side * edge, side, back), .white.opacity(0.12))
                s.line(V3(x0, side * edge, back), V3(x1, side * edge, back), .white.opacity(0.12))
            }
            s.polyline(panel, .white.opacity(0.28), closed: true)
            s.line(V3(x0, 0, back), V3(x1, side, back), .white.opacity(0.32), dash: [3, 3])
            // Two grey scales: what the brightness was (below) and what it becomes (left).
            for k in 0..<20 {
                let a = Double(k) / 20, b = Double(k + 1) / 20, grey = Rgb(white: (a + b) / 2)
                s.face([V3(x0 + side * a, -1.4, front), V3(x0 + side * b, -1.4, front), V3(x0 + side * b, -0.6, front), V3(x0 + side * a, -0.6, front)],
                       V3(0, 0, -1), grey, twoSided: true, flat: true)
                s.face([V3(x0 - 1.4, side * a, front), V3(x0 - 0.6, side * a, front), V3(x0 - 0.6, side * b, front), V3(x0 - 1.4, side * b, front)],
                       V3(0, 0, -1), grey, twoSided: true, flat: true)
            }
        }
        // Names under the bottom scale, on level rows however the chart is turned.
        let baseline = scene.camera.project(V3(x0 + side / 2, -1.4, front)).point.y
        func below(_ text: Text, _ x: Double, row: Double) {
            let at = V3(x, -1.4, front)
            let level = Double(baseline - scene.camera.project(at).point.y)
            scene.label(text, at: at, dy: level + 10 + row * 12)
        }
        for (k, zone) in ToneZone.allCases.enumerated() {
            let mid = (zone.range.lowerBound + zone.range.upperBound) / 2
            below(Text(zone.title).font(.caption2).foregroundStyle(.secondary), x0 + side * mid, row: Double(k % 2))
        }
        below(Text("原来的亮度 →").font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.85)), x0 + side / 2, row: 2.4)
        scene.label(Text("现在 ↑").font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.85)), at: V3(x0 - 1, side, front), dy: -12)

        // The curve as a ribbon standing on its edge: its top is lit by how steep it is.
        let reveal = ease((t - 0.2) / 1.0), thick = 0.3, steps = 50
        for j in 0..<steps where Double(j + 1) / Double(steps) <= reveal + 0.01 {
            let u0: Double = Double(j) / Double(steps), u1: Double = Double(j + 1) / Double(steps)
            let p = V3(x0 + side * u0, ribbon[j * 2] * side, 0), q = V3(x0 + side * u1, ribbon[j * 2 + 2] * side, 0)
            let run = q - p, normal = V3(-run.y, run.x, 0) / max(0.001, (run.x * run.x + run.y * run.y).squareRoot())
            scene.face([V3(p.x, p.y, front), V3(q.x, q.y, front), V3(q.x, q.y, back), V3(p.x, p.y, back)], normal, Rgb(white: 0.95), twoSided: true)
            scene.face([V3(p.x, p.y, front), V3(q.x, q.y, front), V3(q.x, q.y - thick, front), V3(p.x, p.y - thick, front)], V3(0, 0, -1), Rgb(white: 0.95), twoSided: true)
        }
        if let marker {
            let p = V3(x0 + side * marker.x, side * marker.y, front - 0.1)
            scene.line(p, V3(p.x, 0, front - 0.1), amber.opacity(0.7), dash: [3, 3], onTop: true)
            scene.line(p, V3(x0, p.y, front - 0.1), amber.opacity(0.7), dash: [3, 3], onTop: true)
            scene.ball(p, 0.5, amberRgb)
        }
    }

    // MARK: 2D control

    /// The curve as a plain graph with the middle point to drag.
    private var editor: some View {
        GeometryReader { proxy in
            let box = CGRect(origin: .zero, size: proxy.size).insetBy(dx: 10, dy: 10)
            ZStack {
                Canvas { context, _ in
                    context.stroke(Path(box), with: .color(.white.opacity(0.2)), lineWidth: 1)
                    var diagonal = Path(); diagonal.move(to: CGPoint(x: box.minX, y: box.maxY)); diagonal.addLine(to: CGPoint(x: box.maxX, y: box.minY))
                    context.stroke(diagonal, with: .color(.white.opacity(0.25)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    var line = Path()
                    for (i, y) in ToneCurves.sample(points, count: 101).enumerated() {
                        let p = CGPoint(x: box.minX + box.width * Double(i) / 100, y: box.maxY - box.height * y)
                        if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
                    }
                    context.stroke(line, with: .color(.white), lineWidth: 2)
                    for point in points.dropFirst().dropLast() {
                        let p = CGPoint(x: box.minX + box.width * point.x, y: box.maxY - box.height * point.y)
                        context.fill(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)), with: .color(amber))
                    }
                }
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        let x = min(0.9, max(0.1, (value.location.x - box.minX) / box.width))
                        let y = min(0.98, max(0.02, (box.maxY - value.location.y) / box.height))
                        points = [CurvePoint(x: 0, y: 0), CurvePoint(x: x, y: y), CurvePoint(x: 1, y: 1)]
                    })
            }
        }
    }
}
