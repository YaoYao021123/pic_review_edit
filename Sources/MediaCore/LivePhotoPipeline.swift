import AVFoundation
import CoreImage
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

public struct LivePhotoResources: Sendable {
    public let imageURL: URL
    public let videoURL: URL
    public let identifier: String
    public let coverSeconds: Double
}

public enum LivePhotoPipeline {
    /// Creates an atomic new folder. Original media is never modified.
    public static func export(_ url: URL, to directory: URL, clip: ClipSettings, edits: MediaEdits,
                              progress: (@Sendable (Double) -> Void)? = nil) async throws -> LivePhotoResources {
        guard directory.isFileURL, !FileManager.default.fileExists(atPath: directory.path) else { throw VideoWorkError.outputExists }
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        try clip.validate(duration: duration, live: true)
        let staging = directory.deletingLastPathComponent().appendingPathComponent(".live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        let encoded = staging.appendingPathComponent("render.mov")
        let videoProgress: (@Sendable (Double) -> Void)?
        if let report = progress {
            videoProgress = { fraction in report(fraction * 0.8) }
        } else {
            videoProgress = nil
        }
        try await VideoPipeline.export(url, to: encoded, clip: clip, edits: edits, progress: videoProgress)
        let asset = AVURLAsset(url: encoded)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.dynamicRangePolicy = edits.hdrEffect ? .matchSource : .forceSDR
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (photo, actualTime) = try await generator.image(at: CMTime(seconds: clip.outputCover, preferredTimescale: 60000))
        let identifier = UUID().uuidString
        let imageName = edits.hdrEffect ? "LivePhoto.heic" : "LivePhoto.jpg"
        let imageURL = staging.appendingPathComponent(imageName)
        let videoURL = staging.appendingPathComponent("LivePhoto.mov")
        if edits.hdrEffect {
            try HDRExpansion.writeCover(CIImage(cgImage: photo), identifier: identifier, to: imageURL)
        } else {
            guard let destination = CGImageDestinationCreateWithURL(imageURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw StraighteningError.renderFailed
            }
            CGImageDestinationAddImage(destination, photo, [
                kCGImagePropertyMakerAppleDictionary: ["17": identifier],
                kCGImagePropertyOrientation: 1, kCGImageDestinationLossyCompressionQuality: 0.95
            ] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw StraighteningError.renderFailed }
        }
        try await pairMovie(asset, to: videoURL, identifier: identifier, coverTime: actualTime, duration: clip.outputDuration)
        progress?(0.9)
        // Decode through Photos before publishing, so an invalid pair is not
        // presented as a successful Live export. No photo-library access occurs.
        _ = try await load(imageURL: imageURL, videoURL: videoURL)
        if let lut = edits.lut {
            try lut.cube.textRepresentation().write(to: staging.appendingPathComponent("lut.cube"), atomically: false, encoding: .utf8)
        }
        let geometry = try JSONSerialization.jsonObject(with: JSONEncoder().encode(edits.geometry))
        let recipe: [String: Any] = ["version": 4, "source": url.lastPathComponent,
            "start": clip.start, "end": clip.end, "cover": clip.start + actualTime.seconds * clip.speed,
            "speed": clip.speed, "outputDuration": clip.outputDuration, "outputCover": actualTime.seconds,
            "geometry": geometry, "adjustments": edits.adjustments.dictionary, "degrees": edits.degrees, "lut": edits.lut?.name ?? "none", "lutFile": edits.lut == nil ? "none" : "lut.cube", "strength": edits.strength,
            "lutEncoding": edits.lut?.encoding.rawValue ?? "none",
            "originalVolume": clip.originalVolume, "music": clip.musicURL?.lastPathComponent ?? "none",
            "musicVolume": clip.musicVolume, "hdrEffect": edits.hdrEffect,
            "output": edits.hdrEffect ? "SDR-derived HDR effect: HEIC gain map + HEVC Main10 Rec.2020 HLG MOV" : "SDR sRGB JPEG + Rec.709 MOV",
            "identifier": identifier]
        try JSONSerialization.data(withJSONObject: recipe, options: [.prettyPrinted, .sortedKeys])
            .write(to: staging.appendingPathComponent("recipe.json"), options: .withoutOverwriting)
        try FileManager.default.removeItem(at: encoded)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: staging, to: directory)
        progress?(1)
        return LivePhotoResources(imageURL: directory.appendingPathComponent(imageName),
            videoURL: directory.appendingPathComponent("LivePhoto.mov"), identifier: identifier, coverSeconds: actualTime.seconds)
    }

    public static func load(imageURL: URL, videoURL: URL) async throws -> PHLivePhoto {
        try await withCheckedThrowingContinuation { continuation in
            PHLivePhoto.request(withResourceFileURLs: [imageURL, videoURL], placeholderImage: nil,
                                targetSize: CGSize(width: 1200, height: 1200), contentMode: .aspectFit) { photo, info in
                guard !(info[PHLivePhotoInfoIsDegradedKey] as? Bool ?? false) else { return }
                if let photo { continuation.resume(returning: photo) }
                else { continuation.resume(throwing: info[PHLivePhotoInfoErrorKey] as? Error ?? VideoWorkError.failed(L("系统未识别 Live Photo 配对"))) }
            }
        }
    }

    /// Only the explicitly selected image's same-name MOV is considered.
    public static func pairedMovie(for imageURL: URL) async throws -> URL? {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let maker = properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any],
              let identifier = maker["17"] as? String else { return nil }
        for ext in ["mov", "MOV"] {
            let candidate = imageURL.deletingPathExtension().appendingPathExtension(ext)
            guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
            let metadata = try await AVURLAsset(url: candidate).load(.metadata)
            for item in metadata where item.identifier == .quickTimeMetadataContentIdentifier {
                if try await item.load(.stringValue) == identifier { return candidate }
            }
        }
        return nil
    }

    public static func coverTime(in videoURL: URL) async throws -> Double? {
        let asset = AVURLAsset(url: videoURL)
        for track in try await asset.loadTracks(withMediaType: .metadata) {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            guard reader.canAdd(output) else { continue }
            reader.add(output)
            let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
            guard reader.startReading() else { throw reader.error ?? VideoWorkError.failed(L("无法读取 Live 封面时间")) }
            defer { reader.cancelReading() }
            // Only a short Live resource is inspected; cap ancillary camera
            // metadata groups instead of scanning an arbitrary movie forever.
            for _ in 0..<1000 {
                try Task.checkCancellation()
                guard let group = adaptor.nextTimedMetadataGroup() else { break }
                if group.items.contains(where: { $0.identifier?.rawValue == "mdta/com.apple.quicktime.still-image-time" }) {
                    let value = group.timeRange.start.seconds
                    if value.isFinite && value >= 0 { return value }
                }
            }
        }
        return nil
    }

    private static func pairMovie(_ asset: AVAsset, to output: URL, identifier: String, coverTime: CMTime, duration: Double) async throws {
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let contentID = AVMutableMetadataItem()
        contentID.identifier = .quickTimeMetadataContentIdentifier
        contentID.value = identifier as NSString
        contentID.dataType = kCMMetadataBaseDataType_UTF8 as String
        writer.metadata = [contentID]
        var channels: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        for type in [AVMediaType.video, .audio] {
            for track in try await asset.loadTracks(withMediaType: type) {
                let formats = try await track.load(.formatDescriptions)
                guard let format = formats.first else { throw VideoWorkError.missingTrack }
                let read = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                read.alwaysCopiesSampleData = false
                let write = AVAssetWriterInput(mediaType: type, outputSettings: nil, sourceFormatHint: format)
                if type == .video { write.transform = try await track.load(.preferredTransform) }
                guard reader.canAdd(read), writer.canAdd(write) else { throw VideoWorkError.failed(L("无法添加配对轨道")) }
                reader.add(read); writer.add(write); channels.append((read, write))
            }
        }
        var metadataFormat: CMMetadataFormatDescription?
        let spec: [String: Any] = [kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String:
            "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: kCMMetadataBaseDataType_SInt8]
        guard CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed, metadataSpecifications: [spec] as CFArray,
            formatDescriptionOut: &metadataFormat) == noErr, let metadataFormat else { throw VideoWorkError.failed(L("封面时间格式无效")) }
        let metadataInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: metadataFormat)
        let adaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)
        guard writer.canAdd(metadataInput) else { throw VideoWorkError.failed(L("无法写入封面时间")) }
        writer.add(metadataInput)
        guard writer.startWriting(), reader.startReading() else { throw writer.error ?? reader.error ?? VideoWorkError.failed(L("配对写入未开始")) }
        writer.startSession(atSourceTime: .zero)
        let still = AVMutableMetadataItem()
        still.keySpace = .quickTimeMetadata; still.key = "com.apple.quicktime.still-image-time" as NSString
        still.value = NSNumber(value: Int8(0)); still.dataType = kCMMetadataBaseDataType_SInt8 as String
        let group = AVTimedMetadataGroup(items: [still], timeRange: CMTimeRange(start: coverTime, duration: CMTime(value: 1, timescale: 30)))
        do {
            while !metadataInput.isReadyForMoreMediaData {
                try Task.checkCancellation()
                guard writer.status == .writing else { throw writer.error ?? VideoWorkError.failed(L("封面时间轨道未就绪")) }
                try await Task.sleep(for: .milliseconds(2))
            }
            guard adaptor.append(group) else { throw writer.error ?? VideoWorkError.failed(L("封面时间写入失败")) }
            metadataInput.markAsFinished()
            var finished = Set<Int>()
            while finished.count < channels.count {
                try Task.checkCancellation()
                guard writer.status == .writing else { throw writer.error ?? VideoWorkError.failed(L("配对写入中断")) }
                var advanced = false
                for (index, channel) in channels.enumerated() where !finished.contains(index) && channel.1.isReadyForMoreMediaData {
                    if let sample = channel.0.copyNextSampleBuffer() {
                        guard channel.1.append(sample) else { throw writer.error ?? VideoWorkError.failed(L("媒体样本写入失败")) }
                    } else { channel.1.markAsFinished(); finished.insert(index) }
                    advanced = true
                }
                if !advanced { try await Task.sleep(for: .milliseconds(2)) }
            }
            guard reader.status == .completed else { throw reader.error ?? VideoWorkError.failed(L("配对读取失败")) }
            // Keep Live length exact even when the final 59.94 fps sample
            // straddles the requested end time by a fraction of a frame.
            writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 60000))
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? VideoWorkError.failed(L("配对未完成")) }
        } catch { reader.cancelReading(); writer.cancelWriting(); throw error }
    }
}
