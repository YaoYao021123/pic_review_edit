import Foundation
import Testing
@testable import MediaCore

struct ExactDuplicatesTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dupes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func testFindsIdenticalFilesAndOnlyHashesSizeMatches() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = Data((0..<5000).map { UInt8($0 % 251) })
        var sameSizeDifferent = photo; sameSizeDifferent[2500] ^= 0xff
        let files: [(String, Data)] = [("a.jpg", photo), ("b.mov", Data(repeating: 7, count: 900)), ("copy of a.jpg", photo),
                                       ("c.jpg", sameSizeDifferent), ("sub-a.jpg", photo), ("empty1", Data()), ("empty2", Data())]
        var list: [ExactDuplicates.File] = []
        for (name, data) in files {
            let url = root.appendingPathComponent(name)
            try data.write(to: url)
            list.append(.init(id: name, url: url, size: data.count))
        }
        var hashed: [String] = []
        let groups = ExactDuplicates.groups(list) { file in hashed.append(file.id); return ExactDuplicates.sha256(file.url) }
        #expect(groups == [["a.jpg", "copy of a.jpg", "sub-a.jpg"]])
        // b.mov has a unique size and empty files are ignored, so neither is read.
        #expect(Set(hashed) == ["a.jpg", "copy of a.jpg", "c.jpg", "sub-a.jpg"])
    }

    @Test func testSHA256MatchesAKnownValue() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("abc.txt")
        try Data("abc".utf8).write(to: url)
        #expect(ExactDuplicates.sha256(url) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(ExactDuplicates.sha256(root.appendingPathComponent("missing")) == nil)
    }

    @Test func testDuplicatesComeFirstAndCopiesStayOutOfSimilarGroups() {
        let print = PhotoFingerprint(hash: 0xF0F0_F0F0_0F0F_0F0F, color: [0.3, 0.4, 0.5], aspect: 1.5, captured: nil, camera: nil)
        var near = print; near.hash ^= 0b111
        let items = [("a", print), ("a-copy", print), ("b", near)].map { SimilarPhotos.Item(id: $0.0, folder: "/f", print: $0.1) }
        let groups = SimilarPhotos.groups(items, duplicates: [["a", "a-copy"], ["v1.mov", "v2.mov"]])
        #expect(groups == [PhotoGroup(kind: .duplicate, ids: ["a", "a-copy"]), PhotoGroup(kind: .duplicate, ids: ["v1.mov", "v2.mov"]),
                           PhotoGroup(kind: .similar, ids: ["a", "b"])])
    }
}
