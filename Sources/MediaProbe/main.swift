import AVFoundation
import Foundation
import ImageIO
import MediaCore

@main
struct MediaProbe {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first,
              ((["inspect", "lut", "straighten", "details", "analyze", "auto", "similar", "labels"].contains(command) && arguments.count == 2)
                || (command == "auto" && arguments.count == 3)
                || (["render", "match"].contains(command) && (4...5).contains(arguments.count))
                || (command == "ailook" && (3...4).contains(arguments.count))
                || (command == "live" && (3...4).contains(arguments.count))
                || (command == "details" && arguments.count == 3)
                || (command == "rotate" && arguments.count == 4)
                || (command == "straighten" && arguments.count == 3)) else {
            print("用法：media-probe inspect <素材> | similar <文件夹> | labels <图片> | render <图片> <配方.json|-> <输出.jpg> [长边] | match <图片> <参考图> <输出.jpg> [长边] | ailook <图片> <输出.jpg> [长边] | live <≤3 秒的视频> <新文件夹> [封面秒数] | details <素材> [Live 动态 .mov] | lut <.cube> | straighten <图片> [新.png] | rotate <图片> <校正角度> <新.png>")
            exit(arguments.isEmpty ? 0 : 2)
        }
        do {
            let url = URL(fileURLWithPath: arguments[1]).standardizedFileURL
            if command == "labels" {
                // labels <image>: what content search knows about a photo
                print((ContentLabels.classify(url) ?? []).joined(separator: " "))
                return
            }
            if command == "ailook" {
                // ailook <image> <out.jpg> [long edge]: 「AI 调色」 at 75%, as the app applies it; prints the mixing weights.
                guard let model = AdaptiveLUT.shared else { print("找不到 adaptive-lut.bin"); exit(4) }
                let session = try ImageGradeSession(url: url, maximumDimension: 1600)
                let plain = try await session.frame(edits: MediaEdits())
                guard let input = AdaptiveLUT.input(plain.original, headroom: plain.sourceHeadroom) else { exit(4) }
                let weights = model.weights(planar: input)
                print("weights", weights.x, weights.y, weights.z)
                var options = ImageExportOptions()
                options.maxLongEdge = arguments.count == 4 ? Int(arguments[3]) : 1600
                options.keepMetadata = false
                let output = URL(fileURLWithPath: arguments[2])
                try? FileManager.default.removeItem(at: output)
                let lut = CreativeLUT(cube: model.lut(weights: weights, title: "AI Look"), name: "AI Look")
                try ImageExporter.export(url, to: output, edits: MediaEdits(lut: lut, strength: 0.75), options: options)
                print("已写入 \(output.path)")
                return
            }
            if command == "render" || command == "match" {
                // render <image> <recipe.json | -> <out.jpg> [long edge]: the image with a saved recipe applied
                //   (local adjustments included; LUT references are skipped).
                // match <image> <reference> <out.jpg> [long edge]: 「匹配色调」 toward the reference, at 80%.
                let output = URL(fileURLWithPath: arguments[3])
                var options = ImageExportOptions()
                options.maxLongEdge = arguments.count == 5 ? Int(arguments[4]) : 1600
                options.keepMetadata = false
                // WATERMARK="text" (and WATERMARK_POSITION=topLeft…) draws a watermark, as in export.
                if let text = ProcessInfo.processInfo.environment["WATERMARK"] {
                    var mark = Watermark(text: text)
                    if let position = ProcessInfo.processInfo.environment["WATERMARK_POSITION"].flatMap(Watermark.Position.init) { mark.position = position }
                    options.watermark = mark
                }
                var edits = MediaEdits()
                if command == "render" {
                    if arguments[2] != "-" {
                        var recipe = try JSONDecoder().decode(EditRecipe.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
                        recipe.lut = nil
                        try recipe.validate()
                        edits = MediaEdits(recipe: recipe, lut: nil)
                    }
                } else {
                    let session = try ImageGradeSession(url: url, maximumDimension: 1024)
                    let plain = try await session.frame(edits: MediaEdits())
                    let source = try ColorPipeline.sdrBitmap(plain.image, headroom: plain.headroom)
                    let reference = URL(fileURLWithPath: arguments[2])
                    guard let referenceSource = CGImageSourceCreateWithURL(reference as CFURL, nil),
                          let referenceImage = CGImageSourceCreateThumbnailAtIndex(referenceSource, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 1024] as CFDictionary),
                          let from = LookMatch.statistics(source), let to = LookMatch.statistics(referenceImage) else { exit(4) }
                    edits = MediaEdits(lut: CreativeLUT(cube: LookMatch.lut(from: from, to: to, title: "match"), name: "match"), strength: 0.8)
                }
                try? FileManager.default.removeItem(at: output)
                try ImageExporter.export(url, to: output, edits: edits, options: options)
                print("已写入 \(output.path)")
            } else if command == "similar" {
                // Groups near-duplicates and bursts among the images in a folder.
                let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                    .filter { ["jpg", "jpeg", "heic", "png", "dng", "tif", "tiff"].contains($0.pathExtension.lowercased()) }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                let start = Date()
                let items = files.compactMap { file in PhotoFingerprint.read(file).map { SimilarPhotos.Item(id: file.lastPathComponent, folder: url.path, print: $0) } }
                print("\(items.count) 张，指纹用时 \(Int(Date().timeIntervalSince(start) * 1000)) ms")
                for group in SimilarPhotos.groups(items) { print("\(group.kind.rawValue) · \(group.ids.joined(separator: ", "))") }
                if ProcessInfo.processInfo.environment["SIMILAR_DEBUG"] != nil {
                    for (i, a) in items.enumerated() {
                        let nearest = items.enumerated().filter { $0.offset != i }.min { SimilarPhotos.distance(a.print.hash, $0.element.print.hash) < SimilarPhotos.distance(a.print.hash, $1.element.print.hash) }
                        if let n = nearest?.element {
                            let color = zip(a.print.color, n.print.color).reduce(Float(0)) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }
                            print(a.id, "→", n.id, SimilarPhotos.distance(a.print.hash, n.print.hash), String(format: "color %.3f aspect %.3f/%.3f", color, a.print.aspect, n.print.aspect))
                        }
                    }
                }
            } else if command == "live" {
                // Turns a short video into a Live Photo pair (cover JPEG + paired MOV) in a new folder; the system's
                // pairing check runs inside. The cover defaults to just before the end of the clip.
                let duration = try await AVURLAsset(url: url).load(.duration).seconds
                let cover = arguments.count == 4 ? (Double(arguments[3]) ?? duration - 0.2) : duration - 0.2
                let clip = ClipSettings(start: 0, end: min(duration, 3.0), cover: min(cover, min(duration, 3.0) - 0.05))
                let result = try await LivePhotoPipeline.export(url, to: URL(fileURLWithPath: arguments[2]).standardizedFileURL,
                                                                 clip: clip, edits: MediaEdits())
                print(result.imageURL.path); print(result.videoURL.path)
            } else if command == "auto" {
                // Developer check for 自动: the values, the statistics after, and an optional before|after JPEG.
                let session = try ImageGradeSession(url: url, maximumDimension: 1024)
                let plain = try await session.frame(edits: MediaEdits())
                guard let before = ScopeAnalyzer.analyze(plain.image, headroom: plain.headroom)?.analysis else { exit(4) }
                let auto = AutoEnhance.adjustments(for: before)
                let changed = AdjustmentParameter.allCases.filter { auto[$0] != 0 }.map { "\($0.title) \(auto[$0])" }
                print(changed.isEmpty ? "（无需调整）" : changed.joined(separator: "  "))
                let edited = try await session.frame(edits: MediaEdits(adjustments: auto))
                if let after = ScopeAnalyzer.analyze(edited.image, headroom: edited.headroom)?.analysis {
                    print(String(format: "p5 %.2f→%.2f  p50 %.2f→%.2f  p95 %.2f→%.2f  sat %.2f→%.2f  clipH %.3f→%.3f",
                                 before.p5, after.p5, before.p50, after.p50, before.p95, after.p95,
                                 before.meanSaturation, after.meanSaturation, before.clippedHighlights, after.clippedHighlights))
                }
                if arguments.count == 3 {
                    let left = ColorPipeline.toneMap(plain.image, sourceHeadroom: plain.headroom)
                    let right = edited.image.transformed(by: .init(translationX: left.extent.width + 8, y: 0))
                    let pair = right.composited(over: left)
                    try ColorPipeline.shared.writeJPEGRepresentation(of: pair, to: URL(fileURLWithPath: arguments[2]),
                        colorSpace: ColorPipeline.outputSpace, options: [:])
                }
            } else if command == "analyze" {
                // Developer check for the coach: statistics and tips for one photo, as the app computes them.
                let session = try ImageGradeSession(url: url, maximumDimension: 1024)
                let frame = try await session.frame(edits: MediaEdits())
                guard let a = ScopeAnalyzer.analyze(frame.image, headroom: frame.headroom)?.analysis else { exit(4) }
                print(String(format: "p1 %.2f p5 %.2f p50 %.2f p95 %.2f p99 %.2f mean %.2f clipH %.3f clipS %.3f sat %.2f bright %.2f dark %.2f neutral %.2f rgb %@",
                             a.p1, a.p5, a.p50, a.p95, a.p99, a.meanLuma, a.clippedHighlights, a.clippedShadows, a.meanSaturation,
                             a.brightFraction, a.darkFraction, a.neutralFraction, a.neutralRGB.map { String(format: "%.3f", $0) }.joined(separator: "/")))
                for insight in PhotoCoach.insights(for: a, edits: MediaEdits(), profile: LearnerProfile()) {
                    print("· \(insight.title)  \(insight.suggestion?.label ?? "")")
                }
            } else if command == "details" {
                let motion = arguments.count == 3 ? URL(fileURLWithPath: arguments[2]).standardizedFileURL : nil
                for file in [url] + (motion.map { [$0] } ?? []) where !FileManager.default.fileExists(atPath: file.path) {
                    print("找不到文件：\(file.path)")
                    exit(1)
                }
                print(await MediaDetails.read(url, motion: motion).text)
            } else if command == "inspect" {
                let metadata = try await MediaInspector.inspect(url)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                print(String(decoding: try encoder.encode(metadata), as: UTF8.self))
            } else if command == "lut" {
                let lut = try CubeLUT(text: String(contentsOf: url, encoding: .utf8))
                print("有效 3D LUT：\(lut.title ?? url.lastPathComponent)，\(lut.dimension) 阶，\(lut.rgb.count / 3) 条 RGB")
                print("输入域：\(lut.domainMin) → \(lut.domainMax)")
                print("这里只验证结构；尚未执行色彩转换或渲染。")
            } else if command == "straighten" {
                let assessment = try await ImageStraightener.analyze(url)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(decoding: try encoder.encode(assessment), as: UTF8.self))
                if arguments.count == 3 {
                    if let plan = assessment.plan {
                        _ = try ImageStraightener.exportPNG(url, to: URL(fileURLWithPath: arguments[2]), degrees: plan.rotationDegrees)
                        print("已导出 SDR PNG 副本；原片保留。")
                    } else {
                        print("未自动导出：\(assessment.message)")
                        exit(3)
                    }
                }
            } else {
                guard let degrees = Double(arguments[2]), degrees.isFinite else { throw StraighteningError.invalidGeometry }
                let plan = try ImageStraightener.exportPNG(url, to: URL(fileURLWithPath: arguments[3]), degrees: degrees)
                print("已导出 SDR PNG 副本：\(plan.outputWidth) × \(plan.outputHeight)；原片保留。")
            }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
