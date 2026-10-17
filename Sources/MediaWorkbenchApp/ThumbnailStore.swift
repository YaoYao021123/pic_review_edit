import AVFoundation
import CoreImage
import ImageIO
import MediaCore
import Observation
import QuickLookThumbnailing

final class ThumbnailBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

/// Caps simultaneous decodes so fast scrolling never queues hundreds of jobs.
actor DecodeLimiter {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ limit: Int) { available = limit }
    func acquire() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if waiters.isEmpty { available += 1 } else { waiters.removeFirst().resume() }
    }
}

/// Library thumbnails: system QuickLook thumbnails, then the saved grade
/// (LUT, color, crop) applied so the grid shows what you will export.
@MainActor
@Observable
final class ThumbnailStore {
    /// Bumped per item when its recipe changes; cells reload when it moves.
    private(set) var versions: [String: Int] = [:]
    /// Video durations, filled lazily for badges.
    private(set) var durations: [String: Double] = [:]
    /// Items with visible edits, per context (the library, or one project's versions).
    private var editedByContext: [String: Set<String>] = [:]
    var edited: Set<String> { editedByContext[contextKey] ?? [] }
    /// The open project: its photos show their project version. Nil for the library's own edits.
    var project: Project? {
        didSet { if project?.id != oldValue?.id { contextKey = project?.id.uuidString ?? "" } }
    }
    /// Part of every cache key and of each cell's reload key.
    private(set) var contextKey = ""

    @ObservationIgnored private let cache = NSCache<NSString, ThumbnailBox>()
    @ObservationIgnored private let limiter = DecodeLimiter(4)
    @ObservationIgnored private let drafts: DraftStore

    init(drafts: DraftStore) {
        self.drafts = drafts
        cache.countLimit = 800
    }

    func version(_ id: String) -> Int { versions[id] ?? 0 }

    func cached(_ id: String) -> CGImage? {
        cache.object(forKey: key(id, version(id)) as NSString)?.image
    }

    /// Every photo of a project needs a new thumbnail (its look changed).
    func invalidate(_ ids: [String]) { for id in ids { versions[id, default: 0] += 1 } }

    func invalidate(_ id: String) {
        versions[id, default: 0] += 1
    }

    private func key(_ id: String, _ version: Int) -> String { "\(contextKey)#\(version)#\(id)" }

    func load(_ entry: LibraryEntry) async -> CGImage? {
        let version = version(entry.id)
        let cacheKey = key(entry.id, version) as NSString
        if let hit = cache.object(forKey: cacheKey) { return hit.image }
        await limiter.acquire()
        guard !Task.isCancelled else { await limiter.release(); return nil }
        let drafts = self.drafts, context = contextKey
        let projectRecipe = project?.recipe(for: entry.id)
        let url = entry.url, isVideo = entry.isVideo
        let result = await Task.detached(priority: .utility) { () -> (CGImage?, Double?, Bool) in
            let base = await Self.systemThumbnail(url, isVideo: isVideo)
            var duration: Double?
            if isVideo { duration = try? await AVURLAsset(url: url).load(.duration).seconds }
            guard let base else { return (nil, duration, false) }
            guard let recipe = projectRecipe ?? (try? drafts.load(url)) else { return (base, duration, false) }
            let lut = recipe.lut.flatMap { try? drafts.loadLUT($0) }
            var edits = MediaEdits(recipe: recipe, lut: lut)
            if !isVideo { edits.source = url }
            guard edits.hasGrade || edits.hasGeometry else { return (base, duration, false) }
            let graded = (try? ColorPipeline.grade(CIImage(cgImage: base), edits: edits))
                .flatMap { try? ColorPipeline.geometry($0, edits: edits) }
                .flatMap { try? ColorPipeline.sdrBitmap($0) }
            return (graded ?? base, duration, true)
        }.value
        await limiter.release()
        // Only publish real changes: every assignment notifies all observing rows.
        if let duration = result.1, duration.isFinite, durations[entry.id] != duration { durations[entry.id] = duration }
        if result.2 != (editedByContext[context]?.contains(entry.id) ?? false) {
            if result.2 { editedByContext[context, default: []].insert(entry.id) } else { editedByContext[context]?.remove(entry.id) }
        }
        guard let image = result.0 else { return nil }
        cache.setObject(ThumbnailBox(image), forKey: cacheKey)
        return image
    }

    private nonisolated static func systemThumbnail(_ url: URL, isVideo: Bool) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 240, height: 240), scale: 2,
                                                   representationTypes: .thumbnail)
        if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            return representation.cgImage
        }
        if isVideo {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 480)
            generator.dynamicRangePolicy = .forceSDR
            return try? await generator.image(at: .zero).image
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 480
        ] as CFDictionary)
    }
}
