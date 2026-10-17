import Foundation

// MARK: - Levels, topics, concepts

public enum LearningLevel: String, Codable, CaseIterable, Sendable {
    case beginner, intermediate, advanced
    public var title: String { switch self { case .beginner: L("入门"); case .intermediate: L("进阶"); case .advanced: L("专业") } }
}

/// What the user wants to learn. Each topic is an ordered learning path.
public enum LearningTopic: String, Codable, CaseIterable, Sendable {
    case exposure, color, cinematic, landscape, portrait, scopes, composition, video
    public var title: String {
        switch self {
        case .exposure: L("曝光与影调"); case .color: L("色彩与白平衡"); case .cinematic: L("电影感调色"); case .landscape: L("风光与天空")
        case .portrait: L("人像与肤色"); case .scopes: L("读懂示波器"); case .composition: L("构图"); case .video: L("视频与 Live")
        }
    }
    public var path: [Concept] {
        switch self {
        case .exposure: [.histogram, .exposure, .highlights, .shadows, .whitesBlacks, .contrast, .clipping]
        case .color: [.whiteBalance, .vibrance, .hsl, .vectorscope, .parade]
        case .cinematic: [.contrast, .curves, .colorWheels, .lut, .logFootage, .parade]
        case .landscape: [.highlights, .sky, .hsl, .straighten, .crop, .sharpening]
        case .portrait: [.skinTone, .vectorscope, .whiteBalance, .hsl, .shadows, .noise]
        case .scopes: [.histogram, .clipping, .waveform, .parade, .vectorscope]
        case .composition: [.straighten, .crop]
        case .video: [.logFootage, .lut, .livePhoto]
        }
    }
}

public enum Concept: String, Codable, CaseIterable, Sendable, CodingKeyRepresentable {
    case histogram, exposure, highlights, shadows, whitesBlacks, contrast, clipping
    case whiteBalance, vibrance, hsl, sky, skinTone
    case curves, colorWheels, lut, logFootage
    case waveform, parade, vectorscope
    case straighten, crop, sharpening, noise, livePhoto

    public var title: String {
        switch self {
        case .histogram: L("直方图"); case .exposure: L("曝光"); case .highlights: L("高光"); case .shadows: L("阴影")
        case .whitesBlacks: L("白色与黑色"); case .contrast: L("对比度"); case .clipping: L("溢出（纯白 / 死黑）")
        case .whiteBalance: L("白平衡"); case .vibrance: L("自然饱和度"); case .hsl: L("HSL 色彩混合"); case .sky: L("让天空更有层次")
        case .skinTone: L("肤色"); case .curves: L("曲线"); case .colorWheels: L("色轮"); case .lut: "LUT"; case .logFootage: L("Log 素材")
        case .waveform: L("波形图"); case .parade: L("RGB 分量"); case .vectorscope: L("矢量图")
        case .straighten: L("水平校正"); case .crop: L("裁剪与构图"); case .sharpening: L("锐化"); case .noise: L("降噪"); case .livePhoto: L("Live Photo 制作")
        }
    }

    /// Plain-language explanation (shown to beginners and intermediate users).
    public var basic: String {
        switch self {
        case .histogram: L("直方图把照片里每个像素按亮度排队：左边是暗的，右边是亮的。山峰在哪里，照片的大部分就在哪里。")
        case .exposure: L("曝光让整张照片同时变亮或变暗，就像拍摄时多进一点或少进一点光。+1 EV 等于光线加倍。")
        case .highlights: L("高光只调整较亮的区域，比如天空和白云。往下拉能找回还没完全过曝的层次。")
        case .shadows: L("阴影只调整较暗的区域。往上拉能看清背光处的细节，但也可能显出噪点。")
        case .whitesBlacks: L("白色决定最亮的地方有多白，黑色决定最暗的地方有多黑。它们设定画面的两端。")
        case .contrast: L("对比度拉开或收拢明暗差距。对比低显得灰、柔；对比高显得硬朗、有冲击力。")
        case .clipping: L("纯白或纯黑的区域已经没有细节。开启溢出显示后，纯白显示为红色、纯黑显示为蓝色。")
        case .whiteBalance: L("白平衡让白色看起来是白的。色温控制冷暖（蓝–黄），色调控制绿–洋红。")
        case .vibrance: L("自然饱和度优先增强不太鲜艳的颜色，已经很鲜艳的颜色和肤色变化较小，比饱和度更不容易过头。")
        case .hsl: L("HSL 只改一种颜色：比如只让蓝天更深、只让树叶更黄，其他颜色不受影响。")
        case .sky: L("降低蓝色的明亮度、略微提高饱和度，天空会更深、云更立体，地面不受影响。")
        case .skinTone: L("健康的肤色在矢量图上落在一条斜线附近。偏离太多会显得发红或发黄。")
        case .curves: L("曲线可以单独改变任何一段亮度。最经典的是 S 曲线：暗部更暗、亮部更亮，中间调基本不变。")
        case .colorWheels: L("色轮分别给暗部、中间调、亮部加上颜色。比如暗部偏青、亮部偏橙，就是常见的电影感。")
        case .lut: L("LUT 是一张颜色对照表，把每种颜色换成另一种，一键得到一种风格。强度可以控制用多少。")
        case .logFootage: L("Log 模式故意拍得很灰，为了保留更多高光和暗部。需要先套用相机厂商的转换 LUT，画面才会恢复正常。")
        case .waveform: L("波形图的横向对应画面从左到右，纵向是亮度。贴着顶部的平线表示过曝，贴着底部表示死黑。")
        case .parade: L("RGB 分量把红、绿、蓝分开显示。灰色或白色的物体，三栏应该差不多高；某栏特别高就说明偏色。")
        case .vectorscope: L("矢量图显示颜色：方向代表色相，离中心越远越鲜艳。斜线是肤色参考线。")
        case .straighten: L("地平线歪了会让画面不稳。拉直后会自动裁掉一点边缘。")
        case .crop: L("裁剪可以去掉干扰元素。把主体放在三分线附近，画面通常更有张力。")
        case .sharpening: L("锐化增强细小边缘，让细节更清楚。要放大到 100% 判断，过度会出现白边。")
        case .noise: L("降噪让画面更干净，但过强会抹掉纹理，看起来像塑料。")
        case .livePhoto: L("Live Photo 是一张封面照片加一段 0.5–3 秒的视频。选好片段和封面，就能在 iPhone 上按住播放。")
        }
    }

    /// Technical detail (intermediate and advanced users).
    public var detail: String {
        switch self {
        case .histogram: L("右侧贴边表示高光溢出，左侧贴边表示暗部溢出；峰值位置比形状更重要。这里统计的是 SDR 显示结果。")
        case .exposure: L("曝光作用在线性光上，是乘法：高光会比暗部变化得更多，所以先看高光是否会溢出。")
        case .highlights: L("高光权重约从亮度 45% 开始，越亮作用越强；与白色配合：先用高光压缩，再用白色定白点。")
        case .shadows: L("阴影权重在亮度 60% 以下逐渐增强。抬阴影会降低整体对比，可再用对比度或曲线补回。")
        case .whitesBlacks: L("白色作用于亮度 70% 以上，黑色作用于 25% 以下；它们决定直方图两端的位置。")
        case .contrast: L("对比度围绕 50% 灰拉伸亮度；曲线可以选择支点和范围，更精细。")
        case .clipping: L("比屏幕能显示的最白还亮（或比最黑还暗）的部分被截断。原片中已经截断的数据无法通过调色恢复。")
        case .whiteBalance: L("这里是对已渲染画面的相对校正，不是相机原始数据的开尔文值；用接近中性灰的像素判断偏色最可靠。")
        case .vibrance: L("自然饱和度的增益随像素已有饱和度递减，避免已饱和颜色溢出色域。")
        case .hsl: L("每个色系在相邻色系之间平滑过渡；低饱和像素受影响更小，避免灰色物体被染色。")
        case .sky: L("蓝色 / 青色的明亮度负值会压暗天空；配合高光可恢复云层细节。注意天空边缘的过渡。")
        case .skinTone: L("肤色线在 Cb/Cr 平面约 123°。用 HSL 橙色的色相微调可以让肤色回到线上。")
        case .curves: L("曲线在调色顺序中位于色轮之后、HSL 之前；RGB 主曲线先作用，再应用单通道曲线。")
        case .colorWheels: L("Lift 作用于暗部、Gain 作用于亮部、Gamma 作用于中间调、Offset 平移整体；色点方向与矢量图一致。")
        case .lut: L("LUT 有输入色彩空间：创意 LUT 通常是 Rec.709 / sRGB 输入；Log 转换 LUT 需要对应相机的 Log 输入。")
        case .logFootage: L("Log 素材的直方图挤在中间、饱和度很低；先转换到 Rec.709，再做一级和二级调色。")
        case .waveform: L("波形以 0–100 表示亮度。曝光正确的天空通常在 70–90，肤色在 50–70 左右。")
        case .parade: L("白平衡准确时，中性区域在三栏中高度一致；用它来判断色温 / 色调该往哪边调。")
        case .vectorscope: L("图中方框是 75% 饱和度的标准色靶点；颜色点云越接近方框越鲜艳。")
        case .straighten: L("自动拉直使用地平线识别；可信度低时不会自动应用。")
        case .crop: L("常用比例：4:5 适合社交平台竖图，16:9 适合横屏，1:1 适合方形网格。")
        case .sharpening: L("锐化半径随画面尺寸缩放，预览和导出一致；建议在降噪之后、导出之前完成。")
        case .noise: L("降噪在调色链最前端进行，避免后续提亮放大噪点。")
        case .livePhoto: L("输出需为 0.5–3 秒；可用变速把较长片段压缩进 3 秒，背景音乐保持原节奏。")
        }
    }

    public func explanation(for level: LearningLevel) -> String {
        switch level {
        case .beginner: basic
        case .intermediate: basic + "\n" + detail
        case .advanced: detail
        }
    }

    /// The overlay that shows where this concept acts in the current photo.
    public var influence: InfluenceKind? {
        switch self {
        case .highlights: .highlights; case .shadows: .shadows; case .whitesBlacks: .whites
        case .sky: .sky; case .skinTone: .skin; case .whiteBalance: .neutral; case .vibrance: .saturated
        case .hsl: .hue(.blue); case .colorWheels: .lift
        default: nil
        }
    }

    /// A one-click demonstration on whatever photo is open.
    public var demo: CoachSuggestion? {
        switch self {
        case .histogram: CoachSuggestion(label: L("显示直方图"), actions: [.showScope("histogram")])
        case .exposure: CoachSuggestion(label: L("曝光 +0.5 EV"), deltas: [.exposure: 0.5])
        case .highlights: CoachSuggestion(label: L("高光 -40"), deltas: [.highlights: -40])
        case .shadows: CoachSuggestion(label: L("阴影 +40"), deltas: [.shadows: 40])
        case .whitesBlacks: CoachSuggestion(label: L("白色 +20 · 黑色 +15"), deltas: [.whites: 20, .blackPoint: 15])
        case .contrast: CoachSuggestion(label: L("对比度 +25"), deltas: [.contrast: 25])
        case .clipping: CoachSuggestion(label: L("显示溢出区域"), actions: [.showClipping])
        case .whiteBalance: CoachSuggestion(label: L("色温 +20"), deltas: [.warmth: 20])
        case .vibrance: CoachSuggestion(label: L("自然饱和度 +35"), deltas: [.vibrance: 35])
        case .hsl, .sky:
            CoachSuggestion(label: L("蓝色明亮度 -25 · 饱和度 +15"),
                            hsl: [HSLChange(band: .blue, component: .luminance, delta: -25),
                                  HSLChange(band: .blue, component: .saturation, delta: 15)])
        case .skinTone, .vectorscope: CoachSuggestion(label: L("显示矢量图"), actions: [.showScope("vectorscope")])
        case .curves:
            CoachSuggestion(label: L("S 曲线"), masterCurve: [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.25, y: 0.19),
                                                         CurvePoint(x: 0.75, y: 0.82), CurvePoint(x: 1, y: 1)])
        case .colorWheels:
            CoachSuggestion(label: L("暗部偏青 · 亮部偏橙"),
                            wheels: [.lift: WheelValue(x: 0.3, y: -0.2), .gain: WheelValue(x: -0.25, y: 0.2)])
        case .lut: CoachSuggestion(label: L("套用内置「暖调」LUT"), actions: [.builtInLUT])
        case .logFootage: CoachSuggestion(label: L("导入转换 LUT…"), actions: [.importLUT])
        case .waveform: CoachSuggestion(label: L("显示波形图"), actions: [.showScope("waveform")])
        case .parade: CoachSuggestion(label: L("显示 RGB 分量"), actions: [.showScope("parade")])
        case .straighten: CoachSuggestion(label: L("自动拉直"), actions: [.straighten])
        case .crop: CoachSuggestion(label: L("裁成 4:5"), actions: [.cropFourFive])
        case .sharpening: CoachSuggestion(label: L("锐度 +30 并放大到 100%"), deltas: [.sharpness: 30], actions: [.zoomToActual])
        case .noise: CoachSuggestion(label: L("降噪 +30 并放大到 100%"), deltas: [.noiseReduction: 30], actions: [.zoomToActual])
        case .livePhoto: nil
        }
    }

    /// Concepts whose controls changed between two edit states (usage tracking).
    public static func changed(from old: MediaEdits, to new: MediaEdits) -> Set<Concept> {
        var result = Set<Concept>()
        for parameter in AdjustmentParameter.allCases where old.adjustments[parameter] != new.adjustments[parameter] {
            switch parameter {
            case .exposure: result.insert(.exposure)
            case .highlights: result.insert(.highlights)
            case .shadows: result.insert(.shadows)
            case .whites, .blackPoint: result.insert(.whitesBlacks)
            case .contrast, .brightness, .brilliance: result.insert(.contrast)
            case .warmth, .tint: result.insert(.whiteBalance)
            case .vibrance, .saturation: result.insert(.vibrance)
            case .sharpness, .definition: result.insert(.sharpening)
            case .noiseReduction: result.insert(.noise)
            case .dehaze: result.insert(.contrast)
            case .vignette, .fade, .grain, .monochrome: break
            }
        }
        if old.wheels != new.wheels { result.insert(.colorWheels) }
        if old.curves != new.curves { result.insert(.curves) }
        if old.hsl != new.hsl { result.insert(.hsl) }
        if old.lut?.id != new.lut?.id { result.insert(.lut) }
        if old.degrees != new.degrees { result.insert(.straighten) }
        if old.geometry.aspectRatio != new.geometry.aspectRatio || old.geometry.cropScale != new.geometry.cropScale { result.insert(.crop) }
        return result
    }
}

// MARK: - Suggestions

public struct HSLChange: Equatable, Sendable {
    public var band: HueBand
    public var component: HSLAdjustments.Component
    public var delta: Double
    public init(band: HueBand, component: HSLAdjustments.Component, delta: Double) {
        self.band = band; self.component = component; self.delta = delta
    }
}

/// A concrete change the user can preview and keep (always one undo step).
public struct CoachSuggestion: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case straighten, importLUT, builtInLUT, showClipping, zoomToActual, cropFourFive
        case showScope(String)
    }
    public var label: String
    public var deltas: [AdjustmentParameter: Double]
    public var hsl: [HSLChange]
    public var masterCurve: [CurvePoint]?
    public var wheels: [ColorWheels.Wheel: WheelValue]
    public var actions: [Action]

    public init(label: String, deltas: [AdjustmentParameter: Double] = [:], hsl: [HSLChange] = [],
                masterCurve: [CurvePoint]? = nil, wheels: [ColorWheels.Wheel: WheelValue] = [:], actions: [Action] = []) {
        self.label = label; self.deltas = deltas; self.hsl = hsl; self.masterCurve = masterCurve
        self.wheels = wheels; self.actions = actions
    }

    /// True when applying it changes the edit values (not just the view).
    public var changesEdits: Bool { !deltas.isEmpty || !hsl.isEmpty || masterCurve != nil || !wheels.isEmpty }

    /// Adds the deltas to the current values, clamped to each control's range.
    public func applied(to edits: MediaEdits) -> MediaEdits {
        var result = edits
        for (parameter, delta) in deltas { result.adjustments[parameter] = edits.adjustments[parameter] + delta }
        for change in hsl { result.hsl[change.band, change.component] = edits.hsl[change.band, change.component] + change.delta }
        if let masterCurve { result.curves[.master] = masterCurve }
        for (wheel, value) in wheels {
            let current = edits.wheels[wheel]
            result.wheels[wheel] = WheelValue(x: current.x + value.x, y: current.y + value.y, master: current.master + value.master)
        }
        return result
    }
}

// MARK: - Learner profile

public struct ConceptProgress: Codable, Equatable, Sendable {
    public var shown = 0
    public var tried = 0
    public var used = 0
    public var helpful = 0
    /// Questions the user asked that touched this concept: a direct signal of interest.
    public var asked = 0
    public var known = false
    public var muted = false
    public init() {}

    private enum CodingKeys: String, CodingKey { case shown, tried, used, helpful, asked, known, muted }
    /// Missing keys default, so profiles saved by earlier versions keep loading.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        shown = try values.decodeIfPresent(Int.self, forKey: .shown) ?? 0
        tried = try values.decodeIfPresent(Int.self, forKey: .tried) ?? 0
        used = try values.decodeIfPresent(Int.self, forKey: .used) ?? 0
        helpful = try values.decodeIfPresent(Int.self, forKey: .helpful) ?? 0
        asked = try values.decodeIfPresent(Int.self, forKey: .asked) ?? 0
        known = try values.decodeIfPresent(Bool.self, forKey: .known) ?? false
        muted = try values.decodeIfPresent(Bool.self, forKey: .muted) ?? false
    }
}

/// What this user knows and wants to learn. Updated by usage and feedback.
public struct LearnerProfile: Codable, Equatable, Sendable {
    public var level = LearningLevel.beginner
    public var topics: Set<LearningTopic> = [.exposure, .color]
    public var progress: [Concept: ConceptProgress] = [:]
    public var hoverHints = true
    public var onboarded = false
    /// Interactive lessons finished (ids from `Lesson.catalog`).
    public var lessonsDone: Set<String> = []
    public init() {}

    private enum CodingKeys: String, CodingKey { case level, topics, progress, hoverHints, onboarded, lessonsDone }
    /// Missing keys default, so profiles saved by earlier versions keep loading.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        level = try values.decodeIfPresent(LearningLevel.self, forKey: .level) ?? .beginner
        topics = try values.decodeIfPresent(Set<LearningTopic>.self, forKey: .topics) ?? [.exposure, .color]
        progress = try values.decodeIfPresent([Concept: ConceptProgress].self, forKey: .progress) ?? [:]
        hoverHints = try values.decodeIfPresent(Bool.self, forKey: .hoverHints) ?? true
        onboarded = try values.decodeIfPresent(Bool.self, forKey: .onboarded) ?? false
        lessonsDone = try values.decodeIfPresent(Set<String>.self, forKey: .lessonsDone) ?? []
    }

    public func state(_ concept: Concept) -> ConceptProgress { progress[concept] ?? ConceptProgress() }

    /// Learned when marked known, demonstrated on a photo, or used regularly.
    public func isLearned(_ concept: Concept) -> Bool {
        let s = state(concept)
        return s.known || s.tried > 0 || s.used >= 5
    }

    public mutating func update(_ concept: Concept, _ change: (inout ConceptProgress) -> Void) {
        var s = state(concept)
        change(&s)
        progress[concept] = s
    }

    /// Ordered, de-duplicated concepts across the chosen topics.
    public var path: [Concept] {
        var seen = Set<Concept>()
        let topics = LearningTopic.allCases.filter { self.topics.contains($0) }
        return (topics.isEmpty ? [.exposure] : topics).flatMap(\.path).filter { seen.insert($0).inserted }
    }

    public var nextConcepts: [Concept] { path.filter { !isLearned($0) && !state($0).muted } }
    public var learnedInPath: Int { path.filter(isLearned).count }

    /// Chosen topics count fully; questions the user asked about a concept add up to the same weight.
    func interest(_ concept: Concept) -> Double {
        let chosen: Double = topics.contains { $0.path.contains(concept) } ? 1 : 0
        return max(chosen, min(1, Double(state(concept).asked) / 3))
    }
}

// MARK: - Insights

public struct CoachInsight: Identifiable, Equatable, Sendable {
    public let id: String
    public let concept: Concept
    public let severity: Double
    public let symbol: String
    public let title: String
    public let observation: String
    public let why: String
    public let suggestion: CoachSuggestion?
    public let influence: InfluenceKind?
    public let showsClipping: Bool
}

/// Turns photo facts + current edits + the learner profile into ranked, explained tips.
public enum PhotoCoach {
    static func pct(_ value: Double) -> String {
        value >= 0.1 ? String(format: "%.0f%%", value * 100) : String(format: "%.1f%%", value * 100)
    }

    private static func place(_ center: [Double]?) -> String {
        guard let center else { return "" }
        // Whole phrases, so each language can order "upper left" its own way.
        let row = center[1] < 0.38 ? 0 : center[1] > 0.62 ? 2 : 1
        let column = center[0] < 0.35 ? 0 : center[0] > 0.65 ? 2 : 1
        switch (row, column) {
        case (0, 0): return L("，主要在画面左上方")
        case (0, 1): return L("，主要在画面上方")
        case (0, _): return L("，主要在画面右上方")
        case (1, 0): return L("，主要在画面左中部")
        case (1, 1): return L("，主要在画面中部")
        case (1, _): return L("，主要在画面右中部")
        case (_, 0): return L("，主要在画面左下方")
        case (_, 1): return L("，主要在画面下方")
        default: return L("，主要在画面右下方")
        }
    }

    /// - Parameter faces: analysis of the detected face regions only; skin advice
    ///   is given only when faces exist (orange-brown landscapes are not skin).
    public static func insights(for a: PhotoAnalysis, original: PhotoAnalysis? = nil, faces: PhotoAnalysis? = nil,
                                edits: MediaEdits, profile: LearnerProfile, tilt: Double? = nil,
                                isVideo: Bool = false) -> [CoachInsight] {
        var list: [CoachInsight] = []
        let level = profile.level
        let adj = edits.adjustments
        func add(_ id: String, _ concept: Concept, _ severity: Double, _ symbol: String, _ title: String, _ observation: String,
                 _ why: String, _ suggestion: CoachSuggestion? = nil, influence: InfluenceKind? = nil, clipping: Bool = false) {
            list.append(CoachInsight(id: id, concept: concept, severity: min(1, max(0, severity)), symbol: symbol, title: title,
                                     observation: observation, why: why, suggestion: suggestion, influence: influence,
                                     showsClipping: clipping))
        }
        let numbers = level == .advanced
            ? String(format: L("（P5 %.0f%% · P50 %.0f%% · P95 %.0f%%）"), a.p5 * 100, a.p50 * 100, a.p95 * 100) : ""

        // Log footage first: other tone advice would be misleading before conversion.
        let log = a.looksLikeLog && !edits.hasLUT
        if log {
            add("log", .logFootage, 0.95, "camera.filters", L("画面发灰、颜色很淡：可能是 Log 素材"),
                L("亮度都挤在中间，平均饱和度只有 \(pct(a.meanSaturation))\(numbers)。"),
                Concept.logFootage.explanation(for: level),
                CoachSuggestion(label: L("导入相机转换 LUT…"), actions: [.importLUT]))
        }

        if a.clippedHighlights > 0.004 {
            let sourceClipped = (original?.clippedHighlights ?? 0) > 0.004
            if sourceClipped, adj.highlights <= -60 {
                add("highlights-lost", .clipping, 0.55, "sun.max.trianglebadge.exclamationmark", L("仍有 \(pct(a.clippedHighlights)) 是纯白"),
                    L("高光已经拉到 \(Int(adj.highlights))，这些地方依然没有细节\(place(a.brightCenter))。"),
                    L("拍摄时已经过曝的区域没有任何数据，调色只能让它变灰，不能找回细节。下次可以降低曝光补偿 0.3–0.7 EV，或开启 HDR。"),
                    influence: nil, clipping: true)
            } else {
                var deltas: [AdjustmentParameter: Double] = [:]
                if adj.highlights > -65 { deltas[.highlights] = -35 }
                if adj.whites > -60 { deltas[.whites] = -15 }
                let label = deltas.keys.sorted { $0.rawValue < $1.rawValue }
                    .map { "\($0.title) \(Int(deltas[$0]!))" }.joined(separator: " · ")
                add("highlights-clipped", .clipping, 0.45 + a.clippedHighlights * 25, "sun.max.fill",
                    L("高光溢出 \(pct(a.clippedHighlights))"),
                    L("这些像素已经是纯白\(place(a.brightCenter))，开启溢出显示时会标成红色。"),
                    level == .beginner
                        ? L("纯白的地方没有细节，看起来会很刺眼。把高光往下拉，可以找回还没完全丢失的层次。")
                        : L("直方图右端贴边、波形顶部出现平线。先用高光压缩亮部，再用白色设定白点。"),
                    deltas.isEmpty ? nil : CoachSuggestion(label: label, deltas: deltas), influence: .highlights, clipping: true)
            }
        }

        if a.clippedShadows > 0.01 {
            add("shadows-clipped", .clipping, 0.3 + a.clippedShadows * 12, "moon.fill", L("暗部死黑 \(pct(a.clippedShadows))"),
                L("这些像素是纯黑\(place(a.darkCenter))，开启溢出显示时会标成蓝色。"),
                level == .beginner ? L("完全的黑色没有细节。抬起阴影能看到更多东西；如果是剪影效果，可以保留。")
                    : L("直方图左端贴边。阴影抬起暗部，黑色负值让最暗处变浅；需要剪影或高反差风格时可以保留。"),
                CoachSuggestion(label: L("阴影 +30 · 黑色 -10"), deltas: [.shadows: 30, .blackPoint: -10]),
                influence: .shadows, clipping: true)
        }

        // A dark mid-tone alone is not underexposure: night scenes and silhouettes have bright
        // parts too (P95). Only a frame with nothing bright is dark overall, and the suggested
        // exposure stops before the brightest tones would clip.
        if !log, a.p50 < 0.28, a.p95 < 0.7, a.clippedHighlights < 0.003 {
            let headroom = log2(pow(0.95 / max(0.05, a.p95), 2.2))
            let ev = min(1.5, headroom, max(0.2, (log2(pow(0.42 / max(0.05, a.p50), 2.2)) * 20).rounded() / 20))
            add("underexposed", .exposure, 0.35 + (0.28 - a.p50) * 2.5, "sun.min", L("整体偏暗"),
                L("中间亮度只有 \(pct(a.p50))，大部分像素集中在直方图左侧\(numbers)。"),
                level == .beginner ? L("曝光会让整张照片一起变亮。如果只是阴影太暗而天空正常，改用阴影更合适。")
                    : L("曝光是线性的乘法；亮部还有余量时用曝光，亮部已经接近溢出时用阴影或曲线提亮暗部。"),
                CoachSuggestion(label: String(format: L("曝光 +%.2f EV"), ev), deltas: [.exposure: ev]))
        } else if a.p50 > 0.7, a.p5 > 0.25 || a.clippedHighlights > 0.02 {
            // High-key photos (white backgrounds, snow, bright skies) are bright on purpose and still
            // have real blacks (low P5). Only a washed-out frame or one losing its highlights is
            // overexposed, and the fix aims for bright-but-natural rather than middle grey.
            let ev = min(1.0, max(0.2, (log2(pow(a.p50 / 0.6, 2.2)) * 20).rounded() / 20))
            add("overexposed", .exposure, 0.3 + (a.p50 - 0.7) * 2, "sun.max", L("整体偏亮"),
                L("中间亮度达到 \(pct(a.p50))，画面显得发白\(numbers)。"),
                L("降低曝光会让所有亮度一起下降；如果只是天空太亮，改用高光更合适。"),
                CoachSuggestion(label: String(format: L("曝光 -%.2f EV"), ev), deltas: [.exposure: -ev]))
        }

        if !log, a.contrastSpan < 0.45, edits.curves.isIdentity, adj.contrast < 30 {
            let useCurve = level != .beginner
            add("flat", useCurve ? .curves : .contrast, 0.4 + (0.45 - a.contrastSpan), "circle.lefthalf.filled",
                L("画面偏灰、对比不足"),
                L("大部分亮度落在 \(pct(a.p5)) 到 \(pct(a.p95)) 之间，没有用满从黑到白的范围。"),
                useCurve ? L("S 曲线压暗暗部、提亮亮部，中间调几乎不变，比对比度滑块更可控。也可以分别拖动两端设定黑白点。")
                    : L("对比度会拉开明暗差距，让画面更通透。"),
                useCurve ? Concept.curves.demo : CoachSuggestion(label: L("对比度 +20"), deltas: [.contrast: 20]))
        }

        if a.neutralFraction > 0.03, abs(adj.warmth) < 15, abs(adj.tint) < 15 {
            let r = a.neutralRGB[0], g = a.neutralRGB[1], b = a.neutralRGB[2]
            let blueYellow = b - r, green = g - (r + b) / 2
            if abs(blueYellow) > 0.025 || abs(green) > 0.02 {
                let warmth = min(50, max(-50, (blueYellow / (0.16 * max(0.05, r + b)) * 100).rounded()))
                let tint = min(50, max(-50, (green / (0.12 * max(0.05, g) + 0.04 * (r + b) / 2) * 100).rounded()))
                var deltas: [AdjustmentParameter: Double] = [:]
                if abs(blueYellow) > 0.025 { deltas[.warmth] = warmth }
                if abs(green) > 0.02 { deltas[.tint] = tint }
                let direction = [abs(blueYellow) > 0.025 ? (blueYellow > 0 ? L("偏蓝（冷）") : L("偏黄（暖）")) : nil,
                                 abs(green) > 0.02 ? (green > 0 ? L("偏绿") : L("偏洋红")) : nil].compactMap { $0 }.joined(separator: L("、"))
                let label = deltas.keys.sorted { $0.rawValue > $1.rawValue }
                    .map { String(format: "%@ %+.0f", $0.title, deltas[$0]!) }.joined(separator: " · ")
                add("cast", .whiteBalance, 0.3 + (abs(blueYellow) + abs(green)) * 4, "thermometer.medium", L("画面\(direction)"),
                    L("接近灰色的区域（约 \(pct(a.neutralFraction))）并不是中性灰。")
                        + (level == .advanced ? String(format: L(" 中性区 RGB %.2f / %.2f / %.2f。"), r, g, b) : ""),
                    L("如果是日落、灯光等想保留的氛围，可以不改；想要还原真实颜色，就让这些灰色区域回到中性。"),
                    CoachSuggestion(label: label, deltas: deltas), influence: .neutral)
            }
        }

        if a.saturatedFraction > 0.05 {
            let reduce = adj.saturation > 10
            add("oversaturated", .vibrance, 0.3 + a.saturatedFraction * 3, "drop.fill", L("部分颜色过于饱和"),
                L("\(pct(a.saturatedFraction)) 的像素接近最大饱和度，细节会糊成一片色块。"),
                reduce ? L("你提高了饱和度。改用自然饱和度：它会放过已经很鲜艳的颜色，主要增强偏灰的颜色。")
                    : L("降低一点饱和度，再用自然饱和度补回整体的鲜艳感。"),
                CoachSuggestion(label: reduce ? L("饱和度 -\(Int(min(adj.saturation, 20))) · 自然饱和度 +15") : L("饱和度 -10 · 自然饱和度 +10"),
                                deltas: [.saturation: -(reduce ? min(adj.saturation, 20) : 10), .vibrance: reduce ? 15 : 10]),
                influence: .saturated)
        }

        if a.skyFraction > 0.1, edits.hsl[.blue, .luminance] == 0 {
            add("sky", .sky, 0.25 + a.skyFraction * 0.4, "cloud.sun", L("天空约占画面 \(pct(a.skyFraction))"),
                L("可以单独让蓝色更深、更有层次，而不影响地面和人物。"), Concept.sky.explanation(for: level),
                CoachSuggestion(label: L("蓝色明亮度 -20 · 饱和度 +10 · 青色明亮度 -10"),
                                hsl: [HSLChange(band: .blue, component: .luminance, delta: -20),
                                      HSLChange(band: .blue, component: .saturation, delta: 10),
                                      HSLChange(band: .aqua, component: .luminance, delta: -10)]),
                influence: .sky)
        }

        if let face = faces, face.skinFraction > 0.12 {
            let deviation = face.skinAngle - 123
            if abs(deviation) > 6, edits.hsl[.orange, .hue] == 0 {
                let shift = min(25, max(-25, (-deviation * 1.5).rounded()))
                add("skin", .skinTone, 0.45, "person.crop.circle", deviation < 0 ? L("肤色偏红") : L("肤色偏黄"),
                    L("在识别到的人脸区域里，肤色平均偏离肤色线约 \(String(format: "%.0f", abs(deviation)))°。"),
                    Concept.skinTone.explanation(for: level),
                    CoachSuggestion(label: String(format: L("橙色色相 %+.0f"), shift), hsl: [HSLChange(band: .orange, component: .hue, delta: shift)]),
                    influence: .skin)
            } else if profile.topics.contains(.portrait) || profile.topics.contains(.scopes) {
                add("skin-ok", .vectorscope, 0.15, "person.crop.circle.badge.checkmark", L("肤色在肤色线附近"),
                    L("人脸区域的肤色在矢量图上落在斜线附近。"), Concept.vectorscope.explanation(for: level),
                    CoachSuggestion(label: L("显示矢量图"), actions: [.showScope("vectorscope")]), influence: .skin)
            }
        }

        if let tilt, !isVideo, abs(tilt) > 0.6, abs(edits.degrees) < 0.05 {
            // Horizon detection also fires on aerial and top-down shots with no real horizon,
            // so small angles are offered as a check, not a verdict.
            let clear = abs(tilt) >= 1.5
            add("tilt", .straighten, clear ? 0.5 : 0.22, "level",
                String(format: clear ? L("地平线倾斜约 %.1f°") : L("可能倾斜约 %.1f°"), abs(tilt)),
                L("画面中识别到的水平参考线不是水平的。如果这是俯拍或画面里没有地平线，可以忽略这条。"),
                Concept.straighten.explanation(for: level),
                CoachSuggestion(label: L("自动拉直"), actions: [.straighten]))
        }

        if profile.topics.contains(.landscape), !isVideo, adj.sharpness == 0, a.contrastSpan > 0.4 {
            add("sharpen", .sharpening, 0.12, "scope", L("放大检查细节"),
                L("风光照片常需要一点锐化，但要在 100% 下判断。"), Concept.sharpening.explanation(for: level),
                CoachSuggestion(label: L("锐度 +25 并放大到 100%"), deltas: [.sharpness: 25], actions: [.zoomToActual]))
        }

        // Rank: photo relevance × interest × novelty; drop muted concepts.
        return list.filter { !profile.state($0.concept).muted }
            .map { insight -> (CoachInsight, Double) in
                let s = profile.state(insight.concept)
                var score = insight.severity * (1 + 0.5 * profile.interest(insight.concept))
                if profile.isLearned(insight.concept) { score *= 0.8 }
                if s.helpful > 0 { score *= 1.1 }
                if s.shown > 8, s.helpful == 0, s.tried == 0 { score *= 0.7 }
                return (insight, score)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// One-line interpretation of a scope for this photo.
    public static func reading(scope: String, _ a: PhotoAnalysis, level: LearningLevel) -> String {
        switch scope {
        case "waveform":
            var parts: [String] = []
            if let bright = a.brightCenter, a.brightFraction > 0.02 {
                let share = pct(a.brightFraction)
                parts.append(bright[0] < 0.35 ? L("最亮的部分在画面左侧（\(share)）")
                             : bright[0] > 0.65 ? L("最亮的部分在画面右侧（\(share)）") : L("最亮的部分在画面中部（\(share)）"))
            }
            if a.clippedHighlights > 0.004 { parts.append(L("顶部平线 = 过曝")) }
            if a.darkFraction > 0.15 { parts.append(L("暗部较多（\(pct(a.darkFraction))）")) }
            return parts.isEmpty ? L("亮度分布均匀，没有贴近顶部或底部。") : parts.joined(separator: " · ")
        case "parade":
            let r = a.channelMeans[0], g = a.channelMeans[1], b = a.channelMeans[2]
            if r - b > 0.05 { return L("红色分量整体高于蓝色：画面偏暖") + (level == .advanced ? String(format: L("（R %.2f / B %.2f）"), r, b) : "") }
            if b - r > 0.05 { return L("蓝色分量整体高于红色：画面偏冷") + (level == .advanced ? String(format: L("（B %.2f / R %.2f）"), b, r) : "") }
            if g - (r + b) / 2 > 0.04 { return L("绿色分量偏高：草木较多，或有偏绿") }
            return L("三个分量高度接近：色彩基本平衡。")
        case "vectorscope":
            let ranked = HueBand.allCases.sorted { a.hueShare[$0.rawValue] > a.hueShare[$1.rawValue] }
                .filter { a.hueShare[$0.rawValue] > 0.15 }.prefix(2).map(\.title)
            let saturation = a.meanSaturation < 0.15 ? L("整体饱和度低") : a.meanSaturation > 0.45 ? L("整体很鲜艳") : L("饱和度适中")
            let hues = ranked.map { AppLanguage.current == .chinese ? $0 : $0.lowercased() }.joined(separator: L("、"))
            var text = (ranked.isEmpty ? L("颜色较少") : L("颜色主要是\(hues)色")) + " · " + saturation
            if a.skinFraction > 0.04 { text += L(" · \(pct(a.skinFraction)) 在肤色线方向（暖色，不一定是皮肤）") }
            return text
        default:
            let tone = a.p50 < 0.3 ? L("偏暗") : a.p50 > 0.65 ? L("偏亮") : L("亮度适中")
            let span = a.contrastSpan < 0.45 ? L("对比偏低") : a.contrastSpan > 0.85 ? L("对比强") : L("对比适中")
            var parts = [tone, span]
            if a.clippedHighlights > 0.004 { parts.append(L("高光溢出 \(pct(a.clippedHighlights))")) }
            if a.clippedShadows > 0.01 { parts.append(L("暗部死黑 \(pct(a.clippedShadows))")) }
            if level == .advanced { parts.append(String(format: "P50 %.0f%%", a.p50 * 100)) }
            return parts.joined(separator: " · ")
        }
    }
}
