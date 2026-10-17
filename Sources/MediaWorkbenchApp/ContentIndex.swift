import Foundation
import MediaCore
import Observation

/// What each photo shows, for searching the library by content ("sky", "狗"). Labels come from
/// Vision on the Mac and are cached on disk by file size and date. Indexing starts the first
/// time someone searches, so a library that is never searched costs nothing.
@MainActor
@Observable
final class ContentIndex {
    private(set) var labels: [String: [String]] = [:]
    /// Photos labelled so far while indexing runs.
    private(set) var progress: (done: Int, total: Int)?
    /// Called with the labels whenever they change.
    @ObservationIgnored var onChange: (([String: [String]]) -> Void)?

    private struct Record: Codable {
        var size: Int
        var modified: Date
        var labels: [String]
    }
    @ObservationIgnored private var cache: [String: Record] = [:]
    @ObservationIgnored private let file: URL
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var indexed: Set<String> = []

    init(root: URL) {
        file = root.appendingPathComponent("content-labels.json")
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([String: Record].self, from: data) {
            cache = saved
            labels = saved.mapValues(\.labels)
        }
    }

    /// Labels photos that don't have labels yet. Cheap when nothing is new.
    func refresh(_ entries: [LibraryEntry], missing: Set<String>) {
        let photos = entries.filter { !$0.isVideo && !missing.contains($0.id) }
        let wanted = Set(photos.map(\.id))
        guard task == nil, !wanted.isSubset(of: indexed) else { return }
        let known = cache
        task = Task { [weak self] in
            let stale = await Task.detached(priority: .utility) {
                photos.compactMap { entry -> (LibraryEntry, Int, Date)? in
                    let values = try? entry.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    let size = values?.fileSize ?? 0, modified = values?.contentModificationDate ?? .distantPast
                    if let record = known[entry.id], record.size == size, record.modified == modified { return nil }
                    return (entry, size, modified)
                }
            }.value
            guard let self else { return }
            defer { self.task = nil; self.progress = nil; self.indexed.formUnion(wanted) }
            guard !stale.isEmpty else { return }
            self.progress = (0, stale.count)
            for start in stride(from: 0, to: stale.count, by: 24) {
                if Task.isCancelled { return }
                let chunk = Array(stale[start..<min(stale.count, start + 24)])
                let read = await withTaskGroup(of: (String, Record?).self) { group in
                    var results: [(String, Record?)] = []
                    var iterator = chunk.makeIterator()
                    func add(_ item: (LibraryEntry, Int, Date)) {
                        group.addTask(priority: .utility) {
                            (item.0.id, ContentLabels.classify(item.0.url).map { Record(size: item.1, modified: item.2, labels: $0) })
                        }
                    }
                    for _ in 0..<3 { if let next = iterator.next() { add(next) } }
                    while let result = await group.next() {
                        results.append(result)
                        if let next = iterator.next() { add(next) }
                    }
                    return results
                }
                for (id, record) in read { if let record { self.cache[id] = record; self.labels[id] = record.labels } }
                self.progress = (min(stale.count, start + chunk.count), stale.count)
                self.onChange?(self.labels)
            }
            let cache = self.cache, file = self.file
            await Task.detached(priority: .utility) {
                if let data = try? JSONEncoder().encode(cache) { try? data.write(to: file, options: .atomic) }
            }.value
        }
    }
}
