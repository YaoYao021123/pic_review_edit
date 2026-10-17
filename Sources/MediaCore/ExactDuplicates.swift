import CryptoKit
import Foundation

/// Byte-for-byte identical files (the same photo imported twice, a Finder copy, a card
/// re-imported into another folder). Sizes are compared first and only files that share a
/// size are hashed, so a typical library hashes almost nothing.
public enum ExactDuplicates {
    public struct File: Sendable {
        public let id: String
        public let url: URL
        public let size: Int
        public init(id: String, url: URL, size: Int) { self.id = id; self.url = url; self.size = size }
    }

    /// Files that could be duplicates: those sharing a size with another file.
    public static func candidates(_ files: [File]) -> [File] {
        Dictionary(grouping: files.filter { $0.size > 0 }, by: \.size).values.filter { $0.count > 1 }.flatMap { $0 }
    }

    /// Groups of two or more identical files, in the order given. `digest` returns a file's
    /// SHA-256 (or nil if it can't be read); files without one are left out.
    public static func groups(_ files: [File], digest: (File) -> String?) -> [[String]] {
        var byDigest: [String: [String]] = [:]
        var firstSeen: [String] = []
        for file in candidates(files) {
            guard let key = digest(file).map({ "\(file.size):\($0)" }) else { continue }
            if byDigest[key] == nil { firstSeen.append(key) }
            byDigest[key, default: []].append(file.id)
        }
        let order = Dictionary(uniqueKeysWithValues: files.enumerated().map { ($1.id, $0) })
        return firstSeen.compactMap { byDigest[$0] }.filter { $0.count > 1 }
            .map { $0.sorted { (order[$0] ?? 0) < (order[$1] ?? 0) } }
            .sorted { (order[$0[0]] ?? 0) < (order[$1[0]] ?? 0) }
    }

    /// SHA-256 of a file, read in 1 MB pieces so large videos don't fill memory.
    public static func sha256(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            // read(upToCount:) returns nil (or empty data) at the end of the file.
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
                if Task.isCancelled { return nil }
            }
        } catch { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
