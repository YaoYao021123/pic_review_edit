import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Question and answer

/// Everything one question sends. Built fresh for every turn from the photo as it is now.
public struct TutorContext: Sendable {
    public var question: String
    /// Downscaled JPEG of the current edited frame (no metadata); nil = text only.
    public var previewJPEG: Data?
    public var analysis: PhotoAnalysis?
    public var edits: MediaEdits
    public var profile: LearnerProfile
    public var isVideo: Bool
    public var pixelSize: CGSize?
    /// Titles of the local coach's current tips, so the answer can build on them.
    public var coachTips: [String]

    public init(question: String, previewJPEG: Data?, analysis: PhotoAnalysis?, edits: MediaEdits,
                profile: LearnerProfile, isVideo: Bool, pixelSize: CGSize?, coachTips: [String]) {
        self.question = question; self.previewJPEG = previewJPEG; self.analysis = analysis; self.edits = edits
        self.profile = profile; self.isVideo = isVideo; self.pixelSize = pixelSize; self.coachTips = coachTips
    }
}

public struct TutorSuggestion: Equatable, Sendable {
    public var label: String
    public var concept: Concept?
    public var suggestion: CoachSuggestion
}

public struct TutorAnswer: Equatable, Sendable {
    public var answer: String
    public var suggestions: [TutorSuggestion]
    public var concepts: [Concept]
    public var followUps: [String]
    /// Model that produced the answer (may differ from the requested one after a fallback).
    public var model: String
}

public enum TutorError: Error, LocalizedError, Equatable {
    case missingKey, refused, truncated, badResponse(String), http(Int, String), network(String)
    public var errorDescription: String? {
        switch self {
        case .missingKey: L("还没有设置 Anthropic API 密钥。")
        case .refused: L("这个问题没有得到回答（被安全策略拒绝）。换个问法试试。")
        case .truncated: L("回答过长被截断了，请把问题问得更具体一些。")
        case .badResponse(let detail): L("无法解析回答：\(detail)")
        case .http(401, _): L("API 密钥无效或已失效，请在设置中更新。")
        case .http(429, _): L("请求太频繁或额度已用完，请稍后再试。")
        case .http(let code, let message) where code >= 500: L("服务暂时不可用（\(code)）。\(message)")
        case .http(let code, let message): L("请求失败（\(code)）：\(message)")
        case .network(let detail): L("无法连接 Anthropic：\(detail)")
        }
    }
}

/// A conversation-capable tutor backend. Other providers can implement this
/// (for example a provider available in mainland China) without UI changes.
public protocol PhotoTutor: Sendable {
    var displayName: String { get }
    /// Answers a question. `history` is the opaque transcript returned by the
    /// previous call; pass it back unchanged for follow-ups.
    func ask(_ context: TutorContext, history: TutorTranscript) async throws -> (TutorAnswer, TutorTranscript)
}

/// Opaque, append-only message history. Assistant turns are kept byte-for-byte
/// (thinking blocks included) because newer models reject edited histories.
public struct TutorTranscript: Sendable, Equatable {
    public var messages: [Data] = []
    public var turns: Int { messages.count / 2 }
    public init() {}
}

// MARK: - Preview image

public enum TutorPreview {
    /// A small sRGB JPEG with no EXIF, GPS or maker data.
    public static func jpeg(_ image: CIImage, headroom: Float = 1, maxDimension: CGFloat = 1024, quality: Double = 0.8) -> Data? {
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1, !extent.isInfinite else { return nil }
        let scale = min(1, maxDimension / max(extent.width, extent.height))
        let small = image.transformed(by: .init(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: .init(scaleX: scale, y: scale))
        guard let bitmap = try? ColorPipeline.sdrBitmap(small, headroom: headroom) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, bitmap, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

// MARK: - Claude backend (raw HTTP; Swift has no official Anthropic SDK)

public struct ClaudePhotoTutor: PhotoTutor {
    public struct ModelOption: Identifiable, Sendable, Equatable {
        public let id: String
        public let title: String
        public let note: String
    }
    public static let models: [ModelOption] = [
        ModelOption(id: "claude-opus-5-5", title: "Claude Opus 5.5", note: L("默认：讲解最准确（$4 / $20 每百万 token）")),
        ModelOption(id: "claude-sonnet-5-5", title: "Claude Sonnet 5.5", note: L("更快，成本约一半（$2 / $10 每百万 token）")),
        ModelOption(id: "claude-haiku-4-5", title: "Claude Haiku 4.5", note: L("最快最便宜，讲解较简单（$1 / $5 每百万 token）"))
    ]
    public static let defaultModel = "claude-opus-5-5"

    public let apiKey: String
    public let model: String
    public var endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public var displayName: String { Self.models.first { $0.id == model }?.title ?? model }

    /// The interface language; Claude answers in it.
    public var language = AppLanguage.current

    public init(apiKey: String, model: String = ClaudePhotoTutor.defaultModel) {
        self.apiKey = apiKey; self.model = model
    }

    /// Server-side refusal fallback ("default" routing) on models that accept it.
    var usesFallbacks: Bool { model == "claude-opus-5-5" || model == "claude-sonnet-5-5" }
    /// Haiku 4.5 rejects `output_config.effort`.
    var usesEffort: Bool { !model.hasPrefix("claude-haiku") }

    public func ask(_ context: TutorContext, history: TutorTranscript) async throws -> (TutorAnswer, TutorTranscript) {
        guard !apiKey.isEmpty else { throw TutorError.missingKey }
        let (body, transcript) = try buildRequest(context, history: history)
        var request = URLRequest(url: endpoint, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if usesFallbacks { request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta") }
        request.httpBody = body
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw TutorError.network(error.localizedDescription) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw TutorError.http(status, Self.errorMessage(data)) }
        let (answer, assistant) = try Self.parseResponse(data)
        var next = transcript
        next.messages.append(assistant)
        return (answer, next)
    }

    // MARK: Request

    /// Returns the JSON body and the transcript extended with this user turn.
    func buildRequest(_ context: TutorContext, history: TutorTranscript) throws -> (Data, TutorTranscript) {
        var userContent: [[String: Any]] = []
        if let jpeg = context.previewJPEG {
            userContent.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg",
                                                            "data": jpeg.base64EncodedString()]])
        }
        userContent.append(["type": "text", "text": Self.userText(context)])
        let userMessage = try JSONSerialization.data(withJSONObject: ["role": "user", "content": userContent], options: [.sortedKeys])
        var transcript = history
        transcript.messages.append(userMessage)
        let messages = try transcript.messages.map { try JSONSerialization.jsonObject(with: $0) }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "system": [["type": "text", "text": Self.systemPrompt(language)]],
            "messages": messages,
            // Caches the frozen prefix (system + earlier turns) for follow-up questions.
            "cache_control": ["type": "ephemeral"]
        ]
        var outputConfig: [String: Any] = ["format": ["type": "json_schema", "schema": Self.answerSchema(language)]]
        if usesEffort { outputConfig["effort"] = "medium" }
        body["output_config"] = outputConfig
        if usesFallbacks { body["fallbacks"] = "default" }
        return (try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), transcript)
    }

    static func userText(_ c: TutorContext) -> String {
        var context: [String: Any] = [
            "learner": [
                "level": c.profile.level.rawValue,
                "interests": c.profile.topics.map(\.rawValue).sorted(),
                "alreadyKnows": Concept.allCases.filter { c.profile.isLearned($0) }.map(\.rawValue)
            ],
            "media": c.isVideo ? "video frame" : "photo",
            "currentSettings": settingsSummary(c.edits),
            "localCoachTips": c.coachTips,
            "previewAttached": c.previewJPEG != nil
        ]
        if let size = c.pixelSize { context["pixelSize"] = "\(Int(size.width))x\(Int(size.height))" }
        if let a = c.analysis {
            func r(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
            let hues = HueBand.allCases.sorted { a.hueShare[$0.rawValue] > a.hueShare[$1.rawValue] }
                .filter { a.hueShare[$0.rawValue] > 0.1 }.map { "\($0)" }
            context["stats"] = [
                "lumaP5": r(a.p5), "lumaP50": r(a.p50), "lumaP95": r(a.p95),
                "clippedHighlights": r(a.clippedHighlights), "clippedShadows": r(a.clippedShadows),
                "meanSaturation": r(a.meanSaturation), "nearlySaturated": r(a.saturatedFraction),
                "neutralRGB": a.neutralRGB.map(r), "skyShare": r(a.skyFraction), "dominantHues": hues,
                "looksLikeLog": a.looksLikeLog
            ]
        }
        let json = (try? JSONSerialization.data(withJSONObject: context, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return "<context>\n\(json)\n</context>\n\nQuestion: \(c.question)"
    }

    static func settingsSummary(_ edits: MediaEdits) -> [String: Any] {
        var result: [String: Any] = [:]
        let adjustments = AdjustmentParameter.allCases.filter { edits.adjustments[$0] != 0 }
        if !adjustments.isEmpty {
            result["adjustments"] = Dictionary(uniqueKeysWithValues: adjustments.map { ($0.rawValue, edits.adjustments[$0]) })
        }
        var hsl: [String: Double] = [:]
        for band in HueBand.allCases {
            for component in HSLAdjustments.Component.allCases where edits.hsl[band, component] != 0 {
                hsl["\(band).\(component.rawValue)"] = edits.hsl[band, component]
            }
        }
        if !hsl.isEmpty { result["hsl"] = hsl }
        if let lut = edits.lut { result["lut"] = ["name": lut.name, "strength": edits.strength] }
        if !edits.wheels.isNeutral { result["colorWheels"] = "adjusted" }
        if !edits.curves.isIdentity { result["curves"] = "adjusted" }
        if edits.degrees != 0 { result["straightenDegrees"] = edits.degrees }
        if !edits.bypass.isEmpty { result["stagesSwitchedOff"] = edits.bypass.map(\.rawValue).sorted() }
        return result
    }

    // MARK: Response

    static func parseResponse(_ data: Data) throws -> (TutorAnswer, Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TutorError.badResponse(L("不是 JSON"))
        }
        let stop = object["stop_reason"] as? String
        if stop == "refusal" { throw TutorError.refused }
        if stop == "max_tokens" { throw TutorError.truncated }
        guard let content = object["content"] as? [[String: Any]] else { throw TutorError.badResponse(L("缺少 content")) }
        // Structured output arrives as the final text block; thinking blocks precede it.
        guard let text = content.last(where: { $0["type"] as? String == "text" })?["text"] as? String,
              let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw TutorError.badResponse(L("回答格式不符"))
        }
        let assistant = try JSONSerialization.data(withJSONObject: ["role": "assistant", "content": content], options: [.sortedKeys])
        return (decodeAnswer(json, model: object["model"] as? String ?? ""), assistant)
    }

    static func decodeAnswer(_ json: [String: Any], model: String) -> TutorAnswer {
        let suggestions = (json["suggestions"] as? [[String: Any]] ?? []).prefix(3).compactMap { item -> TutorSuggestion? in
            let label = (item["label"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var deltas: [AdjustmentParameter: Double] = [:]
            for change in item["adjustments"] as? [[String: Any]] ?? [] {
                guard let name = change["parameter"] as? String, let parameter = AdjustmentParameter(rawValue: name),
                      let delta = (change["delta"] as? NSNumber)?.doubleValue, delta.isFinite else { continue }
                let span = parameter.range.upperBound - parameter.range.lowerBound
                deltas[parameter] = min(span / 2, max(-span / 2, delta))
            }
            var hsl: [HSLChange] = []
            for change in item["hsl"] as? [[String: Any]] ?? [] {
                guard let bandName = change["band"] as? String, let band = HueBand.allCases.first(where: { "\($0)" == bandName }),
                      let componentName = change["component"] as? String,
                      let component = HSLAdjustments.Component(rawValue: componentName),
                      let delta = (change["delta"] as? NSNumber)?.doubleValue, delta.isFinite else { continue }
                hsl.append(HSLChange(band: band, component: component, delta: min(100, max(-100, delta))))
            }
            guard !label.isEmpty, !deltas.isEmpty || !hsl.isEmpty else { return nil }
            return TutorSuggestion(label: label, concept: (item["concept"] as? String).flatMap(Concept.init(rawValue:)),
                                   suggestion: CoachSuggestion(label: label, deltas: deltas, hsl: hsl))
        }
        return TutorAnswer(answer: json["answer"] as? String ?? "",
                           suggestions: Array(suggestions),
                           concepts: (json["concepts"] as? [String] ?? []).compactMap(Concept.init(rawValue:)),
                           followUps: Array((json["followUps"] as? [String] ?? []).prefix(3)),
                           model: model)
    }

    static func errorMessage(_ data: Data) -> String {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return ((object?["error"] as? [String: Any])?["message"] as? String) ?? String(decoding: data.prefix(200), as: UTF8.self)
    }

    // MARK: Schema and prompt (frozen: byte-identical on every request)

    /// Built on demand ([String: Any] is not Sendable); key-sorted serialization keeps it byte-identical.
    static func answerSchema(_ language: AppLanguage) -> [String: Any] {
        func object(_ properties: [String: Any], required: [String]) -> [String: Any] {
            ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
        }
        let adjustment = object([
            "parameter": ["type": "string", "enum": AdjustmentParameter.allCases.map(\.rawValue)],
            "delta": ["type": "number", "description": "Change in slider units, added to the current value"]
        ], required: ["parameter", "delta"])
        let hsl = object([
            "band": ["type": "string", "enum": HueBand.allCases.map { "\($0)" }],
            "component": ["type": "string", "enum": HSLAdjustments.Component.allCases.map(\.rawValue)],
            "delta": ["type": "number", "description": "Change in slider units (-100...100)"]
        ], required: ["band", "component", "delta"])
        let suggestion = object([
            "label": ["type": "string", "description": language == .chinese
                      ? "Short Chinese label, e.g. 高光 -30 · 阴影 +20" // loc:ignore
                      : "Short English label, e.g. Highlights -30 · Shadows +20"],
            "concept": ["type": "string", "enum": Concept.allCases.map(\.rawValue)],
            "adjustments": ["type": "array", "items": adjustment],
            "hsl": ["type": "array", "items": hsl]
        ], required: ["label", "concept", "adjustments", "hsl"])
        return object([
            "answer": ["type": "string", "description": "The explanation, in \(language.replyLanguage)"],
            "suggestions": ["type": "array", "items": suggestion, "description": "0 to 3 concrete edits the app can apply"],
            "concepts": ["type": "array", "items": ["type": "string", "enum": Concept.allCases.map(\.rawValue)]],
            "followUps": ["type": "array", "items": ["type": "string"], "description": "2-3 short follow-up questions in \(language.replyLanguage)"]
        ], required: ["answer", "suggestions", "concepts", "followUps"])
    }

    static func systemPrompt(_ language: AppLanguage) -> String {
        let parameters = AdjustmentParameter.allCases.map { p in
            "- \(p.rawValue) (\(p.title)): range \(Int(p.range.lowerBound))...\(Int(p.range.upperBound))\(p == .exposure ? " EV" : "")"
        }.joined(separator: "\n")
        let concepts = Concept.allCases.map { "\($0.rawValue) (\($0.title))" }.joined(separator: ", ")
        // loc:ignore-next
        return """
        You are the photo-editing teacher inside Lucet 光集, a Mac app for grading photos, videos and Live Photos. \
        A learner asks about the photo they are editing. Each question comes with a small preview of the photo \
        as it currently looks (when attached), measured statistics, the current settings, the app's own coach tips, \
        and what the learner already knows.

        How to answer:
        - Answer in \(language.replyLanguage). Base every claim on the preview, the statistics or the settings; \
        if something cannot be judged from them, say so instead of guessing.
        - Teach, don't just prescribe: say what you see in this photo, why it matters, and what to try.
        - Match the learner's level. beginner: plain words, one idea at a time, at most about 200 characters, \
        no jargon without a short explanation. intermediate: may refer to the histogram, waveform, curves and HSL. \
        advanced: concise and technical, may cite the statistics.
        - Prefer the learner's interests when several directions are possible, and skip basics listed in alreadyKnows.
        - Never identify or guess who people in a photo are; talk only about how the image looks.
        - Use plain paragraphs; no markdown headings or tables.

        Suggestions (0 to 3) must be changes the app can apply directly: deltas added to the current slider values. \
        Keep them moderate, and give none when the question doesn't call for an edit. Available sliders:
        \(parameters)
        HSL bands: red, orange, yellow, green, aqua, blue, purple, magenta; components hue, saturation, luminance; \
        each -100...100 (hue ±100 shifts that band's hue by about ±30°).
        The app also has color wheels, tone curves, LUTs, cropping and straightening; you may teach them, but \
        express applicable suggestions only with the sliders and HSL above.
        Processing order: noise reduction, basic (light and color), color wheels, curves, HSL, LUT, sharpening, vignette.

        Concept ids for "concepts" and each suggestion's "concept": \(concepts).
        followUps: 2 to 3 short questions this learner might want to ask next about this photo.
        """
    }
}

/// Offline tutor for previews and development; never touches the network.
public struct SampleTutor: PhotoTutor {
    public init() {}
    public var displayName: String { L("示例回答（离线）") }
    public func ask(_ context: TutorContext, history: TutorTranscript) async throws -> (TutorAnswer, TutorTranscript) {
        try await Task.sleep(for: .milliseconds(400))
        var next = history
        next.messages.append(Data("{\"role\":\"user\",\"content\":\"\"}".utf8))
        next.messages.append(Data("{\"role\":\"assistant\",\"content\":[]}".utf8))
        let answer = TutorAnswer(
            answer: L("天空偏亮、云层细节少，是因为高光接近溢出。先把高光往下拉找回云的层次，再单独降低蓝色的明亮度让天空更深；地面不会受影响。"),
            suggestions: [TutorSuggestion(label: L("高光 -30 · 蓝色明亮度 -15"), concept: .highlights,
                                          suggestion: CoachSuggestion(label: L("高光 -30 · 蓝色明亮度 -15"), deltas: [.highlights: -30],
                                                                      hsl: [HSLChange(band: .blue, component: .luminance, delta: -15)]))],
            concepts: [.highlights, .sky], followUps: [L("为什么不直接降低曝光？"), L("怎么让云更立体？")], model: "sample")
        return (answer, next)
    }
}
