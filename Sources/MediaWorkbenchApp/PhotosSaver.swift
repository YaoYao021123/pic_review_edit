import AppKit
import Foundation
import MediaCore
import Photos

/// Adds finished exports to the Photos library (add-only access), so they sync to iPhone
/// through iCloud Photos. Live Photos are added as one Live asset (still + paired video).
enum PhotosSaver {
    enum Item: Sendable {
        case photo(URL)
        case video(URL)
        case live(image: URL, video: URL)
    }

    static func save(_ items: [Item]) async throws {
        guard !items.isEmpty else { return }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw VideoWorkError.failed(L("光集没有存入「照片」的权限。请在 系统设置 › 隐私与安全性 › 照片 中允许光集，或改为保存到文件夹。"))
        }
        try await PHPhotoLibrary.shared().performChanges {
            for item in items {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                switch item {
                case .photo(let url): request.addResource(with: .photo, fileURL: url, options: options)
                case .video(let url): request.addResource(with: .video, fileURL: url, options: options)
                case .live(let image, let video):
                    request.addResource(with: .photo, fileURL: image, options: options)
                    request.addResource(with: .pairedVideo, fileURL: video, options: options)
                }
            }
        }
    }

    /// Everything a finished export folder holds, as Photos items (Live folders become Live Photos).
    static func items(in folder: URL) -> [Item] {
        let fm = FileManager.default
        let children = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return children.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url -> Item? in
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let files = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                guard let image = files.first(where: { ["jpg", "jpeg", "heic"].contains($0.pathExtension.lowercased()) }),
                      let video = files.first(where: { $0.pathExtension.lowercased() == "mov" }) else { return nil }
                return .live(image: image, video: video)
            }
            switch url.pathExtension.lowercased() {
            case "jpg", "jpeg", "heic", "png": return .photo(url)
            case "mov", "mp4": return .video(url)
            default: return nil
            }
        }
    }

    /// A private scratch folder for exports headed to Photos; removed after import.
    static func stagingFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(L("光集-照片-\(UUID().uuidString)"), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @MainActor static func openPhotos() {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Photos") {
            NSWorkspace.shared.openApplication(at: app, configuration: .init())
        }
    }
}
