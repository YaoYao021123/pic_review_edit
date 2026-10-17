import AppKit
import Foundation
import MediaCore
import Observation
import Photos
import SwiftUI

/// Reads the user's Photos library (iCloud Photos included) and copies originals into the
/// app's own folder, so they can be browsed and edited like any other file. Photos itself is never changed.
enum PhotosImporter {
    struct Album: Identifiable, Hashable, Sendable {
        let id: String
        let title: String
        let count: Int
    }

    static let allPhotosID = "all"

    static func authorize() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }

    /// "All photos", then the useful smart albums, then the user's own albums.
    static func albums() -> [Album] {
        var result: [Album] = []
        let all = PHAsset.fetchAssets(with: nil)
        result.append(Album(id: allPhotosID, title: L("全部照片"), count: all.count))
        let smartTypes: [PHAssetCollectionSubtype] = [.smartAlbumFavorites, .smartAlbumSelfPortraits, .smartAlbumScreenshots,
                                                      .smartAlbumLivePhotos, .smartAlbumVideos, .smartAlbumPanoramas]
        for type in smartTypes {
            PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: type, options: nil).enumerateObjects { collection, _, _ in
                let count = PHAsset.fetchAssets(in: collection, options: nil).count
                if count > 0 { result.append(Album(id: collection.localIdentifier, title: collection.localizedTitle ?? "", count: count)) }
            }
        }
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil).enumerateObjects { collection, _, _ in
            let count = PHAsset.fetchAssets(in: collection, options: nil).count
            if count > 0 { result.append(Album(id: collection.localIdentifier, title: collection.localizedTitle ?? "", count: count)) }
        }
        return result
    }

    static func assets(in albumID: String, newest limit: Int?) -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        if let limit { options.fetchLimit = limit }
        let fetched: PHFetchResult<PHAsset>
        if albumID == allPhotosID {
            fetched = PHAsset.fetchAssets(with: options)
        } else if let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject {
            fetched = PHAsset.fetchAssets(in: collection, options: options)
        } else {
            return []
        }
        var assets: [PHAsset] = []
        fetched.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    /// Every asset of an album as a lazy fetch result (it can hold tens of thousands).
    static func fetch(_ albumID: String, newestFirst: Bool) -> PHFetchResult<PHAsset>? {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: !newestFirst)]
        if albumID == allPhotosID { return PHAsset.fetchAssets(with: options) }
        guard let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject else { return nil }
        return PHAsset.fetchAssets(in: collection, options: options)
    }

    static var folder: URL { AppPaths.dataRoot.appendingPathComponent("PhotosImport", isDirectory: true) }

    /// Assets already copied in, so the browser can mark them.
    private static var importedFile: URL { folder.appendingPathComponent("imported.json") }
    static func importedIDs() -> Set<String> {
        guard let data = try? Data(contentsOf: importedFile), let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(ids)
    }
    static func remember(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let all = importedIDs().union(ids)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(all.sorted()).write(to: importedFile, options: .atomic)
    }

    /// Copies one asset's original (downloading it from iCloud if needed). Live Photos also bring
    /// their motion part, named alike so the library folds them into one item. Returns the still/video file.
    static func export(_ asset: PHAsset) async throws -> URL? {
        let resources = PHAssetResource.assetResources(for: asset)
        let main = resources.first { $0.type == .photo && asset.mediaType == .image }
            ?? resources.first { $0.type == .video && asset.mediaType == .video }
            ?? resources.first { $0.type == .fullSizePhoto }
        guard let main else { return nil }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The identifier prefix keeps IMG_0001 from different years apart and makes re-imports idempotent.
        let prefix = asset.localIdentifier.split(separator: "/").first.map { String($0.prefix(8)) } ?? UUID().uuidString.prefix(8).description
        let base = "\(prefix)-\((main.originalFilename as NSString).deletingPathExtension)"
        let target = folder.appendingPathComponent(base).appendingPathExtension((main.originalFilename as NSString).pathExtension)
        try await write(main, to: target)
        if let paired = resources.first(where: { $0.type == .pairedVideo }) {
            try await write(paired, to: folder.appendingPathComponent(base).appendingPathExtension("mov"))
        }
        return target
    }

    private static func write(_ resource: PHAssetResource, to url: URL) async throws {
        if FileManager.default.fileExists(atPath: url.path) { return }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        let partial = url.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: partial)
        try await PHAssetResourceManager.default().writeData(for: resource, toFile: partial, options: options)
        try FileManager.default.moveItem(at: partial, to: url)
    }
}

// MARK: - Sources

/// One photo or video in the browser.
struct PhotoItem: Identifiable, Hashable, Sendable {
    let id: String
    let isVideo: Bool
    let isLive: Bool
    let duration: Double
    let date: Date?
}

/// Where the browser's pictures come from: the Photos library, or (in snapshot runs) a folder,
/// so the screen can be checked without asking for Photos access.
@MainActor
protocol PhotoSource: AnyObject {
    func authorize() async -> Bool
    func albums() -> [PhotosImporter.Album]
    func show(album: String, newestFirst: Bool)
    var count: Int { get }
    func item(_ index: Int) -> PhotoItem?
    func image(_ id: String, size: CGSize) async -> NSImage?
    /// The chosen ids in the shown order (ids from other albums last).
    func ordered(_ ids: Set<String>) -> [String]
    /// Copies the original in; returns the file and whether it is a Live Photo still.
    func export(_ id: String) async throws -> (url: URL, live: Bool)?
}

@MainActor
final class PhotoKitSource: PhotoSource {
    private var assets: PHFetchResult<PHAsset>?
    private let images = PHCachingImageManager()

    func authorize() async -> Bool { await PhotosImporter.authorize() }
    func albums() -> [PhotosImporter.Album] { PhotosImporter.albums() }
    func show(album: String, newestFirst: Bool) { assets = PhotosImporter.fetch(album, newestFirst: newestFirst) }
    var count: Int { assets?.count ?? 0 }

    func item(_ index: Int) -> PhotoItem? {
        guard let assets, index >= 0, index < assets.count else { return nil }
        let asset = assets.object(at: index)
        return PhotoItem(id: asset.localIdentifier, isVideo: asset.mediaType == .video, isLive: asset.mediaSubtypes.contains(.photoLive),
                         duration: asset.duration, date: asset.creationDate)
    }

    private func asset(_ id: String) -> PHAsset? { PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject }

    func image(_ id: String, size: CGSize) async -> NSImage? {
        guard let asset = asset(id) else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            images.requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    func ordered(_ ids: Set<String>) -> [String] {
        var rest = ids, result: [String] = []
        assets?.enumerateObjects { asset, _, stop in
            if rest.remove(asset.localIdentifier) != nil { result.append(asset.localIdentifier) }
            if rest.isEmpty { stop.pointee = true }
        }
        return result + rest.sorted()
    }

    func export(_ id: String) async throws -> (url: URL, live: Bool)? {
        guard let asset = asset(id), let url = try await PhotosImporter.export(asset) else { return nil }
        return (url, asset.mediaSubtypes.contains(.photoLive))
    }
}

/// Snapshot runs: the pictures of a folder stand in for the Photos library.
@MainActor
final class FolderPhotoSource: PhotoSource {
    private let all: [URL]
    private var shown: [URL] = []
    init(_ folder: URL) {
        all = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["jpg", "jpeg", "heic", "png"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    func authorize() async -> Bool { true }
    func albums() -> [PhotosImporter.Album] { [.init(id: PhotosImporter.allPhotosID, title: L("全部照片"), count: all.count)] }
    func show(album: String, newestFirst: Bool) { shown = newestFirst ? all.reversed() : all }
    var count: Int { shown.count }
    func item(_ index: Int) -> PhotoItem? {
        guard shown.indices.contains(index) else { return nil }
        return PhotoItem(id: shown[index].path, isVideo: false, isLive: false, duration: 0, date: nil)
    }
    func image(_ id: String, size: CGSize) async -> NSImage? { NSImage(contentsOfFile: id) }
    func ordered(_ ids: Set<String>) -> [String] { shown.map(\.path).filter(ids.contains) }
    func export(_ id: String) async throws -> (url: URL, live: Bool)? { (URL(fileURLWithPath: id), false) }
}

// MARK: - Browser

/// The Photos library as a grid to choose from: click to select, ⇧-click for a range, double-click
/// to look closer, or "select the first N" for an exact number. Only the chosen photos are copied.
@MainActor
@Observable
final class PhotosBrowserModel {
    enum Phase: Equatable {
        case loading
        case denied
        case ready
        case importing(done: Int, total: Int)
    }

    private(set) var phase = Phase.loading
    private(set) var albums: [PhotosImporter.Album] = []
    var albumID = PhotosImporter.allPhotosID { didSet { if albumID != oldValue { reload() } } }
    var newestFirst = true { didSet { if newestFirst != oldValue { reload() } } }
    private(set) var count = 0
    /// Bumped when the shown album or order changes, so cells reload.
    private(set) var generation = 0
    private(set) var selection: Set<String> = []
    private(set) var imported: Set<String> = []
    /// Where a ⇧-click range starts.
    private(set) var anchor: Int?
    /// The photo shown large (double-click), by index.
    var previewIndex: Int?
    private(set) var failed = 0
    @ObservationIgnored let source: PhotoSource
    @ObservationIgnored private var task: Task<Void, Never>?

    init(source: PhotoSource) { self.source = source }

    func item(_ index: Int) -> PhotoItem? { source.item(index) }

    func load() async {
        guard await source.authorize() else { phase = .denied; return }
        albums = source.albums()
        imported = PhotosImporter.importedIDs()
        reload()
        phase = .ready
        // Snapshot runs: a selection or a preview to look at (GUANGJI_PHOTOS_SELECT / _PREVIEW).
        if DebugSnapshot.photosFolder != nil {
            let environment = ProcessInfo.processInfo.environment
            if let n = environment["GUANGJI_PHOTOS_SELECT"].flatMap(Int.init) { selectFirst(n) }
            if let i = environment["GUANGJI_PHOTOS_PREVIEW"].flatMap(Int.init) { previewIndex = i }
        }
    }

    private func reload() {
        source.show(album: albumID, newestFirst: newestFirst)
        count = source.count
        generation += 1
        anchor = nil
        previewIndex = nil
    }

    /// Click: toggle one. ⇧-click: select everything between the last click and this one.
    func click(_ index: Int, shift: Bool) {
        guard let item = item(index) else { return }
        if shift, let anchor {
            for i in min(anchor, index)...max(anchor, index) { if let id = source.item(i)?.id { selection.insert(id) } }
        } else if selection.contains(item.id) {
            selection.remove(item.id)
        } else {
            selection.insert(item.id)
        }
        anchor = index
    }

    func toggle(_ index: Int) {
        guard let id = item(index)?.id else { return }
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    /// Exactly the first `n` in the current order (newest or oldest first).
    func selectFirst(_ n: Int) {
        var chosen: Set<String> = []
        for i in 0..<min(max(0, n), count) { if let id = source.item(i)?.id { chosen.insert(id) } }
        selection = chosen
        anchor = nil
    }

    func selectAll() { selectFirst(count) }
    func clearSelection() { selection = []; anchor = nil }

    func start(into app: AppModel, finished: @escaping () -> Void) {
        let ids = source.ordered(selection)
        guard !ids.isEmpty else { return }
        failed = 0
        phase = .importing(done: 0, total: ids.count)
        let source = self.source
        task = Task {
            var files: [URL] = []
            var live: Set<String> = []
            var done: Set<String> = []
            for (index, id) in ids.enumerated() {
                if Task.isCancelled { break }
                do {
                    if let result = try await source.export(id) {
                        files.append(result.url)
                        done.insert(id)
                        if result.live { live.insert(result.url.standardizedFileURL.path) }
                    }
                } catch { failed += 1 }
                phase = .importing(done: index + 1, total: ids.count)
            }
            if source is PhotoKitSource { PhotosImporter.remember(done) }
            let added = app.library.add(files, liveCompanions: live)
            if let project = app.currentProjectID { app.addToProject(added, projectID: project) }
            app.library.filter = app.library.filter.cleared
            if let first = added.first { app.library.select(first) }
            app.mode = .browse
            var message = L("已从「照片」读入 \(added.count) 项。")
            if failed > 0 { message += L("有 \(failed) 项没能读取（可能还在 iCloud 上，或网络中断）。") }
            app.show(message)
            finished()
        }
    }

    func cancel() { task?.cancel() }
}

struct PhotosImportSheet: View {
    let app: AppModel
    @UIState private var model = PhotosBrowserModel(source: DebugSnapshot.photosFolder.map { FolderPhotoSource($0) } ?? PhotoKitSource())
    @UIState private var firstCount = 100
    @AppStorage("photosImport.cellSize") private var cellSize = 120.0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("从「照片」导入").font(.title3.weight(.semibold))
                    Text("选好要编辑的照片，光集会把原图（包括 iCloud 里的）复制一份进来。「照片」里的内容不会被改动或删除。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if case .importing = model.phase {} else {
                    // Esc closes the preview first when one is open.
                    Button("取消") { app.sheet = nil }.glassButton().keyboardShortcut(model.previewIndex == nil ? .cancelAction : nil)
                }
            }
            switch model.phase {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .denied:
                VStack(alignment: .leading, spacing: 10) {
                    Text("光集没有读取「照片」的权限。请在 系统设置 › 隐私与安全性 › 照片 中允许光集。")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("打开系统设置") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") { NSWorkspace.shared.open(url) }
                    }.glassButton()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .ready:
                browser
            case .importing(let done, let total):
                VStack(alignment: .leading, spacing: 10) {
                    ProgressView(value: Double(done), total: Double(max(1, total)))
                    Text("正在读取 \(done) / \(total)…").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    Text("iCloud 里的原图要先下载到这台 Mac，数量多时需要一些时间。").font(.caption).foregroundStyle(.secondary)
                    HStack { Spacer(); Button("停止") { model.cancel() }.glassButton() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .padding(20)
        .frame(width: 980, height: 700)
        .task {
            await model.load()
            // Snapshot runs: import right away, to check the whole path (GUANGJI_PHOTOS_IMPORT).
            if DebugSnapshot.photosFolder != nil, ProcessInfo.processInfo.environment["GUANGJI_PHOTOS_IMPORT"] != nil {
                model.start(into: app) { app.sheet = nil }
            }
        }
    }

    private var browser: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Picker("相簿", selection: $model.albumID) {
                    ForEach(model.albums) { album in Text(verbatim: "\(album.title) (\(album.count))").tag(album.id) }
                }
                .labelsHidden().fixedSize()
                // The same native segmented control as the other sheets (Export, Sync).
                Picker("排序", selection: $model.newestFirst) {
                    Text("最新在前").tag(true)
                    Text("最早在前").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                Image(systemName: "square.grid.3x3").foregroundStyle(.secondary)
                Slider(value: $cellSize, in: 80...220).frame(width: 110)
                Image(systemName: "square.grid.2x2").foregroundStyle(.secondary)
            }
            ZStack {
                grid
                if let index = model.previewIndex, let item = model.item(index) {
                    PhotosPreview(model: model, index: index, item: item)
                }
            }
            HStack(spacing: 8) {
                TextField("数量", value: $firstCount, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 72).monospacedDigit()
                    .onSubmit { model.selectFirst(firstCount) }
                Button(L("选择前 \(max(0, firstCount)) 张")) { model.selectFirst(firstCount) }
                    .glassButton().help(model.newestFirst ? L("从最新的一张开始数") : L("从最早的一张开始数"))
                Button("全选") { model.selectAll() }.buttonStyle(.borderless)
                Button("取消选择") { model.clearSelection() }.buttonStyle(.borderless).disabled(model.selection.isEmpty)
                Spacer()
                Text(L("已选 \(model.selection.count) 张")).foregroundStyle(.secondary).monospacedDigit()
                // No Return shortcut: typing a number and pressing Return must not start a big import.
                Button(L("导入 \(model.selection.count) 张")) { model.start(into: app) { app.sheet = nil } }
                    .primaryButton().disabled(model.selection.isEmpty)
            }
            Text("点按选择或取消，按住 ⇧ 点按选一段，连按两下放大看。iCloud 里的原图会在导入时下载。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: cellSize, maximum: cellSize * 1.3), spacing: 4)], spacing: 4) {
                ForEach(0..<model.count, id: \.self) { index in
                    if let item = model.item(index) {
                        PhotosCell(model: model, item: item, size: cellSize,
                                   selected: model.selection.contains(item.id), imported: model.imported.contains(item.id))
                            // One handler (no double-tap recognizer) keeps single clicks instant.
                            .onTapGesture {
                                if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { model.previewIndex = index; return }
                                model.click(index, shift: NSEvent.modifierFlags.contains(.shift))
                            }
                    }
                }
            }
            .padding(2)
            .id(model.generation)
        }
        .overlay {
            if model.count == 0 { Text("这个相簿里没有照片或视频。").foregroundStyle(.secondary) }
        }
    }
}

private struct PhotosCell: View {
    let model: PhotosBrowserModel
    let item: PhotoItem
    let size: Double
    let selected: Bool
    let imported: Bool
    @UIState private var image: NSImage?

    var body: some View {
        Color.white.opacity(0.05)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) { badges }
            .overlay(alignment: .topTrailing) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17)).symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, selected ? WorkbenchTheme.accent : Color.black.opacity(0.25))
                    .padding(5).opacity(selected ? 1 : 0.7)
            }
            .overlay { if selected { Rectangle().strokeBorder(WorkbenchTheme.accent, lineWidth: 3) } }
            .contentShape(Rectangle())
            .task(id: "\(item.id)#\(Int(size))") {
                image = await model.source.image(item.id, size: CGSize(width: size * 2, height: size * 2))
            }
            .help(item.date?.formatted(date: .abbreviated, time: .shortened) ?? "")
    }

    @ViewBuilder private var badges: some View {
        if item.isVideo || item.isLive || imported {
            HStack(spacing: 4) {
                if item.isVideo {
                    Label(String(format: "%d:%02d", Int(item.duration.rounded()) / 60, Int(item.duration.rounded()) % 60), systemImage: "video.fill")
                } else if item.isLive {
                    Image(systemName: "livephoto")
                }
                if imported { Image(systemName: "checkmark.seal").help("已经导入过") }
            }
            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 3))
            .padding(4)
        }
    }
}

/// Double-click: the photo large, with select / deselect and ← → to move on.
private struct PhotosPreview: View {
    let model: PhotosBrowserModel
    let index: Int
    let item: PhotoItem
    @UIState private var image: NSImage?

    var body: some View {
        let selected = model.selection.contains(item.id)
        VStack(spacing: 10) {
            ZStack {
                Color.black
                if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) } else { ProgressView() }
            }
            HStack(spacing: 10) {
                Button { move(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless).keyboardShortcut(.leftArrow, modifiers: []).disabled(index == 0)
                Text(item.date?.formatted(date: .long, time: .shortened) ?? "").foregroundStyle(.secondary)
                Button { move(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless).keyboardShortcut(.rightArrow, modifiers: []).disabled(index >= model.count - 1)
                Spacer()
                Button(selected ? L("取消选择这张") : L("选择这张")) { model.toggle(index) }
                    .glassButton().keyboardShortcut(.space, modifiers: [])
                Button("返回网格") { model.previewIndex = nil }.glassButton().keyboardShortcut(.cancelAction)
            }
        }
        .padding(10)
        .background(WorkbenchTheme.canvas)
        .task(id: item.id) {
            image = nil
            image = await model.source.image(item.id, size: CGSize(width: 1800, height: 1800))
        }
    }

    private func move(_ step: Int) {
        let next = index + step
        if next >= 0, next < model.count { model.previewIndex = next }
    }
}
