import Foundation
import MediaCore
import Observation

/// Finds exact duplicates, similar shots and bursts in the library (Library › Duplicates &
/// Similar). Fingerprints and file hashes are cached on disk by file size and date, so only
/// new or changed files are read again.
@MainActor
@Observable
final class SimilarityIndex {
    private(set) var groups: [PhotoGroup] = []
    /// Photos fingerprinted so far while a scan runs.
    private(set) var progress: (done: Int, total: Int)?
    private(set) var hasScanned = false
    /// Hashing files that share a size, to find exact duplicates.
    private(set) var checkingDuplicates = false

    private struct Record: Codable {
        var size: Int
        var modified: Date
        var print: PhotoFingerprint
    }
    private struct Digest: Codable {
        var size: Int
        var modified: Date
        var sha256: String
    }
    @ObservationIgnored private var cache: [String: Record] = [:]
    @ObservationIgnored private var digests: [String: Digest] = [:]
    @ObservationIgnored private let file: URL
    @ObservationIgnored private let digestFile: URL
    @ObservationIgnored private var task: Task<Void, Never>?

    init(root: URL) {
        file = root.appendingPathComponent("fingerprints.json")
        digestFile = root.appendingPathComponent("file-digests.json")
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([String: Record].self, from: data) {
            cache = saved
        }
        if let data = try? Data(contentsOf: digestFile), let saved = try? JSONDecoder().decode([String: Digest].self, from: data) {
            digests = saved
        }
    }

    /// Fingerprints any photos that need it, hashes files that share a size, then regroups.
    /// Videos only take part in the exact-duplicate check.
    func refresh(_ entries: [LibraryEntry], missing: Set<String>) {
        task?.cancel()
        let present = entries.filter { !missing.contains($0.id) }
        let known = cache
        task = Task { [weak self] in
            let all = await Task.detached(priority: .utility) {
                present.map { entry -> (LibraryEntry, Int, Date) in
                    let values = try? entry.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    return (entry, values?.fileSize ?? 0, values?.contentModificationDate ?? .distantPast)
                }
            }.value
            let stamps = all.filter { !$0.0.isVideo }
            let photos = stamps.map(\.0)
            let stale = stamps.filter { entry, size, modified in
                guard let record = known[entry.id] else { return true }
                return record.size != size || record.modified != modified
            }
            guard let self else { return }
            self.progress = stale.isEmpty ? nil : (0, stale.count)
            var fresh: [String: Record] = [:]
            // Four decoders at a time: each is a small, subsampled decode (a few ms).
            for start in stride(from: 0, to: stale.count, by: 32) {
                if Task.isCancelled { return }
                let chunk = Array(stale[start..<min(stale.count, start + 32)])
                let read = await withTaskGroup(of: (String, Record?).self) { group in
                    var results: [(String, Record?)] = []
                    var iterator = chunk.makeIterator()
                    func add(_ item: (LibraryEntry, Int, Date)) {
                        group.addTask(priority: .utility) {
                            (item.0.id, PhotoFingerprint.read(item.0.url).map { Record(size: item.1, modified: item.2, print: $0) })
                        }
                    }
                    for _ in 0..<4 { if let next = iterator.next() { add(next) } }
                    while let result = await group.next() {
                        results.append(result)
                        if let next = iterator.next() { add(next) }
                    }
                    return results
                }
                for (id, record) in read { if let record { fresh[id] = record } }
                self.progress = (min(stale.count, start + chunk.count), stale.count)
            }
            self.cache.merge(fresh) { $1 }
            let items = photos.compactMap { entry in
                self.cache[entry.id].map { SimilarPhotos.Item(id: entry.id, folder: entry.url.deletingLastPathComponent().path, print: $0.print) }
            }
            let cache = self.cache, file = self.file, knownDigests = self.digests, digestFile = self.digestFile
            self.progress = nil
            self.checkingDuplicates = true
            defer { self.checkingDuplicates = false }
            let (groups, digests) = await Task.detached(priority: .utility) { () -> ([PhotoGroup], [String: Digest]) in
                if !fresh.isEmpty, let data = try? JSONEncoder().encode(cache) { try? data.write(to: file, options: .atomic) }
                let modified = Dictionary(all.map { ($0.0.id, $0.2) }) { first, _ in first }
                var digests = knownDigests, hashed = false
                let duplicates = ExactDuplicates.groups(all.map { ExactDuplicates.File(id: $0.0.id, url: $0.0.url, size: $0.1) }) { file in
                    if let known = digests[file.id], known.size == file.size, known.modified == modified[file.id] { return known.sha256 }
                    guard let sha = ExactDuplicates.sha256(file.url) else { return nil }
                    digests[file.id] = Digest(size: file.size, modified: modified[file.id] ?? .distantPast, sha256: sha)
                    hashed = true
                    return sha
                }
                if hashed, !Task.isCancelled, let data = try? JSONEncoder().encode(digests) { try? data.write(to: digestFile, options: .atomic) }
                return (SimilarPhotos.groups(items, duplicates: duplicates), digests)
            }.value
            guard !Task.isCancelled else { return }
            self.digests = digests
            self.groups = groups
            self.hasScanned = true
        }
    }

    func capture(_ id: String) -> Date? { cache[id]?.print.captured }
}
