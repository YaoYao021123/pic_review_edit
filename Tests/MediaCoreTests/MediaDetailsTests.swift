import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import MediaCore

struct MediaDetailsTests {
    private func value(_ details: MediaDetails, _ group: String, _ row: String) -> String? {
        details.groups.first { $0.title == group }?.rows.first { $0.title == row }?.value
    }

    @Test func testReadsPhotoExposureColorAndLocation() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let pixels: [UInt8] = Array(repeating: 120, count: 4 * 3 * 2)
        let image = CGImage(width: 4, height: 2, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: 12,
                            space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: CGBitmapInfo(rawValue: 0),
                            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil,
                            shouldInterpolate: false, intent: .defaultIntent)!
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 16 Pro"],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:09:28 11:55:48",
                kCGImagePropertyExifOffsetTimeOriginal: "+08:00",
                kCGImagePropertyExifLensModel: "iPhone 16 Pro back camera 6.765mm f/1.78",
                kCGImagePropertyExifFocalLength: 6.765, kCGImagePropertyExifFocalLenIn35mmFilm: 24,
                kCGImagePropertyExifFNumber: 1.78, kCGImagePropertyExifExposureTime: 1.0 / 120,
                kCGImagePropertyExifISOSpeedRatings: [125], kCGImagePropertyExifExposureBiasValue: -0.7,
                kCGImagePropertyExifExposureProgram: 2, kCGImagePropertyExifMeteringMode: 5,
                kCGImagePropertyExifFlash: 16
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 33.8688, kCGImagePropertyGPSLatitudeRef: "S",
                kCGImagePropertyGPSLongitude: 151.2093, kCGImagePropertyGPSLongitudeRef: "E",
                kCGImagePropertyGPSAltitude: 12.0, kCGImagePropertyGPSAltitudeRef: 0
            ]
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))

        let details = await MediaDetails.read(url)
        #expect(details.groups.map(\.kind) == [.capture, .color, .location, .file])
        #expect(details.hasExposure)
        #expect(value(details, "拍摄", "拍摄时间") == "2026年9月28日 11:55:48（UTC+08:00）")
        #expect(value(details, "拍摄", "设备") == "Apple iPhone 16 Pro")
        #expect(value(details, "拍摄", "焦距") == "6.8 mm（等效 24 mm）")
        #expect(value(details, "拍摄", "光圈") == "ƒ/1.8")
        #expect(value(details, "拍摄", "快门") == "1/120 秒")
        #expect(value(details, "拍摄", "ISO") == "125")
        #expect(value(details, "拍摄", "曝光补偿") == "-0.7 EV")
        #expect(value(details, "拍摄", "曝光模式") == "程序自动")
        #expect(value(details, "拍摄", "测光") == "评价测光")
        #expect(value(details, "拍摄", "闪光灯") == "未闪光")
        #expect(value(details, "色彩", "色彩空间") == "Display P3")
        #expect(value(details, "色彩", "动态范围") == "SDR")
        #expect(value(details, "文件", "尺寸") == "2 × 4（0.0 百万像素）")
        #expect(value(details, "文件", "格式") == "JPEG")
        let coordinate = try #require(details.coordinate)
        #expect(abs(coordinate.latitude + 33.8688) < 1e-6 && abs(coordinate.longitude - 151.2093) < 1e-6)
        #expect(value(details, "位置", "海拔") == "12 m")
        #expect(details.text.contains("快门：1/120 秒"))
    }

    @Test func testReadsMovieCodecColorDeviceAndLocation() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.metadata = [
            (AVMetadataIdentifier.quickTimeMetadataMake, "Apple"),
            (.quickTimeMetadataModel, "iPhone 16 Pro"),
            (.quickTimeMetadataLocationISO6709, "+22.5432+114.0579+010.000/")
        ].map { identifier, value in
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            return item
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 32,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ])
        input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 32, ty: 0)
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB])
        writer.add(input)
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for index in 0..<30 {
            var buffer: CVPixelBuffer?
            #expect(CVPixelBufferCreate(kCFAllocatorDefault, 64, 32, kCVPixelFormatType_32ARGB, nil, &buffer) == kCVReturnSuccess)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels)!, 0, CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            var attempts = 0
            while !input.isReadyForMoreMediaData && attempts < 500 && writer.status == .writing {
                try await Task.sleep(for: .milliseconds(10))
                attempts += 1
            }
            try #require(adapter.append(pixels, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        try #require(writer.status == .completed)

        let details = await MediaDetails.read(url)
        #expect(details.groups.map(\.kind) == [.capture, .video, .color, .location, .file])
        #expect(value(details, "视频", "编码")?.hasPrefix("H.264") == true)
        #expect(value(details, "视频", "帧率") == "30.00 fps")
        #expect(value(details, "视频", "音频") == "无")
        #expect(value(details, "色彩", "色域") == "Rec.709")
        #expect(value(details, "色彩", "传递函数") == "Rec.709（SDR）")
        #expect(value(details, "色彩", "动态范围") == "SDR")
        #expect(value(details, "文件", "尺寸") == "32 × 64")
        #expect(value(details, "拍摄", "设备") == "Apple iPhone 16 Pro")
        let coordinate = try #require(details.coordinate)
        #expect(abs(coordinate.latitude - 22.5432) < 1e-6 && abs(coordinate.longitude - 114.0579) < 1e-6)
    }

    @Test func testFormattingHelpers() {
        #expect(MediaDetails.shutter(1.0 / 120) == "1/120 秒")
        #expect(MediaDetails.shutter(0.5) == "1/2 秒")
        #expect(MediaDetails.shutter(2) == "2 秒")
        #expect(MediaDetails.shutter(1.5) == "1.5 秒")
        #expect(MediaDetails.duration(28.14) == "00:28.14")
        #expect(MediaDetails.duration(3725) == "1:02:05")
        #expect(MediaDetails.device(make: "DJI", model: "DJI Mini 4 Pro") == "DJI Mini 4 Pro")
        #expect(MediaDetails.device(make: "Apple", model: "iPhone 16 Pro") == "Apple iPhone 16 Pro")
        #expect(MediaDetails.device(make: nil, model: nil) == nil)
        let parsed = MediaDetails.parseISO6709("+22.5432+114.0579+010.000/")
        #expect(parsed?.0 == 22.5432 && parsed?.1 == 114.0579 && parsed?.2 == 10)
        let south = MediaDetails.parseISO6709("-33.8688+151.2093/")
        #expect(south?.0 == -33.8688 && south?.1 == 151.2093 && south?.2 == nil)
        #expect(MediaDetails.parseISO6709("garbage") == nil)
        #expect(MediaDetails.coordinateText(-33.8688, 151.2093) == "33.86880°S, 151.20930°E")
        // Primaries and matrices share spellings; the lookup must not trap on duplicate keys.
        #expect(MediaDetails.primariesName(AVVideoColorPrimaries_ITU_R_2020) == "Rec.2020")
        #expect(MediaDetails.primariesName(AVVideoYCbCrMatrix_ITU_R_601_4) == "Rec.601")
        #expect(MediaDetails.transferName(AVVideoTransferFunction_ITU_R_2100_HLG) == "HLG（HDR）")
        #expect(MediaDetails.isHDR(AVVideoTransferFunction_SMPTE_ST_2084_PQ))
        #expect(!MediaDetails.isHDR(AVVideoTransferFunction_ITU_R_709_2))
        #expect(MediaDetails.fourCC(0x68766331) == "hvc1")
    }
}
