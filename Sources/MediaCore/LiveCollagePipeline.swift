import AVFoundation
import Foundation

public struct LiveCollagePane: Sendable {
    public let url: URL
    public let clip: ClipSettings
    public let edits: MediaEdits
    public init(url: URL, clip: ClipSettings, edits: MediaEdits) {
        self.url = url; self.clip = clip; self.edits = edits
    }
}

/// Equal landscape panels stacked into a portrait Live; each panel keeps its own time and grade.
public enum LiveCollagePipeline {
    public static func validate(_ panes: [LiveCollagePane]) throws -> Double {
        guard (1...3).contains(panes.count) else { throw VideoWorkError.failed(L("拼图需选择 1–3 个视频或 Live 动态资源。")) }
        let duration = panes[0].clip.outputDuration
        guard duration.isFinite, (0.5...3.001).contains(duration) else { throw VideoWorkError.failed(L("拼图 Live 输出需为 0.5–3 秒。")) }
        for pane in panes {
            guard abs(pane.clip.outputDuration - duration) < 0.001 else { throw VideoWorkError.failed(L("各画面变速后的时长必须一致。")) }
            guard !pane.edits.hdrEffect else { throw VideoWorkError.failed(L("当前拼图使用 SDR，请先关闭各画面的 HDR 效果。")) }
        }
        return duration
    }

    public static func export(_ panes: [LiveCollagePane], to directory: URL,
                              progress: (@Sendable (Double) -> Void)? = nil) async throws -> LivePhotoResources {
        let duration = try validate(panes)
        guard directory.isFileURL, !FileManager.default.fileExists(atPath: directory.path) else { throw VideoWorkError.outputExists }
        let staging = directory.deletingLastPathComponent().appendingPathComponent(".collage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        var rendered: [URL] = []
        for (i, pane) in panes.enumerated() {
            try Task.checkCancellation()
            let target = staging.appendingPathComponent("pane-\(i).mov")
            // Individual grading uses the same pipeline as the workbench; audio is muted by design.
            var clip = pane.clip; clip.originalVolume = 0; clip.musicURL = nil
            try await VideoPipeline.export(pane.url, to: target, clip: clip, edits: pane.edits)
            rendered.append(target); progress?(Double(i + 1) / Double(panes.count) * 0.65)
        }
        let movie: URL
        if panes.count == 1 { movie = rendered[0] }
        else {
            movie = staging.appendingPathComponent("stack.mov")
            try await stack(rendered, to: movie, duration: duration)
        }
        try Task.checkCancellation(); progress?(0.75)
        let output = staging.appendingPathComponent("resources")
        let cover = min(panes[0].clip.outputCover, duration - 1 / 30)
        let resources = try await LivePhotoPipeline.export(movie, to: output,
            clip: .init(start: 0, end: duration, cover: max(0, cover), originalVolume: 0), edits: .init())
        guard var recipe = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("recipe.json"))) as? [String: Any] else { throw VideoWorkError.failed(L("无法读取拼图配方。")) }
        recipe["type"] = "live-collage"; recipe["layout"] = "stacked"; recipe["audio"] = "muted"
        recipe["panes"] = try panes.enumerated().map { i, pane -> [String: Any] in
            if let lut = pane.edits.lut {
                try lut.cube.textRepresentation().write(to: output.appendingPathComponent("pane-\(i + 1)-lut.cube"), atomically: false, encoding: .utf8)
            }
            return ["source": pane.url.path, "start": pane.clip.start, "end": pane.clip.end,
                "speed": pane.clip.speed, "strength": pane.edits.strength, "lut": pane.edits.lut?.name ?? "none",
                "adjustments": pane.edits.adjustments.dictionary,
                "geometry": try JSONSerialization.jsonObject(with: JSONEncoder().encode(pane.edits.geometry)),
                "degrees": pane.edits.degrees]
        }
        try JSONSerialization.data(withJSONObject: recipe, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("recipe.json"), options: .atomic)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: output, to: directory); progress?(1)
        return .init(imageURL: directory.appendingPathComponent(resources.imageURL.lastPathComponent),
                     videoURL: directory.appendingPathComponent(resources.videoURL.lastPathComponent),
                     identifier: resources.identifier, coverSeconds: resources.coverSeconds)
    }

    private static func stack(_ urls: [URL], to output: URL, duration: Double) async throws {
        let composition = AVMutableComposition()
        let height: CGFloat = 608, width: CGFloat = 1080
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 60000))
        var layers: [AVVideoCompositionLayerInstruction] = []
        for (i, url) in urls.enumerated() {
            let asset = AVURLAsset(url: url)
            guard let source = try await asset.loadTracks(withMediaType: .video).first,
                  let target = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { throw VideoWorkError.failed(L("拼图缺少视频轨道。")) }
            try target.insertTimeRange(range, of: source, at: .zero)
            let size = try await source.load(.naturalSize), orientation = try await source.load(.preferredTransform)
            let bounds = CGRect(origin: .zero, size: size).applying(orientation)
            let factor = max(width / bounds.width, height / bounds.height)
            let transform = orientation.concatenating(.init(translationX: -bounds.minX, y: -bounds.minY))
                .concatenating(.init(scaleX: factor, y: factor))
                .concatenating(.init(translationX: (width - bounds.width * factor) / 2,
                                    y: CGFloat(i) * height + (height - bounds.height * factor) / 2))
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: target)
            layer.setTransform(transform, at: .zero)
            // Crop in source coordinates to prevent scaled panels from bleeding into neighbours.
            let canvas = CGRect(x: 0, y: CGFloat(i) * height, width: width, height: height)
            layer.setCropRectangle(canvas.applying(transform.inverted()), at: .zero)
            layers.append(layer)
        }
        let instruction = AVMutableVideoCompositionInstruction(); instruction.timeRange = range; instruction.layerInstructions = layers
        let video = AVMutableVideoComposition(); video.instructions = [instruction]
        video.renderSize = CGSize(width: width, height: height * CGFloat(urls.count))
        video.frameDuration = CMTime(value: 1, timescale: 30)
        video.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        video.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        video.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)
        else { throw VideoWorkError.failed(L("无法创建拼图导出。")) }
        session.videoComposition = video
        let handle = CollageExportHandle(session)
        try await withTaskCancellationHandler {
            try await session.export(to: output, as: .mov)
        } onCancel: { handle.session.cancelExport() }
        try Task.checkCancellation()
    }
}
private final class CollageExportHandle: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}
