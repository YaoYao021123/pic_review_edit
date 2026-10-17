import AVFoundation
import CoreImage
import MediaCore
import SwiftUI

struct CollageDraftPane: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    let duration: Double
    var start: Double
    var speed: Double
    let edits: MediaEdits
}

struct CollageSheet: View {
    let app: AppModel
    @UIState private var items: [CollageDraftPane] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("拼图 Live").font(.system(size: 20, weight: .semibold))
                    Text("单画面 / 双拼 / 三拼 · 每格独立运动 · 统一 3 秒")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { app.sheet = nil }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(spacing: 18) {
                    ForEach($items) { $item in
                        CollagePaneRow(item: $item,
                            canMoveUp: items.first?.id != item.id, canMoveDown: items.last?.id != item.id,
                            moveUp: { move(item.id, by: -1) }, moveDown: { move(item.id, by: 1) })
                    }
                }
            }.frame(maxHeight: 470)
            HStack(alignment: .center) {
                Text("从上到下等宽拼接；预览为各格中间帧。继承各素材已保存的调色与裁切。\n导出为静音 SDR，在后台进行。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("生成 \(items.count) 画面 Live") { app.exportCollage(items) }.primaryButton()
                    .keyboardShortcut(.defaultAction)
                    .disabled(items.isEmpty)
            }
        }.padding(24).frame(width: 780).onAppear { items = app.collageDrafts }
    }
    private func move(_ id: UUID, by delta: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }), items.indices.contains(index + delta) else { return }
        items.swapAt(index, index + delta)
    }
}
private struct CollagePaneRow: View {
    @Binding var item: CollageDraftPane
    let canMoveUp: Bool
    let canMoveDown: Bool
    let moveUp: () -> Void
    let moveDown: () -> Void
    private var speeds: [Double] { Array(Set([0.5, 1, 1.5, 2, 3, 4, item.speed])).filter { 3 * $0 <= item.duration }.sorted() }
    var body: some View {
        HStack(spacing: 18) {
            CollagePanePreview(pane: item).frame(width: 240, height: 136).clipped()
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(action: moveUp) { Image(systemName: "chevron.up") }.buttonStyle(.plain)
                        .disabled(!canMoveUp).help("向上移动画面")
                    Button(action: moveDown) { Image(systemName: "chevron.down") }.buttonStyle(.plain)
                        .disabled(!canMoveDown).help("向下移动画面")
                }
                HStack {
                    Text("起点").foregroundStyle(.secondary)
                    TextField("秒", value: $item.start, format: FloatingPointFormatStyle<Double>.number.precision(.fractionLength(2)))
                        .frame(width: 70).onChange(of: item.start) { normalizeStart() }
                    Text("秒").foregroundStyle(.secondary)
                    Spacer()
                    Text("速度").foregroundStyle(.secondary)
                    Picker("速度", selection: $item.speed) {
                        ForEach(speeds, id: \.self) { speed in Text(String(format: "%g×", speed)).tag(speed) }
                    }.labelsHidden().frame(width: 100).onChange(of: item.speed) { normalizeStart() }
                }
                Text(String(format: L("源片段 %.2f–%.2f 秒 → 3 秒 · %@"), item.start, item.start + 3 * item.speed,
                    item.edits.lut?.name ?? L("已保存的基础调色")))
                    .font(.caption).foregroundStyle(.secondary)
            }.font(.callout)
        }
    }
    private func normalizeStart() {
        let limit = max(0, item.duration - 3 * item.speed)
        item.start = item.start.isFinite ? min(max(0, item.start), limit) : 0
    }
}
private struct CollagePanePreview: View {
    let pane: CollageDraftPane
    @UIState private var bitmap: CGImage?
    var body: some View {
        ZStack {
            Color.black
            if let bitmap { Image(decorative: bitmap, scale: 1).resizable().scaledToFit() }
            else { ProgressView().controlSize(.small) }
        }.task(id: "\(pane.id)-\(pane.start)-\(pane.speed)") {
            do {
                try await Task.sleep(for: .milliseconds(180))
                let value = try await Task.detached(priority: .utility) {
                    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: pane.url))
                    generator.appliesPreferredTrackTransform = true; generator.dynamicRangePolicy = .forceSDR
                    generator.maximumSize = CGSize(width: 640, height: 640)
                    let image = try await generator.image(at: CMTime(seconds: pane.start + 1.5 * pane.speed, preferredTimescale: 60000)).image
                    let graded = try ColorPipeline.grade(CIImage(cgImage: image), edits: pane.edits)
                    return try ColorPipeline.sdrBitmap(try ColorPipeline.geometry(graded, edits: pane.edits))
                }.value
                try Task.checkCancellation(); bitmap = value
            } catch { /* Optional cover preview does not block export. */ }
        }
    }
}
