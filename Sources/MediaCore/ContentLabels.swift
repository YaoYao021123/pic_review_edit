// loc:ignore-file (the Chinese here is search vocabulary, not interface text)
import CoreGraphics
import Foundation
import ImageIO
import Vision

/// What a photo shows, from Vision's on-device scene classifier (about 1,300 English labels such
/// as "sky", "mountain", "dog"), so the library can be searched by content. Nothing leaves the Mac.
public enum ContentLabels {
    /// Labels below this confidence are left out.
    public static let minimumConfidence: Float = 0.12
    public static let maximumLabels = 16

    /// Labels for a photo file, most confident first; nil when it can't be read.
    public static func classify(_ url: URL) -> [String]? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 512]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return classify(image)
    }

    public static func classify(_ image: CGImage) -> [String] {
        let request = VNClassifyImageRequest()
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil else { return [] }
        return (request.results ?? []).filter { $0.confidence >= minimumConfidence }
            .sorted { $0.confidence > $1.confidence }.prefix(maximumLabels).map(\.identifier)
    }

    /// Whether labels answer a search: a Chinese word from the table below, or an English word
    /// that starts one of the label's words ("sun" finds "sunset_sunrise").
    public static func matches(_ labels: [String], query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty, !labels.isEmpty else { return false }
        if let wanted = chinese[query] ?? english[query] { return labels.contains(where: wanted.contains) }
        if query.unicodeScalars.contains(where: { $0.value > 0x2E7F }) {
            // A Chinese phrase not in the table: any table word it contains.
            let wanted = chinese.filter { query.contains($0.key) || $0.key.contains(query) }.flatMap(\.value)
            return labels.contains(where: wanted.contains)
        }
        let words = query.split(separator: " ").map(String.init)
        return labels.contains { label in
            let parts = label.split(separator: "_").map(String.init)
            return words.allSatisfy { word in parts.contains { $0.hasPrefix(word) } }
        }
    }

    /// A label as shown to people: Chinese from the table when the interface is Chinese.
    public static func displayName(_ label: String) -> String {
        if AppLanguage.current == .chinese, let name = chineseNames[label] { return name }
        return label.replacingOccurrences(of: "_", with: " ")
    }

    /// Everyday English words that aren't label names.
    static let english: [String: Set<String>] = [
        "sea": ["ocean", "shore", "beach", "water_body"], "person": ["people", "adult", "child", "baby", "teen", "crowd"],
        "people": ["people", "adult", "child", "baby", "teen", "crowd"], "kid": ["child"], "kids": ["child"],
        "pet": ["dog", "cat", "kitten", "adult_cat"], "sunset": ["sunset_sunrise"], "sunrise": ["sunset_sunrise"],
        "clouds": ["sky", "cloudy"], "trees": ["tree", "forest", "foliage"], "flowers": ["flower", "blossom"], "city": ["cityscape", "skyscraper", "street", "building"]
    ]

    /// Chinese search words and the labels they stand for.
    static let chinese: [String: Set<String>] = [
        "天空": ["sky", "blue_sky", "cloudy", "night_sky"], "蓝天": ["blue_sky", "sky"], "云": ["cloudy", "sky"], "云彩": ["cloudy", "sky"],
        "夜空": ["night_sky"], "星空": ["night_sky"], "夜景": ["night_sky", "cityscape"], "月亮": ["moon"], "太阳": ["sun", "sunset_sunrise"],
        "日落": ["sunset_sunrise"], "日出": ["sunset_sunrise"], "夕阳": ["sunset_sunrise"], "晚霞": ["sunset_sunrise"], "彩虹": ["rainbow"],
        "闪电": ["lightning"], "风暴": ["storm"], "雾": ["haze"], "霾": ["haze"],
        "山": ["mountain", "hill"], "山脉": ["mountain"], "山丘": ["hill"], "峡谷": ["canyon"], "悬崖": ["cliff"], "火山": ["volcano"],
        "冰川": ["glacier"], "沙漠": ["desert", "sand"], "沙滩": ["beach", "sand"], "海滩": ["beach"], "海": ["ocean", "shore", "beach"],
        "大海": ["ocean"], "海边": ["shore", "beach"], "海岸": ["shore"], "岛": ["island"], "港口": ["harbour"],
        "水": ["water", "water_body"], "河": ["river", "creek"], "河流": ["river", "creek"], "小溪": ["creek"], "湖": ["lake"], "湖泊": ["lake"],
        "瀑布": ["waterfall"], "湿地": ["wetland"], "雪": ["snow", "frozen"], "冰": ["ice", "frozen"], "冬天": ["snow", "winter_sport", "frozen"],
        "森林": ["forest", "tree", "foliage"], "树": ["tree", "forest"], "树林": ["forest"], "树叶": ["foliage"], "草": ["grass"], "草地": ["grass"],
        "草原": ["grass"], "花": ["flower", "blossom", "rose", "tulip", "sunflower"], "花朵": ["flower", "blossom"], "樱花": ["blossom", "cherry"],
        "玫瑰": ["rose"], "郁金香": ["tulip"], "向日葵": ["sunflower"], "植物": ["plant", "foliage", "flower"],
        "农田": ["farm", "agriculture", "rice_field", "wheat"], "稻田": ["rice_field"], "麦田": ["wheat"], "农场": ["farm"],
        "花园": ["garden"], "公园": ["park"], "户外": ["outdoor"], "室内": ["interior_room"],
        "人": ["people", "adult", "child", "baby", "teen", "crowd"], "人物": ["people", "adult", "child", "baby", "teen"], "人群": ["crowd"],
        "孩子": ["child", "baby"], "小孩": ["child", "baby"], "宝宝": ["baby"], "婴儿": ["baby"], "新娘": ["bride"], "婚礼": ["wedding", "bride"],
        "演唱会": ["concert"], "运动": ["sport"], "烟花": ["fireworks"],
        "动物": ["animal", "dog", "cat", "bird", "horse", "sheep", "fish", "insect"], "狗": ["dog"], "小狗": ["dog"],
        "猫": ["cat", "kitten", "adult_cat"], "小猫": ["kitten"], "宠物": ["dog", "cat", "kitten", "adult_cat"], "鸟": ["bird"],
        "马": ["horse"], "羊": ["sheep"], "鱼": ["fish"], "昆虫": ["insect"], "蝴蝶": ["butterfly"],
        "城市": ["cityscape", "skyscraper", "street", "building"], "街道": ["street", "road"], "街": ["street"], "路": ["road", "street"],
        "公路": ["road"], "桥": ["bridge"], "建筑": ["building", "structure", "skyscraper", "tower"], "高楼": ["skyscraper"], "塔": ["tower"],
        "城堡": ["castle"], "雕像": ["statue", "monument"], "纪念碑": ["monument"],
        "车": ["car", "vehicle"], "汽车": ["car"], "火车": ["train"], "飞机": ["airplane", "aircraft"], "船": ["boat"], "自行车": ["bicycle"],
        "摩托车": ["motorcycle"],
        "食物": ["food", "dessert", "bread", "fruit", "vegetable", "seafood"], "美食": ["food", "dessert", "seafood"], "吃的": ["food"],
        "甜点": ["dessert", "cake"], "蛋糕": ["cake"], "面包": ["bread"], "水果": ["fruit"], "蔬菜": ["vegetable"], "海鲜": ["seafood"],
        "饮料": ["drink", "coffee", "wine", "beer"], "咖啡": ["coffee"], "酒": ["wine", "beer"], "红酒": ["wine"], "啤酒": ["beer"],
        "书": ["book"], "文件": ["document"], "文档": ["document"], "截图": ["screenshot"], "截屏": ["screenshot"], "电脑": ["computer"],
        "手机": ["phone"], "玩具": ["toy"], "衣服": ["clothing"], "帽子": ["hat"], "灯": ["lamp", "light"], "标志": ["sign"]
    ]

    /// Names shown in the Info panel for the Chinese interface.
    static let chineseNames: [String: String] = {
        var names: [String: String] = [:]
        // The first (shortest) Chinese word for each label.
        for (word, labels) in chinese.sorted(by: { ($0.key.count, $0.key) < ($1.key.count, $1.key) }) {
            for label in labels where names[label] == nil { names[label] = word }
        }
        let exact: [String: String] = [
            "sky": "天空", "blue_sky": "蓝天", "cloudy": "多云", "sunset_sunrise": "日出日落", "outdoor": "户外", "water_body": "水域",
            "people": "人物", "adult": "成人", "teen": "少年", "structure": "建筑结构", "vehicle": "交通工具", "foliage": "树叶",
            "frozen": "冰雪", "adult_cat": "猫", "agriculture": "农业", "night_sky": "夜空", "interior_room": "室内"
        ]
        names.merge(exact) { _, new in new }
        return names
    }()
}
