import MediaCore
import SwiftUI

private let amber = Color(red: 1, green: 0.82, blue: 0.4)
private let amberRgb = Rgb(1, 0.82, 0.4)

private func ease(_ t: Double) -> Double { let x = min(1, max(0, t)); return x * x * (3 - 2 * x) }

// MARK: - Shutter: time runs into the distance

/// A ball crosses the frame. Time runs away from the viewer, so the ball's path is a slanted line, and the
/// shutter is a slab of that time. Everything inside the slab lands on one photo at the far end.
struct ShutterScene: View {
    let photo: LessonPhoto
    let started: Date
    // 1/60 s: a visible trail, but only one stop brighter than the correct 1/125.
    @UIState private var stop = 4.0

    /// Seconds the ball takes to cross the frame.
    private static let crossing = 0.25

    var body: some View {
        let time = shutterStops[Int(stop.rounded())]
        var a = BasicAdjustments(); a.exposure = min(3, max(-3, log2(time / (1.0 / 125))))
        let image = photo.render(a).image
        let share = min(1, time / Self.crossing) * 100
        return VStack(spacing: 12) {
            Orbit3D(started: started, yaw: 0.45, pitch: 0.38, pitchRange: -0.2...1.4, distance: 70, fit: 17, wide: true,
                    target: V3(0, 2.5, 8), motion: .sway(0.25)) { scene, t in
                draw(&scene, t, image: image, time: time)
            }
            .frame(height: 330)
            LessonSlider(title: L("快门"), value: $stop, range: 0...Double(shutterStops.count - 1), format: { shutterLabel(shutterStops[Int($0.rounded())]) })
            Text(time <= 1.0 / 500 ? L("快门很快：运动被冻结，但画面变暗了。") : time >= 1.0 / 30 ? L("快门慢：画面变亮，但运动的东西拖出了影子。") : L("中间档：亮度合适，运动略有拖影。"))
                .font(.callout).foregroundStyle(.secondary)
            Text(String(format: L("球横穿画面只要 0.25 秒。快门开着的这段时间里，它走过了画面宽度的 %@。"),
                        share < 10 ? String(format: "%.1f%%", share) : String(format: "%.0f%%", share)))
                .font(.caption).foregroundStyle(.secondary)
            if let focal = photo.capture?.focalLength35mm, let shot = photo.capture?.exposureTime {
                Text("你这张照片用了 \(shutterLabel(shot))；按等效焦距 \(Int(focal)) mm，手持时最好快于 1/\(Int(focal)) 秒。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func draw(_ scene: inout Scene3D, _ t: Double, image: CGImage, time: Double) {
        let aspect = Double(image.width) / Double(image.height)
        let w = min(12, 8 * aspect), h = w / aspect
        // Time and distance share one scale: the ball crosses the frame in `crossing` seconds.
        let speed = w / Self.crossing, margin = 2.0
        let end = w + 2 * margin                 // the far end, where the photo is
        let length = speed * time                // how long it stays open, as a distance
        let open = margin + (w - length) / 2     // it opens so that the ball is mid-frame halfway through
        let close = open + max(0.05, length)
        let yb = h * 0.55, radius = w * 0.05
        func ballX(_ z: Double) -> Double { z - margin - w / 2 }

        // The shutter sweeps its window once, holds the picture, and starts over.
        let clock = t >= 900 ? 1.8 : t.truncatingRemainder(dividingBy: 3.8)
        let q = min(1, clock / 1.8)
        let fade = t >= 900 ? 1 : 1 - ease((clock - 3.3) / 0.45)
        let now = open + q * length

        scene.underlay { s in
            s.face([V3(-w / 2, 0, 0), V3(w / 2, 0, 0), V3(w / 2, 0, end), V3(-w / 2, 0, end)], V3(0, 1, 0), Rgb(white: 0.13), twoSided: true, flat: true)
            // One grid line every twentieth of a second.
            for i in 0...6 { let x = -w / 2 + w * Double(i) / 6; s.line(V3(x, 0, 0), V3(x, 0, end), .white.opacity(0.08)) }
            var z = 0.0
            while z <= end + 0.01 { s.line(V3(-w / 2, 0, z), V3(w / 2, 0, z), .white.opacity(0.08)); z += speed * 0.05 }
        }
        // The time arrow beside the floor, on the side nearest the eye.
        let edge = w / 2 + 0.9
        scene.line(V3(edge, 0, 0.4), V3(edge, 0, end - 0.4), .white.opacity(0.5))
        scene.polyline([V3(edge - 0.3, 0, end - 1.2), V3(edge, 0, end - 0.4), V3(edge + 0.3, 0, end - 1.2)], .white.opacity(0.5))
        scene.label(Text("更早").font(.caption2).foregroundStyle(.secondary), at: V3(edge, 0, 0), dy: 12)
        scene.label(Text("更晚").font(.caption2).foregroundStyle(.secondary), at: V3(edge, 0, end), dy: 12)

        // The ball's path through space and time, and its shadow on the floor.
        scene.line(V3(ballX(margin), yb, margin), V3(ballX(end - margin), yb, end - margin), .white.opacity(0.32), dash: [4, 4])
        scene.line(V3(ballX(margin), 0, margin), V3(ballX(end - margin), 0, end - margin), .white.opacity(0.14), dash: [4, 4])

        // The shutter: a slab of time as thick as it stays open.
        let front = [V3(-w / 2, 0, open), V3(w / 2, 0, open), V3(w / 2, h, open), V3(-w / 2, h, open)]
        let back = front.map { V3($0.x, $0.y, close) }
        for plate in [front, back] { scene.face(plate, V3(0, 0, -1), Rgb(white: 1), opacity: 0.06, edge: .white.opacity(0.4), twoSided: true, flat: true) }
        for k in 0..<4 { scene.line(front[k], back[k], .white.opacity(0.22)) }
        scene.label(Text(String(format: L("快门开着 %@"), shutterLabel(time))).font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.9)),
                    at: V3(w / 2, 0, (open + close) / 2), dy: 14)
        if q < 1 {
            let slice = [V3(-w / 2, 0, now), V3(w / 2, 0, now), V3(w / 2, h, now), V3(-w / 2, h, now)]
            scene.polyline(slice, .white.opacity(0.65), width: 1.4, closed: true)
        }

        // The ball while the shutter is open: copies along its path, each sending its light to the photo.
        scene.line(V3(ballX(open), yb, open), V3(ballX(now), yb, now), amber, width: 3)
        let copies = max(1, min(14, Int(length / 0.7) + 1))
        for k in 0..<copies {
            let u = copies == 1 ? 0 : Double(k) / Double(copies - 1)
            guard u <= q + 1e-9 else { continue }
            let z = open + u * length, x = ballX(z)
            scene.ball(V3(x, yb, z), radius, amberRgb, opacity: 0.5 * fade)
            scene.line(V3(x, yb, z), V3(x, yb, end), amber.opacity(0.22 * fade), dash: [2, 3])
        }
        scene.ball(V3(ballX(now), yb, now), radius, amberRgb)

        // The photo at the far end, with the streak the sensor has gathered so far.
        let corners = [V3(-w / 2, h, end), V3(w / 2, h, end), V3(w / 2, 0, end), V3(-w / 2, 0, end)]
        scene.layer(at: V3(0, h / 2, end)) { s in
            s.picture(image, corners: corners, cells: (10, 7))
            s.polyline(corners, .white.opacity(0.5), width: 1, closed: true)
            let xa = ballX(open), xb = ballX(now), z = end - 0.03
            var outline: [V3] = []
            for i in 0...8 { let a = Double.pi / 2 + Double.pi * Double(i) / 8; outline.append(V3(xa + cos(a) * radius, yb + sin(a) * radius, z)) }
            for i in 0...8 { let a = -Double.pi / 2 + Double.pi * Double(i) / 8; outline.append(V3(xb + cos(a) * radius, yb + sin(a) * radius, z)) }
            s.face(outline, V3(0, 0, -1), amberRgb, opacity: 0.8 * fade, twoSided: true, flat: true)
        }
        scene.label(Text("拍到的照片").font(.caption2).foregroundStyle(.secondary), at: V3(-w / 2, h, end), dx: 70, dy: -14)
    }
}

// MARK: - ISO: a grid of photosites that count light

/// The sensor as a grid of photosites. Light lands as single photons and is counted per cell; ISO then
/// multiplies the counts. The counts are random, so neighbours differ, and the multiplying shows that as noise.
struct ISOScene: View {
    let photo: LessonPhoto
    let started: Date
    @UIState private var stop = 5.0   // ISO 3200

    /// Photons a pure-white cell collects in this dim light.
    private static let fullWell = 24.0
    /// The height that means pure white.
    private static let ceiling = 10.0

    var body: some View {
        let iso = isoStops[Int(stop.rounded())]
        // A very dim room: at ISO 100 it is 5 stops too dark; each ISO step makes up one stop.
        let image = noisy(photo, iso: iso, exposure: log2(Double(iso) / 3200))
        let landscape = photo.width >= photo.height
        let relief = photo.relief(columns: landscape ? 20 : max(10, Int((14 * Double(photo.width) / Double(photo.height)).rounded())))
        let arrivals = Self.arrivals(relief)
        return VStack(spacing: 12) {
            HStack(spacing: 14) {
                LessonImage(image: image, caption: L("同样的弱光，只改变 ISO")).frame(width: 220, height: 300)
                Orbit3D(started: started, yaw: -0.5, pitch: 0.55, distance: 70, fit: 13.5, wide: true, target: V3(0, 3, 0), motion: .sway(0.3)) { scene, t in
                    draw(&scene, t, relief: relief, arrivals: arrivals, gain: Double(iso) / 100)
                }
                .frame(height: 340)
            }
            LessonSlider(title: "ISO", value: $stop, range: 0...Double(isoStops.count - 1), format: { "\(isoStops[Int($0.rounded())])" })
            Text(iso <= 200 ? L("ISO 低：干净，但光不够时太暗。") : iso >= 3200 ? L("ISO 高：亮了，但颗粒（噪点）也明显了。") : L("中间档：亮度和噪点的折中。"))
                .font(.callout).foregroundStyle(.secondary)
            Text("每一格收到的光没有变，ISO 只是把数字统统放大。光子是随机落下来的，相邻的格子数目不同，放大以后就是噪点。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let shot = photo.capture?.isoValue {
                Text("你这张照片用的是 ISO \(shot)。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// When each photon reaches its cell (seconds after the start). Brighter cells get more; the number
    /// is a Poisson draw from a fixed seed, so it is random from cell to cell but the same every time.
    private static func arrivals(_ relief: LessonPhoto.Relief) -> [[Double]] {
        var seed: UInt64 = 0x1234ABCD5678EF01
        func next() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double((seed >> 33) & 0xFFFFF) / Double(0xFFFFF) }
        return relief.luma.map { luma in
            let limit = exp(-fullWell * pow(luma, 2.2))
            var count = -1, p = 1.0
            repeat { count += 1; p *= next() } while p > limit
            return (0..<count).map { _ in 0.15 + next() * 1.9 }
        }
    }

    private func draw(_ scene: inout Scene3D, _ t: Double, relief: LessonPhoto.Relief, arrivals: [[Double]], gain: Double) {
        let columns = relief.columns, rows = relief.rows, ceiling = Self.ceiling
        let w = Double(columns), d = Double(rows)
        // One photon is this tall at ISO 100; at ISO 3200 a full cell reaches the ceiling.
        let chip = ceiling / (Self.fullWell * 32)
        let amplified = 1 + (gain - 1) * ease((t - 2.9) / 1.1)
        scene.underlay { s in
            s.face([V3(-w / 2, 0, d / 2), V3(w / 2, 0, d / 2), V3(w / 2, 0, -d / 2), V3(-w / 2, 0, -d / 2)], V3(0, 1, 0), Rgb(white: 0.15), twoSided: true, flat: true)
        }
        for row in 0..<rows {
            for column in 0..<columns {
                let i = row * columns + column
                let x = Double(column) - w / 2 + 0.5, z = d / 2 - Double(row) - 0.5
                let landed = arrivals[i].filter { t - $0 >= 0.5 }.count
                let level = Double(landed) * chip * amplified
                let height = max(0.05, min(level, ceiling))
                scene.box(V3(x, height / 2, z), V3(0.9, height, 0.9), Rgb(white: 0.1 + 0.9 * pow(min(1, level / ceiling), 1 / 2.2)), sortAt: V3(x, 0, z))
                // Photons still on their way down.
                for (k, start) in arrivals[i].enumerated() where t - start > 0 && t - start < 0.5 {
                    let u = (t - start) / 0.5
                    let jitter = V3(Double((i * 7 + k * 13) % 10) / 10 - 0.5, 0, Double((i * 11 + k * 5) % 10) / 10 - 0.5) * 0.6
                    scene.dot(V3(x, height + (ceiling + 3 - height) * (1 - u * u), z) + jitter, 0.22, amber)
                }
            }
        }
        // The ceiling: nothing can be whiter than this, so tall cells are cut off flat.
        let top = [V3(-w / 2, ceiling, -d / 2), V3(w / 2, ceiling, -d / 2), V3(w / 2, ceiling, d / 2), V3(-w / 2, ceiling, d / 2)]
        scene.polyline(top, .white.opacity(0.35), dash: [4, 3], closed: true, onTop: true)
        for corner in top { scene.line(corner, V3(corner.x, 0, corner.z), .white.opacity(0.18), dash: [2, 3], onTop: true) }
        scene.label(Text("纯白的上限").font(.caption2).foregroundStyle(.secondary), at: top[3], dx: 50, dy: -10)
        scene.label(Text("传感器上的一格").font(.caption2).foregroundStyle(.secondary), at: V3(0, 0, -d / 2 - 0.4), dy: 12)
        let hint = ease((t - 0.1) / 0.3) * (1 - ease((t - 2.3) / 0.4))
        scene.label(Text("光子一颗颗落进每一格").font(.callout).foregroundStyle(Color.primary.opacity(0.85 * hint)), at: V3(0, ceiling + 1, 0))
        scene.label(Text(String(format: L("放大 ×%.0f"), amplified)).font(.callout.weight(.semibold)).foregroundStyle(Color.primary.opacity(0.9 * ease((t - 2.5) / 0.3))),
                    at: V3(0, ceiling + 1, 0))
    }
}

// MARK: - Exposure triangle: the settings as a box, equal brightness as a slab

/// The three knobs are three axes, each running towards "more light". Settings that give the same
/// brightness lie on one slanted slab through the box: a point on it is a correct exposure.
struct ExposureTriangleScene: View {
    let photo: LessonPhoto
    let started: Date
    @UIState private var aperture = Double(ExposureSetting.reference.aperture)
    @UIState private var shutter = Double(ExposureSetting.reference.shutter)
    @UIState private var iso = Double(ExposureSetting.reference.iso)
    /// Where the point started from when a recipe was chosen, and when (seconds since the scene began).
    @UIState private var glide: (from: ExposureSetting, at: Double)?

    private var setting: ExposureSetting {
        ExposureSetting(aperture: Int(aperture.rounded()), shutter: Int(shutter.rounded()), iso: Int(iso.rounded()))
    }

    var body: some View {
        let setting = setting
        let ev = Double(setting.stopsFromReference)
        let image = noisy(photo, iso: isoStops[setting.iso], exposure: min(3, max(-3, ev)))
        let (a, s, i) = (setting.aperture, setting.shutter, setting.iso)
        return VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    LessonImage(image: image).frame(width: 220, height: 150)
                    meter(ev)
                    effect(L("背景虚化"), 1 - Double(a) / 7, a <= 2 ? L("背景虚") : a >= 5 ? L("前后都清楚") : L("略虚"))
                    effect(L("拖影风险"), Double(s) / 8, s >= 5 ? L("容易糊") : s <= 2 ? L("冻结运动") : L("一般"))
                    effect(L("噪点"), Double(i) / 7, i >= 5 ? L("明显") : i <= 1 ? L("干净") : L("轻微"))
                }
                .frame(width: 220)
                Orbit3D(started: started, yaw: 2.4, pitch: 0.45, pitchRange: -0.6...1.4, distance: 40, fit: 6.4, motion: .sway(0.25)) { scene, t in
                    draw(&scene, t, setting: setting)
                }
                .frame(height: 330)
            }
            HStack(spacing: 6) {
                Text("同样的亮度，换一种拍法：").font(.callout).foregroundStyle(.secondary)
                ForEach(ExposureRecipe.allCases, id: \.self) { recipe in
                    Button(recipe.title) { choose(recipe) }
                        .buttonStyle(.plain).font(.callout)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(setting == recipe.setting ? WorkbenchTheme.selection : WorkbenchTheme.well))
                }
                Spacer(minLength: 0)
            }
            LessonSlider(title: L("光圈"), value: knob($aperture), range: 0...7, format: { stopLabel(fStops[Int($0.rounded())]) })
            LessonSlider(title: L("快门"), value: knob($shutter), range: 0...8, format: { shutterLabel(shutterStops[Int($0.rounded())]) })
            LessonSlider(title: "ISO", value: knob($iso), range: 0...7, format: { "\(isoStops[Int($0.rounded())])" })
        }
    }

    /// A slider that takes over from any glide in progress.
    private func knob(_ value: Binding<Double>) -> Binding<Double> {
        Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0; glide = nil })
    }

    private func choose(_ recipe: ExposureRecipe) {
        glide = (setting, Date().timeIntervalSince(started))
        let target = recipe.setting
        aperture = Double(target.aperture); shutter = Double(target.shutter); iso = Double(target.iso)
    }

    // MARK: 3D

    /// Axis lengths in stops: the opening (ƒ/16 → ƒ/1.4), the shutter (1/1000 → 1/4 s) and the ISO (100 → 12800).
    private static let size = (opening: 7.0, shutter: 8.0, iso: 7.0)
    /// Turns of the three knobs that add up to a correct exposure (ƒ/2.8, 1/125 s, ISO 400).
    private static let correct = { let t = ExposureSetting.reference.turns; return Double(t.opening + t.shutter + t.iso) }()

    /// A place in the box of settings, as a point in the scene: aperture runs along x, shutter along z, ISO up.
    private static func at(_ opening: Double, _ shutter: Double, _ iso: Double) -> V3 {
        V3(opening - 3.5, iso - 3.5, shutter * 7 / 8 - 3.5)
    }

    /// The outline of the slab where the three turns add up to `total`, cut to the box.
    private static func slab(_ total: Double) -> [V3] {
        let (a, b, c) = size
        var corners: [(Double, Double, Double)] = []
        for x in [0.0, a] { for y in [0.0, b] { for z in [0.0, c] { corners.append((x, y, z)) } } }
        var cuts: [(Double, Double, Double)] = []
        for p in corners {
            for q in corners where (p.0 != q.0 ? 1 : 0) + (p.1 != q.1 ? 1 : 0) + (p.2 != q.2 ? 1 : 0) == 1 && (p.0, p.1, p.2) < (q.0, q.1, q.2) {
                let fp = p.0 + p.1 + p.2 - total, fq = q.0 + q.1 + q.2 - total
                guard fp * fq < 0 else { continue }
                let k = fp / (fp - fq)
                cuts.append((p.0 + (q.0 - p.0) * k, p.1 + (q.1 - p.1) * k, p.2 + (q.2 - p.2) * k))
            }
        }
        let centre = cuts.reduce((0.0, 0.0, 0.0)) { ($0.0 + $1.0, $0.1 + $1.1, $0.2 + $1.2) }
        let n = Double(max(1, cuts.count)), mid = (centre.0 / n, centre.1 / n, centre.2 / n)
        func angle(_ p: (Double, Double, Double)) -> Double {
            let d = (p.0 - mid.0, p.1 - mid.1, p.2 - mid.2)
            return atan2((d.0 + d.1 - 2 * d.2) / 6.0.squareRoot(), (d.0 - d.1) / 2.0.squareRoot())
        }
        return cuts.sorted { angle($0) < angle($1) }.map { at($0.0, $0.1, $0.2) }
    }

    private func draw(_ scene: inout Scene3D, _ t: Double, setting: ExposureSetting) {
        let (a, b, c) = Self.size
        let mix = glide.map { ease((t - $0.at) / 0.6) } ?? 1
        let from = glide?.from ?? setting
        func between(_ x: Int, _ y: Int) -> Double { Double(x) + Double(y - x) * mix }
        let opening = Double(ExposureSetting.apertureSteps - 1) - between(from.aperture, setting.aperture)
        let slow = between(from.shutter, setting.shutter), high = between(from.iso, setting.iso)
        let here = Self.at(opening, slow, high)
        let gap = Self.correct - (opening + slow + high)     // stops short of a correct exposure (negative: too bright)

        // The three walls behind the point, with a line for every stop.
        scene.underlay { s in
            func wall(_ corners: [V3]) { s.face(corners, V3(0, 1, 0), Rgb(white: 1), opacity: 0.045, twoSided: true, flat: true) }
            wall([Self.at(0, 0, 0), Self.at(a, 0, 0), Self.at(a, 0, c), Self.at(0, 0, c)])
            wall([Self.at(0, 0, 0), Self.at(a, 0, 0), Self.at(a, b, 0), Self.at(0, b, 0)])
            wall([Self.at(0, 0, 0), Self.at(0, 0, c), Self.at(0, b, c), Self.at(0, b, 0)])
            for k in 0...7 {
                let v = Double(k)
                s.line(Self.at(v, 0, 0), Self.at(v, 0, c), .white.opacity(0.08)); s.line(Self.at(v, 0, 0), Self.at(v, b, 0), .white.opacity(0.08))
                s.line(Self.at(0, 0, v), Self.at(a, 0, v), .white.opacity(0.08)); s.line(Self.at(0, v, 0), Self.at(0, v, c), .white.opacity(0.08))
                s.line(Self.at(0, v, 0), Self.at(a, v, 0), .white.opacity(0.08)); s.line(Self.at(0, 0, v), Self.at(0, b, v), .white.opacity(0.08))
            }
            s.line(Self.at(0, 8, 0), Self.at(a, 8, 0), .white.opacity(0.08)); s.line(Self.at(0, 8, 0), Self.at(0, 8, c), .white.opacity(0.08))
        }
        // The axes, with the part the knobs have been turned shown bright.
        let origin = Self.at(0, 0, 0)
        for (end, reach) in [(Self.at(a, 0, 0), Self.at(opening, 0, 0)), (Self.at(0, b, 0), Self.at(0, slow, 0)), (Self.at(0, 0, c), Self.at(0, 0, high))] {
            scene.line(origin, end, .white.opacity(0.35), width: 1.2)
            scene.line(origin, reach, .white.opacity(0.95), width: 3)
        }
        let axisNames: [(V3, String, String)] = [(Self.at(a, 0, 0), L("光圈开大"), L("背景更虚")), (Self.at(0, b, 0), L("快门变慢"), L("拖影更重")), (Self.at(0, 0, c), L("ISO 升高"), L("噪点更多"))]
        for (end, name, cost) in axisNames {
            scene.dot(end, 2.5, .white.opacity(0.7), fog: false)
            scene.label(Text(name).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.9)), at: end, dy: 14)
            scene.label(Text(cost).font(.caption2).foregroundStyle(.secondary), at: end, dy: 28)
        }

        // All the settings that give a correct exposure.
        let outline = Self.slab(Self.correct)
        scene.face(outline, V3(1, 1, 1) / 3.0.squareRoot(), Rgb(white: 1), opacity: 0.12, edge: .white.opacity(0.55), twoSided: true, flat: true)
        if let corner = outline.max(by: { $0.y * 100 - $0.z < $1.y * 100 - $1.z }) {
            scene.label(Text("亮度正好的设置").font(.caption2).foregroundStyle(.white.opacity(0.85)), at: corner, dy: -10)
        }

        // Your settings: a point, with a line for how far each knob has been turned.
        for foot in [Self.at(0, slow, high), Self.at(opening, 0, high), Self.at(opening, slow, 0)] {
            scene.line(here, foot, .white.opacity(0.4), dash: [3, 3])
        }
        if abs(gap) >= 0.5 {
            // The short way to the slab: every knob a third of the way.
            let toSlab = Self.at(opening + gap / 3, slow + gap / 3, high + gap / 3)
            scene.line(here, toSlab, amber, width: 3)
            scene.dot(toSlab, 4, amber, fog: false)
        }
        scene.ball(here, 0.3, amberRgb)
        // The note sits on the side of the point that faces away from the axes' corner.
        let side = scene.camera.project(here).point.x < scene.camera.project(origin).point.x - 15 ? -74.0 : 74.0
        scene.label(Text(abs(gap) < 0.5 ? L("亮度正好") : gap > 0 ? String(format: L("暗了 %.0f 档"), gap) : String(format: L("亮了 %.0f 档"), -gap))
            .font(.caption.weight(.semibold)).foregroundStyle(amber), at: here, dx: side, dy: 2)
    }

    // MARK: Readouts

    private func meter(_ ev: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(abs(ev) < 0.5 ? L("亮度正好") : ev > 0 ? String(format: L("亮了 %.0f 档"), ev) : String(format: L("暗了 %.0f 档"), -ev))
                .font(.callout.weight(.semibold))
            GeometryReader { proxy in
                let x = proxy.size.width * (min(3, max(-3, ev)) + 3) / 6
                ZStack(alignment: .leading) {
                    Capsule().fill(LinearGradient(colors: [.black, .gray, .white], startPoint: .leading, endPoint: .trailing)).frame(height: 6)
                    Rectangle().fill(Color.white.opacity(0.6)).frame(width: 1, height: 14).offset(x: proxy.size.width / 2)
                    Circle().fill(Color.white).frame(width: 12, height: 12).offset(x: x - 6)
                }
            }
            .frame(height: 14)
        }
    }

    private func effect(_ title: String, _ amount: Double, _ word: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack { Text(title).font(.caption); Spacer(); Text(word).font(.caption).foregroundStyle(.secondary) }
            GeometryReader { proxy in
                Capsule().fill(WorkbenchTheme.well).overlay(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.7)).frame(width: max(4, proxy.size.width * min(1, max(0, amount))))
                }
            }
            .frame(height: 5)
        }
    }
}
