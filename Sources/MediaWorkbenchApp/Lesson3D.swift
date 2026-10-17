import SwiftUI

// 3D for the lessons, drawn on a plain Canvas with our own perspective projection. The app's
// headless snapshots capture Canvas but not SceneKit, RealityKit or Metal views, and a few
// thousand dots and polygons are all these scenes need.

typealias V3 = SIMD3<Double>

private func dot3(_ a: V3, _ b: V3) -> Double { (a * b).sum() }

/// A colour whose channels can be scaled by a light factor.
struct Rgb {
    var r: Double, g: Double, b: Double
    init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
    init(white: Double) { self.init(white, white, white) }
    func color(_ k: Double = 1, opacity: Double = 1) -> Color {
        Color(red: min(1, r * k), green: min(1, g * k), blue: min(1, b * k)).opacity(opacity)
    }
}

/// A camera orbiting a target. +x is right, +y up and +z away from the eye when yaw and pitch are 0;
/// a positive pitch looks down from above.
struct OrbitCamera {
    var yaw: Double
    var pitch: Double
    var target = V3.zero
    /// Eye distance from the target, in world units.
    var distance = 14.0
    /// Pixels per world unit at the target.
    var scale = 20.0
    var center = CGPoint.zero
    /// World radius the scene fills; farther points fade a little (depth cue).
    var fit = 8.0

    private let sy: Double, cy: Double, sp: Double, cp: Double

    /// `fit` is the world radius that should fit the frame's smaller side, or its width when `wide`.
    init(yaw: Double, pitch: Double, target: V3 = .zero, distance: Double = 14, fit: Double = 8, wide: Bool = false, size: CGSize = .zero) {
        self.yaw = yaw; self.pitch = pitch; self.target = target; self.distance = distance; self.fit = fit
        sy = sin(yaw); cy = cos(yaw); sp = sin(pitch); cp = cos(pitch)
        center = CGPoint(x: size.width / 2, y: size.height / 2)
        // A little looser than a strict fit: scenes seldom fill their whole bounding sphere.
        scale = (wide ? size.width : min(size.width, size.height)) / (2 * fit) * (distance - fit * 0.2) / distance * 1.1
    }

    var eye: V3 { target + V3(distance * cp * sy, distance * sp, -distance * cp * cy) }

    func project(_ p: V3) -> (point: CGPoint, depth: Double) {
        let q = p - target
        let x = q.x * cy + q.z * sy, z1 = -q.x * sy + q.z * cy
        let y = q.y * cp + z1 * sp, z = -q.y * sp + z1 * cp
        let depth = max(0.1, z + distance), k = distance / depth
        return (CGPoint(x: center.x + x * scale * k, y: center.y - y * scale * k), depth)
    }

    /// Pixels per world unit for something at this depth.
    func pixels(at depth: Double) -> Double { scale * distance / max(0.1, depth) }
}

/// What a scene wants drawn, in world space. Projects, shades and depth-sorts it (painter's
/// algorithm), so scenes only describe boxes, lines and dots.
struct Scene3D {
    enum Mark {
        case dot(CGPoint, Double, Color)
        case shape(Path, fill: Color?, stroke: Color?, width: Double, dash: [CGFloat], evenOdd: Bool)
        case picture(CGImage, clip: Path, transform: CGAffineTransform, opacity: Double)
    }

    let camera: OrbitCamera
    private var under: [Mark] = []
    private var marks: [(depth: Double, order: Int, mark: Mark)] = []
    private var labels: [(Text, CGPoint)] = []
    private var drawingUnder = false
    /// While set, everything added sorts as if it sat at this depth (see `layer`).
    private var layerDepth: Double?
    /// The light is fixed in the world, so faces change shade as the view turns.
    private static let light: V3 = { let v = V3(-0.35, 0.85, -0.4); return v / dot3(v, v).squareRoot() }()

    init(camera: OrbitCamera) { self.camera = camera }

    private func lit(_ normal: V3) -> Double { 0.5 + 0.5 * max(0, dot3(normal, Self.light)) }
    private func fade(_ depth: Double) -> Double {
        1 - 0.5 * min(1, max(0, (depth - camera.distance + camera.fit) / (2 * camera.fit)))
    }
    private mutating func add(_ depth: Double, _ mark: Mark) {
        if drawingUnder { under.append(mark); return }
        // Marks forced on top (negative depth) stay on top; the order breaks ties, so layers keep their sequence.
        marks.append((depth >= 0 ? layerDepth ?? depth : depth, marks.count, mark))
    }

    /// Everything added inside is drawn first, in order (floors, grids), behind the sorted marks.
    mutating func underlay(_ body: (inout Scene3D) -> Void) { drawingUnder = true; body(&self); drawingUnder = false }

    /// Everything added inside is ordered as one piece, at the depth of `p`, in the order it was added:
    /// a picture and what is drawn on it stay together however the view turns.
    mutating func layer(at p: V3, _ body: (inout Scene3D) -> Void) {
        layerDepth = camera.project(p).depth; body(&self); layerDepth = nil
    }

    // MARK: Lines and dots

    mutating func dot(_ p: V3, _ radius: Double, _ color: Color, fog: Bool = true) {
        let q = camera.project(p)
        let r = max(0.6, radius * camera.pixels(at: q.depth) / camera.scale)
        add(q.depth, .dot(q.point, r, fog ? color.opacity(fade(q.depth)) : color))
    }

    mutating func line(_ a: V3, _ b: V3, _ color: Color, width: Double = 1, dash: [CGFloat] = [], onTop: Bool = false) {
        polyline([a, b], color, width: width, dash: dash, onTop: onTop)
    }

    /// `onTop` draws it after everything else (a measuring bar that must not hide behind a solid).
    mutating func polyline(_ points: [V3], _ color: Color, width: Double = 1, dash: [CGFloat] = [], closed: Bool = false, onTop: Bool = false) {
        guard points.count > 1 else { return }
        var path = Path(), depth = 0.0
        for (i, p) in points.enumerated() {
            let q = camera.project(p)
            depth += q.depth
            i == 0 ? path.move(to: q.point) : path.addLine(to: q.point)
        }
        if closed { path.closeSubpath() }
        depth /= Double(points.count)
        add(onTop ? -1 : depth, .shape(path, fill: nil, stroke: color.opacity(fade(depth)), width: width, dash: dash, evenOdd: false))
    }

    /// A circle around `center` in the plane perpendicular to `axis` (0 = x, 1 = y, 2 = z).
    static func circle(_ center: V3, _ radius: Double, axis: Int = 1, count: Int = 48) -> [V3] {
        (0..<count).map { i in
            let a = Double(i) / Double(count) * 2 * .pi, c = cos(a) * radius, s = sin(a) * radius
            return axis == 1 ? center + V3(c, 0, s) : axis == 2 ? center + V3(c, s, 0) : center + V3(0, c, s)
        }
    }

    // MARK: Solids

    /// A flat polygon, shaded by the light. Skipped when it faces away, unless `twoSided`.
    mutating func face(_ points: [V3], _ normal: V3, _ rgb: Rgb, opacity: Double = 1, edge: Color? = nil,
                       twoSided: Bool = false, depth: Double? = nil, flat: Bool = false) {
        let center = points.reduce(V3.zero, +) / Double(points.count)
        let facing = dot3(normal, camera.eye - center) > 0
        guard facing || twoSided else { return }
        var path = Path(), sum = 0.0
        for (i, p) in points.enumerated() {
            let q = camera.project(p)
            sum += q.depth
            i == 0 ? path.move(to: q.point) : path.addLine(to: q.point)
        }
        path.closeSubpath()
        let k = flat ? 1 : lit(facing ? normal : -normal)
        add(depth ?? sum / Double(points.count), .shape(path, fill: rgb.color(k, opacity: opacity), stroke: edge, width: 0.6, dash: [], evenOdd: false))
    }

    /// A flat ring: `outer` with `inner` cut out of it (the blades of an iris).
    mutating func hollowFace(_ outer: [V3], _ inner: [V3], _ normal: V3, _ rgb: Rgb, opacity: Double = 1) {
        let center = outer.reduce(V3.zero, +) / Double(outer.count)
        let facing = dot3(normal, camera.eye - center) > 0
        var path = Path(), sum = 0.0
        for ring in [outer, inner] {
            for (i, p) in ring.enumerated() {
                let q = camera.project(p)
                sum += q.depth
                i == 0 ? path.move(to: q.point) : path.addLine(to: q.point)
            }
            path.closeSubpath()
        }
        add(sum / Double(outer.count + inner.count), .shape(path, fill: rgb.color(lit(facing ? normal : -normal), opacity: opacity),
                                                              stroke: nil, width: 0, dash: [], evenOdd: true))
    }

    /// An axis-aligned box. `sortAt` is the point whose depth orders it among its neighbours.
    mutating func box(_ c: V3, _ size: V3, _ rgb: Rgb, edge: Color? = nil, sortAt: V3? = nil, opacity: Double = 1) {
        let h = size / 2, e = camera.eye
        let x0 = c.x - h.x, x1 = c.x + h.x, y0 = c.y - h.y, y1 = c.y + h.y, z0 = c.z - h.z, z1 = c.z + h.z
        let depth = camera.project(sortAt ?? c).depth
        func quad(_ pts: [V3], _ n: V3) {
            face(pts, n, rgb, opacity: opacity, edge: edge, depth: depth)
        }
        if e.y > y1 { quad([V3(x0, y1, z0), V3(x1, y1, z0), V3(x1, y1, z1), V3(x0, y1, z1)], V3(0, 1, 0)) }
        if e.y < y0 { quad([V3(x0, y0, z0), V3(x1, y0, z0), V3(x1, y0, z1), V3(x0, y0, z1)], V3(0, -1, 0)) }
        if e.x > x1 { quad([V3(x1, y0, z0), V3(x1, y1, z0), V3(x1, y1, z1), V3(x1, y0, z1)], V3(1, 0, 0)) }
        if e.x < x0 { quad([V3(x0, y0, z0), V3(x0, y1, z0), V3(x0, y1, z1), V3(x0, y0, z1)], V3(-1, 0, 0)) }
        if e.z > z1 { quad([V3(x0, y0, z1), V3(x1, y0, z1), V3(x1, y1, z1), V3(x0, y1, z1)], V3(0, 0, 1)) }
        if e.z < z0 { quad([V3(x0, y0, z0), V3(x1, y0, z0), V3(x1, y1, z0), V3(x0, y1, z0)], V3(0, 0, -1)) }
    }

    /// A vertical cylinder, or a cone when `topRadius` is 0, standing on `base`.
    mutating func column(_ base: V3, radius: Double, height: Double, topRadius: Double = -1, _ rgb: Rgb, sides: Int = 14) {
        let top = topRadius < 0 ? radius : topRadius
        let depth = camera.project(base + V3(0, height / 2, 0)).depth
        let slope = (radius - top) / max(0.001, height)
        for i in 0..<sides {
            let a0 = Double(i) / Double(sides) * 2 * .pi, a1 = Double(i + 1) / Double(sides) * 2 * .pi, mid = (a0 + a1) / 2
            let b0 = base + V3(cos(a0) * radius, 0, sin(a0) * radius), b1 = base + V3(cos(a1) * radius, 0, sin(a1) * radius)
            let t0 = base + V3(cos(a0) * top, height, sin(a0) * top), t1 = base + V3(cos(a1) * top, height, sin(a1) * top)
            let n = V3(cos(mid), slope, sin(mid))
            face([b0, b1, t1, t0], n / (1 + slope * slope).squareRoot(), rgb, depth: depth)
        }
        if top > 0 { face(Self.circle(base + V3(0, height, 0), top, count: sides), V3(0, 1, 0), rgb, depth: depth) }
    }

    /// A shaded ball, drawn as a disc with a highlight.
    mutating func ball(_ c: V3, _ radius: Double, _ rgb: Rgb, opacity: Double = 1) {
        let q = camera.project(c)
        let r = radius * camera.pixels(at: q.depth)
        add(q.depth, .dot(q.point, r, rgb.color(0.85, opacity: opacity)))
        add(q.depth, .dot(CGPoint(x: q.point.x - r * 0.28, y: q.point.y - r * 0.3), r * 0.5, rgb.color(1.15, opacity: 0.8 * opacity)))
    }

    // MARK: Text and pictures

    /// Text at a world position, drawn on top of everything.
    mutating func label(_ text: Text, at p: V3, dx: Double = 0, dy: Double = 0) {
        let q = camera.project(p)
        labels.append((text, CGPoint(x: q.point.x + dx, y: q.point.y + dy)))
    }

    /// A picture on a quad (corners: top-left, top-right, bottom-right, bottom-left). Perspective is
    /// approximated by cutting it into small cells, each drawn with its own affine map.
    mutating func picture(_ image: CGImage, corners: [V3], cells: (Int, Int) = (8, 6), opacity: Double = 1) {
        guard corners.count == 4 else { return }
        func at(_ u: Double, _ v: Double) -> V3 {
            let top = corners[0] + (corners[1] - corners[0]) * u, bottom = corners[3] + (corners[2] - corners[3]) * u
            return top + (bottom - top) * v
        }
        let (n, m) = cells
        let sorted = camera.project((corners[0] + corners[2]) / 2).depth
        for j in 0..<m {
            for i in 0..<n {
                let u0 = Double(i) / Double(n), u1 = Double(i + 1) / Double(n), v0 = Double(j) / Double(m), v1 = Double(j + 1) / Double(m)
                let c00 = camera.project(at(u0, v0)).point, c10 = camera.project(at(u1, v0)).point
                let c11 = camera.project(at(u1, v1)).point, c01 = camera.project(at(u0, v1)).point
                let mid = CGPoint(x: (c00.x + c11.x) / 2, y: (c00.y + c11.y) / 2)
                // Grown by half a point so neighbouring cells overlap and leave no seams.
                func grown(_ p: CGPoint) -> CGPoint {
                    let dx = p.x - mid.x, dy = p.y - mid.y, d = max(0.001, (dx * dx + dy * dy).squareRoot())
                    return CGPoint(x: p.x + dx / d * 0.6, y: p.y + dy / d * 0.6)
                }
                var clip = Path()
                clip.move(to: grown(c00)); clip.addLine(to: grown(c10)); clip.addLine(to: grown(c11)); clip.addLine(to: grown(c01)); clip.closeSubpath()
                let ex = CGPoint(x: c10.x - c00.x, y: c10.y - c00.y), ey = CGPoint(x: c01.x - c00.x, y: c01.y - c00.y)
                let transform = CGAffineTransform(a: ex.x * Double(n), b: ex.y * Double(n), c: ey.x * Double(m), d: ey.y * Double(m),
                                                  tx: c00.x - ex.x * Double(i) - ey.x * Double(j), ty: c00.y - ex.y * Double(i) - ey.y * Double(j))
                add(sorted, .picture(image, clip: clip, transform: transform, opacity: opacity))
            }
        }
    }

    // MARK: Drawing

    mutating func render(into context: inout GraphicsContext) {
        for mark in under { draw(mark, &context) }
        marks.sort { $0.depth != $1.depth ? $0.depth > $1.depth : $0.order < $1.order }
        for entry in marks { draw(entry.mark, &context) }
        for (text, point) in labels { context.draw(text, at: point) }
    }

    private func draw(_ mark: Mark, _ context: inout GraphicsContext) {
        switch mark {
        case .dot(let p, let r, let color):
            context.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(color))
        case .shape(let path, let fill, let stroke, let width, let dash, let evenOdd):
            if let fill { context.fill(path, with: .color(fill), style: FillStyle(eoFill: evenOdd)) }
            if let stroke {
                context.stroke(path, with: .color(stroke), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: dash))
            }
        case .picture(let image, let clip, let transform, let opacity):
            var layer = context
            layer.opacity = opacity
            layer.clip(to: clip)
            layer.concatenate(transform)
            layer.draw(Image(decorative: image, scale: 1), in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }
}

// MARK: - The orbit view

/// Drag to turn the scene; while nobody is dragging it keeps moving gently (a slow spin, or a
/// sway for scenes that have a front). Reduce Motion stops that movement.
struct Orbit3D: View {
    enum Motion { case spin(Double), sway(Double), still }
    /// A named camera angle; changing the id glides the view there.
    struct Viewpoint: Equatable { var id: Int; var yaw: Double; var pitch: Double }

    var started = Date.distantPast
    var yaw = -0.55
    var pitch = 0.5
    var pitchRange = 0.05...1.5
    var distance = 14.0
    var fit = 8.0
    /// Size the scene by the frame's width (for scenes that run along the long side).
    var wide = false
    var target = V3.zero
    var motion = Motion.spin(0.16)
    var viewpoint: Viewpoint?
    /// Idle motion is slow, so half the display rate is plenty; dragging redraws at once anyway.
    var framesPerSecond = 30.0
    let draw: (inout Scene3D, Double) -> Void

    private struct Pose {
        var dYaw = 0.0, dPitch = 0.0
        /// Motion resumes from this moment (nil while dragging).
        var idleSince: Date? = Date().addingTimeInterval(0.8)
        var glideFrom: (yaw: Double, pitch: Double, start: Date)?
        var dragStart: (yaw: Double, pitch: Double)?
    }
    @UIState private var pose = Pose()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let glideTime = 0.55

    private func angles(_ now: Date) -> (yaw: Double, pitch: Double) {
        var a = (yaw: yaw + pose.dYaw, pitch: pitch + pose.dPitch)
        if !reduceMotion, let since = pose.idleSince {
            let s = max(0, now.timeIntervalSince(since))
            switch motion {
            case .spin(let rate): a.yaw += rate * s
            case .sway(let amount): a.yaw += amount * sin(s * 0.55)
            case .still: break
            }
        }
        if let g = pose.glideFrom {
            let u = min(1, now.timeIntervalSince(g.start) / Self.glideTime), e = u * u * (3 - 2 * u)
            if u < 1 { a = (g.yaw + (a.yaw - g.yaw) * e, g.pitch + (a.pitch - g.pitch) * e) }
        }
        return a
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / framesPerSecond, paused: reduceMotion)) { timeline in
            let a = angles(timeline.date)
            let phase = reduceMotion ? 1000 : max(0, timeline.date.timeIntervalSince(started))
            Canvas { context, size in
                var scene = Scene3D(camera: OrbitCamera(yaw: a.yaw, pitch: a.pitch, target: target, distance: distance, fit: fit, wide: wide, size: size))
                draw(&scene, phase)
                scene.render(into: &context)
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { value in
                if pose.dragStart == nil {
                    let now = angles(Date())
                    pose = Pose(dYaw: now.yaw - yaw, dPitch: now.pitch - pitch, idleSince: nil, glideFrom: nil, dragStart: (now.yaw - yaw, now.pitch - pitch))
                }
                guard let start = pose.dragStart else { return }
                pose.dYaw = start.yaw - value.translation.width * 0.008
                pose.dPitch = min(pitchRange.upperBound, max(pitchRange.lowerBound, pitch + start.pitch + value.translation.height * 0.008)) - pitch
            }
            .onEnded { _ in
                pose.dragStart = nil
                pose.idleSince = Date().addingTimeInterval(1.5)
            })
        .onChange(of: viewpoint) { _, next in
            guard let next else { return }
            let now = angles(Date())
            // Take the short way round.
            var goal = next.yaw
            while goal - now.yaw > .pi { goal -= 2 * .pi }
            while goal - now.yaw < -.pi { goal += 2 * .pi }
            pose = Pose(dYaw: goal - yaw, dPitch: next.pitch - pitch, idleSince: Date().addingTimeInterval(Self.glideTime + 1.5),
                        glideFrom: reduceMotion ? nil : (now.yaw, now.pitch, Date()), dragStart: nil)
        }
        .overlay(alignment: .bottomTrailing) {
            Label("拖动旋转", systemImage: "rotate.3d").font(.caption2).foregroundStyle(.tertiary).padding(4)
        }
        .clipped()
        .accessibilityElement()
        .accessibilityLabel(Text("三维演示，拖动可以旋转"))
    }
}
