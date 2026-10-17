import CoreImage
import MediaCore
import SwiftUI

// MARK: - Colour helpers

extension LessonPhoto {
    /// The photo with each channel multiplied in linear light (how a coloured light or a white
    /// balance correction acts).
    func gains(_ r: Double, _ g: Double, _ b: Double) -> CGImage {
        let tinted = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
        return ColorPipeline.shared.createCGImage(tinted, from: image.extent, format: .RGBA8, colorSpace: ColorPipeline.outputSpace) ?? thumbnail
    }

    /// The colour (0…1, display-encoded) around a point given in 0…1 coordinates, top-left origin.
    func color(at point: CGPoint) -> (Double, Double, Double)? {
        guard let pixels = LessonPhoto.bytes(image, width, height) else { return nil }
        let cx = Int(point.x * Double(width)), cy = Int(point.y * Double(height))
        var r = 0.0, g = 0.0, b = 0.0, n = 0.0
        for y in max(0, cy - 3)...min(height - 1, cy + 3) {
            for x in max(0, cx - 3)...min(width - 1, cx + 3) {
                let i = (y * width + x) * 4
                r += Double(pixels[i]); g += Double(pixels[i + 1]); b += Double(pixels[i + 2]); n += 1
            }
        }
        guard n > 0 else { return nil }
        return (r / n / 255, g / n / 255, b / n / 255)
    }

    /// Only pixels of one colour family keep their colour (same band centres as the HSL panel).
    func bandMask(_ band: HueBand, on pixels: [UInt8]) -> CGImage {
        var out = pixels
        let centers = HueBand.allCases.map(\.degrees)
        for i in 0..<(pixels.count / 4) {
            let r = Double(pixels[i * 4]) / 255, g = Double(pixels[i * 4 + 1]) / 255, b = Double(pixels[i * 4 + 2]) / 255
            let high = max(r, g, b), low = min(r, g, b)
            var keep = 0.0
            if high > 0.05, (high - low) / high > 0.12 {
                let hue = Self.hue(r, g, b, high, low)
                // Membership falls off halfway to the neighbouring band centres.
                let d = centers.map { abs(((hue - $0 + 540).truncatingRemainder(dividingBy: 360)) - 180) }
                if d.enumerated().min(by: { $0.element < $1.element })?.offset == band.rawValue { keep = 1 }
            }
            if keep == 0 {
                let grey = UInt8((0.2126 * r + 0.7152 * g + 0.0722 * b) * 255 * 0.45)
                out[i * 4] = grey; out[i * 4 + 1] = grey; out[i * 4 + 2] = grey
            }
        }
        return Self.cgImage(out, width, height) ?? thumbnail
    }

    /// The colour family a pixel belongs to (nil for greys), by the same rule as `bandMask`.
    static func band(_ r: Double, _ g: Double, _ b: Double) -> HueBand? {
        let high = max(r, g, b), low = min(r, g, b)
        guard high > 0.05, (high - low) / high > 0.12 else { return nil }
        let hue = hue(r, g, b, high, low)
        let d = HueBand.allCases.map { abs(((hue - $0.degrees + 540).truncatingRemainder(dividingBy: 360)) - 180) }
        return d.enumerated().min(by: { $0.element < $1.element }).flatMap { HueBand(rawValue: $0.offset) }
    }

    /// The photo's cloud of pixels in the colour cylinder. `edited` gives the positions (the
    /// rendered, adjusted bytes) while the family each dot belongs to stays that of the original
    /// pixel, so the same dots can be followed as sliders move them. Others turn grey when a
    /// family is highlighted.
    func cylinderDots(edited: [UInt8]? = nil, highlight: HueBand? = nil, count: Int = 1800) -> [CloudDot] {
        let source = edited?.count == pixels.count ? edited! : pixels
        return cloud(count).map { i in
            let now = Self.rgb(source, i)
            let p = hsvOf(now.r, now.g, now.b)
            let original = Self.rgb(pixels, i)
            guard let highlight else { return CloudDot(position: cylinderPosition(p.h, p.s, p.v), color: Color(red: now.r, green: now.g, blue: now.b)) }
            let member = Self.band(original.r, original.g, original.b) == highlight
            return CloudDot(position: cylinderPosition(p.h, p.s, p.v), color: member ? Color(red: now.r, green: now.g, blue: now.b) : Color(white: 0.45, opacity: 0.5))
        }
    }

    static func hue(_ r: Double, _ g: Double, _ b: Double, _ high: Double, _ low: Double) -> Double {
        let c = high - low
        guard c > 0 else { return 0 }
        let h: Double = high == r ? (g - b) / c : high == g ? (b - r) / c + 2 : (r - g) / c + 4
        return (h * 60 + 360).truncatingRemainder(dividingBy: 360)
    }
}

/// Approximate colour of a light at this colour temperature (display-encoded RGB, 0…1).
private func lightColor(_ kelvin: Double) -> (Double, Double, Double) {
    let t = kelvin / 100
    let r = t <= 66 ? 255 : 329.698727446 * pow(t - 60, -0.1332047592)
    let g = t <= 66 ? 99.4708025861 * log(t) - 161.1195681661 : 288.1221695283 * pow(t - 60, -0.0755148492)
    let b = t >= 66 ? 255 : t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307
    return (min(255, max(0, r)) / 255, min(255, max(0, g)) / 255, min(255, max(0, b)) / 255)
}

private func linear(_ v: Double) -> Double { pow(max(0, v), 2.2) }

/// A colour with each channel multiplied in linear light, like `LessonPhoto.gains` does to the picture.
private func scaled(_ c: (r: Double, g: Double, b: Double), _ gain: (Double, Double, Double)) -> (r: Double, g: Double, b: Double) {
    func channel(_ v: Double, _ k: Double) -> Double { min(1, pow(linear(v) * k, 1 / 2.2)) }
    return (channel(c.r, gain.0), channel(c.g, gain.1), channel(c.b, gain.2))
}

// MARK: - White balance

struct ColorTemperatureScene: View {
    let photo: LessonPhoto
    private static let lights: [(String, Double)] = [(L("烛光"), 1900), (L("灯泡"), 2800), (L("日出日落"), 3500), (L("正午阳光"), 5500), (L("阴天"), 6500), (L("树荫"), 8000)]
    @UIState private var kelvin = 2800.0
    var body: some View {
        // The camera is set for daylight; the scene is lit by `kelvin`.
        let light = lightColor(kelvin), day = lightColor(5500)
        let gains = (linear(light.0) / linear(day.0), linear(light.1) / linear(day.1), linear(light.2) / linear(day.2))
        let norm = 0.2126 * gains.0 + 0.7152 * gains.1 + 0.0722 * gains.2
        let g = (gains.0 / norm, gains.1 / norm, gains.2 / norm)
        let cloud = photo.cubeDots(photo.pixels) { scaled($0, g) }
        return VStack(spacing: 14) {
            HStack(spacing: 14) {
                LessonImage(image: photo.gains(g.0, g.1, g.2), caption: String(format: L("在 %.0f K 的光下，相机按日光拍摄时的样子"), kelvin))
                    .frame(maxWidth: .infinity)
                VStack(spacing: 4) {
                    ColorCubeView(dots: cloud.dots, average: cloud.average)
                    Text("每个点是照片里的一个像素。白圆点是整体的平均颜色，离灰色竖线越远，偏色越重。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 290)
            }
            .frame(height: 320)
            HStack(spacing: 6) {
                ForEach(Self.lights, id: \.1) { name, k in
                    let c = lightColor(k)
                    Button { withAnimation(.easeInOut(duration: 0.3)) { kelvin = k } } label: {
                        VStack(spacing: 4) {
                            Circle().fill(Color(red: c.0, green: c.1, blue: c.2)).frame(width: 26, height: 26)
                                .overlay(Circle().strokeBorder(abs(kelvin - k) < 50 ? Color.white : .clear, lineWidth: 2))
                            Text(name).font(.caption)
                            Text("\(Int(k)) K").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }
            LessonSlider(title: L("色温"), value: $kelvin, range: 1800...9000, format: { String(format: "%.0f K", $0) })
            Text(kelvin < 4500 ? L("光偏暖：白墙看起来发黄发橙。") : kelvin > 6000 ? L("光偏冷：白墙看起来发蓝。") : L("接近日光：白色基本是白的。"))
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct WhitePickerScene: View {
    let photo: LessonPhoto
    @UIState private var picked: CGPoint?
    @UIState private var sample: (Double, Double, Double)?
    @UIState private var showFixed = true
    var body: some View {
        let fixed: CGImage? = sample.map { s in
            // Gains that make the picked colour neutral (in linear light), keeping its brightness.
            let (r, g, b) = (linear(s.0), linear(s.1), linear(s.2))
            let mean = (r + g + b) / 3
            return photo.gains(mean / max(0.001, r), mean / max(0.001, g), mean / max(0.001, b))
        }
        // The cloud in the RGB cube: the fix moves everything the same way, so the picked colour lands on the grey axis.
        let gain: (Double, Double, Double)? = sample.map { s in
            let (r, g, b) = (linear(s.0), linear(s.1), linear(s.2)), mean = (r + g + b) / 3
            return (mean / max(0.001, r), mean / max(0.001, g), mean / max(0.001, b))
        }
        let applied = showFixed ? gain : nil
        let cloud = photo.cubeDots(photo.pixels) { c in applied.map { scaled(c, $0) } ?? c }
        let marker = sample.map { s in applied.map { scaled((s.0, s.1, s.2), $0) } ?? (r: s.0, g: s.1, b: s.2) }
        return VStack(spacing: 12) {
            HStack(spacing: 14) {
            GeometryReader { proxy in
                let fit = fitRect(proxy.size)
                ZStack(alignment: .topLeading) {
                    Image(decorative: showFixed ? fixed ?? photo.thumbnail : photo.thumbnail, scale: 1)
                        .resizable().aspectRatio(contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 6))
                        .frame(width: fit.width, height: fit.height).offset(x: fit.minX, y: fit.minY)
                    if let picked {
                        Circle().strokeBorder(Color.white, lineWidth: 2).background(Circle().strokeBorder(Color.black.opacity(0.6), lineWidth: 4))
                            .frame(width: 22, height: 22)
                            .offset(x: fit.minX + picked.x * fit.width - 11, y: fit.minY + picked.y * fit.height - 11)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { location in
                    guard fit.contains(location) else { return }
                    let point = CGPoint(x: (location.x - fit.minX) / fit.width, y: (location.y - fit.minY) / fit.height)
                    picked = point; sample = photo.color(at: point); showFixed = true
                }
            }
            VStack(spacing: 4) {
                ColorCubeView(dots: cloud.dots, average: cloud.average, picked: marker)
                Text(sample == nil ? L("每个点是照片里的一个像素。点一下左边的照片，看它落在立方体的哪里。")
                     : showFixed ? L("校正后：你点的颜色回到了灰色竖线上，整团颜色一起跟着挪过来了。")
                     : L("校正前：你点的颜色偏离了灰色竖线，整团颜色都偏向同一边。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 290)
            }
            .frame(height: 320)
            if let s = sample {
                HStack(spacing: 14) {
                    swatch(L("你点的颜色"), Color(red: s.0, green: s.1, blue: s.2))
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    let grey = (s.0 + s.1 + s.2) / 3
                    swatch(L("校正成中性灰"), Color(white: grey))
                    Spacer()
                    Text(cast(s)).font(.callout).foregroundStyle(.secondary).frame(maxWidth: 260, alignment: .leading)
                }
                Toggle("显示校正后", isOn: $showFixed).toggleStyle(.checkbox).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("点照片里本来应该是白色或灰色的地方：墙、云、路面、白衣服。").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func fitRect(_ size: CGSize) -> CGRect {
        let aspect = Double(photo.width) / Double(photo.height)
        let w = min(size.width, size.height * aspect), h = w / aspect
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func swatch(_ title: String, _ color: Color) -> some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 5).fill(color).frame(width: 46, height: 30)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white.opacity(0.3)))
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// The same 色温 / 色调 the app's sliders would need (kernel: R×(1+0.16w), B×(1−0.16w); G×(1−0.12t)).
    private func cast(_ s: (Double, Double, Double)) -> String {
        let warm = (s.2 - s.0) / max(0.01, s.2 + s.0) / 0.16 * 100
        let tint = (s.1 - (s.0 + s.2) / 2) / max(0.01, s.1) / 0.16 * 100
        guard abs(warm) > 4 || abs(tint) > 4 else { return L("这里本来就接近中性，照片基本没有偏色。") }
        var parts: [String] = []
        if abs(warm) > 4 { parts.append(String(format: L("色温 %+.0f"), min(100, max(-100, warm)))) }
        if abs(tint) > 4 { parts.append(String(format: L("色调 %+.0f"), min(100, max(-100, tint)))) }
        let lead = warm < -4 ? L("这里偏暖。在光集里相当于：") : warm > 4 ? L("这里偏冷。在光集里相当于：")
            : tint > 4 ? L("这里偏绿。在光集里相当于：") : L("这里偏洋红。在光集里相当于：")
        return lead + parts.joined(separator: L("，")) + L("。")
    }
}

// MARK: - HSL

struct ColorThreeNumbersScene: View {
    let photo: LessonPhoto
    @UIState private var hue = 0.58
    @UIState private var saturation = 0.7
    @UIState private var lightness = 0.85
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 20) {
                VStack(spacing: 6) {
                    wheel.frame(width: 230, height: 230)
                    Text("色轮：从上往下看这根圆柱").font(.caption).foregroundStyle(.secondary)
                }
                VStack(spacing: 6) {
                    ColorCylinderView(dots: photo.cylinderDots(), marker: (hue, saturation, lightness)).frame(height: 230)
                    Text("圆柱：拖动旋转，小点是你照片里的颜色").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            HStack(alignment: .center, spacing: 18) {
                RoundedRectangle(cornerRadius: 8).fill(Color(hue: hue, saturation: saturation, brightness: lightness)).frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 8) {
                    row(L("色相"), "\(Int(hue * 360))°", L("绕圈：哪一种颜色"))
                    row(L("饱和度"), "\(Int(saturation * 100))", L("向外：有多鲜艳"))
                    row(L("明亮度"), "\(Int(lightness * 100))", L("向上：有多亮"))
                }
                Spacer()
            }
            LessonSlider(title: L("明亮度"), value: $lightness, range: 0.1...1, format: { "\(Int($0 * 100))" })
        }
    }

    private var wheel: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            ZStack {
                Circle().fill(AngularGradient(gradient: Gradient(colors: stride(from: 0.0, through: 1.0, by: 1.0 / 12).map { Color(hue: $0, saturation: 1, brightness: lightness) }),
                                              center: .center, angle: .degrees(0)))
                Circle().fill(RadialGradient(colors: [Color(white: lightness), Color(white: lightness).opacity(0)], center: .center, startRadius: 0, endRadius: size / 2))
                Circle()
                    .strokeBorder(Color.white, lineWidth: 2).frame(width: 18, height: 18)
                    .position(x: center.x + cos(hue * 2 * .pi) * saturation * size / 2, y: center.y + sin(hue * 2 * .pi) * saturation * size / 2)
            }
            .frame(width: size, height: size).position(center)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let dx = value.location.x - center.x, dy = value.location.y - center.y
                hue = (atan2(dy, dx) / (2 * .pi) + 1).truncatingRemainder(dividingBy: 1)
                saturation = min(1, (dx * dx + dy * dy).squareRoot() / (size / 2))
            })
        }
    }

    private func row(_ title: String, _ value: String, _ hint: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.callout.weight(.medium)).frame(width: .label(48), alignment: .leading)
            Text(value).font(.callout.monospacedDigit()).frame(width: 40, alignment: .trailing)
            Text(hint).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct HSLBandScene: View {
    let photo: LessonPhoto
    @UIState private var band = HueBand.blue
    @UIState private var values: [HueBand: (Double, Double, Double)] = [:]
    @UIState private var isolate = true
    var body: some View {
        var hsl = HSLAdjustments()
        for (b, v) in values { hsl[b, .hue] = v.0; hsl[b, .saturation] = v.1; hsl[b, .luminance] = v.2 }
        let r = photo.render(MediaEdits(hsl: hsl))
        let v = values[band] ?? (0, 0, 0)
        return VStack(spacing: 12) {
            HStack(spacing: 14) {
                LessonImage(image: isolate ? photo.bandMask(band, on: r.pixels) : r.image,
                            caption: isolate ? L("彩色的部分属于「\(band.title)」色系") : nil)
                    .frame(maxWidth: .infinity)
                VStack(spacing: 4) {
                    ColorCylinderView(dots: photo.cylinderDots(edited: r.pixels, highlight: isolate ? band : nil))
                    Text("圆柱里的每个点是一个像素。被选中色系的点会跟着滑块移动。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 270)
            }
            .frame(height: 290)
            HStack(spacing: 6) {
                ForEach(HueBand.allCases, id: \.self) { item in
                    Button { band = item } label: {
                        Circle().fill(Color(hue: item.degrees / 360, saturation: 0.8, brightness: 0.9))
                            .frame(width: 22, height: 22)
                            .overlay(Circle().strokeBorder(band == item ? Color.white : .clear, lineWidth: 2).padding(-3))
                    }
                    .buttonStyle(.plain).help(item.title)
                }
                Spacer()
                Toggle("只显示这种颜色", isOn: $isolate).toggleStyle(.checkbox).font(.callout)
            }
            LessonSlider(title: L("\(band.title) 色相"), value: binding(0), range: -100...100)
            LessonSlider(title: L("饱和度"), value: binding(1), range: -100...100)
            LessonSlider(title: L("明亮度"), value: binding(2), range: -100...100)
        }
    }
    private func binding(_ index: Int) -> Binding<Double> {
        Binding(get: { let v = values[band] ?? (0, 0, 0); return [v.0, v.1, v.2][index] },
                set: { new in var v = values[band] ?? (0, 0, 0)
                    if index == 0 { v.0 = new } else if index == 1 { v.1 = new } else { v.2 = new }
                    values[band] = v })
    }
}

// MARK: - Video: frame rate, shutter angle, Log

private struct BallTrack: View {
    let title: String
    let fps: Double
    var shutter: Double?      // seconds; nil = no blur drawn
    var slowdown = 1.0
    var body: some View {
        VStack(spacing: 6) {
            TimelineView(.animation) { timeline in
                Canvas { context, size in
                    let speed = size.width / 1.6    // crosses in 1.6 s
                    let now = timeline.date.timeIntervalSinceReferenceDate / slowdown
                    // Only whole frames exist: hold each frame for 1/fps.
                    let frameTime = (now * fps).rounded(.down) / fps
                    let x = (frameTime * speed).truncatingRemainder(dividingBy: size.width + 60) - 30, y = size.height / 2
                    if let shutter {
                        let streak = speed * shutter
                        let steps = max(1, Int(streak / 2))
                        for i in 0...steps {
                            let px = x - streak * Double(i) / Double(steps)
                            context.fill(Path(ellipseIn: CGRect(x: px - 14, y: y - 14, width: 28, height: 28)), with: .color(Color.orange.opacity(min(1, 1.4 / Double(steps + 1)))))
                        }
                    } else {
                        context.fill(Path(ellipseIn: CGRect(x: x - 14, y: y - 14, width: 28, height: 28)), with: .color(.orange))
                    }
                }
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            }
            .frame(height: 90)
            Text(title).font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct FrameRateScene: View {
    var body: some View {
        VStack(spacing: 18) {
            BallTrack(title: L("每秒 12 帧：明显一顿一顿"), fps: 12)
            BallTrack(title: L("每秒 24 帧：电影的标准"), fps: 24)
            BallTrack(title: L("每秒 60 帧：非常顺滑"), fps: 60)
            BallTrack(title: L("60 帧拍、按 24 帧播放：2.5 倍慢动作"), fps: 24, slowdown: 2.5)
        }
    }
}

struct ShutterAngleScene: View {
    private static let speeds: [Double] = [1.0 / 1000, 1.0 / 250, 1.0 / 100, 1.0 / 50, 1.0 / 30]
    @UIState private var stop = 3.0
    var body: some View {
        let shutter = Self.speeds[Int(stop.rounded())]
        let degrees = shutter * 24 * 360
        return VStack(spacing: 18) {
            BallTrack(title: L("24 帧 · 快门 1/\(Int((1 / shutter).rounded())) 秒"), fps: 24, shutter: shutter)
            BallTrack(title: L("对照：24 帧 · 快门 1/50 秒（180°）"), fps: 24, shutter: 1.0 / 50)
            LessonSlider(title: L("快门"), value: $stop, range: 0...Double(Self.speeds.count - 1), format: { "1/\(Int((1 / Self.speeds[Int($0.rounded())]).rounded()))" })
            Text(String(format: L("相当于 %.0f° 快门。"), degrees) + (degrees < 90 ? L("每帧都太清楚，动作像在跳。") : degrees > 250 ? L("拖影很重，画面发糊。") : L("拖影适中，动作自然。")))
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct LogCurveScene: View {
    @UIState private var stops = 2.0
    var body: some View {
        func rec709(_ s: Double) -> Double { min(1, pow(min(1, 0.18 * pow(2, s)), 1 / 2.4) * 1.0) }
        // Log: evenly spaced per stop from deep shadows to bright highlights — above Rec.709 in the
        // shadows (the "grey" look), below it in the highlights, and it only reaches the top at +6.
        func log(_ s: Double) -> Double { min(1, max(0, 0.1 + 0.85 * (s + 8) / 14)) }
        let clipped = rec709(stops) >= 0.999
        return VStack(spacing: 14) {
            Canvas { context, size in
                let box = CGRect(x: 40, y: 10, width: size.width - 60, height: size.height - 44)
                context.stroke(Path(box), with: .color(.white.opacity(0.15)), lineWidth: 1)
                func point(_ s: Double, _ v: Double) -> CGPoint { CGPoint(x: box.minX + box.width * (s + 8) / 14, y: box.maxY - box.height * v) }
                for (curve, color, name) in [(rec709 as (Double) -> Double, Color.white, L("普通（Rec.709）")), (log, Color.orange, "Log")] {
                    var line = Path()
                    for i in 0...140 { let s = -8 + Double(i) / 10; i == 0 ? line.move(to: point(s, curve(s))) : line.addLine(to: point(s, curve(s))) }
                    context.stroke(line, with: .color(color), lineWidth: 2)
                    context.draw(Text(name).font(.caption).foregroundStyle(color), at: point(name == "Log" ? 5 : -5.5, curve(name == "Log" ? 5 : -5.5) + 0.07))
                }
                var marker = Path(); marker.move(to: point(stops, 0)); marker.addLine(to: point(stops, 1))
                context.stroke(marker, with: .color(.white.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                context.fill(Path(ellipseIn: CGRect(origin: point(stops, rec709(stops)), size: .zero).insetBy(dx: -5, dy: -5)), with: .color(.white))
                context.fill(Path(ellipseIn: CGRect(origin: point(stops, log(stops)), size: .zero).insetBy(dx: -5, dy: -5)), with: .color(.orange))
                context.draw(Text("场景越来越亮 →").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: box.midX, y: size.height - 10))
                context.draw(Text("记录的值").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: 20, y: box.minY + 6))
            }
            .frame(maxHeight: 320)
            LessonSlider(title: L("场景亮度"), value: $stops, range: -8...6, format: { String(format: L("%+.0f 档"), $0) })
            Text(clipped ? L("普通模式已经是纯白（顶到头了），Log 还在往上走，细节还在。") : L("两种模式都还记得这里的亮度。往右拖，看谁先到顶。"))
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct LogConversionScene: View {
    let photo: LessonPhoto
    @UIState private var strength = 0.0
    var body: some View {
        // A simulated Log look from the user's photo: lifted blacks, lowered whites, washed-out colour.
        // The "LUT" undoes it in proportion to its strength.
        let flat = 1 - strength
        var curves = ToneCurves()
        curves.master = [CurvePoint(x: 0, y: 0.16 * flat), CurvePoint(x: 0.5, y: 0.5), CurvePoint(x: 1, y: 1 - 0.2 * flat)]
        var a = BasicAdjustments(); a.saturation = -60 * flat
        let r = photo.render(MediaEdits(adjustments: a, curves: curves))
        let table = lattice(flat: flat, curve: ToneCurves.sample(curves.master, count: 256))
        let cloud = photo.cubeDots(r.pixels, count: 1400).dots.map { CloudDot(position: $0.position, color: $0.color.opacity(0.55), radius: 1.1) }
        return VStack(spacing: 12) {
            HStack(spacing: 14) {
                LessonImage(image: r.image, caption: strength < 0.05 ? L("模拟的 Log 画面：灰、淡，但什么都在") : strength > 0.95 ? L("套用转换 LUT 之后") : nil)
                    .frame(maxWidth: .infinity)
                VStack(spacing: 4) {
                    ColorCubeView(dots: table.nodes + cloud, edges: table.edges)
                    Text("每个交叉点是一种颜色。LUT 把整张网拉开，照片里的颜色（小点）跟着铺开。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 290)
            }
            .frame(height: 300)
            ZoneHistogram(histogram: LessonPhoto.histogram(of: r.pixels), height: 56, showsCaption: false)
            LessonSlider(title: L("LUT 强度"), value: $strength, range: 0...1, format: { "\(Int($0 * 100))%" })
            Text("Log 的直方图挤在中间；转换 LUT 把它重新铺开，对比和颜色就回来了。")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    /// A grid of colours (0, 0.2 … 1 per channel) after the same look as the photo: where a LUT's table
    /// would send each of them. Joined, the grid is the cube bent into shape.
    private func lattice(flat: Double, curve: [Double]) -> (nodes: [CloudDot], edges: [(V3, V3)]) {
        let n = 6
        func look(_ c: (r: Double, g: Double, b: Double)) -> (r: Double, g: Double, b: Double) {
            func lift(_ v: Double) -> Double { curve[min(255, max(0, Int((v * 255).rounded())))] }
            let (r, g, b) = (lift(c.r), lift(c.g), lift(c.b))
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b, k = 1 - 0.6 * flat
            return (luma + (r - luma) * k, luma + (g - luma) * k, luma + (b - luma) * k)
        }
        var nodes: [CloudDot] = [], edges: [(V3, V3)] = [], place: [Int: V3] = [:]
        for i in 0..<n { for j in 0..<n { for k in 0..<n {
            let c = look((Double(i) / Double(n - 1), Double(j) / Double(n - 1), Double(k) / Double(n - 1)))
            let p = cubePosition(c.r, c.g, c.b)
            place[(i * n + j) * n + k] = p
            nodes.append(CloudDot(position: p, color: Color(red: c.r, green: c.g, blue: c.b), radius: 2.6))
        } } }
        for i in 0..<n { for j in 0..<n { for k in 0..<n {
            let here = place[(i * n + j) * n + k]!
            if i + 1 < n { edges.append((here, place[((i + 1) * n + j) * n + k]!)) }
            if j + 1 < n { edges.append((here, place[(i * n + j + 1) * n + k]!)) }
            if k + 1 < n { edges.append((here, place[(i * n + j) * n + k + 1]!)) }
        } } }
        return (nodes, edges)
    }
}
