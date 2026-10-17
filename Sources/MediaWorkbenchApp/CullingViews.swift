import AppKit
import CoreImage
import ImageIO
import MediaCore
import SwiftUI

// Culling: compare similar shots side by side and keep the best (after the Lucet web
// edition's 选片 screen), plus the grouped "Similar & Bursts" view of the library.

/// Larger previews than the grid thumbnails, with each photo's saved edits applied.
enum CompareImageLoader {
    /// `maxPixel` 0 loads the full resolution (for the synchronized 100% view).
    nonisolated static func load(_ url: URL, drafts: DraftStore, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        var size = maxPixel
        if size == 0 {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
            size = max(properties[kCGImagePropertyPixelWidth] as? Int ?? 0, properties[kCGImagePropertyPixelHeight] as? Int ?? 0, 1)
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: size]
        guard let base = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        guard let recipe = try? drafts.load(url) else { return base }
        let lut = recipe.lut.flatMap { try? drafts.loadLUT($0) }
        var edits = MediaEdits(recipe: recipe, lut: lut)
        edits.source = url
        guard edits.hasGrade || edits.hasGeometry else { return base }
        return (try? ColorPipeline.grade(CIImage(cgImage: base), edits: edits))
            .flatMap { try? ColorPipeline.geometry($0, edits: edits) }
            .flatMap { try? ColorPipeline.sdrBitmap($0) } ?? base
    }
}

struct CullingSheet: View {
    let app: AppModel
    let ids: [String]
    @UIState private var active = 0
    @UIState private var zoomed = CullingSheet.debugZoomed
    /// Developer snapshots can open the sheet already zoomed.
    nonisolated(unsafe) static var debugZoomed = false
    /// Normalized point shown at the center of every photo while zoomed.
    @UIState private var focusPoint = CGPoint(x: 0.5, y: 0.5)
    @FocusState private var keyboard: Bool

    private var entries: [LibraryEntry] { ids.compactMap { app.library.entry($0) } }

    var body: some View {
        let entries = entries
        VStack(spacing: 0) {
            header(entries)
            WorkbenchTheme.hairline.frame(height: 1)
            grid(entries)
            WorkbenchTheme.hairline.frame(height: 1)
            Text("点按选择 · ← → 切换 · P 选用 · X 排除 · U 取消标记 · 1–5 评级 · Z 或双击放大到 100% · 放大时拖动可同步平移")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 8)
        }
        .frame(minWidth: 960, idealWidth: 1280, minHeight: 660, idealHeight: 840)
        .background(WorkbenchTheme.canvas)
        .focusable().focused($keyboard).focusEffectDisabled()
        .onAppear { keyboard = true }
        .onKeyPress { press in handle(press, entries) }
    }

    private func header(_ entries: [LibraryEntry]) -> some View {
        let picked = entries.filter { $0.flag == .pick }.count, rejected = entries.filter { $0.flag == .reject }.count
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("并排选片").font(.headline)
                Text(L("\(entries.count) 张 · 选用 \(picked) · 排除 \(rejected)")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(isOn: $zoomed) { Label("放大到 100%", systemImage: "plus.magnifyingglass") }
                .toggleStyle(.button).help("所有照片同时放大到同一个位置，比较清晰度（Z）")
            Button("只保留选中的这张") { keepOnly(entries) }
                .help("选用当前这张，排除这组里的其他照片")
                .disabled(entries.isEmpty)
            Button("完成") { app.sheet = nil }.keyboardShortcut(.cancelAction).primaryButton()
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private func grid(_ entries: [LibraryEntry]) -> some View {
        let columns = entries.count <= 3 ? max(1, entries.count) : entries.count == 4 ? 2 : entries.count <= 6 ? 3 : 4
        return ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns), spacing: 10) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    CullingCell(app: app, entry: entry, active: index == active, zoomed: zoomed, focusPoint: $focusPoint,
                                height: entries.count <= columns ? 560 : 340,
                                activate: { active = index; keyboard = true },
                                zoomAt: { point in focusPoint = point; zoomed = true; active = index })
                }
            }
            .padding(12)
        }
    }

    private func handle(_ press: KeyPress, _ entries: [LibraryEntry]) -> KeyPress.Result {
        guard !entries.isEmpty else { return .ignored }
        let current = entries[min(active, entries.count - 1)]
        switch press.key {
        case .leftArrow: active = (active - 1 + entries.count) % entries.count; return .handled
        case .rightArrow: active = (active + 1) % entries.count; return .handled
        default: break
        }
        switch press.characters.lowercased() {
        case "p": app.library.setFlag(current.flag == .pick ? .none : .pick, for: [current.id])
        case "x": app.library.setFlag(current.flag == .reject ? .none : .reject, for: [current.id])
        case "u": app.library.setFlag(.none, for: [current.id])
        case "z": zoomed.toggle()
        case "0", "1", "2", "3", "4", "5": app.library.setRating(Int(press.characters) ?? 0, for: [current.id])
        default: return .ignored
        }
        return .handled
    }

    private func keepOnly(_ entries: [LibraryEntry]) {
        guard !entries.isEmpty else { return }
        let keep = entries[min(active, entries.count - 1)].id
        app.library.setFlag(.pick, for: [keep])
        app.library.setFlag(.reject, for: entries.map(\.id).filter { $0 != keep })
        app.show(L("已选用 1 张，排除 \(entries.count - 1) 张。可在筛选里隐藏已排除的照片。"))
    }
}

private struct CullingCell: View {
    let app: AppModel
    let entry: LibraryEntry
    let active: Bool
    let zoomed: Bool
    @Binding var focusPoint: CGPoint
    let height: CGFloat
    let activate: () -> Void
    let zoomAt: (CGPoint) -> Void
    @UIState private var preview: CGImage?
    @UIState private var full: CGImage?
    @UIState private var dragStart: CGPoint?
    @Environment(\.displayScale) private var displayScale

    /// Capture times are the camera's local clock stored as UTC; show them as recorded.
    private static let captureFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.current.displayLocale
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                ZStack {
                    WorkbenchTheme.well
                    if zoomed, let full { actualPixels(full, in: geometry.size) }
                    else if let preview { Image(decorative: preview, scale: 1).resizable().scaledToFit() }
                    else { ProgressView().controlSize(.small) }
                }
                .clipped()
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture(count: 2).onEnded { value in zoomAt(normalized(value.location, in: geometry.size)) }
                    .exclusively(before: SpatialTapGesture().onEnded { _ in activate() }))
                .simultaneousGesture(zoomed ? panGesture(geometry.size) : nil)
            }
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(active ? WorkbenchTheme.selectionStroke : .clear, lineWidth: 2))
            .overlay(alignment: .topLeading) { FlagBadge(flag: entry.flag).font(.system(size: 15)).padding(8) }
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name).font(.callout.weight(active ? .semibold : .regular)).lineLimit(1).truncationMode(.middle)
                    if let date = app.similar.capture(entry.id) {
                        Text(Self.captureFormatter.string(from: date))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                RatingStars(rating: entry.rating, size: 10)
                Button { app.library.setFlag(entry.flag == .pick ? .none : .pick, for: [entry.id]) } label: {
                    Image(systemName: entry.flag == .pick ? "flag.fill" : "flag")
                }
                .buttonStyle(.borderless).foregroundStyle(entry.flag == .pick ? WorkbenchTheme.pick : .secondary).help("选用（P）")
                Button { app.library.setFlag(entry.flag == .reject ? .none : .reject, for: [entry.id]) } label: {
                    Image(systemName: entry.flag == .reject ? "xmark.circle.fill" : "xmark.circle")
                }
                .buttonStyle(.borderless).foregroundStyle(entry.flag == .reject ? WorkbenchTheme.reject : .secondary).help("排除（X）")
            }
            .opacity(entry.flag == .reject ? 0.6 : 1)
        }
        .task(id: entry.id) {
            let url = entry.url, drafts = app.drafts
            preview = await Task.detached(priority: .userInitiated) { CompareImageLoader.load(url, drafts: drafts, maxPixel: 1600) }.value
        }
        .task(id: zoomed) {
            guard zoomed, full == nil else { return }
            let url = entry.url, drafts = app.drafts
            full = await Task.detached(priority: .userInitiated) { CompareImageLoader.load(url, drafts: drafts, maxPixel: 0) }.value
        }
    }

    /// One image pixel per screen pixel, with `focusPoint` at the center of the cell.
    private func actualPixels(_ image: CGImage, in cell: CGSize) -> some View {
        let size = CGSize(width: CGFloat(image.width) / displayScale, height: CGFloat(image.height) / displayScale)
        return Image(decorative: image, scale: 1).resizable()
            .frame(width: size.width, height: size.height)
            .position(x: cell.width / 2 + (0.5 - focusPoint.x) * size.width, y: cell.height / 2 + (0.5 - focusPoint.y) * size.height)
    }

    /// Where a click lands in the photo, 0...1, for the fitted (not zoomed) preview.
    private func normalized(_ location: CGPoint, in cell: CGSize) -> CGPoint {
        guard let preview, !zoomed else { return focusPoint }
        let aspect = CGFloat(preview.width) / CGFloat(preview.height)
        let fitted = cell.width / cell.height > aspect ? CGSize(width: cell.height * aspect, height: cell.height)
                                                       : CGSize(width: cell.width, height: cell.width / aspect)
        let x = (location.x - (cell.width - fitted.width) / 2) / fitted.width
        let y = (location.y - (cell.height - fitted.height) / 2) / fitted.height
        return CGPoint(x: min(1, max(0, x)), y: min(1, max(0, y)))
    }

    private func panGesture(_ cell: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard let full else { return }
                if dragStart == nil { dragStart = focusPoint }
                let size = CGSize(width: CGFloat(full.width) / displayScale, height: CGFloat(full.height) / displayScale)
                let start = dragStart ?? focusPoint
                focusPoint = CGPoint(x: min(1, max(0, start.x - value.translation.width / size.width)),
                                     y: min(1, max(0, start.y - value.translation.height / size.height)))
            }
            .onEnded { _ in dragStart = nil }
    }
}

/// Browse view grouped into exact duplicates, similar shots and bursts.
struct GroupedBrowse: View {
    let app: AppModel
    let cellWidth: Double
    var library: LibraryModel { app.library }

    /// The copy worth keeping: picked, then rated, then edited, then the first imported.
    private func keeper(_ ids: [String]) -> String? {
        let entries = ids.compactMap(library.entry)
        let edited = app.thumbnails.edited
        return entries.max { a, b in
            let ka = (a.flag == .pick ? 1 : 0, a.rating, edited.contains(a.id) ? 1 : 0, -a.added.timeIntervalSinceReferenceDate)
            let kb = (b.flag == .pick ? 1 : 0, b.rating, edited.contains(b.id) ? 1 : 0, -b.added.timeIntervalSinceReferenceDate)
            return ka < kb
        }?.id
    }

    private func rejectCopies(_ ids: [String]) {
        guard let keep = keeper(ids) else { return }
        library.setFlag(.reject, for: ids.filter { $0 != keep })
        app.show(L("已排除 \(ids.count - 1) 个副本，保留 \(library.entry(keep)?.name ?? "")。"))
    }

    private func removeCopies(_ ids: [String]) {
        guard let keep = keeper(ids) else { return }
        let copies = Set(ids.filter { $0 != keep })
        if let current = library.currentID, copies.contains(current) { app.editor.close(); app.mode = .browse }
        library.remove(copies)
        app.show(L("已从素材库移除 \(copies.count) 个副本；硬盘上的文件未改动。"))
        app.similar.refresh(library.entries, missing: library.missing)
    }

    var body: some View {
        let visible = Set(library.visible.map(\.id))
        let groups = app.similar.groups.compactMap { group -> PhotoGroup? in
            let ids = group.ids.filter(visible.contains)
            return ids.count > 1 ? PhotoGroup(kind: group.kind, ids: ids) : nil
        }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if let progress = app.similar.progress {
                    HStack(spacing: 8) {
                        ProgressView(value: Double(progress.done), total: Double(max(1, progress.total))).frame(width: 160)
                        Text(L("正在比对照片 \(progress.done) / \(progress.total)…")).font(.callout).foregroundStyle(.secondary)
                    }
                } else if app.similar.checkingDuplicates {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在查找完全相同的文件…").font(.callout).foregroundStyle(.secondary)
                    }
                } else if groups.isEmpty, app.similar.hasScanned {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("没有找到重复、相似的照片或连拍").font(.title3)
                        Text("重复：内容完全相同的文件，比如同一张照片导入了两次。相似：同一场景、构图和颜色几乎一样的几张。连拍：同一台相机 2 秒内连续拍下的照片。视频只查找完全相同的文件。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.top, 40)
                }
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Label(group.kind.title, systemImage: group.kind.symbol)
                                .font(.callout.weight(.semibold))
                            Text(group.kind == .duplicate ? L("\(group.ids.count) 个文件") : L("\(group.ids.count) 张"))
                                .font(.callout).foregroundStyle(.secondary)
                            Spacer()
                            if group.kind == .duplicate {
                                Button("排除副本") { rejectCopies(group.ids) }.glassButton().controlSize(.small)
                                    .help("保留一份（已评分、已编辑或最早导入的那份），其余标为排除")
                                Button("从素材库移除副本") { removeCopies(group.ids) }.glassButton().controlSize(.small)
                                    .help("保留一份，其余从素材库移除；硬盘上的文件不会被删除或改动")
                            } else {
                                Button("并排比较") { app.sheet = .compare(group.ids) }.glassButton().controlSize(.small)
                            }
                        }
                        if group.kind == .duplicate {
                            Text(group.ids.compactMap { library.entry($0)?.url.deletingLastPathComponent().path }
                                .map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: "\n"))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(4).truncationMode(.middle).textSelection(.enabled)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: cellWidth, maximum: cellWidth * 1.4), spacing: 10)], alignment: .leading, spacing: 10) {
                            ForEach(group.ids, id: \.self) { id in
                                if let entry = library.entry(id) {
                                    GridCell(entry: entry, store: app.thumbnails, selected: library.selection.contains(id),
                                             current: id == library.currentID, missing: library.missing.contains(id))
                                        .onTapGesture {
                                            endTextEditing()
                                            if (NSApp.currentEvent?.clickCount ?? 1) >= 2, group.kind != .duplicate { app.sheet = .compare(group.ids); return }
                                            let flags = NSEvent.modifierFlags
                                            library.click(id, command: flags.contains(.command), shift: flags.contains(.shift))
                                        }
                                        .contextMenu { LibraryContextMenu(app: app, entry: entry) }
                                }
                            }
                        }
                    }
                    WorkbenchTheme.hairline.frame(height: 1)
                }
            }
            .padding(14)
        }
    }
}

extension PhotoGroup.Kind {
    var title: String {
        switch self { case .duplicate: L("完全相同"); case .similar: L("相似"); case .burst: L("连拍") }
    }
    var symbol: String {
        switch self { case .duplicate: "doc.on.doc"; case .similar: "square.on.square"; case .burst: "square.stack.3d.down.right" }
    }
}
