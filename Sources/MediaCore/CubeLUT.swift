import Foundation

/// A 3D .cube table. Entries preserve file order (red changes fastest).
/// Parsing alone does not choose the input/output color space or perform Log conversion.
public struct CubeLUT: Sendable {
    public let title: String?
    public let dimension: Int
    public let domainMin: [Float]
    public let domainMax: [Float]
    public let rgb: [Float]

    public enum ParseError: Error, LocalizedError, Equatable {
        case invalid(line: Int, reason: String)
        public var errorDescription: String? {
            switch self {
            case let .invalid(line, reason): return L("LUT 第 \(line) 行：\(reason)")
            }
        }
    }

    public init(text: String) throws {
        try self.init(data: Data(text.utf8))
    }

    /// Parses raw file bytes. Numbers and keywords are ASCII; only the quoted
    /// TITLE may use another encoding (several vendor LUTs ship GBK titles).
    public init(data: Data) throws {
        var bytes = [UInt8](data)
        bytes.append(0) // strtof needs a terminator after the final number.
        var title: String?
        var size: Int?
        var minimum: [Float] = [0, 0, 0]
        var maximum: [Float] = [1, 1, 1]
        var values: [Float] = []
        var headers: Set<String> = []
        var line = 0
        var expected = 0
        let count = bytes.count - 1

        try bytes.withUnsafeBufferPointer { buffer in
            let base = buffer.baseAddress!
            var start = 0
            if count >= 3, buffer[0] == 0xEF, buffer[1] == 0xBB, buffer[2] == 0xBF { start = 3 }
            while start < count {
                line += 1
                var end = start
                while end < count, buffer[end] != 0x0A, buffer[end] != 0x0D { end += 1 }
                defer {
                    start = end
                    if start < count, buffer[start] == 0x0D { start += 1 }
                    if start < count, buffer[start] == 0x0A { start += 1 }
                }
                func fail(_ reason: String) -> ParseError { .invalid(line: line, reason: reason) }

                // Strip comments that are outside a quoted title.
                var contentEnd = start
                var quoted = false
                while contentEnd < end {
                    let byte = buffer[contentEnd]
                    if byte == 0x22 { quoted.toggle() }
                    if byte == 0x23, !quoted { break }
                    contentEnd += 1
                }
                var first = start
                while first < contentEnd, Self.isSpace(buffer[first]) { first += 1 }
                if first == contentEnd { continue }

                let lead = buffer[first]
                let isKeyword = (lead >= 0x41 && lead <= 0x5A) || (lead >= 0x61 && lead <= 0x7A) || lead == 0x5F
                if !isKeyword {
                    guard let size else { throw fail(L("色表前缺少 LUT_3D_SIZE")) }
                    if expected == 0 { expected = size * size * size * 3; values.reserveCapacity(expected) }
                    guard values.count < expected else { throw fail(L("色表条目过多")) }
                    var cursor = first
                    for _ in 0..<3 {
                        let pointer = UnsafeMutablePointer(mutating: base + cursor)
                        var next: UnsafeMutablePointer<CChar>?
                        let value = pointer.withMemoryRebound(to: CChar.self, capacity: 1) { strtof($0, &next) }
                        let consumed = next.map { UnsafeRawPointer($0) - UnsafeRawPointer(base) } ?? cursor
                        guard consumed > cursor, consumed <= contentEnd,
                              consumed == contentEnd || Self.isSpace(buffer[consumed]) else { throw fail(L("需要三个数值")) }
                        guard value.isFinite else { throw fail(L("数值必须有限")) }
                        values.append(value)
                        cursor = consumed
                    }
                    while cursor < contentEnd, Self.isSpace(buffer[cursor]) { cursor += 1 }
                    guard cursor == contentEnd else { throw fail(L("需要三个数值")) }
                    continue
                }

                var keyEnd = first
                while keyEnd < contentEnd, !Self.isSpace(buffer[keyEnd]) { keyEnd += 1 }
                let key = String(decoding: buffer[first..<keyEnd], as: UTF8.self)
                let rest = Array(buffer[keyEnd..<contentEnd])
                let tokens = Self.tokens(rest)
                func triple() throws -> [Float] {
                    guard tokens.count == 3 else { throw fail(L("需要三个数值")) }
                    return try tokens.map {
                        guard let value = Float($0), value.isFinite else { throw fail(L("数值必须有限")) }
                        return value
                    }
                }
                let known = ["TITLE", "LUT_3D_SIZE", "DOMAIN_MIN", "DOMAIN_MAX", "LUT_3D_INPUT_RANGE"]
                if known.contains(key) {
                    guard values.isEmpty else { throw fail(L("头信息必须在色表之前")) }
                    guard headers.insert(key).inserted else { throw fail(L("头信息重复：\(key)")) }
                }
                switch key {
                case "TITLE":
                    var body = rest[...]
                    while let byte = body.first, Self.isSpace(byte) { body = body.dropFirst() }
                    while let byte = body.last, Self.isSpace(byte) { body = body.dropLast() }
                    guard body.count >= 2, body.first == 0x22, body.last == 0x22 else { throw fail(L("TITLE 必须使用双引号")) }
                    title = Self.decodeTitle(Array(body.dropFirst().dropLast()))
                case "LUT_3D_SIZE":
                    guard tokens.count == 1, let parsed = Int(tokens[0]), (2...128).contains(parsed) else {
                        throw fail(L("当前支持 2–128 阶 3D LUT"))
                    }
                    size = parsed
                case "DOMAIN_MIN": minimum = try triple()
                case "DOMAIN_MAX": maximum = try triple()
                case "LUT_3D_INPUT_RANGE":
                    guard tokens.count == 2, let low = Float(tokens[0]), let high = Float(tokens[1]),
                          low.isFinite, high.isFinite else { throw fail(L("输入范围需要两个数值")) }
                    minimum = [low, low, low]; maximum = [high, high, high]
                case "LUT_1D_SIZE", "LUT_1D_INPUT_RANGE": throw fail(L("当前不支持 1D 或组合 LUT"))
                default:
                    // Unknown vendor keywords (for example LUT_IN_VIDEO_RANGE) are
                    // tolerated before the table; after it they indicate a malformed file.
                    guard values.isEmpty else { throw fail(L("色表中出现未知关键字：\(key)")) }
                }
            }
        }
        guard let size else { throw ParseError.invalid(line: 1, reason: L("缺少 LUT_3D_SIZE")) }
        guard zip(minimum, maximum).allSatisfy({ $0 < $1 }) else {
            throw ParseError.invalid(line: 1, reason: L("DOMAIN_MAX 必须逐通道大于 DOMAIN_MIN"))
        }
        guard values.count == size * size * size * 3 else {
            throw ParseError.invalid(line: max(1, line), reason: L("色表不完整，需要 \(size * size * size) 条 RGB"))
        }
        self.title = title
        dimension = size
        domainMin = minimum
        domainMax = maximum
        rgb = values
    }

    private static func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 }

    private static func tokens(_ bytes: [UInt8]) -> [String] {
        bytes.split(whereSeparator: isSpace).map { String(decoding: $0, as: UTF8.self) }
    }

    private static func decodeTitle(_ bytes: [UInt8]) -> String {
        if let text = String(bytes: bytes, encoding: .utf8) { return text }
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let text = String(bytes: bytes, encoding: gb18030) { return text }
        return String(bytes: bytes, encoding: .isoLatin1) ?? ""
    }

    /// Float32 RGBA data for CIColorCube. Non-default domains need a separate
    /// input normalization stage; this data must not silently bypass that stage.
    public func rgbaData() -> Data {
        var rgba = [Float](repeating: 1, count: dimension * dimension * dimension * 4)
        for entry in 0..<(rgb.count / 3) {
            rgba[entry * 4] = rgb[entry * 3]
            rgba[entry * 4 + 1] = rgb[entry * 3 + 1]
            rgba[entry * 4 + 2] = rgb[entry * 3 + 2]
        }
        return rgba.withUnsafeBytes { Data($0) }
    }

    /// Portable copy for export recipes; retains domain and exact Float values.
    public func textRepresentation() -> String {
        var lines: [String] = []
        lines.reserveCapacity(rgb.count / 3 + 4)
        if let title { lines.append("TITLE \"\(title.replacingOccurrences(of: "\"", with: "'"))\"") }
        lines.append("LUT_3D_SIZE \(dimension)")
        lines.append("DOMAIN_MIN " + domainMin.map(String.init(describing:)).joined(separator: " "))
        lines.append("DOMAIN_MAX " + domainMax.map(String.init(describing:)).joined(separator: " "))
        for index in stride(from: 0, to: rgb.count, by: 3) {
            lines.append("\(rgb[index]) \(rgb[index + 1]) \(rgb[index + 2])")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
