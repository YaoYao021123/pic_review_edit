import CoreGraphics
import Foundation
import ImageIO

// Near-duplicate and burst grouping for culling, ported from the Lucet web edition
// (Apache-2.0, `review.py`, algorithm "lucet-dct64-color-v1"): a 64-bit DCT perceptual
// hash plus the mean color and aspect ratio, clustered around anchors; bursts are runs of
// shots from one camera less than 2 seconds apart.

/// What a photo looks like at a glance, for finding near-duplicates.
public struct PhotoFingerprint: Codable, Sendable, Equatable {
    /// Bits of the 8×8 low-frequency DCT of a 32×32 gray thumbnail, above / below their median.
    public var hash: UInt64
    /// Mean sRGB color, 0...1.
    public var color: [Float]
    /// Width / height as displayed.
    public var aspect: Double
    public var captured: Date?
    public var camera: String?

    public init(hash: UInt64, color: [Float], aspect: Double, captured: Date? = nil, camera: String? = nil) {
        self.hash = hash; self.color = color; self.aspect = aspect; self.captured = captured; self.camera = camera
    }

    /// Reads a small thumbnail (decoded from the image, never the embedded preview, which can
    /// be letterboxed) and the capture time. Nil for files ImageIO can't decode.
    public static func read(_ url: URL) -> PhotoFingerprint? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 160,
                                        kCGImageSourceShouldCacheImmediately: false]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        guard var print = fingerprint(of: thumbnail) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        print.captured = captureDate(exif[kCGImagePropertyExifDateTimeOriginal] as? String,
                                     subsecond: exif[kCGImagePropertyExifSubsecTimeOriginal] as? String)
        print.camera = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
        return print
    }

    /// Hash, color and aspect of an already decoded image.
    public static func fingerprint(of image: CGImage) -> PhotoFingerprint? {
        guard image.width > 0, image.height > 0 else { return nil }
        let side = 32
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        var gray = [Double](repeating: 0, count: side * side)
        var sum = SIMD3<Double>(repeating: 0)
        for index in 0..<(side * side) {
            let r = Double(bytes[index * 4]) / 255, g = Double(bytes[index * 4 + 1]) / 255, b = Double(bytes[index * 4 + 2]) / 255
            gray[index] = 0.299 * r + 0.587 * g + 0.114 * b
            sum += SIMD3(r, g, b)
        }
        let mean = sum / Double(side * side)
        return PhotoFingerprint(hash: dctHash(gray, side: side), color: [Float(mean.x), Float(mean.y), Float(mean.z)],
                                aspect: Double(image.width) / Double(image.height))
    }

    /// Orthonormal 2D DCT-II of a side×side gray image, keeping the 8×8 lowest frequencies.
    /// Bit (u, v) is set when the coefficient is above the median of the 63 non-DC ones.
    static func dctHash(_ gray: [Double], side: Int) -> UInt64 {
        let n = Double(side)
        func scale(_ k: Int) -> Double { k == 0 ? (1 / n).squareRoot() : (2 / n).squareRoot() }
        var cosines = [[Double]](repeating: [Double](repeating: 0, count: side), count: 8)
        for k in 0..<8 { for x in 0..<side { cosines[k][x] = cos(Double(2 * x + 1) * Double(k) * .pi / (2 * n)) } }
        // Rows first: partial[y][u] = Σx f(x, y)·cos(u, x)
        var partial = [[Double]](repeating: [Double](repeating: 0, count: 8), count: side)
        for y in 0..<side { for u in 0..<8 {
            var total = 0.0
            for x in 0..<side { total += gray[y * side + x] * cosines[u][x] }
            partial[y][u] = total
        } }
        var low = [Double](repeating: 0, count: 64)
        for v in 0..<8 { for u in 0..<8 {
            var total = 0.0
            for y in 0..<side { total += partial[y][u] * cosines[v][y] }
            low[v * 8 + u] = total * scale(u) * scale(v)
        } }
        let rest = low.dropFirst().sorted()
        let median = (rest[30] + rest[31]) / 2
        var hash: UInt64 = 0
        for index in 1..<64 where low[index] > median { hash |= 1 << UInt64(63 - index) }
        return hash
    }

    static func captureDate(_ text: String?, subsecond: String?) -> Date? {
        guard let text else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let date = formatter.date(from: text) else { return nil }
        let fraction = subsecond.flatMap { Double("0." + $0.filter(\.isNumber)) } ?? 0
        return date.addingTimeInterval(fraction)
    }
}

/// A set of photos to compare and cull together.
public struct PhotoGroup: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case duplicate, similar, burst }
    public var kind: Kind
    public var ids: [String]
    public var id: String { ids.first ?? "" }
    public init(kind: Kind, ids: [String]) { self.kind = kind; self.ids = ids }
}

public enum SimilarPhotos {
    public struct Item: Sendable {
        public let id: String
        public let folder: String
        public let print: PhotoFingerprint
        public init(id: String, folder: String, print: PhotoFingerprint) { self.id = id; self.folder = folder; self.print = print }
    }

    public static func distance(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }

    /// Hash bits two shots of the same scene may differ by. The web edition uses 6 (true
    /// duplicates); frames of one scene taken moments apart measured 8–14 on real drone
    /// footage while unrelated photos were 16+, so 10 finds "several tries at one shot".
    public static let defaultDistance = 10

    /// Same framing, same picture, similar colors.
    public static func close(_ a: PhotoFingerprint, _ b: PhotoFingerprint, distance limit: Int = defaultDistance) -> Bool {
        guard a.aspect > 0, b.aspect > 0, abs(log(a.aspect / b.aspect)) <= 0.035 else { return false }
        guard distance(a.hash, b.hash) <= limit else { return false }
        return zip(a.color, b.color).reduce(0) { $0 + Double(($1.0 - $1.1) * ($1.0 - $1.1)) } <= 0.045
    }

    /// Groups of two or more similar photos. Each photo joins the closest existing anchor
    /// rather than chaining through intermediate shots, so a slow pan doesn't collapse into
    /// one huge group. (The web edition indexes 8-bit bands, which only guarantees matches
    /// up to distance 7; comparing against anchors directly is fast enough for a library:
    /// a few million XOR-popcounts for thousands of photos.)
    public static func similarGroups(_ items: [Item], distance limit: Int = defaultDistance) -> [[String]] {
        var anchors: [PhotoFingerprint] = []
        var groups: [[String]] = []
        for item in items {
            var best: (distance: Int, index: Int)?
            for (index, anchor) in anchors.enumerated() {
                let d = distance(anchor.hash, item.print.hash)
                guard d <= limit, d < (best?.distance ?? .max), close(item.print, anchor, distance: limit) else { continue }
                best = (d, index)
            }
            if let best {
                groups[best.index].append(item.id)
            } else {
                anchors.append(item.print); groups.append([item.id])
            }
        }
        return groups.filter { $0.count > 1 }
    }

    /// Runs of shots from the same camera in the same folder, each less than `gap` seconds
    /// after the previous one and at most `span` seconds from the first.
    public static func burstGroups(_ items: [Item], gap: TimeInterval = 2, span: TimeInterval = 15) -> [[String]] {
        var buckets: [String: [(Date, String)]] = [:]
        for item in items {
            guard let date = item.print.captured, let camera = item.print.camera, !camera.isEmpty else { continue }
            buckets[item.folder + "\u{1}" + camera, default: []].append((date, item.id))
        }
        var result: [[String]] = []
        for bucket in buckets.values {
            var run: [(Date, String)] = []
            for shot in bucket.sorted(by: { ($0.0, $0.1) < ($1.0, $1.1) }) {
                if let last = run.last, let first = run.first,
                   shot.0.timeIntervalSince(last.0) > gap || shot.0.timeIntervalSince(first.0) > span {
                    if run.count > 1 { result.append(run.map(\.1)) }
                    run = []
                }
                run.append(shot)
            }
            if run.count > 1 { result.append(run.map(\.1)) }
        }
        return result
    }

    /// Exact duplicates first, then similar and burst groups merged where they share photos,
    /// largest first. A merged group is "similar" if any of its parts was visually similar.
    /// Only the first copy of each duplicate takes part in the similar and burst groups, so
    /// identical files don't show up twice.
    public static func groups(_ items: [Item], duplicates: [[String]] = []) -> [PhotoGroup] {
        let copies = Set(duplicates.flatMap { $0.dropFirst() })
        let items = items.filter { !copies.contains($0.id) }
        let order = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) })
        var parent: [String: String] = [:]
        func root(_ id: String) -> String {
            var node = id
            while let next = parent[node], next != node { node = next }
            return node
        }
        var similar = Set<String>()
        let all = similarGroups(items).map { ($0, PhotoGroup.Kind.similar) } + burstGroups(items).map { ($0, PhotoGroup.Kind.burst) }
        for (ids, kind) in all {
            for id in ids where parent[id] == nil { parent[id] = id }
            for id in ids.dropFirst() { parent[root(id)] = root(ids[0]) }
            if kind == .similar { similar.formUnion(ids) }
        }
        var merged: [String: [String]] = [:]
        for id in parent.keys { merged[root(id), default: []].append(id) }
        return duplicates.filter { $0.count > 1 }.map { PhotoGroup(kind: .duplicate, ids: $0) } + merged.values
            .map { ids in
                let sorted = ids.sorted { (order[$0] ?? 0) < (order[$1] ?? 0) }
                return PhotoGroup(kind: sorted.contains(where: similar.contains) ? .similar : .burst, ids: sorted)
            }
            .sorted { $0.ids.count != $1.ids.count ? $0.ids.count > $1.ids.count : (order[$0.ids[0]] ?? 0) < (order[$1.ids[0]] ?? 0) }
    }
}
