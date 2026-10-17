import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Everything worth knowing about a file, grouped for the Info panel
/// (Lightroom's Metadata panel, plus video codec, color and audio details).
public struct MediaDetails: Sendable, Equatable {
    public struct Row: Sendable, Equatable, Identifiable {
        public let title: String
        public let value: String
        public var id: String { title }
        public init(title: String, value: String) { self.title = title; self.value = value }
    }
    public struct Group: Sendable, Equatable, Identifiable {
        /// Stable identity; the title is localized.
        public enum Kind: String, Sendable, CaseIterable {
            case capture, video, liveMotion, color, location, file
            public var title: String {
                switch self {
                case .capture: L("拍摄"); case .video: L("视频"); case .liveMotion: L("Live 动态部分")
                case .color: L("色彩"); case .location: L("位置"); case .file: L("文件")
                }
            }
        }
        public let kind: Kind
        public var rows: [Row]
        public var title: String { kind.title }
        public var id: String { kind.rawValue }
    }
    public var groups: [Group] = []
    public var latitude: Double?
    public var longitude: Double?
    /// Aperture, shutter or ISO were recorded (the Info tab links to the lessons about them).
    public var hasExposure = false

    public var coordinate: (latitude: Double, longitude: Double)? {
        guard let latitude, let longitude else { return nil }
        return (latitude, longitude)
    }

    /// Plain text for "copy info".
    public var text: String {
        groups.map { group in ([group.title] + group.rows.map { L("\($0.title)：\($0.value)") }).joined(separator: "\n") }
            .joined(separator: "\n\n")
    }

    // MARK: Reading

    /// Reads a still or a movie. For a Live Photo pass the still and its motion file.
    public static func read(_ url: URL, motion: URL? = nil) async -> MediaDetails {
        var details = MediaDetails()
        if LibraryKind.isMovie(url) {
            await details.addMovie(url, kind: .video)
        } else {
            details.addImage(url)
            if let motion { await details.addMovie(motion, kind: .liveMotion) }
        }
        details.addFile(url, motion: motion)
        details.groups.removeAll { $0.rows.isEmpty }
        let order: [Group.Kind] = [.capture, .video, .liveMotion, .color, .location, .file]
        details.groups.sort { (order.firstIndex(of: $0.kind) ?? order.count) < (order.firstIndex(of: $1.kind) ?? order.count) }
        return details
    }

    private mutating func add(_ kind: Group.Kind, _ rows: [Row]) {
        if let index = groups.firstIndex(where: { $0.kind == kind }) { groups[index].rows += rows }
        else { groups.append(Group(kind: kind, rows: rows)) }
    }

    private static func row(_ title: String, _ value: String?) -> Row? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return Row(title: title, value: value)
    }

    // MARK: Stills (EXIF / TIFF / GPS / color)

    private mutating func addImage(_ url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return }
        let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = p[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]

        var capture: [Row?] = []
        capture.append(Self.row(L("拍摄时间"), Self.exifDate(exif[kCGImagePropertyExifDateTimeOriginal] as? String,
                                                     offset: exif[kCGImagePropertyExifOffsetTimeOriginal] as? String)))
        capture.append(Self.row(L("设备"), Self.device(make: tiff[kCGImagePropertyTIFFMake] as? String, model: tiff[kCGImagePropertyTIFFModel] as? String)))
        capture.append(Self.row(L("镜头"), exif[kCGImagePropertyExifLensModel] as? String))
        if let focal = Self.number(exif[kCGImagePropertyExifFocalLength]) {
            let equivalent = Self.number(exif[kCGImagePropertyExifFocalLenIn35mmFilm]).map { String(format: L("（等效 %.0f mm）"), $0) } ?? ""
            capture.append(Self.row(L("焦距"), String(format: "%.1f mm", focal).replacingOccurrences(of: ".0 mm", with: " mm") + equivalent))
        }
        capture.append(Self.row(L("光圈"), Self.number(exif[kCGImagePropertyExifFNumber]).map { String(format: "ƒ/%.1f", $0) }))
        capture.append(Self.row(L("快门"), Self.number(exif[kCGImagePropertyExifExposureTime]).map(Self.shutter)))
        capture.append(Self.row("ISO", (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first.map { "\($0.intValue)" }))
        capture.append(Self.row(L("曝光补偿"), Self.number(exif[kCGImagePropertyExifExposureBiasValue]).map { abs($0) < 0.05 ? "0 EV" : String(format: "%+.1f EV", $0) }))
        capture.append(Self.row(L("曝光模式"), Self.number(exif[kCGImagePropertyExifExposureProgram]).flatMap { Self.exposureProgram[Int($0)] }))
        capture.append(Self.row(L("测光"), Self.number(exif[kCGImagePropertyExifMeteringMode]).flatMap { Self.metering[Int($0)] }))
        capture.append(Self.row(L("白平衡"), Self.number(exif[kCGImagePropertyExifWhiteBalance]).map { $0 == 0 ? L("自动") : L("手动") }))
        capture.append(Self.row(L("闪光灯"), Self.number(exif[kCGImagePropertyExifFlash]).map { Int($0) & 1 == 1 ? L("已闪光") : L("未闪光") }))
        capture.append(Self.row(L("软件"), tiff[kCGImagePropertyTIFFSoftware] as? String))
        hasExposure = [kCGImagePropertyExifFNumber, kCGImagePropertyExifExposureTime, kCGImagePropertyExifISOSpeedRatings]
            .contains { exif[$0] != nil }
        add(.capture, capture.compactMap { $0 })

        var color: [Row?] = []
        color.append(Self.row(L("色彩空间"), p[kCGImagePropertyProfileName] as? String))
        color.append(Self.row(L("位深"), Self.number(p[kCGImagePropertyDepth]).map { L("\(Int($0)) 位 / 通道") }))
        let gainMap = [kCGImageAuxiliaryDataTypeHDRGainMap, kCGImageAuxiliaryDataTypeISOGainMap]
            .contains { CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, $0) != nil }
        color.append(Self.row(L("动态范围"), gainMap ? L("HDR（带增益图）") : "SDR"))
        add(.color, color.compactMap { $0 })

        var image: [Row?] = []
        if let w = Self.number(p[kCGImagePropertyPixelWidth]), let h = Self.number(p[kCGImagePropertyPixelHeight]) {
            let orientation = Self.number(p[kCGImagePropertyOrientation]) ?? 1
            let (dw, dh) = (5...8).contains(Int(orientation)) ? (h, w) : (w, h)
            image.append(Self.row(L("尺寸"), String(format: L("%.0f × %.0f（%.1f 百万像素）"), dw, dh, dw * dh / 1_000_000)))
        }
        if let type = CGImageSourceGetType(source) as String?, let utType = UTType(type) {
            image.append(Self.row(L("格式"), utType.preferredFilenameExtension?.uppercased() ?? utType.localizedDescription))
        }
        add(.file, image.compactMap { $0 })

        if let latitude = Self.number(gps[kCGImagePropertyGPSLatitude]), let longitude = Self.number(gps[kCGImagePropertyGPSLongitude]) {
            let lat = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -latitude : latitude
            let lon = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -longitude : longitude
            self.latitude = lat; self.longitude = lon
            var rows = [Row(title: L("坐标"), value: Self.coordinateText(lat, lon))]
            // Phones without a barometer often record exactly 0 m; that means "unknown".
            if let altitude = Self.number(gps[kCGImagePropertyGPSAltitude]), altitude != 0 {
                let below = Self.number(gps[kCGImagePropertyGPSAltitudeRef]) == 1
                rows.append(Row(title: L("海拔"), value: String(format: "%@%.0f m", below ? "-" : "", altitude)))
            }
            add(.location, rows)
        }
    }

    // MARK: Movies (codec, color, bitrate, audio, device, location)

    private mutating func addMovie(_ url: URL, kind: Group.Kind) async {
        let liveMotion = kind == .liveMotion
        let asset = AVURLAsset(url: url)
        var video: [Row?] = []
        var color: [Row?] = []
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let (size, transform, fps, formats, rate, range) = try? await track.load(.naturalSize, .preferredTransform, .nominalFrameRate,
                                                                                .formatDescriptions, .estimatedDataRate, .timeRange) {
            let display = CGRect(origin: .zero, size: size).applying(transform).standardized.size
            if !liveMotion {
                add(.file, [Row(title: L("尺寸"), value: String(format: "%.0f × %.0f", display.width, display.height))])
            }
            let seconds = range.duration.seconds
            if let format = formats.first {
                video.append(Self.row(L("编码"), Self.videoCodec(format)))
                let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
                let primaries = extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String
                let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String
                let matrix = extensions[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String
                if !liveMotion {
                    color.append(Self.row(L("色域"), primaries.map(Self.primariesName)))
                    color.append(Self.row(L("传递函数"), transfer.map(Self.transferName)))
                    color.append(Self.row(L("矩阵"), matrix.map(Self.primariesName)))
                    color.append(Self.row(L("位深"), Self.videoBitDepth(format, extensions).map { L("\($0) 位") }))
                    color.append(Self.row(L("动态范围"), transfer.map(Self.isHDR) == true ? "HDR" : "SDR"))
                }
            }
            video.append(Self.row(L("帧率"), fps > 0 ? String(format: "%.2f fps", fps) : nil))
            video.append(Self.row(L("时长"), seconds.isFinite ? Self.duration(seconds) : nil))
            if fps > 0, seconds.isFinite { video.append(Self.row(L("总帧数"), "\(Int((seconds * Double(fps)).rounded()))")) }
            video.append(Self.row(L("码率"), rate > 0 ? String(format: "%.1f Mbps", rate / 1_000_000) : nil))
        }
        if let audio = try? await asset.loadTracks(withMediaType: .audio).first,
           let format = try? await audio.load(.formatDescriptions).first {
            video.append(Self.row(L("音频"), Self.audioSummary(format)))
        } else if !liveMotion {
            video.append(Row(title: L("音频"), value: L("无")))
        }
        add(kind, video.compactMap { $0 })
        if !color.isEmpty { add(.color, color.compactMap { $0 }) }

        guard !liveMotion, let items = try? await asset.load(.commonMetadata) else { return }
        func string(_ key: AVMetadataKey) async -> String? {
            guard let item = AVMetadataItem.metadataItems(from: items, withKey: key, keySpace: .common).first else { return nil }
            return try? await item.load(.stringValue)
        }
        var capture: [Row?] = []
        if let created = try? await asset.load(.creationDate), let date = try? await created.load(.dateValue) {
            capture.append(Self.row(L("拍摄时间"), Self.dateText(date)))
        } else {
            capture.append(Self.row(L("拍摄时间"), await string(.commonKeyCreationDate)))
        }
        var device = Self.device(make: await string(.commonKeyMake), model: await string(.commonKeyModel))
        var software = await string(.commonKeySoftware)
        // DJI cameras name themselves only in the encoder tag ("DJI Lito X1").
        if device == nil, let name = software, name.hasPrefix("DJI") { device = name; software = nil }
        capture.append(Self.row(L("设备"), device))
        capture.append(Self.row(L("软件"), software))
        add(.capture, capture.compactMap { $0 })
        if let iso6709 = await string(.commonKeyLocation), let parsed = Self.parseISO6709(iso6709) {
            latitude = parsed.0; longitude = parsed.1
            var rows = [Row(title: L("坐标"), value: Self.coordinateText(parsed.0, parsed.1))]
            if let altitude = parsed.2 { rows.append(Row(title: L("海拔"), value: String(format: "%.0f m", altitude))) }
            add(.location, rows)
        }
    }

    // MARK: File system

    private mutating func addFile(_ url: URL, motion: URL?) {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
        var rows: [Row?] = []
        var size = values?.fileSize.map { Int64($0) }
        if let motion, let extra = try? motion.resourceValues(forKeys: [.fileSizeKey]).fileSize { size = (size ?? 0) + Int64(extra) }
        rows.append(Self.row(L("大小"), size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) + (motion != nil ? L("（含动态部分）") : "") }))
        rows.append(Self.row(L("修改时间"), values?.contentModificationDate.map(Self.dateText)))
        rows.append(Self.row(L("文件夹"), url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")))
        if let motion { rows.append(Self.row(L("动态文件"), motion.lastPathComponent)) }
        add(.file, rows.compactMap { $0 })
    }

    // MARK: Formatting helpers

    static func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }

    static func shutter(_ seconds: Double) -> String {
        seconds >= 1 ? String(format: L("%.1f 秒"), seconds).replacingOccurrences(of: L(".0 秒"), with: L(" 秒"))
            : L("1/\(Int((1 / seconds).rounded())) 秒")
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds), fraction = Int(((seconds - Double(total)) * 100).rounded()) % 100
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%02d:%02d.%02d", total / 60, total % 60, fraction)
    }

    static func dateText(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .long, time: .standard).locale(AppLanguage.current.displayLocale))
    }

    static func exifDate(_ text: String?, offset: String?) -> String? {
        guard let text else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        // EXIF time is local to the camera; show it as recorded, plus the zone when known.
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        guard let date = formatter.date(from: text) else { return text }
        let display = DateFormatter()
        display.locale = AppLanguage.current.displayLocale
        display.timeZone = TimeZone(secondsFromGMT: 0)
        display.dateStyle = .long
        display.timeStyle = .medium
        return display.string(from: date) + (offset.map { L("（UTC\($0)）") } ?? "")
    }

    static func device(make: String?, model: String?) -> String? {
        let make = make?.trimmingCharacters(in: .whitespaces), model = model?.trimmingCharacters(in: .whitespaces)
        switch (make, model) {
        case let (make?, model?) where model.localizedCaseInsensitiveContains(make): return model
        case let (make?, model?): return "\(make) \(model)"
        default: return model ?? make
        }
    }

    static func coordinateText(_ latitude: Double, _ longitude: Double) -> String {
        String(format: "%.5f°%@, %.5f°%@", abs(latitude), latitude >= 0 ? "N" : "S", abs(longitude), longitude >= 0 ? "E" : "W")
    }

    /// "+22.5432+114.0579+010.000/" → (lat, lon, altitude?)
    static func parseISO6709(_ text: String) -> (Double, Double, Double?)? {
        var numbers: [Double] = []
        var current = ""
        for character in text {
            if character == "+" || character == "-" || character == "/" {
                if let value = Double(current) { numbers.append(value) }
                current = character == "/" ? "" : String(character)
            } else { current.append(character) }
        }
        if let value = Double(current) { numbers.append(value) }
        guard numbers.count >= 2, abs(numbers[0]) <= 90, abs(numbers[1]) <= 180 else { return nil }
        return (numbers[0], numbers[1], numbers.count > 2 ? numbers[2] : nil)
    }

    static let exposureProgram: [Int: String] = [1: L("手动"), 2: L("程序自动"), 3: L("光圈优先"), 4: L("快门优先"), 5: L("创意程序"),
                                                 6: L("运动程序"), 7: L("人像模式"), 8: L("风景模式")]
    static let metering: [Int: String] = [1: L("平均测光"), 2: L("中央重点"), 3: L("点测光"), 4: L("多点测光"), 5: L("评价测光"), 6: L("局部测光")]

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "\(code)"
    }

    static func videoCodec(_ format: CMFormatDescription) -> String {
        let code = fourCC(CMFormatDescriptionGetMediaSubType(format))
        let names = ["hvc1": "HEVC (H.265)", "hev1": "HEVC (H.265)", "avc1": "H.264", "avc3": "H.264", "av01": "AV1",
                     "apch": "ProRes 422 HQ", "apcn": "ProRes 422", "apcs": "ProRes 422 LT", "apco": "ProRes 422 Proxy",
                     "ap4h": "ProRes 4444", "ap4x": "ProRes 4444 XQ", "aprn": "ProRes RAW", "aprh": "ProRes RAW HQ",
                     "jpeg": "Motion JPEG"]
        var name = names[code] ?? code
        let atoms = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any]
        if let hvcC = atoms?["hvcC"] as? Data, hvcC.count > 1 {
            let profile = hvcC[hvcC.startIndex + 1] & 0x1F
            name += [1: " Main", 2: " Main 10", 3: " Main Still", 4: " Range Extensions"][Int(profile)] ?? ""
        } else if let avcC = atoms?["avcC"] as? Data, avcC.count > 1 {
            name += [66: " Baseline", 77: " Main", 100: " High", 110: " High 10", 122: " High 4:2:2"][Int(avcC[avcC.startIndex + 1])] ?? ""
        }
        return name
    }

    static func videoBitDepth(_ format: CMFormatDescription, _ extensions: [String: Any]) -> Int? {
        if let bits = extensions[kCMFormatDescriptionExtension_BitsPerComponent as String] as? NSNumber { return bits.intValue }
        let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any]
        if let hvcC = atoms?["hvcC"] as? Data, hvcC.count > 1 { return (hvcC[hvcC.startIndex + 1] & 0x1F) == 2 ? 10 : 8 }
        if let avcC = atoms?["avcC"] as? Data, avcC.count > 1 { return avcC[avcC.startIndex + 1] == 110 ? 10 : 8 }
        return nil
    }

    /// Color primaries and YCbCr matrices share their CoreMedia spellings ("ITU_R_709_2" etc.).
    static func primariesName(_ value: String) -> String {
        let names = ["ITU_R_709_2": "Rec.709", "ITU_R_2020": "Rec.2020", "P3_D65": "Display P3", "DCI_P3": "DCI-P3",
                     "ITU_R_601_4": "Rec.601", "SMPTE_C": "SMPTE-C", "EBU_3213": "EBU 3213", "SMPTE_240M_1995": "SMPTE 240M"]
        return names[value] ?? value
    }

    static func transferName(_ value: String) -> String {
        let names = [kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String: L("Rec.709（SDR）"),
                     kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String: L("HLG（HDR）"),
                     kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String: L("PQ（HDR10）"),
                     kCMFormatDescriptionTransferFunction_sRGB as String: "sRGB"]
        return names[value] ?? value
    }

    static func isHDR(_ transfer: String) -> Bool {
        transfer == kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String
            || transfer == kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String
    }

    static func audioSummary(_ format: CMFormatDescription) -> String {
        let code = fourCC(CMFormatDescriptionGetMediaSubType(format))
        let names = ["aac": "AAC", "lpcm": "PCM", "alac": "Apple Lossless", "ac-3": "AC-3", "ec-3": "E-AC-3", ".mp3": "MP3", "opus": "Opus"]
        var parts = [names[code] ?? code]
        if let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
            if description.mSampleRate > 0 { parts.append(String(format: "%.1f kHz", description.mSampleRate / 1000).replacingOccurrences(of: ".0 kHz", with: " kHz")) }
            let channels = Int(description.mChannelsPerFrame)
            parts.append(channels == 1 ? L("单声道") : channels == 2 ? L("立体声") : L("\(channels) 声道"))
        }
        return parts.joined(separator: " · ")
    }
}

/// File-type check that MediaCore can use without the app's library code.
enum LibraryKind {
    static func isMovie(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ["mp4", "mov", "m4v", "mts", "m2ts", "avi"].contains(ext) { return true }
        return UTType(filenameExtension: ext)?.conforms(to: .movie) == true
    }
}
