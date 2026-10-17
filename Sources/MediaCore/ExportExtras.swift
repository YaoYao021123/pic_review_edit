import CoreImage
import CoreText
import Foundation
import ImageIO

/// A text watermark for exported photos (the Lucet web edition's export options): at most two
/// lines, drawn in the system font so Chinese and English both render.
public struct Watermark: Codable, Equatable, Sendable {
    public enum Position: String, Codable, CaseIterable, Sendable {
        case bottomRight, bottomLeft, bottomCenter, topRight, topLeft
        public var title: String {
            switch self {
            case .bottomRight: L("右下"); case .bottomLeft: L("左下"); case .bottomCenter: L("底部居中")
            case .topRight: L("右上"); case .topLeft: L("左上")
            }
        }
    }
    public enum Ink: String, Codable, CaseIterable, Sendable {
        case white, black
        public var title: String { self == .white ? L("白色") : L("黑色") }
    }
    public var text: String
    public var position = Position.bottomRight
    public var ink = Ink.white
    /// 0.05...1
    public var opacity = 0.65
    /// Text size as a percentage of the picture's short edge, 1...8.
    public var size = 2.8
    /// Distance from the edges as a percentage of the short edge, 0.5...10.
    public var margin = 3.0
    public var shadow = true

    public static let maximumLength = 80
    public init(text: String = "") { self.text = text }

    private enum CodingKeys: String, CodingKey { case text, position, ink, opacity, size, margin, shadow }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        text = try values.decodeIfPresent(String.self, forKey: .text) ?? ""
        position = (try? values.decodeIfPresent(Position.self, forKey: .position)) ?? .bottomRight
        ink = (try? values.decodeIfPresent(Ink.self, forKey: .ink)) ?? .white
        opacity = min(1, max(0.05, try values.decodeIfPresent(Double.self, forKey: .opacity) ?? 0.65))
        size = min(8, max(1, try values.decodeIfPresent(Double.self, forKey: .size) ?? 2.8))
        margin = min(10, max(0.5, try values.decodeIfPresent(Double.self, forKey: .margin) ?? 3))
        shadow = try values.decodeIfPresent(Bool.self, forKey: .shadow) ?? true
    }

    /// The text as drawn: no control characters, at most two lines and 80 characters.
    public var cleanedText: String {
        let lines = text.precomposedStringWithCanonicalMapping
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in String(line.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init)).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return String(lines.prefix(2).joined(separator: "\n").prefix(Self.maximumLength))
    }

    /// The picture with the text drawn on. Text that can't fit is shrunk; if it still can't,
    /// the picture is returned unchanged.
    public func drawn(over image: CIImage) -> CIImage {
        let text = cleanedText
        let extent = image.extent
        guard !text.isEmpty, extent.width >= 32, extent.height >= 32 else { return image }
        let short = min(extent.width, extent.height)
        let inset = max(1, short * min(10, max(0.5, margin)) / 100)
        let available = CGSize(width: extent.width - 2 * inset, height: extent.height - 2 * inset)
        var fontSize = max(8, short * min(8, max(1, size)) / 100)
        var measured = measure(text, fontSize: fontSize)
        if measured.size.width > available.width {
            fontSize = max(8, fontSize * available.width / measured.size.width * 0.98)
            measured = measure(text, fontSize: fontSize)
        }
        let pad = ceil(fontSize * 0.25)
        let stampSize = CGSize(width: ceil(measured.size.width + 2 * pad), height: ceil(measured.size.height + 2 * pad))
        guard stampSize.width - 2 * pad <= available.width, stampSize.height - 2 * pad <= available.height,
              let stamp = render(measured.frame, size: stampSize, pad: pad, fontSize: fontSize) else { return image }
        let x: CGFloat = switch position {
        case .bottomLeft, .topLeft: extent.minX + inset - pad
        case .bottomCenter: extent.midX - stampSize.width / 2
        case .bottomRight, .topRight: extent.maxX - inset - stampSize.width + pad
        }
        let y: CGFloat = position == .topLeft || position == .topRight ? extent.maxY - inset - stampSize.height + pad : extent.minY + inset - pad
        return CIImage(cgImage: stamp).transformed(by: .init(translationX: x.rounded(), y: y.rounded()))
            .composited(over: image).cropped(to: extent)
    }

    private func measure(_ text: String, fontSize: CGFloat) -> (frame: CTFramesetter, size: CGSize) {
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil) ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        var alignment: CTTextAlignment = switch position {
        case .bottomCenter: .center
        case .bottomRight, .topRight: .right
        case .bottomLeft, .topLeft: .left
        }
        var spacing = fontSize * 0.2
        let style = withUnsafeBytes(of: &alignment) { alignmentBytes in
            withUnsafeBytes(of: &spacing) { spacingBytes in
                let settings = [
                    CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: alignmentBytes.baseAddress!),
                    CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size, value: spacingBytes.baseAddress!)
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
        let color = ink == .white ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1) : CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        let attributed = CFAttributedStringCreate(nil, text as CFString, [
            kCTFontAttributeName: font, kCTForegroundColorAttributeName: color, kCTParagraphStyleAttributeName: style
        ] as CFDictionary)!
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil,
                                                                CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude), nil)
        return (framesetter, CGSize(width: ceil(size.width), height: ceil(size.height)))
    }

    private func render(_ framesetter: CTFramesetter, size: CGSize, pad: CGFloat, fontSize: CGFloat) -> CGImage? {
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setAlpha(min(1, max(0.05, opacity)))
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        if shadow {
            // A soft shadow in the opposite tone keeps the text readable on busy backgrounds.
            let shade = ink == .white ? CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.55) : CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.5)
            context.setShadow(offset: CGSize(width: fontSize * 0.03, height: -fontSize * 0.03), blur: fontSize * 0.12, color: shade)
        }
        let path = CGPath(rect: CGRect(x: pad, y: pad, width: size.width - 2 * pad, height: size.height - 2 * pad), transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil), context)
        context.endTransparencyLayer()
        return context.makeImage()
    }
}

/// File names for exports, from a pattern such as "{date}-{seq}-{name}".
public enum ExportNaming {
    public static let defaultPattern = "{name}"
    public static let tokens = ["name", "date", "seq", "width", "height"]

    public struct Values: Sendable {
        public var name: String
        /// yyyyMMdd
        public var day: String
        public var sequence: Int
        public var total: Int
        public var width: Int?
        public var height: Int?
        public init(name: String, day: String, sequence: Int, total: Int, width: Int? = nil, height: Int? = nil) {
            self.name = name; self.day = day; self.sequence = sequence; self.total = total; self.width = width; self.height = height
        }
    }

    /// Why a pattern can't be used, or nil if it's fine.
    public static func problem(_ pattern: String) -> String? {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 100 else { return L("文件名规则不能为空，最长 100 个字符。") }
        var literal = "", rest = Substring(trimmed)
        while let open = rest.firstIndex(of: "{") {
            literal += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else { return L("「{」没有对应的「}」。") }
            let token = String(rest[rest.index(after: open)..<close])
            guard tokens.contains(token) else { return L("不认识 {\(token)}，可用 {name} {date} {seq} {width} {height}。") }
            rest = rest[rest.index(after: close)...]
        }
        literal += rest
        if literal.contains(where: { "{}/\\:*?\"<>|".contains($0) }) || literal.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
            return L("文件名不能包含 / \\ : * ? \" < > | 等符号。")
        }
        return nil
    }

    /// The file name without extension. Falls back to the original name for a bad pattern.
    public static func name(_ pattern: String, _ values: Values) -> String {
        let pattern = problem(pattern) == nil ? pattern.trimmingCharacters(in: .whitespaces) : defaultPattern
        let digits = max(2, String(max(1, values.total)).count)
        let replacements = [
            "name": values.name, "date": values.day,
            "seq": String(repeating: "0", count: max(0, digits - String(values.sequence).count)) + String(values.sequence),
            "width": values.width.map(String.init) ?? "", "height": values.height.map(String.init) ?? ""
        ]
        // One pass, so a name that itself contains "{date}" stays as it is.
        var result = "", rest = Substring(pattern)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            result += rest[..<open]
            result += replacements[String(rest[rest.index(after: open)..<close])] ?? ""
            rest = rest[rest.index(after: close)...]
        }
        result += rest
        let safe = safeName(result)
        return safe.isEmpty ? (safeName(values.name).isEmpty ? "Lucet" : safeName(values.name)) : safe
    }

    /// Removes characters that file systems reject and trims stray separators.
    public static func safeName(_ value: String) -> String {
        let cleaned = String(value.precomposedStringWithCanonicalMapping.map { "/\\:*?\"<>|".contains($0) ? "_" : $0 })
            .unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return String(String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: CharacterSet(charactersIn: " ._-")).prefix(120))
    }

    /// The capture day from EXIF (yyyyMMdd), else the file's modification day.
    public static func day(of url: URL) -> String {
        if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let digits = original.prefix(10).filter(\.isNumber)
            if digits.count == 8 { return String(digits) }
        }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: modified)
    }
}
