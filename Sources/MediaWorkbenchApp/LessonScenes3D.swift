import MediaCore
import SwiftUI

// MARK: - Brightness as height

private func ease(_ t: Double) -> Double { let x = min(1, max(0, t)); return x * x * (3 - 2 * x) }

/// Every cell of the photo lifted to a height that matches its brightness: a relief map you can turn.
struct BrightnessReliefScene: View {
    let photo: LessonPhoto
    let started: Date

    var body: some View {
        let relief = photo.relief(columns: 40)
        HStack(spacing: 10) {
            VStack(spacing: 6) {
                Text("100 纯白").font(.caption2).foregroundStyle(.secondary)
                RoundedRectangle(cornerRadius: 3).fill(LinearGradient(colors: [.white, .black], startPoint: .top, endPoint: .bottom))
                    .frame(width: 8)
                Text("0 纯黑").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: AppLanguage.current == .chinese ? 56 : 76).padding(.vertical, 40)
            VStack(spacing: 8) {
                Orbit3D(started: started, yaw: -0.5, pitch: 0.62, distance: 80, fit: 23, target: V3(0, 3, 0),
                        motion: .spin(0.12)) { scene, t in
                    let columns = relief.columns, rows = relief.rows, maxHeight = 12.0
                    let w = Double(columns), d = Double(rows)
                    scene.underlay { s in
                        s.face([V3(-w / 2, 0, d / 2), V3(w / 2, 0, d / 2), V3(w / 2, 0, -d / 2), V3(-w / 2, 0, -d / 2)], V3(0, 1, 0),
                               Rgb(white: 0.15), twoSided: true, flat: true)
                    }
                    for row in 0..<rows {
                        for column in 0..<columns {
                            let luma = relief.luma[row * columns + column]
                            // The columns rise in a wave from left to right.
                            let rise = ease((t - 0.3 - Double(column) / w * 0.7) / 0.9)
                            let height = max(0.12, luma * maxHeight * rise)
                            let x = Double(column) - w / 2 + 0.5, z = d / 2 - Double(row) - 0.5
                            scene.box(V3(x, height / 2, z), V3(0.96, height, 0.96), Rgb(white: 0.1 + 0.9 * luma), sortAt: V3(x, 0, z))
                        }
                    }
                }
                .overlay(alignment: .topLeading) {
                    // The photo itself, in grey, so the relief can be matched to what it is made from.
                    Image(decorative: photo.thumbnail, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        .saturation(0).clipShape(RoundedRectangle(cornerRadius: 4)).frame(width: 110).padding(6)
                }
                Text("越亮的格子越高；越暗的越矮。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Cells falling into the histogram

/// The photo's cells lift off the table and drop into columns by brightness. Piled up, the
/// columns are the histogram.
struct HistogramPileScene: View {
    let photo: LessonPhoto
    let started: Date

    var body: some View {
        let relief = photo.relief(columns: 40)
        let bins = 30
        // Which column each cell lands in and how high up it sits.
        let (slot, tallest) = Self.stack(relief.luma, bins: bins)
        return VStack(spacing: 8) {
            Orbit3D(started: started, yaw: -0.3, pitch: 0.5, distance: 90, fit: 15, target: V3(0, 1.5, 6),
                    motion: .sway(0.3)) { scene, t in
                let columns = relief.columns, rows = relief.rows
                let cell = 0.62, tableZ = 3.0, thin = 0.14
                let pileTile = min(0.5, 12 / tallest)
                let width = Double(bins)
                let axis = ease((t - 0.2) / 0.6)
                scene.underlay { s in
                    // Where the photo lies, and the ground strip in the five zones.
                    let w = Double(columns) * cell / 2, far = tableZ + Double(rows) * cell
                    s.polyline([V3(-w, 0, tableZ), V3(w, 0, tableZ), V3(w, 0, far), V3(-w, 0, far)], .white.opacity(0.14), closed: true)
                    for zone in ToneZone.allCases {
                        let a = zone.range.lowerBound * width - width / 2, b = zone.range.upperBound * width - width / 2
                        s.face([V3(a, 0, -1.4), V3(b, 0, -1.4), V3(b, 0, -0.5), V3(a, 0, -0.5)], V3(0, 1, 0),
                               Rgb(white: (zone.range.lowerBound + zone.range.upperBound) / 2 * 0.9 + 0.1), opacity: axis, twoSided: true, flat: true)
                    }
                }
                for row in 0..<rows {
                    for column in 0..<columns {
                        let i = row * columns + column
                        let luma = relief.luma[i]
                        let bin = min(bins - 1, Int(luma * Double(bins)))
                        // Darker cells leave first, so the pile grows from left to right.
                        let p = ease((t - 0.5 - luma * 1.3) / 1.0)
                        let from = V3((Double(column) - Double(columns) / 2 + 0.5) * cell, thin / 2, tableZ + (Double(rows - row) - 0.5) * cell)
                        let to = V3(Double(bin) - width / 2 + 0.5, (Double(slot[i]) + 0.5) * pileTile, 0)
                        var at = from + (to - from) * p
                        at.y += sin(p * .pi) * 4
                        let size = V3(cell + (0.9 - cell) * p, thin + (pileTile - thin) * p, cell + (0.9 - cell) * p)
                        scene.box(at, size, Rgb(white: luma), edge: Color.black.opacity(0.3))
                    }
                }
                for zone in ToneZone.allCases {
                    let mid = (zone.range.lowerBound + zone.range.upperBound) / 2 * width - width / 2
                    scene.label(Text(zone.title).font(.caption2).foregroundStyle(Color.secondary.opacity(axis)), at: V3(mid, 0, -1.4), dy: 14)
                }
            }
            Text("越暗的格子先落下，落在越靠左的柱子里。")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

extension HistogramPileScene {
    /// The place of each cell in its column (0 = bottom) and the height of the tallest column.
    static func stack(_ luma: [Double], bins: Int) -> (slot: [Int], tallest: Double) {
        var counts = [Int](repeating: 0, count: bins), slot = [Int](repeating: 0, count: luma.count)
        for (i, value) in luma.enumerated() {
            let bin = min(bins - 1, Int(value * Double(bins)))
            slot[i] = counts[bin]; counts[bin] += 1
        }
        return (slot, Double(max(1, counts.max() ?? 1)))
    }
}

// MARK: - Colour in space

/// One dot of a colour cloud: where it sits and its own colour.
struct CloudDot {
    var position: V3
    var color: Color
    var radius = 1.5
}

/// A colour (0…1 per channel) at its place in the RGB cube, stood on the black corner so the
/// grey axis runs straight up. Nothing on that axis has a colour cast.
func cubePosition(_ r: Double, _ g: Double, _ b: Double) -> V3 {
    V3((2 * r - g - b) / 6.0.squareRoot(), (r + g + b - 1.5) / 3.0.squareRoot(), (g - b) / 2.0.squareRoot()) * 2
}

/// The same colour as hue (turns), saturation and brightness (0…1).
func hsvOf(_ r: Double, _ g: Double, _ b: Double) -> (h: Double, s: Double, v: Double) {
    let high = max(r, g, b), low = min(r, g, b)
    return (LessonPhoto.hue(r, g, b, high, low) / 360, high > 0 ? (high - low) / high : 0, high)
}

/// A colour in the cylinder: hue around, saturation outward, brightness up. The top view is the colour wheel.
func cylinderPosition(_ h: Double, _ s: Double, _ v: Double) -> V3 {
    V3(cos(h * 2 * .pi) * s * 1.5, (v - 0.5) * 2.6, -sin(h * 2 * .pi) * s * 1.5)
}

/// The photo's pixels as dots inside the RGB cube.
struct ColorCubeView: View {
    let dots: [CloudDot]
    /// The average colour of the dots: its distance from the grey axis is the colour cast.
    var average: (r: Double, g: Double, b: Double)?
    /// A colour the learner picked, ringed.
    var picked: (r: Double, g: Double, b: Double)?
    /// Lines between dots (the lattice of a LUT).
    var edges: [(V3, V3)] = []

    var body: some View {
        Orbit3D(yaw: -0.6, pitch: 0.3, pitchRange: -1.2...1.4, distance: 14, fit: 2.3, motion: .spin(0.2)) { scene, _ in
            let corners: [(Double, Double, Double)] = (0..<8).map { (Double($0 & 1), Double(($0 >> 1) & 1), Double(($0 >> 2) & 1)) }
            for a in 0..<8 {
                for bit in [1, 2, 4] where a & bit == 0 {
                    let p = corners[a], q = corners[a | bit]
                    scene.line(cubePosition(p.0, p.1, p.2), cubePosition(q.0, q.1, q.2), .white.opacity(0.28))
                }
            }
            let axisTop = cubePosition(1, 1, 1), axisBottom = cubePosition(0, 0, 0)
            scene.line(axisBottom, axisTop, .white.opacity(0.6), width: 1, dash: [3, 3])
            for edge in edges { scene.line(edge.0, edge.1, .white.opacity(0.3), width: 0.8) }
            for dot in dots { scene.dot(dot.position, dot.radius, dot.color) }
            for (rgb, name) in [((1.0, 0.0, 0.0), HueBand.red.title), ((0.0, 1.0, 0.0), HueBand.green.title), ((0.0, 0.0, 1.0), HueBand.blue.title)] {
                let p = cubePosition(rgb.0, rgb.1, rgb.2)
                scene.dot(p, 3.5, Color(red: rgb.0, green: rgb.1, blue: rgb.2))
                scene.label(Text(name).font(.caption2).foregroundStyle(.secondary), at: p, dy: -11)
            }
            scene.label(Text("白").font(.caption2).foregroundStyle(.secondary), at: axisTop, dy: -10)
            scene.label(Text("黑").font(.caption2).foregroundStyle(.secondary), at: axisBottom, dy: 10)
            if let average {
                let p = cubePosition(average.r, average.g, average.b)
                scene.line(V3(0, p.y, 0), p, .white.opacity(0.9), width: 1.5)
                scene.dot(p, 7, .white)
                scene.dot(p, 4.8, Color(red: average.r, green: average.g, blue: average.b), fog: false)
            }
            if let picked {
                let p = cubePosition(picked.r, picked.g, picked.b)
                scene.dot(p, 10, .black.opacity(0.7), fog: false)
                scene.dot(p, 8.5, .white, fog: false)
                scene.dot(p, 6, Color(red: picked.r, green: picked.g, blue: picked.b), fog: false)
                scene.label(Text("你点的颜色").font(.caption2.weight(.semibold)).foregroundStyle(.white), at: p, dy: 17)
            }
        }
    }
}

/// The photo's pixels as dots in the colour cylinder (hue round, saturation out, brightness up).
struct ColorCylinderView: View {
    let dots: [CloudDot]
    /// The colour being explained: drawn with guides for each of its three numbers.
    var marker: (h: Double, s: Double, v: Double)?

    var body: some View {
        Orbit3D(yaw: -0.5, pitch: 0.55, pitchRange: -0.9...1.5, distance: 14, fit: 2.25, motion: .spin(0.15)) { scene, _ in
            let half = 1.3, radius = 1.5
            let bottom = Scene3D.circle(V3(0, -half, 0), radius, count: 72), top = Scene3D.circle(V3(0, half, 0), radius, count: 72)
            scene.underlay { s in
                s.face(bottom, V3(0, 1, 0), Rgb(white: 0.1), twoSided: true, flat: true)
            }
            scene.polyline(bottom, .white.opacity(0.3), closed: true)
            // The rim is the hue circle (the circle helper runs the other way round, hence 72 - i).
            for i in 0..<72 {
                scene.line(top[i], top[(i + 1) % 72], Color(hue: Double((72 - i) % 72) / 72, saturation: 0.85, brightness: 1), width: 2.5)
            }
            for i in 0..<12 {
                let a = Double(i) / 12 * 2 * .pi
                scene.line(V3(cos(a) * radius, -half, -sin(a) * radius), V3(cos(a) * radius, half, -sin(a) * radius), .white.opacity(0.1))
            }
            scene.line(V3(0, -half, 0), V3(0, half, 0), .white.opacity(0.45), dash: [3, 3])
            for dot in dots { scene.dot(dot.position, 1.5, dot.color) }
            // Names round the rim: above the far side of the ring, below the near side, so none sits on the line.
            let middle = scene.camera.project(V3(0, half, 0)).depth
            for band in [HueBand.red, .yellow, .green, .aqua, .blue, .magenta] {
                let h = band.degrees / 360, p = V3(cos(h * 2 * .pi) * (radius + 0.3), half, -sin(h * 2 * .pi) * (radius + 0.3))
                scene.label(Text(band.title).font(.caption2).foregroundStyle(.secondary), at: p, dy: scene.camera.project(p).depth > middle ? -9 : 11)
            }
            guard let marker else { return }
            let m = cylinderPosition(marker.h, marker.s, marker.v), floor = V3(m.x, -half, m.z)
            let hueColor = Color(hue: marker.h, saturation: 0.85, brightness: 1)
            // Hue: the angle on the floor from red round to this colour.
            let arc = (0...24).map { i -> V3 in
                let a = marker.h * 2 * .pi * Double(i) / 24
                return V3(cos(a) * radius * 0.3, -half, -sin(a) * radius * 0.3)
            }
            let rim = V3(cos(marker.h * 2 * .pi) * radius, -half, -sin(marker.h * 2 * .pi) * radius)
            scene.line(V3(0, -half, 0), V3(radius * 0.5, -half, 0), .white.opacity(0.4), dash: [2, 2])
            scene.line(V3(0, -half, 0), rim, hueColor.opacity(0.6), width: 1)
            scene.polyline(arc, hueColor, width: 3)
            // Saturation: the way out from the axis. Brightness: the way up.
            scene.line(V3(0, -half, 0), floor, .white.opacity(0.95), width: 2)
            scene.line(floor, m, .white.opacity(0.95), width: 2)
            scene.dot(m, 8, .white)
            scene.dot(m, 6, Color(hue: marker.h, saturation: marker.s, brightness: marker.v), fog: false)
            let bold = Font.caption2.weight(.semibold)
            scene.label(Text("色相").font(bold).foregroundStyle(hueColor), at: rim, dx: 0, dy: 11)
            scene.label(Text("饱和度").font(bold).foregroundStyle(.white), at: floor / 2 + V3(0, -half / 2, 0), dy: 11)
            scene.label(Text("明亮度").font(bold).foregroundStyle(.white), at: floor + (m - floor) * 0.4, dx: -34)
        }
    }
}

extension LessonPhoto {
    /// The photo's cloud of pixels in a given set of (possibly edited) bytes, as dots in the cube.
    func cubeDots(_ pixels: [UInt8], count: Int = 2400, transform: ((r: Double, g: Double, b: Double)) -> (r: Double, g: Double, b: Double) = { $0 }) -> (dots: [CloudDot], average: (r: Double, g: Double, b: Double)) {
        var sum = (r: 0.0, g: 0.0, b: 0.0)
        let indices = pixels.count == self.pixels.count ? cloud(count) : []
        let dots = indices.map { i -> CloudDot in
            let c = transform(Self.rgb(pixels, i))
            sum.r += c.r; sum.g += c.g; sum.b += c.b
            return CloudDot(position: cubePosition(c.r, c.g, c.b), color: Color(red: c.r, green: c.g, blue: c.b))
        }
        let n = Double(max(1, indices.count))
        return (dots, (sum.r / n, sum.g / n, sum.b / n))
    }
}
