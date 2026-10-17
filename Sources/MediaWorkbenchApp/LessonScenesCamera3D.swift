import MediaCore
import SwiftUI

private let amber = Color(red: 1, green: 0.82, blue: 0.4)

// MARK: - Aperture: light through the opening

/// A lens seen in space: parallel light enters, the iris blocks the outer rays, the rest meet on the sensor.
struct ApertureScene: View {
    let photo: LessonPhoto
    @UIState private var stop = 2.0
    @UIState private var viewIndex = 0
    @UIState private var viewShot = 0

    private static let views: [(title: String, yaw: Double, pitch: Double)] = [
        (L("斜着看"), 1.05, 0.3), (L("正面看"), 0, 0), (L("侧面看"), .pi / 2, 0.02),
    ]

    var body: some View {
        let f = fStops[Int(stop.rounded())]
        let focal = photo.capture?.focalLengthMM ?? 50
        let diameter = focal / f
        let lessLight = pow(2, log2(f / 1.4) * 2)
        let view = Self.views[viewIndex]
        return VStack(spacing: 12) {
            Orbit3D(yaw: Self.views[0].yaw, pitch: Self.views[0].pitch, pitchRange: -0.5...1.4, distance: 40, fit: 7.2, wide: true, target: V3(0, 0, 1.0), motion: .sway(0.22),
                    viewpoint: .init(id: viewShot, yaw: view.yaw, pitch: view.pitch)) { scene, _ in
                draw(&scene, f)
            }
            .frame(height: 290)
            GlassSegmentedControl(options: Array(Self.views.indices), selection: Binding(get: { viewIndex }, set: { viewIndex = $0; viewShot += 1 }),
                                  title: { Self.views[$0].title }, size: .small)
                .frame(maxWidth: 280)
            Text(String(format: L("开口直径 = %.0f mm ÷ %.1f ≈ %.1f mm"), focal, f, diameter)).font(.title3.monospacedDigit())
            Text(f == 1.4 ? L("最大的开口，进光最多。") : String(format: L("进来的光只有 ƒ/1.4 的 1/%.0f。"), lessLight))
                .font(.callout).foregroundStyle(.secondary)
            LessonSlider(title: L("光圈"), value: $stop, range: 0...Double(fStops.count - 1), format: { stopLabel(fStops[Int($0.rounded())]) })
            if let capture = photo.capture, let fn = capture.fNumber {
                Text(L("你这张照片用的是 \(stopLabel(fn))") + (capture.focalLengthMM.map { String(format: L("，焦距 %.1f mm，开口约 %.1f mm。"), $0, $0 / fn) } ?? L("。")))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func draw(_ scene: inout Scene3D, _ f: Double) {
        // The barrel runs along +z: light comes in at z < 0, the iris sits at z = 2, the sensor at z = 7.
        let radius = 2.2, irisZ = 2.0, endZ = 4.4, sensorZ = 7.0, startZ = -5.0
        let shrink = (sensorZ - irisZ) / sensorZ          // a ray is this share of its entry radius at the iris
        let open = radius * shrink * 1.4 / f               // ƒ/1.4 lets every ray through
        let focus = V3(0, 0, sensorZ)
        var passed = 0, total = 0
        for ring in 1...5 {
            let rho = radius * Double(ring) / 5, count = 4 + 3 * ring
            for i in 0..<count {
                let a = (Double(i) + Double(ring) * 0.4) / Double(count) * 2 * .pi
                let enter = V3(cos(a) * rho, sin(a) * rho, 0)
                let passes = rho * shrink <= open + 1e-9
                total += 1
                scene.line(V3(enter.x, enter.y, startZ), enter, amber.opacity(passes ? 0.5 : 0.22))
                if passes {
                    passed += 1
                    scene.line(enter, focus, amber.opacity(0.75))
                } else {
                    let hit = V3(enter.x * shrink, enter.y * shrink, irisZ)
                    scene.line(enter, hit, amber.opacity(0.2))
                    scene.dot(hit, 1.8, Color(white: 0.5))
                }
            }
        }
        // The lens barrel, the iris with its opening, the sensor.
        scene.polyline(Scene3D.circle(V3(0, 0, 0), radius, axis: 2), .white.opacity(0.55), width: 1.5, closed: true)
        scene.polyline(Scene3D.circle(V3(0, 0, endZ), radius, axis: 2), .white.opacity(0.3), closed: true)
        for i in 0..<10 {
            let a = Double(i) / 10 * 2 * .pi, x = cos(a) * radius, y = sin(a) * radius
            scene.line(V3(x, y, 0), V3(x, y, endZ), .white.opacity(0.14))
        }
        let hole = (0..<9).map { i -> V3 in
            let a = Double(i) / 9 * 2 * .pi + 0.2
            return V3(cos(a) * max(0.05, open), sin(a) * max(0.05, open), irisZ)
        }
        scene.hollowFace(Scene3D.circle(V3(0, 0, irisZ), radius * 0.98, axis: 2, count: 40), hole, V3(0, 0, -1), Rgb(white: 0.78))
        scene.face([V3(-1.6, -1.07, sensorZ), V3(1.6, -1.07, sensorZ), V3(1.6, 1.07, sensorZ), V3(-1.6, 1.07, sensorZ)], V3(0, 0, -1),
                   Rgb(white: 0.85), opacity: 0.3, edge: .white.opacity(0.5), twoSided: true, flat: true)
        let share = Double(passed) / Double(total)
        scene.dot(focus, 5 + 4 * share, amber.opacity(0.3 + 0.7 * share), fog: false)
        scene.line(V3(0, 0, startZ), V3(0, 0, sensorZ), .white.opacity(0.25), dash: [3, 3])
        scene.label(Text("来自远处的光").font(.caption2).foregroundStyle(.secondary), at: V3(0, radius, startZ + 2), dy: -10)
        scene.label(Text("光圈（可变的开口）").font(.caption2).foregroundStyle(.secondary), at: V3(0, radius, irisZ), dy: -10)
        scene.label(Text("传感器").font(.caption2).foregroundStyle(.secondary), at: V3(0, -1.07, sensorZ), dy: 12)
    }
}

// MARK: - Depth of field: a thin slab of sharpness in space

struct DepthOfFieldScene: View {
    @UIState private var stop = 1.0

    // Thin-lens numbers for a 50 mm lens focused at 3 m. The sharp zone is where a point of light
    // spreads over less than 0.03 mm of sensor.
    private static let focal = 50.0, focus = 3000.0, limit = 0.03
    /// Width in mm of the blur disc on the sensor for a point at `distance` mm (nil = very far).
    private static func blur(_ f: Double, at distance: Double?) -> Double {
        let across = focal * focal / (f * (focus - focal))
        guard let distance else { return across }
        return across * abs(distance - focus) / distance
    }
    private static let flower = 2000.0, tree = 6500.0

    var body: some View {
        let f = fStops[Int(stop.rounded())]
        let hyper = Self.focal * Self.focal / (f * Self.limit) + Self.focal
        let near = Self.focus * (hyper - Self.focal) / (hyper + Self.focus - 2 * Self.focal)
        let far = hyper > Self.focus ? Self.focus * (hyper - Self.focal) / (hyper - Self.focus) : .infinity
        let blurs = (flower: Self.blur(f, at: Self.flower), tree: Self.blur(f, at: Self.tree), back: Self.blur(f, at: nil))
        let sharp = (flower: blurs.flower <= Self.limit, tree: blurs.tree <= Self.limit)
        return VStack(spacing: 14) {
            HStack(spacing: 14) {
                Orbit3D(yaw: 0.9, pitch: 0.55, distance: 60, fit: 9.5, wide: true, target: V3(0, 0.8, 6.2), motion: .sway(0.3)) { scene, _ in
                    draw(&scene, near: near, far: far, blurs: blurs)
                }
                picture(blurs, sharp).clipShape(RoundedRectangle(cornerRadius: 6)).frame(width: 210)
            }
            .frame(height: 310)
            LessonSlider(title: L("光圈"), value: $stop, range: 0...Double(fStops.count - 1), format: { stopLabel(fStops[Int($0.rounded())]) })
            Text(sharp.flower && sharp.tree ? L("开口小：从近处的花到远处的树都清楚，适合风景。")
                 : !sharp.flower && !sharp.tree ? L("开口大：只有人是清楚的，背景的灯变成柔和的光斑。") : L("中间档：主体清楚，背景略有虚化。"))
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    /// World units are half metres; the camera stands at z = -1.8 and looks along +z.
    private func draw(_ scene: inout Scene3D, near: Double, far: Double, blurs: (flower: Double, tree: Double, back: Double)) {
        func z(_ mm: Double) -> Double { mm / 500 }
        let zNear = z(near), zFar = min(z(far), 15.6)
        scene.underlay { s in
            for i in -2...2 { s.line(V3(Double(i) * 2.25, 0, 0), V3(Double(i) * 2.25, 0, 16), .white.opacity(0.1)) }
            for i in 0...4 { s.line(V3(-4.5, 0, Double(i) * 4), V3(4.5, 0, Double(i) * 4), .white.opacity(0.1)) }
        }
        // The sharp zone: a slab from the near limit to the far limit.
        let slab = Rgb(white: 1)
        scene.face([V3(-4.5, 0.02, zNear), V3(4.5, 0.02, zNear), V3(4.5, 0.02, zFar), V3(-4.5, 0.02, zFar)], V3(0, 1, 0), slab, opacity: 0.14, twoSided: true, flat: true)
        for edge in [zNear, zFar] {
            scene.face([V3(-4.5, 0, edge), V3(4.5, 0, edge), V3(4.5, 5.5, edge), V3(-4.5, 5.5, edge)], V3(0, 0, -1), slab, opacity: 0.07,
                       edge: .white.opacity(0.35), twoSided: true, flat: true)
        }
        scene.label(Text("清楚的范围").font(.caption2).foregroundStyle(.white.opacity(0.85)), at: V3(4.5, 0, (zNear + zFar) / 2), dy: 13)
        // The camera.
        scene.box(V3(0, 1.4, -1.9), V3(1.4, 0.9, 1.0), Rgb(white: 0.8))
        scene.box(V3(0, 1.4, -1.1), V3(0.7, 0.7, 0.7), Rgb(white: 0.55))
        // Three subjects at different distances, each with a point of light that blurs into a disc.
        func lamp(_ p: V3, _ blur: Double) {
            let r = max(2.4, blur * 40)
            if blur > Self.limit {
                scene.dot(p, r, amber.opacity(0.18), fog: false)
                scene.dot(p, r * 0.7, amber.opacity(0.18), fog: false)
            }
            scene.dot(p, 2.4, amber, fog: false)
        }
        scene.column(V3(-2, 0, z(Self.flower)), radius: 0.07, height: 0.9, Rgb(0.35, 0.65, 0.35))
        scene.ball(V3(-2, 1.05, z(Self.flower)), 0.3, Rgb(0.92, 0.45, 0.6))
        lamp(V3(-2, 1.05, z(Self.flower)), blurs.flower)
        scene.column(V3(0.3, 0, z(Self.focus)), radius: 0.5, height: 2.3, Rgb(0.3, 0.4, 0.7))
        scene.ball(V3(0.3, 2.7, z(Self.focus)), 0.4, Rgb(0.86, 0.72, 0.62))
        lamp(V3(1.1, 1.7, z(Self.focus)), 0)
        scene.column(V3(2.4, 0, z(Self.tree)), radius: 0.28, height: 1.8, Rgb(0.5, 0.36, 0.25))
        scene.column(V3(2.4, 1.5, z(Self.tree)), radius: 1.6, height: 4.2, topRadius: 0, Rgb(0.25, 0.5, 0.3))
        lamp(V3(2.4, 5.9, z(Self.tree)), blurs.tree)
    }

    /// What the camera records: the lights behind turn into discs, the flower and tree soften.
    private func picture(_ blurs: (flower: Double, tree: Double, back: Double), _ sharp: (flower: Bool, tree: Bool)) -> some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.07, green: 0.09, blue: 0.14)))
            func px(_ blur: Double) -> Double { min(14, blur * 22) }
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: px(blurs.back)))
                for i in 0..<14 {
                    let x = size.width * Double((i * 37) % 100) / 100, y = size.height * (0.1 + Double((i * 53) % 40) / 100)
                    let r = 5.0 + Double(i % 3) * 3
                    layer.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                               with: .color([Color.orange, .yellow, .white, .pink][i % 4].opacity(0.85)))
                }
            }
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: px(blurs.tree)))
                var tree = Path()
                tree.move(to: CGPoint(x: size.width * 0.84, y: size.height * 0.2)); tree.addLine(to: CGPoint(x: size.width * 1.02, y: size.height * 0.7))
                tree.addLine(to: CGPoint(x: size.width * 0.66, y: size.height * 0.7)); tree.closeSubpath()
                layer.fill(tree, with: .color(Color(red: 0.17, green: 0.38, blue: 0.22)))
                layer.fill(Path(ellipseIn: CGRect(x: size.width * 0.84 - 6, y: size.height * 0.2 - 6, width: 12, height: 12)), with: .color(amber))
            }
            context.fill(Path(CGRect(x: 0, y: size.height * 0.68, width: size.width, height: size.height * 0.32)), with: .color(Color(red: 0.1, green: 0.16, blue: 0.1)))
            let cx = size.width * 0.5, top = size.height * 0.3
            context.fill(Path(ellipseIn: CGRect(x: cx - 18, y: top, width: 36, height: 40)), with: .color(Color(red: 0.86, green: 0.72, blue: 0.62)))
            context.fill(Path(roundedRect: CGRect(x: cx - 40, y: top + 44, width: 80, height: size.height - top - 44), cornerRadius: 18), with: .color(Color(red: 0.2, green: 0.3, blue: 0.5)))
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: px(blurs.flower)))
                layer.fill(Path(ellipseIn: CGRect(x: size.width * 0.14, y: size.height * 0.8, width: 34, height: 34)), with: .color(Color(red: 0.92, green: 0.45, blue: 0.6)))
                layer.fill(Path(CGRect(x: size.width * 0.14 + 15, y: size.height * 0.8 + 30, width: 4, height: size.height * 0.2)), with: .color(Color(red: 0.35, green: 0.65, blue: 0.35)))
            }
        }
    }
}

// MARK: - Focal length: the slice of the world a lens sees

struct FieldOfViewScene: View {
    let photo: LessonPhoto
    @UIState private var zoom = 1.0
    var body: some View {
        // The photo is the widest view we have; longer lenses are centre crops of it.
        let base = photo.capture?.focalLength35mm ?? 24
        let focal = base * zoom
        let crop = photo.thumbnail.cropping(to: CGRect(x: Double(photo.width) * (1 - 1 / zoom) / 2, y: Double(photo.height) * (1 - 1 / zoom) / 2,
                                                       width: Double(photo.width) / zoom, height: Double(photo.height) / zoom).integral) ?? photo.thumbnail
        let angle = 2 * atan(36 / (2 * focal)) * 180 / .pi
        return VStack(spacing: 14) {
            HStack(spacing: 14) {
                LessonImage(image: crop, caption: String(format: L("等效 %.0f mm · 水平视角约 %.0f°"), focal, angle)).frame(maxWidth: .infinity)
                Orbit3D(yaw: -0.35, pitch: 0.62, distance: 60, fit: 12, wide: true, target: V3(0, 2, 7), motion: .sway(0.3)) { scene, _ in
                    draw(&scene, crop: crop, angle: angle)
                }
                .frame(width: 340)
            }
            .frame(height: 310)
            LessonSlider(title: L("焦距"), value: $zoom, range: 1...8, format: { String(format: "%.0f mm", base * $0) })
            Text(focal < 35 ? L("广角：装得多，适合风景、室内、合影。") : focal < 70 ? L("标准：接近人眼看到的感觉。") : L("长焦：像望远镜，把远处拉近，背景更简洁。"))
                .font(.callout).foregroundStyle(.secondary)
            if photo.capture?.focalLength35mm != nil {
                Text(String(format: L("你这张照片是等效 %.0f mm 拍的；更长的焦距在这里用裁切模拟。"), base)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func draw(_ scene: inout Scene3D, crop: CGImage, angle: Double) {
        let tanHalf = tan(angle / 2 * .pi / 180)
        let eye = V3(0, 2.4, 0), farZ = 14.0
        let w = farZ * tanHalf, h = w * Double(crop.height) / Double(crop.width)
        scene.underlay { s in
            for i in -3...3 { s.line(V3(Double(i) * 4, 0, 0), V3(Double(i) * 4, 0, 16), .white.opacity(0.08)) }
            for i in 0...4 { s.line(V3(-12, 0, Double(i) * 4), V3(12, 0, Double(i) * 4), .white.opacity(0.08)) }
        }
        // Posts in three rows. Those inside the wedge the lens sees keep their colour.
        let rows: [(z: Double, step: Double, rgb: Rgb)] = [(5, 4, Rgb(0.95, 0.62, 0.38)), (9, 4, Rgb(0.5, 0.78, 0.55)), (13, 4, Rgb(0.5, 0.66, 0.95))]
        for row in rows {
            let count = Int(12 / row.step)
            for i in -count...count {
                let x = Double(i) * row.step
                let inside = abs(x) <= row.z * tanHalf
                scene.column(V3(x, 0, row.z), radius: 0.4, height: 3.2, inside ? row.rgb : Rgb(row.rgb.r * 0.3, row.rgb.g * 0.3, row.rgb.b * 0.3))
            }
        }
        scene.box(V3(0, eye.y, -0.9), V3(1.3, 0.9, 1.3), Rgb(white: 0.85))
        let corners = [V3(-w, eye.y + h, farZ), V3(w, eye.y + h, farZ), V3(w, eye.y - h, farZ), V3(-w, eye.y - h, farZ)]
        scene.picture(crop, corners: corners, opacity: 0.92)
        scene.polyline(corners, .white.opacity(0.8), width: 1.2, closed: true)
        for c in corners { scene.line(eye, c, .white.opacity(0.55)) }
        scene.label(Text("相机").font(.caption2).foregroundStyle(.secondary), at: V3(0, eye.y, -0.9), dy: 16)
    }
}

// MARK: - Perspective: why a long lens "pulls" the background closer

struct PerspectiveScene: View {
    @UIState private var focal = 35.0
    var body: some View {
        // The person stays the same size in the frame, so the camera backs away as focal grows.
        let distance = focal / 35 * 3   // metres to the person
        let background = 40.0            // metres from the person to the mountain
        let mountainScale = (distance) / (distance + background) / (3.0 / 43.0)
        return VStack(spacing: 12) {
            Orbit3D(yaw: 1.4, pitch: 1.05, distance: 120, fit: 27, target: V3(0, 0, 15), motion: .sway(0.25)) { scene, _ in
                draw(&scene, distance: distance, background: background)
            }
            .frame(height: 290)
            HStack(spacing: 16) {
                picture(mountainScale).clipShape(RoundedRectangle(cornerRadius: 6)).frame(width: 210, height: 140)
                VStack(alignment: .leading, spacing: 12) {
                    LessonSlider(title: L("焦距"), value: $focal, range: 24...200, format: { String(format: "%.0f mm", $0) })
                    Text(String(format: L("人离相机约 %.0f 米；背景的山看起来有原来的 %.1f 倍大。"), distance, max(0.5, mountainScale)))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// From above: the camera backs away as the lens gets longer, the wedge it sees narrows, and the same
    /// mountain fills more and more of the frame. The person and the camera are drawn larger than life.
    private func draw(_ scene: inout Scene3D, distance: Double, background: Double) {
        let tanHalf = 18 / focal, eyeY = 1.2, endZ = background + 14
        let wideAt: (Double) -> Double = { z in (z + distance) * tanHalf }
        scene.underlay { s in
            let w = wideAt(endZ)
            s.face([V3(0, 0, -distance), V3(-w, 0, endZ), V3(w, 0, endZ)], V3(0, 1, 0), Rgb(white: 1), opacity: 0.07, twoSided: true, flat: true)
            s.line(V3(0, 0, -19), V3(0, 0, 56), .white.opacity(0.14), dash: [3, 3])
        }
        // The width of the frame at the person and at the mountain.
        func frame(_ z: Double) {
            let w = wideAt(z)
            scene.line(V3(-w, 0, z), V3(w, 0, z), .white.opacity(0.95), width: 3, onTop: true)
            scene.line(V3(-w, 0, z - 0.8), V3(-w, 0, z + 0.8), .white.opacity(0.95), width: 2, onTop: true)
            scene.line(V3(w, 0, z - 0.8), V3(w, 0, z + 0.8), .white.opacity(0.95), width: 2, onTop: true)
        }
        let wEnd = wideAt(endZ)
        scene.line(V3(0, 0, -distance), V3(-wEnd, 0, endZ), .white.opacity(0.5))
        scene.line(V3(0, 0, -distance), V3(wEnd, 0, endZ), .white.opacity(0.5))
        scene.column(V3(0, 0, background), radius: 9.5, height: 7, topRadius: 0, Rgb(0.4, 0.48, 0.58), sides: 24)
        scene.column(V3(0, 0, 0), radius: 1.3, height: 3.4, Rgb(0.8, 0.32, 0.27))
        scene.box(V3(0, eyeY, -distance - 1), V3(2.4, 1.6, 2.8), Rgb(white: 0.85))
        frame(0)
        frame(background)
        // The frame's width at each place, so the two can be compared.
        scene.label(Text(String(format: L("画面宽 %.0f 米"), wideAt(0) * 2)).font(.caption2).foregroundStyle(.white.opacity(0.85)),
                    at: V3(wideAt(0), 0, 0), dx: 6, dy: 14)
        scene.label(Text(String(format: L("画面宽 %.0f 米"), wideAt(background) * 2)).font(.caption2).foregroundStyle(.white.opacity(0.85)),
                    at: V3(-wideAt(background), 0, background), dx: 0, dy: -11)
        scene.label(Text("相机").font(.caption2).foregroundStyle(.secondary), at: V3(0, eyeY, -distance - 1), dx: -22, dy: -14)
        scene.label(Text("人").font(.caption2).foregroundStyle(.secondary), at: V3(0, 3.4, 0), dx: 22, dy: -14)
        scene.label(Text("山").font(.caption2).foregroundStyle(.secondary), at: V3(0, 0, background + 9.5), dy: 11)
    }

    /// The picture the camera takes: same person size, a mountain that grows with the focal length.
    private func picture(_ mountainScale: Double) -> some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(Gradient(colors: [Color(red: 0.55, green: 0.7, blue: 0.9), Color(red: 0.85, green: 0.9, blue: 0.95)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height * 0.7)))
            let ground = size.height * 0.72
            let h = size.height * 0.28 * min(3.2, mountainScale)
            var mountain = Path()
            mountain.move(to: CGPoint(x: size.width * 0.5 - h * 1.6, y: ground)); mountain.addLine(to: CGPoint(x: size.width * 0.5, y: ground - h))
            mountain.addLine(to: CGPoint(x: size.width * 0.5 + h * 1.6, y: ground)); mountain.closeSubpath()
            context.fill(mountain, with: .color(Color(red: 0.35, green: 0.42, blue: 0.5)))
            context.fill(Path(CGRect(x: 0, y: ground, width: size.width, height: size.height - ground)), with: .color(Color(red: 0.3, green: 0.45, blue: 0.28)))
            let cx = size.width * 0.5, top = size.height * 0.36
            let k = size.height / 300
            context.fill(Path(ellipseIn: CGRect(x: cx - 22 * k, y: top, width: 44 * k, height: 48 * k)), with: .color(Color(red: 0.86, green: 0.72, blue: 0.62)))
            context.fill(Path(roundedRect: CGRect(x: cx - 50 * k, y: top + 52 * k, width: 100 * k, height: size.height - top - 52 * k), cornerRadius: 20 * k), with: .color(Color(red: 0.75, green: 0.3, blue: 0.25)))
        }
    }
}
