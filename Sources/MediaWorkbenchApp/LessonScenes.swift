import CoreImage
import MediaCore
import SwiftUI

// MARK: - Pixels → brightness → histogram

/// The first two acts of the histogram story: the photo breaks into blocks, then the blocks lose
/// their colour. (The blocks then rise and fall into columns in the 3D scenes.)
struct PixelScene: View {
    let scene: LessonScene
    let photo: LessonPhoto
    let started: Date

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSince(started)
            Canvas { context, size in draw(&context, size, t) }
        }
    }

    private func ease(_ t: Double) -> Double { let x = min(1, max(0, t)); return x * x * (3 - 2 * x) }

    private func draw(_ context: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        let photoBox = CGRect(x: 0, y: 0, width: size.width, height: size.height - 40)
        let aspect = Double(photo.width) / Double(photo.height)
        let fit = min(photoBox.width / aspect, photoBox.height)
        let rect = CGRect(x: photoBox.midX - fit * aspect / 2, y: photoBox.minY + (photoBox.height - fit) / 2, width: fit * aspect, height: fit)
        let cellW = rect.width / Double(photo.gridWidth), cellH = rect.height / Double(photo.gridHeight)

        switch scene {
        case .pixelGrid:
            let grid = ease(t / 0.8), mosaic = ease((t - 0.9) / 0.9)
            context.draw(Image(decorative: photo.thumbnail, scale: 1), in: rect)
            for block in photo.blocks {
                let cell = CGRect(x: rect.minX + Double(block.x) * cellW, y: rect.minY + Double(block.y) * cellH, width: cellW, height: cellH)
                context.fill(Path(cell), with: .color(Color(red: block.r, green: block.g, blue: block.b).opacity(mosaic)))
                context.stroke(Path(cell), with: .color(.white.opacity(0.25 * grid)), lineWidth: 0.5)
            }
            caption(&context, size, mosaic > 0.5 ? L("每一格只有一种颜色：这就是像素（这里放大了很多倍）。") : "")
        case .brightnessOnly:
            let grey = ease(t / 1.2)
            for (i, block) in photo.blocks.enumerated() {
                let cell = CGRect(x: rect.minX + Double(block.x) * cellW, y: rect.minY + Double(block.y) * cellH, width: cellW, height: cellH)
                let r = block.r + (block.luma - block.r) * grey, g = block.g + (block.luma - block.g) * grey, b = block.b + (block.luma - block.b) * grey
                context.fill(Path(cell), with: .color(Color(red: r, green: g, blue: b)))
                context.stroke(Path(cell), with: .color(.white.opacity(0.18)), lineWidth: 0.5)
                if grey > 0.95, i % 23 == 7, cellW > 14 {
                    context.draw(Text("\(Int(block.luma * 100))").font(.system(size: min(10, cellW * 0.45), weight: .semibold))
                        .foregroundStyle(block.luma > 0.55 ? Color.black : Color.white), at: CGPoint(x: cell.midX, y: cell.midY))
                }
            }
            // A brightness scale under the picture.
            let bar = CGRect(x: rect.minX, y: rect.maxY + 14, width: rect.width, height: 8)
            context.fill(Path(roundedRect: bar, cornerRadius: 3), with: .linearGradient(Gradient(colors: [.black, .white]),
                startPoint: CGPoint(x: bar.minX, y: 0), endPoint: CGPoint(x: bar.maxX, y: 0)))
            context.draw(Text("0 纯黑").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: bar.minX + 18, y: bar.maxY + 10))
            context.draw(Text("100 纯白").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: bar.maxX - 22, y: bar.maxY + 10))
        default: break
        }
    }

    private func caption(_ context: inout GraphicsContext, _ size: CGSize, _ text: String) {
        context.draw(Text(text).font(.callout).foregroundStyle(.secondary), at: CGPoint(x: size.width / 2, y: size.height - 14))
    }
}

// MARK: - Reading the histogram and zones

struct HistogramReadScene: View {
    let photo: LessonPhoto
    var body: some View {
        let shares = ToneZone.shares(photo.histogram)
        VStack(spacing: 18) {
            LessonImage(image: photo.thumbnail).frame(maxHeight: 250)
            ZoneHistogram(histogram: photo.histogram, height: 120)
            HStack(spacing: 8) {
                ForEach(ToneZone.allCases, id: \.self) { zone in
                    VStack(spacing: 4) {
                        GeometryReader { proxy in
                            let share = shares[zone] ?? 0
                            VStack { Spacer(); RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.55))
                                .frame(height: max(2, proxy.size.height * min(1, share * 1.6))) }
                        }
                        .frame(height: 50)
                        Text("\(Int(((shares[zone] ?? 0) * 100).rounded()))%").font(.caption.monospacedDigit())
                        Text(zone.title).font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

struct ZoneExplorerScene: View {
    let photo: LessonPhoto
    @UIState private var zone: ToneZone? = .midtones
    var body: some View {
        let shares = ToneZone.shares(photo.histogram)
        VStack(spacing: 14) {
            LessonImage(image: zone.map { photo.zoneMask($0) } ?? photo.thumbnail,
                        caption: zone.map { L("彩色的地方属于「\($0.title)」，比如\($0.example)。") } ?? L("点下面的区域试试。"))
                .frame(maxHeight: 330)
                .animation(.easeInOut(duration: 0.2), value: zone)
            ZoneHistogram(histogram: photo.histogram, height: 70, selectedZone: zone)
            HStack(spacing: 6) {
                ForEach(ToneZone.allCases, id: \.self) { item in
                    Button { zone = zone == item ? nil : item } label: {
                        VStack(spacing: 2) {
                            Text(item.title).font(.callout.weight(zone == item ? .semibold : .regular))
                            Text("\(Int(((shares[item] ?? 0) * 100).rounded()))%").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7).fill(zone == item ? WorkbenchTheme.selection : WorkbenchTheme.well))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct KeyStylesScene: View {
    let photo: LessonPhoto
    @UIState private var renders: [(String, CGImage, [Double])] = []
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(renders.indices, id: \.self) { i in
                VStack(spacing: 8) {
                    LessonImage(image: renders[i].1, caption: renders[i].0)
                    ZoneHistogram(histogram: renders[i].2, height: 44, showsCaption: false)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
        .onAppear {
            var low = BasicAdjustments(); low.exposure = -1.1; low.contrast = 15
            var high = BasicAdjustments(); high.exposure = 0.9; high.shadows = 30; high.contrast = -10
            renders = [(L("暗调：大部分在左边"), low), (L("原图"), BasicAdjustments()), (L("亮调：大部分在右边"), high)].map { name, a in
                let r = photo.render(a)
                return (name, r.image, LessonPhoto.histogram(of: r.pixels))
            }
        }
    }
}

struct ClippingScene: View {
    let photo: LessonPhoto
    @UIState private var exposure = 1.2
    @UIState private var mark = true
    var body: some View {
        var a = BasicAdjustments(); a.exposure = exposure
        let r = photo.render(a)
        let clip = photo.clipping(r.pixels)
        return VStack(spacing: 12) {
            LessonImage(image: mark ? clip.image : r.image,
                        caption: String(format: L("纯白 %.1f%% · 纯黑 %.1f%%"), clip.white * 100, clip.black * 100))
                .frame(maxHeight: 330)
            ZoneHistogram(histogram: LessonPhoto.histogram(of: r.pixels), height: 70, showsCaption: false)
            LessonSlider(title: L("曝光"), value: $exposure, range: -3...3, format: { String(format: "%+.1f EV", $0) })
            Toggle("标出纯白（红）和纯黑（蓝）", isOn: $mark).toggleStyle(.checkbox).font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Tone controls

/// Input → output brightness, the language of curves, for any set of basic adjustments.
struct TransferPlot: View {
    var mapping: (Double) -> Double
    var body: some View {
        Canvas { context, size in
            let box = CGRect(origin: .zero, size: size).insetBy(dx: 18, dy: 14)
            context.stroke(Path(box), with: .color(.white.opacity(0.15)), lineWidth: 1)
            var diagonal = Path(); diagonal.move(to: CGPoint(x: box.minX, y: box.maxY)); diagonal.addLine(to: CGPoint(x: box.maxX, y: box.minY))
            context.stroke(diagonal, with: .color(.white.opacity(0.25)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            var line = Path()
            for step in 0...100 {
                let x = Double(step) / 100, y = mapping(x)
                let point = CGPoint(x: box.minX + box.width * x, y: box.maxY - box.height * y)
                if step == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }
            context.stroke(line, with: .color(.white), lineWidth: 2)
            context.draw(Text("原来的亮度 →").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: box.midX, y: size.height - 4))
            context.draw(Text("现在 ↑").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: 14, y: 6))
        }
    }
}

struct ExposureBrightnessScene: View {
    let photo: LessonPhoto
    @UIState private var exposure = 0.0
    @UIState private var brightness = 0.0
    var body: some View {
        var a = BasicAdjustments(); a.exposure = exposure; a.brightness = brightness
        let r = photo.render(a)
        let adjustments = a
        return VStack(spacing: 12) {
            HStack(spacing: 16) {
                LessonImage(image: r.image).frame(maxWidth: .infinity)
                TransferPlot { ToneResponse.map($0, adjustments) }.frame(width: 220, height: 220)
            }
            .frame(maxHeight: 300)
            ZoneHistogram(histogram: LessonPhoto.histogram(of: r.pixels), height: 64, showsCaption: false)
            LessonSlider(title: L("曝光"), value: $exposure, range: -2...2, format: { String(format: "%+.1f EV", $0) })
            LessonSlider(title: L("亮度"), value: $brightness, range: -100...100)
            Text(exposure > 0.3 ? L("看右上角：曝光让亮的地方先碰到顶（变成纯白）。")
                 : brightness > 20 ? L("亮度把整条线往上挪，暗的和亮的差不多一起变化。") : L("分别拖动两个滑块，比较右边线的形状。"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ToneControlScene: View {
    let photo: LessonPhoto
    private let controls: [AdjustmentParameter] = [.highlights, .shadows, .whites, .blackPoint]
    @UIState private var control = AdjustmentParameter.shadows
    @UIState private var values: [AdjustmentParameter: Double] = [:]
    @UIState private var showArea = true
    var body: some View {
        var a = BasicAdjustments(); a[control] = values[control] ?? 0
        let r = photo.render(a)
        return VStack(spacing: 12) {
            GlassSegmentedControl(options: controls, selection: $control, title: { $0.title }, size: .small)
                .frame(maxWidth: 320)
            LessonImage(image: showArea ? photo.influence(control, on: r.pixels) : r.image,
                        caption: showArea ? L("彩色 = 「\(control.title)」会改变的地方") : nil)
                .frame(maxHeight: 290)
            ZoneHistogram(histogram: LessonPhoto.histogram(of: r.pixels), focus: control, height: 64)
            LessonSlider(title: control.title, value: Binding(get: { values[control] ?? 0 }, set: { values[control] = $0 }), range: -100...100)
            Toggle("显示作用范围", isOn: $showArea).toggleStyle(.checkbox).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Camera scales shared by the 3D scenes

let fStops: [Double] = [1.4, 2, 2.8, 4, 5.6, 8, 11, 16]
let shutterStops: [Double] = [1.0 / 1000, 1.0 / 500, 1.0 / 250, 1.0 / 125, 1.0 / 60, 1.0 / 30, 1.0 / 15, 1.0 / 8, 1.0 / 4]
let isoStops: [Int] = [100, 200, 400, 800, 1600, 3200, 6400, 12800]
func shutterLabel(_ t: Double) -> String { t >= 1 ? String(format: L("%.0f 秒"), t) : L("1/\(Int((1 / t).rounded())) 秒") }
func stopLabel(_ f: Double) -> String { f < 10 ? String(format: "ƒ/%.1f", f).replacingOccurrences(of: ".0", with: "") : String(format: "ƒ/%.0f", f) }

/// The photo at this exposure with sensor-like grain for the ISO: grey, stronger in the shadows,
/// and the same pattern every time (seeded), so dragging doesn't flicker.
func noisy(_ photo: LessonPhoto, iso: Int, exposure: Double) -> CGImage {
    var a = BasicAdjustments(); a.exposure = exposure
    var pixels = photo.render(a).pixels
    let strength = 70 * pow(Double(iso) / 12800, 0.8)   // ± levels out of 255 at ISO 12800
    guard iso > 100, !pixels.isEmpty else { return LessonPhoto.cgImage(pixels, photo.width, photo.height) ?? photo.thumbnail }
    var seed: UInt64 = 0x9E3779B97F4A7C15
    for i in 0..<(pixels.count / 4) {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let u1 = Double((seed >> 11) & 0xFFFFF) / Double(0xFFFFF), u2 = Double((seed >> 33) & 0xFFFFF) / Double(0xFFFFF)
        let gaussian = (u1 + u2 - 1) * 1.7
        let luma = (0.2126 * Double(pixels[i * 4]) + 0.7152 * Double(pixels[i * 4 + 1]) + 0.0722 * Double(pixels[i * 4 + 2])) / 255
        let delta = gaussian * strength * (1.2 - 0.6 * luma)
        for c in 0..<3 { pixels[i * 4 + c] = UInt8(min(255, max(0, Double(pixels[i * 4 + c]) + delta))) }
    }
    return LessonPhoto.cgImage(pixels, photo.width, photo.height) ?? photo.thumbnail
}
