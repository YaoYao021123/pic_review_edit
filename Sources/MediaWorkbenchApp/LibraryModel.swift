import Foundation
import MediaCore
import Observation
import UniformTypeIdentifiers

enum LibraryFlag: String, Codable, Sendable {
    case none, pick, reject
}

struct LibraryEntry: Codable, Hashable, Identifiable, Sendable {
    let url: URL
    let id: String
    let isVideo: Bool
    /// A same-name MOV sits next to this still (a likely Live Photo pair).
    var hasLiveCompanion: Bool
    var rating: Int
    var flag: LibraryFlag
    var added: Date

    init(url: URL, hasLiveCompanion: Bool = false) {
        self.url = url
        id = url.standardizedFileURL.path
        isVideo = LibraryFiles.isVideo(url)
        self.hasLiveCompanion = hasLiveCompanion
        rating = 0
        flag = .none
        added = Date()
    }

    var name: String { url.lastPathComponent }

    /// The same item at a new place (moved or renamed in Finder), keeping rating, flag and date.
    func relocated(to newURL: URL) -> LibraryEntry {
        var entry = LibraryEntry(url: newURL, hasLiveCompanion: hasLiveCompanion)
        entry.rating = rating; entry.flag = flag; entry.added = added
        return entry
    }

    private enum CodingKeys: String, CodingKey { case url, rating, flag, favorite, live, added }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        url = try values.decode(URL.self, forKey: .url)
        id = url.standardizedFileURL.path
        isVideo = LibraryFiles.isVideo(url)
        hasLiveCompanion = try values.decodeIfPresent(Bool.self, forKey: .live) ?? false
        rating = min(5, max(0, try values.decodeIfPresent(Int.self, forKey: .rating) ?? 0))
        // Version 1 libraries stored a favorite star; it becomes a pick flag.
        let favorite = try values.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        flag = try values.decodeIfPresent(LibraryFlag.self, forKey: .flag) ?? (favorite ? .pick : .none)
        added = try values.decodeIfPresent(Date.self, forKey: .added) ?? .distantPast
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(url, forKey: .url)
        try values.encode(rating, forKey: .rating)
        try values.encode(flag, forKey: .flag)
        try values.encode(hasLiveCompanion, forKey: .live)
        try values.encode(added, forKey: .added)
    }
}

struct LibraryFilter: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case all, photos, videos
        var title: String { switch self { case .all: L("全部类型"); case .photos: String(localized: "filter.photos", defaultValue: "照片"); case .videos: String(localized: "filter.videos", defaultValue: "视频") } } // loc:ignore (defaultValue)
    }
    enum Flags: String, CaseIterable, Sendable {
        case all, picked, hideRejected, rejected
        var title: String {
            switch self { case .all: L("全部标记"); case .picked: L("仅已选用"); case .hideRejected: L("隐藏已排除"); case .rejected: L("仅已排除") }
        }
    }
    var kind = Kind.all
    var minimumRating = 0
    var flags = Flags.all
    var search = ""
    /// The open project's photos; nil shows the whole library.
    var members: Set<String>?

    var isActive: Bool { isRefined || members != nil }
    /// Filters the person set (type, rating, flags, search), apart from the open project.
    var isRefined: Bool { kind != .all || minimumRating > 0 || flags != .all || !search.isEmpty }
    /// No filters, still inside the open project.
    var cleared: LibraryFilter { LibraryFilter(members: members) }

    func matches(_ entry: LibraryEntry) -> Bool {
        if let members, !members.contains(entry.id) { return false }
        switch kind {
        case .all: break
        case .photos: if entry.isVideo { return false }
        case .videos: if !entry.isVideo { return false }
        }
        if entry.rating < minimumRating { return false }
        switch flags {
        case .all: break
        case .picked: if entry.flag != .pick { return false }
        case .hideRejected: if entry.flag == .reject { return false }
        case .rejected: if entry.flag != .reject { return false }
        }
        return true
    }

    /// The search box finds file names and, for photos, what they show.
    func matches(_ entry: LibraryEntry, labels: [String]?) -> Bool {
        guard matches(entry) else { return false }
        guard !search.isEmpty else { return true }
        return entry.name.localizedCaseInsensitiveContains(search) || ContentLabels.matches(labels ?? [], query: search)
    }
}

/// The browsable collection: entries, filter, selection and the open item.
@MainActor
@Observable
final class LibraryModel {
    nonisolated static let limit = 20_000

    private(set) var entries: [LibraryEntry] = []
    private(set) var visible: [LibraryEntry] = []
    var filter = LibraryFilter() { didSet { if filter != oldValue { refreshVisible() } } }
    /// What each photo shows (ContentIndex), for searching by content.
    var contentLabels: [String: [String]] = [:] { didSet { if !filter.search.isEmpty { refreshVisible() } } }
    var selection: Set<String> = []
    /// The item open in the editor.
    var currentID: String?
    /// Anchor for shift-click range selection.
    @ObservationIgnored var anchorID: String?
    /// Items whose original file is no longer where the library expects it.
    private(set) var missing: Set<String> = []

    @ObservationIgnored private var positions: [String: Int] = [:]
    @ObservationIgnored private var visiblePositions: [String: Int] = [:]
    @ObservationIgnored private let file: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(root: URL) {
        file = root.appendingPathComponent("library.json")
        entries = Self.load(from: file)
        reindex()
    }

    // MARK: Lookup

    func entry(_ id: String?) -> LibraryEntry? {
        guard let id, let index = positions[id] else { return nil }
        return entries[index]
    }
    func visibleIndex(of id: String?) -> Int? { id.flatMap { visiblePositions[$0] } }
    var selectedEntries: [LibraryEntry] { entries.filter { selection.contains($0.id) } }
    /// Selection for batch actions, falling back to the open item.
    var actionTargets: [LibraryEntry] {
        let selected = selectedEntries
        if !selected.isEmpty { return selected }
        return entry(currentID).map { [$0] } ?? []
    }

    // MARK: Mutation

    /// Adds files in one pass (hash lookup, not a scan per file). Returns the ids, in order.
    @discardableResult
    func add(_ urls: [URL], liveCompanions: Set<String> = []) -> [String] {
        var ids: [String] = []
        var appended = false
        for url in urls {
            let id = url.standardizedFileURL.path
            ids.append(id)
            if let index = positions[id] {
                if liveCompanions.contains(id) { entries[index].hasLiveCompanion = true }
                continue
            }
            guard entries.count < Self.limit else { break }
            positions[id] = entries.count
            entries.append(LibraryEntry(url: url, hasLiveCompanion: liveCompanions.contains(id)))
            appended = true
        }
        if appended { refreshVisible() }
        scheduleSave()
        return ids
    }

    /// Checks which originals are gone (moved, renamed, deleted or on an unplugged drive).
    func checkMissing() async {
        let paths = entries.map(\.id)
        let gone = await Task.detached(priority: .utility) {
            Set(paths.filter { !FileManager.default.fileExists(atPath: $0) })
        }.value
        let current = Set(entries.map(\.id))
        let updated = gone.intersection(current)
        if updated != missing { missing = updated }
    }

    func markMissing(_ id: String, _ isMissing: Bool) {
        if isMissing { missing.insert(id) } else { missing.remove(id) }
    }

    /// Points an item at its new location. Returns the new id.
    @discardableResult
    func relink(_ id: String, to url: URL) -> String? {
        guard let index = positions[id] else { return nil }
        let entry = entries[index].relocated(to: url)
        missing.remove(id)
        if positions[entry.id] != nil {
            // Already in the library at the new place: keep that one.
            remove([id])
            return entry.id
        }
        entries[index] = entry
        if selection.remove(id) != nil { selection.insert(entry.id) }
        if currentID == id { currentID = entry.id }
        if anchorID == id { anchorID = entry.id }
        reindex()
        scheduleSave()
        return entry.id
    }

    func remove(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        missing.subtract(ids)
        entries.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        if let current = currentID, ids.contains(current) { currentID = nil }
        reindex()
        scheduleSave()
    }

    func setRating(_ rating: Int, for ids: [String]) {
        update(ids) { $0.rating = min(5, max(0, rating)) }
    }

    func setFlag(_ flag: LibraryFlag, for ids: [String]) {
        update(ids) { $0.flag = flag }
    }

    private func update(_ ids: [String], _ change: (inout LibraryEntry) -> Void) {
        var changed = false
        for id in ids {
            guard let index = positions[id] else { continue }
            change(&entries[index]); changed = true
        }
        guard changed else { return }
        refreshVisible()
        scheduleSave()
    }

    // MARK: Selection and navigation

    /// Finder-style click: plain selects one, ⌘ toggles, ⇧ extends from the anchor.
    func click(_ id: String, command: Bool, shift: Bool) {
        if shift, let anchor = anchorID, let from = visiblePositions[anchor], let to = visiblePositions[id] {
            let range = min(from, to)...max(from, to)
            let ids = visible[range].map(\.id)
            selection = command ? selection.union(ids) : Set(ids)
        } else if command {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchorID = id
        } else {
            selection = [id]
            anchorID = id
        }
    }

    func selectAll() {
        selection = Set(visible.map(\.id))
        if anchorID == nil || selection.contains(anchorID ?? "") == false { anchorID = visible.first?.id }
    }

    func select(_ id: String) {
        selection = [id]
        anchorID = id
    }

    /// The visible item `offset` steps from `id` (or from the selection), clamped to the ends.
    func neighbor(of id: String?, offset: Int) -> String? {
        guard !visible.isEmpty else { return nil }
        guard let id, let index = visiblePositions[id] else { return visible.first?.id }
        return visible[min(visible.count - 1, max(0, index + offset))].id
    }

    // MARK: Internals

    private func reindex() {
        positions = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($1.id, $0) })
        refreshVisible()
    }

    private func refreshVisible() {
        let filter = self.filter
        let labels = contentLabels
        visible = filter.isActive ? entries.filter { filter.matches($0, labels: labels[$0.id]) } : entries
        visiblePositions = Dictionary(uniqueKeysWithValues: visible.enumerated().map { ($1.id, $0) })
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel(); saveTask = nil
        let snapshot = entries, target = file
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: target, options: .atomic) }
        }
    }

    private static func load(from file: URL) -> [LibraryEntry] {
        if let data = try? Data(contentsOf: file), let entries = try? JSONDecoder().decode([LibraryEntry].self, from: data) {
            return Self.unique(entries)
        }
        // One-time migration from the prototype's UserDefaults list (skipped for isolated dev data folders).
        if ProcessInfo.processInfo.environment["GUANGJI_DATA_DIR"] == nil,
           let data = UserDefaults.standard.data(forKey: "guangji.library"),
           let entries = try? JSONDecoder().decode([LibraryEntry].self, from: data) {
            return Self.unique(entries)
        }
        return []
    }

    private static func unique(_ entries: [LibraryEntry]) -> [LibraryEntry] {
        var seen = Set<String>()
        return entries.filter { seen.insert($0.id).inserted }.prefix(limit).map { $0 }
    }
}

struct EditorSnapshot: Equatable, Sendable {
    var edits: MediaEdits
    var clip: ClipSettings?
    var hdrPreview: Bool
}

struct BatchChange: Sendable {
    let stamp: SourceStamp
    let companion: SourceStamp?
    let before: EditRecipe
    let after: EditRecipe
}

enum LibraryFiles {
    static let movieExtensions: Set<String> = ["mp4", "mov", "m4v", "mts", "m2ts", "avi"]
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "webp", "gif", "dng",
                                                   // Camera RAW, decoded by macOS's RAW engine.
                                                   "cr2", "cr3", "nef", "nrw", "arw", "raf", "orf", "rw2", "pef", "srw", "3fr", "iiq"]

    static func isVideo(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if movieExtensions.contains(ext) { return true }
        if imageExtensions.contains(ext) { return false }
        return UTType(filenameExtension: ext)?.conforms(to: .movie) == true
    }

    static func supported(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if movieExtensions.contains(ext) || imageExtensions.contains(ext) { return true }
        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie)
    }

    struct Collected: Sendable {
        var files: [URL]
        /// Stills with a same-name MOV; the MOV itself is folded into the still.
        var liveStills: Set<String>
        var truncated: Bool
    }

    /// Lists supported media, sorted by name. Same-name image + MOV pairs
    /// (iPhone Live Photos) are shown once, as the still.
    static func collect(_ urls: [URL], limit: Int = LibraryModel.limit) throws -> Collected {
        var files: [URL] = []
        var truncated = false
        outer: for url in urls {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if !isDirectory {
                if supported(url) { files.append(url) }
                continue
            }
            guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let file as URL in enumerator {
                try Task.checkCancellation()
                guard supported(file), (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                files.append(file)
                if files.count >= limit * 2 { truncated = true; break outer }
            }
        }
        var stills: [String: URL] = [:]
        for file in files where !isVideo(file) {
            stills[file.deletingPathExtension().standardizedFileURL.path.lowercased()] = file
        }
        var liveStills = Set<String>()
        var result: [URL] = []
        for file in files {
            if isVideo(file), file.pathExtension.lowercased() == "mov",
               let still = stills[file.deletingPathExtension().standardizedFileURL.path.lowercased()] {
                liveStills.insert(still.standardizedFileURL.path)
                continue
            }
            result.append(file)
        }
        result.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        if result.count > limit { result = Array(result.prefix(limit)); truncated = true }
        return Collected(files: result, liveStills: liveStills, truncated: truncated)
    }
}
