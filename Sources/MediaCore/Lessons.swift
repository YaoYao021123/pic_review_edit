import Foundation

/// Interactive lessons: short sequences of animated, hands-on scenes that run on the user's own
/// photo. Content is data here (testable); the app draws each `LessonScene`.
///
/// Teaching pattern for every lesson: a question worth answering → a picture of the mechanism →
/// try it yourself on your photo → check what you saw.
public struct Lesson: Identifiable, Sendable {
    public let id: String
    public let unit: LessonUnit
    public let title: String
    /// The question the lesson answers, in the learner's words.
    public let hook: String
    public let concept: Concept?
    public let steps: [LessonStep]
    public var minutes: Int { max(1, (steps.count + 1) / 2) }
}

public enum LessonUnit: String, CaseIterable, Sendable {
    case reading, tone, color, camera, video
    public var title: String {
        switch self {
        case .reading: L("看懂一张照片")
        case .tone: L("调整明暗")
        case .color: L("颜色")
        case .camera: L("拍摄的原理")
        case .video: L("视频与 Live")
        }
    }
}

public struct LessonStep: Sendable {
    public let scene: LessonScene
    public let title: String
    public let text: String
    public var question: LessonQuestion?
    public init(_ scene: LessonScene, _ title: String, _ text: String, question: LessonQuestion? = nil) {
        self.scene = scene; self.title = title; self.text = text; self.question = question
    }
}

/// Each scene is an interactive animation the app implements.
public enum LessonScene: String, Sendable, CaseIterable {
    // Reading a photo
    case pixelGrid, brightnessOnly, brightnessRelief, histogramBuild, histogramRead
    case zoneExplorer, keyStyles
    case clippingDemo
    // Tone
    case exposureVsBrightness, toneControl, curveAxes, curveShapes
    // Color
    case colorTemperature, whitePicker, colorThreeNumbers, hslBand
    // Camera
    case apertureOpening, depthOfField, shutterMotion, isoNoise, exposureTriangle, fieldOfView, perspective
    // Video
    case frameRate, shutterAngle, logCurve, logConversion
}

public struct LessonQuestion: Sendable {
    public enum Answer: Sendable, Equatable {
        case option(Int)
        /// The tone zone holding most of the open photo; options are the zone titles.
        case mainZone
    }
    public let prompt: String
    public let options: [String]
    public let answer: Answer
    /// Shown after answering, right or wrong.
    public let explanation: String

    public func correctIndex(zoneShares: [ToneZone: Double]) -> Int? {
        switch answer {
        case .option(let index): return index
        case .mainZone:
            guard let main = zoneShares.max(by: { $0.value < $1.value })?.key else { return nil }
            return options.firstIndex(of: main.title)
        }
    }
}

extension Lesson {
    public static let catalog: [Lesson] = [
        Lesson(id: "pixels-histogram", unit: .reading, title: L("直方图从哪里来"),
               hook: L("调色软件里那座「小山」到底是什么？"), concept: .histogram, steps: [
            LessonStep(.pixelGrid, L("照片由小格子组成"),
                       L("放大到足够大，任何照片都是一格一格的像素。每一格只有一种颜色。")),
            LessonStep(.brightnessOnly, L("先只看明暗"),
                       L("把颜色去掉，每一格只剩下一个亮度：0 是纯黑，100 是纯白。")),
            LessonStep(.brightnessRelief, L("亮度变成高度"),
                       L("把每一格的亮度当成高度：越亮的格子越高，越暗的越矮。照片就变成一片立体的柱子。拖动画面转一转，从侧面看看。")),
            LessonStep(.histogramBuild, L("按亮度排队"),
                       L("把所有格子按亮度从左到右排好，一样亮的叠在同一列。叠出来的形状，就是直方图。")),
            LessonStep(.histogramRead, L("读一读你的照片"),
                       L("山峰在哪里，照片的大部分就在哪里。左边高说明暗的多，右边高说明亮的多。"),
                       question: LessonQuestion(prompt: L("这张照片的大部分在哪个区域？"),
                                                options: ToneZone.allCases.map(\.title), answer: .mainZone,
                                                explanation: L("看直方图最高、最宽的那一段落在哪个区域。"))),
        ]),
        Lesson(id: "five-zones", unit: .reading, title: L("五个亮度区"),
               hook: L("「提亮暗部」里的暗部，到底是哪一部分？"), concept: .histogram, steps: [
            LessonStep(.zoneExplorer, L("把亮度分成五段"),
                       L("从左到右：最暗部、暗部、中间调、亮部、最亮部。点一个区域，照片上只保留属于它的地方。")),
            LessonStep(.keyStyles, L("亮和暗都可以是对的"),
                       L("白墙、雪景常常大部分在亮部，夜景大部分在暗部。直方图偏向一边不等于拍错了，要看你想要的感觉。"),
                       question: LessonQuestion(prompt: L("一张雪景的直方图大部分在右边，说明什么？"),
                                                options: [L("一定过曝了"), L("画面以亮的东西为主，可能正好合适"), L("相机坏了")],
                                                answer: .option(1),
                                                explanation: L("直方图只说明亮度怎么分布。只有贴着最右边、出现纯白时，才是真的丢了细节。"))),
        ]),
        Lesson(id: "clipping", unit: .reading, title: L("纯白和死黑"),
               hook: L("为什么有些天空怎么调都是一片白？"), concept: .clipping, steps: [
            LessonStep(.clippingDemo, L("亮到头，就没有细节了"),
                       L("拖动曝光。太亮的地方会变成纯白（标红），太暗的地方变成纯黑（标蓝）。直方图会在边上堆成一堵墙。"),
                       question: LessonQuestion(prompt: L("拍摄时天空已经是纯白，后期把高光往下拉会怎样？"),
                                                options: [L("能找回云的细节"), L("只会变成一片灰，细节找不回来"), L("会变成蓝色")],
                                                answer: .option(1),
                                                explanation: L("纯白意味着相机没有记录到那里的差别。拍的时候就要留住：降低一点曝光，或者打开 HDR。"))),
        ]),
        Lesson(id: "exposure-brightness", unit: .tone, title: L("曝光和亮度不一样"),
               hook: L("都是变亮，为什么有时候天空先「爆」掉？"), concept: .exposure, steps: [
            LessonStep(.exposureVsBrightness, L("一个乘，一个加"),
                       L("曝光像多进一倍的光：越亮的地方增加得越多。亮度更像整体往上挪一点。拖两个滑块，看右边的线怎么变。"),
                       question: LessonQuestion(prompt: L("照片的天空已经很亮、地面偏暗，想提亮地面，先用哪个？"),
                                                options: [L("曝光"), L("亮度或阴影")], answer: .option(1),
                                                explanation: L("曝光会让本来就亮的天空先溢出；亮度和阴影对亮部影响更小。"))),
        ]),
        Lesson(id: "tone-controls", unit: .tone, title: L("四个滑块各管一段"),
               hook: L("高光、阴影、白色、黑色有什么区别？"), concept: .highlights, steps: [
            LessonStep(.toneControl, L("每个滑块只动自己的那段"),
                       L("选一个滑块拖动。照片上亮起来的是它改变的地方，直方图上阴影部分是它作用的亮度范围。"),
                       question: LessonQuestion(prompt: L("逆光人像，脸太暗但背景的天空正好，应该动哪个？"),
                                                options: [L("高光"), L("阴影"), L("白色")], answer: .option(1),
                                                explanation: L("脸在暗部，阴影只提亮暗部，天空几乎不受影响。"))),
        ]),
        Lesson(id: "curves", unit: .tone, title: L("曲线：把旧亮度换成新亮度"),
               hook: L("曲线看起来很专业，其实只回答一个问题。"), concept: .curves, steps: [
            LessonStep(.curveAxes, L("横轴是原来，竖轴是现在"),
                       L("曲线竖在左边：横着是原来的亮度，竖着是现在的亮度，斜线上的每一点都在说「原来多亮，现在还是多亮」。右边是你照片的亮度地形，柱子的高度就是现在的亮度。拖动中间的点，看哪一段的柱子变了。")),
            LessonStep(.curveShapes, L("三种常见形状"),
                       L("整体往上 = 变亮，柱子整体升高；往下 = 变暗。S 形 = 暗的更暗、亮的更亮：矮的柱子更矮，高的更高，地形更陡，对比更强。点按钮切换，看地形、照片和直方图。"),
                       question: LessonQuestion(prompt: L("照片发灰、没有层次，最常用哪种曲线？"),
                                                options: [L("整体往上"), L("S 形"), L("整体往下")], answer: .option(1),
                                                explanation: L("S 形把直方图向两边拉开，画面就不再发灰。"))),
        ]),
        Lesson(id: "white-balance", unit: .color, title: L("白平衡与色温"),
               hook: L("为什么在室内拍的照片总是发黄？"), concept: .whiteBalance, steps: [
            LessonStep(.colorTemperature, L("光本身有颜色"),
                       L("烛光和灯泡偏橙，正午阳光接近白，阴天和树荫偏蓝。用开尔文（K）表示：数字越小越暖，越大越冷。选一种光，看同一张照片被染成什么样；右边的立方体里，整团颜色会偏离中间的灰色竖线。")),
            LessonStep(.whitePicker, L("找一个本该是白或灰的地方"),
                       L("白纸、白墙、灰色路面在真实世界里没有颜色。点照片里这样的地方，光集会把它校正成中性灰：你点的颜色回到灰色竖线上，整张照片的偏色就跟着消失。"),
                       question: LessonQuestion(prompt: L("暖黄灯光下拍的照片发黄，色温滑块该往哪边？"),
                                                options: [L("往暖（右）"), L("往冷（左）")], answer: .option(1),
                                                explanation: L("照片偏暖，就往冷的方向补回来。日落等想保留的暖色，可以只补一部分。"))),
        ]),
        Lesson(id: "hsl", unit: .color, title: L("HSL：只改一种颜色"),
               hook: L("怎样只让天空更蓝，而草地不变？"), concept: .hsl, steps: [
            LessonStep(.colorThreeNumbers, L("一个颜色，三个数"),
                       L("任何颜色都能用三个数找到：绕圈是色相（哪种颜色，红→黄→绿→青→蓝→紫），向外是饱和度（多鲜艳），向上是明亮度（多亮）。色轮就是这根圆柱的俯视图。拖动色轮上的点和下面的滑块。")),
            LessonStep(.hslBand, L("只挑出一种颜色"),
                       L("选一个色系，照片上只有这种颜色保持彩色。再拖它的色相、饱和度、明亮度：圆柱里这个色系的点会跟着移动，其他颜色不会动。"),
                       question: LessonQuestion(prompt: L("想让天空更深一点、草地不受影响，应该调什么？"),
                                                options: [L("整体饱和度"), L("蓝色的明亮度往下"), L("曝光往下")], answer: .option(1),
                                                explanation: L("HSL 只作用在选中的颜色上：压暗蓝色，天空变深，绿色的草地不变。"))),
        ]),
        Lesson(id: "aperture", unit: .camera, title: L("光圈：数字越大，开口越小"),
               hook: L("为什么 ƒ/4 比 ƒ/2.8 的光圈小？"), concept: nil, steps: [
            LessonStep(.apertureOpening, L("ƒ 后面是一个除数"),
                       L("光圈开口的直径 = 焦距 ÷ ƒ 值。所以 ƒ 值越大，开口越小，进来的光越少。ƒ 值每乘以 1.4，进光量减半。拖动滑块，再转着看：光圈挡住外圈的光，只有开口里的光能到达传感器。")),
            LessonStep(.depthOfField, L("开口还决定背景有多虚"),
                       L("开口大（ƒ 值小），空间里只有很薄的一层（半透明的板）是清楚的，前后的东西就虚；开口小，这一层变厚，前后都清楚。拖动看看，旁边是拍出来的样子。"),
                       question: LessonQuestion(prompt: L("想拍背景虚化的人像，应该怎么选？"),
                                                options: ["ƒ/1.8", "ƒ/11"], answer: .option(0),
                                                explanation: L("ƒ 值小 = 开口大 = 清楚的范围薄，背景更虚。"))),
        ]),
        Lesson(id: "exposure-triangle", unit: .camera, title: L("快门、ISO 和曝光三角"),
               hook: L("同样亮的照片，为什么有的糊、有的满是噪点？"), concept: .noise, steps: [
            LessonStep(.shutterMotion, L("快门：开多久"),
                       L("把时间想成纵深：越远越晚。一个球横穿画面，它的路线是一条斜线。快门开着的那段时间是一块玻璃板：板越厚，进来的光越多，球在板里走过的路也越长，落到照片上就是拖影。拖动快门，再转一转看看。手持拍摄，快门最好快于 1/焦距 秒。")),
            LessonStep(.isoNoise, L("ISO：把信号放大"),
                       L("传感器是一格一格的小格子，光一颗一颗落进去，每一格数一数收到多少。光不够时，ISO 把每一格的数字统统放大，照片就变亮。可光子是随机落下来的，相邻的格子数目总有差别，放大以后，这些差别就成了噪点。拖动 ISO，看柱子怎么变。")),
            LessonStep(.exposureTriangle, L("三个旋钮，同一个亮度"),
                       L("光圈、快门、ISO 是空间里的三条轴，每条轴都指向「更多光」，也各有代价：景深、拖影、噪点。那块斜板上的每个点，亮度都正好；点离开板，就是亮了或暗了几档。下面几种拍法都在板上，只是落在不同的位置。"),
                       question: LessonQuestion(prompt: L("夜里拍街景，照片太暗又不想糊，先试哪个？"),
                                                options: [L("把快门调慢很多"), L("开大光圈，再适当提高 ISO"), L("把 ISO 调到最低")],
                                                answer: .option(1),
                                                explanation: L("先用光圈多进光；还不够再提 ISO。快门太慢，手一抖就糊了。"))),
        ]),
        Lesson(id: "focal-length", unit: .camera, title: L("焦距：广角和长焦"),
               hook: L("同一个位置，为什么手机「2 倍」「5 倍」拍出的画面差这么多？"), concept: nil, steps: [
            LessonStep(.fieldOfView, L("焦距决定看多宽"),
                       L("焦距越短，看到的范围越宽（广角）；越长，越像望远镜（长焦）。拖动焦距：立体图里相机看到的是一个楔形，焦距越长楔形越窄，照片只装得下中间那一小块。手机上的「2 倍」「5 倍」，就是在换焦距。")),
            LessonStep(.perspective, L("长焦会把背景「拉近」"),
                       L("让人在画面里一样大，长焦需要站得更远（上面的图是从上往下看）。楔形变窄，同一座山占的画面比例就变大，背景显得又大又近；广角则背景很远、很小。这叫透视压缩。"),
                       question: LessonQuestion(prompt: L("在小房间里拍一大群人的合影，选哪种焦距？"),
                                                options: [L("广角（短焦距）"), L("长焦（长焦距）")], answer: .option(0),
                                                explanation: L("广角能在近距离装下更宽的画面；长焦要退得很远，小房间里做不到。"))),
        ]),
        Lesson(id: "frame-rate", unit: .video, title: L("帧率与快门"),
               hook: L("为什么视频的快门不能像拍照那样越快越好？"), concept: nil, steps: [
            LessonStep(.frameRate, L("视频是一秒很多张照片"),
                       L("24 帧就是每秒 24 张，60 帧是 60 张。帧越多，动作越顺滑；用 60 帧拍、按 24 帧放，就是 2.5 倍慢动作。")),
            LessonStep(.shutterAngle, L("每一帧要有一点拖影"),
                       L("快门太快，每帧都清清楚楚，连起来反而一跳一跳。常用做法是快门约等于 1/(2×帧率)：24 帧用 1/50，30 帧用 1/60（叫 180° 快门）。白天太亮时，要加 ND 滤镜减光，而不是提高快门。"),
                       question: LessonQuestion(prompt: L("用 25 帧拍视频，按这个原则快门该设多少？"),
                                                options: [L("1/25 秒"), L("1/50 秒"), L("1/1000 秒")], answer: .option(1),
                                                explanation: L("1/(2×25) = 1/50 秒，动作自然。1/1000 太快，画面会有卡顿感。"))),
        ]),
        Lesson(id: "log-lut", unit: .video, title: L("Log 素材与 LUT"),
               hook: L("D-Log 拍出来为什么灰蒙蒙的？"), concept: .logFootage, steps: [
            LessonStep(.logCurve, L("Log 把更多亮度装进同一个文件"),
                       L("普通模式（Rec.709）亮到一定程度就变成纯白。Log 用一条平缓的曲线，把很暗到很亮都记下来，代价是画面看起来又灰又淡。拖动「场景亮度」比较两条线。")),
            LessonStep(.logConversion, L("LUT 把它还原成正常画面"),
                       L("转换 LUT 是一张对照表：在颜色空间里放一张网，把网上每个点搬到新的位置。拖动强度，看这张网被拉开，照片的颜色和直方图一起铺开。注意：这里用你的照片模拟 Log 的样子。"),
                       question: LessonQuestion(prompt: L("拿到 D-Log 素材，第一步做什么？"),
                                                options: [L("直接拉高饱和度和对比度"), L("先套用这台相机对应的转换 LUT"), L("降低曝光")],
                                                answer: .option(1),
                                                explanation: L("先用厂商的转换 LUT 回到正常画面，再在上面调色；直接拉滑块很难还原准确的颜色。"))),
        ]),
    ]

    public static func lesson(_ id: String) -> Lesson? { catalog.first { $0.id == id } }
}
