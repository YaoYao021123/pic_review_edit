import AVFoundation
import CoreImage
import Foundation
import VideoToolbox

private final class ExportSessionHandle: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}

public enum VideoWorkError: Error, LocalizedError {
    case invalidRange, missingTrack, outputExists, failed(String)
    public var errorDescription: String? {
        switch self {
        case .invalidRange: L("片段起止时间或封面时间无效。")
        case .missingTrack: L("没有可用的视频或音频轨道。")
        case .outputExists: L("目标已存在，请选择新的文件名。")
        case .failed(let detail): L("媒体处理失败：\(detail)")
        }
    }
}

public struct ClipSettings: Sendable, Codable, Equatable {
    public var start: Double
    public var end: Double
    public var cover: Double
    public var originalVolume: Float
    public var musicURL: URL?
    public var musicVolume: Float
    public var speed: Double
    public init(start: Double, end: Double, cover: Double, originalVolume: Float = 1,
                musicURL: URL? = nil, musicVolume: Float = 0.5, speed: Double = 1) {
        self.start = start; self.end = end; self.cover = cover
        self.originalVolume = originalVolume; self.musicURL = musicURL; self.musicVolume = musicVolume
        self.speed = speed
    }
    public var sourceDuration: Double { end - start }
    public var outputDuration: Double { sourceDuration / speed }
    public var outputCover: Double { (cover - start) / speed }
    /// Move the selection as one unit, keeping its length and relative cover.
    public func shifted(by delta: Double, duration: Double) -> ClipSettings {
        guard delta.isFinite, duration.isFinite, start.isFinite, end.isFinite,
              sourceDuration > 0, duration >= sourceDuration else { return self }
        let actual = min(duration - end, max(-start, delta))
        var result = self
        result.start += actual; result.end += actual; result.cover += actual
        return result
    }
    public func validate(duration: Double, live: Bool = false) throws {
        guard duration.isFinite, start.isFinite, end.isFinite, cover.isFinite,
              start >= 0, end <= duration + 0.001, end - start >= 0.1,
              cover >= start, cover < end,
              originalVolume.isFinite, musicVolume.isFinite,
              (0...1).contains(originalVolume), (0...1).contains(musicVolume),
              speed.isFinite, (0.5...4).contains(speed),
              !live || (outputDuration >= 0.5 && outputDuration <= 3.001) else { throw VideoWorkError.invalidRange }
    }
}

public struct PreparedVideo {
    public let asset: AVMutableComposition
    public let videoComposition: AVVideoComposition?
    public let audioMix: AVAudioMix
    public let duration: Double
}

public enum VideoCodecChoice: String, Codable, CaseIterable, Sendable {
    case h264, hevc
    public var title: String { self == .h264 ? L("H.264（兼容）") : L("HEVC（更小）") }
    var preset: String { self == .h264 ? AVAssetExportPresetHighestQuality : AVAssetExportPresetHEVCHighestQuality }
}

public enum VideoPipeline {
    /// Previews and exports the same selected range, geometry, LUT and audio mix.
    public static func prepare(_ url: URL, clip: ClipSettings, edits: MediaEdits,
                               sdr: Bool, preview: VideoPreviewState? = nil) async throws -> PreparedVideo {
        let source = AVURLAsset(url: url)
        let duration = try await source.load(.duration).seconds
        try clip.validate(duration: duration)
        guard let sourceVideo = try await source.loadTracks(withMediaType: .video).first else { throw VideoWorkError.missingTrack }
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VideoWorkError.missingTrack
        }
        let range = CMTimeRange(start: CMTime(seconds: clip.start, preferredTimescale: 600),
                                duration: CMTime(seconds: clip.end - clip.start, preferredTimescale: 600))
        try video.insertTimeRange(range, of: sourceVideo, at: .zero)
        video.preferredTransform = try await sourceVideo.load(.preferredTransform)
        var mixInputs: [AVMutableAudioMixInputParameters] = []
        for sourceAudio in try await source.loadTracks(withMediaType: .audio) {
            guard let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            // Some audio tracks finish earlier than the video.
            let audioRange = try await sourceAudio.load(.timeRange)
            let intersection = CMTimeRangeGetIntersection(range, otherRange: audioRange)
            if intersection.duration.seconds > 0 {
                try audio.insertTimeRange(intersection, of: sourceAudio, at: intersection.start - range.start)
                let mix = AVMutableAudioMixInputParameters(track: audio)
                mix.setVolume(clip.originalVolume, at: .zero); mixInputs.append(mix)
            }
        }
        let outputDuration = CMTime(seconds: clip.outputDuration, preferredTimescale: 60000)
        if clip.speed != 1 {
            // Scale camera video and original sound together. Add music later so
            // the soundtrack retains its own tempo and fills the output duration.
            composition.scaleTimeRange(CMTimeRange(start: .zero, duration: range.duration), toDuration: outputDuration)
        }
        if let musicURL = clip.musicURL {
            let musicAsset = AVURLAsset(url: musicURL)
            guard let sourceMusic = try await musicAsset.loadTracks(withMediaType: .audio).first,
                  let music = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw VideoWorkError.missingTrack
            }
            let available = try await sourceMusic.load(.timeRange)
            let length = min(available.duration.seconds, clip.outputDuration)
            guard length > 0 else { throw VideoWorkError.missingTrack }
            try music.insertTimeRange(CMTimeRange(start: available.start, duration: CMTime(seconds: length, preferredTimescale: 600)),
                                      of: sourceMusic, at: .zero)
            let mix = AVMutableAudioMixInputParameters(track: music)
            mix.setVolume(clip.musicVolume, at: .zero); mixInputs.append(mix)
        }
        let mix = AVMutableAudioMix(); mix.inputParameters = mixInputs
        let formats = try await sourceVideo.load(.formatDescriptions)
        let extensions = formats.first.flatMap { CMFormatDescriptionGetExtensions($0) as? [String: Any] }
        let transfer = extensions?[kCMFormatDescriptionExtension_TransferFunction as String] as? String
        let sourceIsHDR = transfer == AVVideoTransferFunction_ITU_R_2100_HLG || transfer == AVVideoTransferFunction_SMPTE_ST_2084_PQ
        var filtered: AVVideoComposition?
        if sdr || edits.hasLUT || edits.hasAdjustments || edits.hasGeometry || edits.hdrEffect {
            let context = ColorPipeline.context()
            let natural = try await sourceVideo.load(.naturalSize)
            let size = CGRect(origin: .zero, size: natural).applying(video.preferredTransform).standardized.size
            let previewScale: CGFloat = preview.map { min(1, CGFloat($0.maximumDimension) / max(size.width, size.height)) } ?? 1
            let previewWidth = CGFloat(max(2, Int(size.width * previewScale) / 2 * 2))
            let previewHeight = CGFloat(max(2, Int(size.height * previewScale) / 2 * 2))
            let previewSize = CGSize(width: previewWidth, height: previewHeight)
            let value = try await AVMutableVideoComposition.videoComposition(with: composition, applyingCIFiltersWithHandler: { request in
                do {
                    let showOriginal = preview?.showsOriginal == true
                    let settings = showOriginal ? MediaEdits() : (preview?.snapshot() ?? edits)
                    // This path is deliberately SDR; the unfiltered AVPlayer path
                    // retains the source HDR transfer function for native playback.
                    // Rec.709 composition properties below ask AVFoundation to
                    // convert source frames. Never invent a PQ/HLG headroom or
                    // tone-map an already converted SDR frame a second time.
                    // An HLG composition gives SDR frames an HDR container's
                    // headroom metadata. It does not make those source pixels
                    // HDR; tone mapping that metadata would darken white twice.
                    let source = settings.hdrEffect && !sourceIsHDR && !showOriginal ? request.sourceImage
                        : ColorPipeline.toneMap(request.sourceImage, sourceHeadroom: max(1, request.sourceImage.contentHeadroom))
                    // Scale before grading: 4K source decoding is retained, but
                    // interactive LUT/HDR/geometry work uses a bounded canvas.
                    let small = preview == nil ? source : source.transformed(by: .init(scaleX: previewScale, y: previewScale))
                    let graded = try ColorPipeline.grade(small, edits: settings)
                    let expanded = settings.hdrEffect ? try HDRExpansion.image(graded) : graded
                    var frame = try ColorPipeline.geometry(expanded, edits: settings)
                    if preview != nil {
                        // A stable canvas permits angle changes without replacing
                        // the player item. Letterbox rather than stretch the crop.
                        let scale = min(previewSize.width / frame.extent.width, previewSize.height / frame.extent.height)
                        frame = frame.transformed(by: .init(scaleX: scale, y: scale))
                        frame = frame.transformed(by: .init(translationX: (previewSize.width - frame.extent.width) / 2,
                                                           y: (previewSize.height - frame.extent.height) / 2))
                        frame = frame.composited(over: CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: previewSize)))
                    }
                    request.finish(with: frame, context: context)
                } catch { request.finish(with: error) }
            })
            let outputSize = try ColorPipeline.geometrySize(width: Int(size.width.rounded()), height: Int(size.height.rounded()), edits: edits)
            // H.264 export dimensions must be even. Crop, never rescale/stretch.
            value.renderSize = preview == nil
                ? CGSize(width: max(2, Int(outputSize.width) / 2 * 2), height: max(2, Int(outputSize.height) / 2 * 2)) : previewSize
            value.colorPrimaries = edits.hdrEffect ? AVVideoColorPrimaries_ITU_R_2020 : AVVideoColorPrimaries_ITU_R_709_2
            value.colorTransferFunction = edits.hdrEffect ? AVVideoTransferFunction_ITU_R_2100_HLG : AVVideoTransferFunction_ITU_R_709_2
            value.colorYCbCrMatrix = edits.hdrEffect ? AVVideoYCbCrMatrix_ITU_R_2020 : AVVideoYCbCrMatrix_ITU_R_709_2
            if clip.speed != 1 {
                let rate = try await sourceVideo.load(.nominalFrameRate)
                // Scaled track timestamps otherwise override frameDuration and
                // turn 60 fps at 2× into an unnecessary 120 fps output.
                value.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
                value.frameDuration = CMTime(seconds: 1 / min(60, max(1, Double(rate))), preferredTimescale: 60000)
            }
            filtered = value
        }
        return PreparedVideo(asset: composition, videoComposition: filtered, audioMix: mix, duration: clip.outputDuration)
    }

    public static func export(_ url: URL, to output: URL, clip: ClipSettings, edits: MediaEdits,
                              codec: VideoCodecChoice = .h264,
                              progress: (@Sendable (Double) -> Void)? = nil) async throws {
        try Task.checkCancellation()
        guard output.isFileURL, !FileManager.default.fileExists(atPath: output.path) else { throw VideoWorkError.outputExists }
        let prepared = try await prepare(url, clip: clip, edits: edits, sdr: true)
        let temporary = output.deletingLastPathComponent().appendingPathComponent(".workbench-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: temporary) }
        if edits.hdrEffect {
            try await exportHLG(prepared, to: temporary, progress: progress)
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: temporary, to: output)
            progress?(1)
            return
        }
        guard let exporter = AVAssetExportSession(asset: prepared.asset, presetName: codec.preset) else {
            throw VideoWorkError.failed(L("无法创建编码器"))
        }
        exporter.videoComposition = prepared.videoComposition; exporter.audioMix = prepared.audioMix
        exporter.audioTimePitchAlgorithm = .spectral
        try Task.checkCancellation()
        let handle = ExportSessionHandle(exporter)
        let updates = progress.map { report in
            Task.detached(priority: .utility) {
                while !Task.isCancelled {
                    report(min(0.99, Double(handle.session.progress)))
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
                }
            }
        }
        defer { updates?.cancel() }
        try await withTaskCancellationHandler {
            try await exporter.export(to: temporary, as: .mov)
        } onCancel: { handle.session.cancelExport() }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporary, to: output)
        progress?(1)
    }

    /// Explicit 10-bit buffers and HEVC Main10 encoding; an HDR flag alone is insufficient.
    private static func exportHLG(_ prepared: PreparedVideo, to output: URL,
                                  progress: (@Sendable (Double) -> Void)?) async throws {
        guard let composition = prepared.videoComposition else { throw VideoWorkError.missingTrack }
        let reader = try AVAssetReader(asset: prepared.asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let videos = try await prepared.asset.loadTracks(withMediaType: .video)
        let readVideo = AVAssetReaderVideoCompositionOutput(videoTracks: videos, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        ])
        readVideo.videoComposition = composition; readVideo.alwaysCopiesSampleData = false
        let size = composition.renderSize
        let writeVideo = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020],
            AVVideoCompressionPropertiesKey: [AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel,
                AVVideoAverageBitRateKey: max(4_000_000, Int(size.width * size.height * 6))]
        ])
        var channels: [(AVAssetReaderOutput, AVAssetWriterInput)] = [(readVideo, writeVideo)]
        let audios = try await prepared.asset.loadTracks(withMediaType: .audio)
        if !audios.isEmpty {
            let readAudio = AVAssetReaderAudioMixOutput(audioTracks: audios, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false
            ])
            readAudio.audioMix = prepared.audioMix; readAudio.audioTimePitchAlgorithm = .spectral
            let writeAudio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192000
            ])
            channels.append((readAudio, writeAudio))
        }
        for (read, write) in channels {
            guard reader.canAdd(read), writer.canAdd(write) else { throw VideoWorkError.failed(L("HDR 编码器不支持当前轨道")) }
            reader.add(read); writer.add(write)
        }
        guard writer.startWriting(), reader.startReading() else { throw writer.error ?? reader.error ?? VideoWorkError.failed(L("HDR 编码未开始")) }
        writer.startSession(atSourceTime: .zero)
        do {
            var finished = Set<Int>()
            var reported = 0.0
            while finished.count < channels.count {
                try Task.checkCancellation()
                guard writer.status == .writing else { throw writer.error ?? VideoWorkError.failed(L("HDR 编码中断")) }
                var advanced = false
                for (index, channel) in channels.enumerated() where !finished.contains(index) && channel.1.isReadyForMoreMediaData {
                    if let sample = channel.0.copyNextSampleBuffer() {
                        guard channel.1.append(sample) else { throw writer.error ?? VideoWorkError.failed(L("HDR 样本写入失败")) }
                        if index == 0 {
                            let fraction = min(0.99, CMSampleBufferGetPresentationTimeStamp(sample).seconds / prepared.duration)
                            if fraction - reported >= 0.02 { progress?(fraction); reported = fraction }
                        }
                    } else { channel.1.markAsFinished(); finished.insert(index) }
                    advanced = true
                }
                if !advanced { try await Task.sleep(for: .milliseconds(2)) }
            }
            guard reader.status == .completed else { throw reader.error ?? VideoWorkError.failed(L("HDR 读取未完成")) }
            writer.endSession(atSourceTime: CMTime(seconds: prepared.duration, preferredTimescale: 60000))
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? VideoWorkError.failed(L("HDR 导出未完成")) }
        } catch { reader.cancelReading(); writer.cancelWriting(); throw error }
    }
}
