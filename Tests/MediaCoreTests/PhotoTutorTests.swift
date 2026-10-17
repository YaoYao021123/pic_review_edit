import CoreImage
import Foundation
import ImageIO
import Testing
@testable import MediaCore

/// Intercepts requests to the fake host and replies with a canned response.
final class FakeAnthropic: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "tutor.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
            Self.lastBody = data
        } else { Self.lastBody = request.httpBody }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: ["content-type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct PhotoTutorTests {
    private func context(_ question: String = "天空为什么发灰？", preview: Data? = Data([0xFF, 0xD8, 0xFF])) -> TutorContext {
        var analysis = PhotoAnalysis(); analysis.p50 = 0.4; analysis.clippedHighlights = 0.02; analysis.skyFraction = 0.3
        var edits = MediaEdits(); edits.adjustments.highlights = -20
        var profile = LearnerProfile(); profile.level = .intermediate; profile.topics = [.landscape]
        return TutorContext(question: question, previewJPEG: preview, analysis: analysis, edits: edits, profile: profile,
                            isVideo: false, pixelSize: CGSize(width: 4000, height: 3000), coachTips: ["高光溢出 2.0%"])
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func response(answer: [String: Any], stop: String = "end_turn", model: String = "claude-opus-5-5") throws -> Data {
        let text = String(decoding: try JSONSerialization.data(withJSONObject: answer), as: UTF8.self)
        return try JSONSerialization.data(withJSONObject: [
            "id": "msg_1", "type": "message", "role": "assistant", "model": model, "stop_reason": stop,
            "content": [["type": "thinking", "thinking": "", "signature": "sig-abc"], ["type": "text", "text": text]]
        ])
    }

    @Test func opusRequestUsesStructuredOutputFallbacksEffortAndCaching() throws {
        let tutor = ClaudePhotoTutor(apiKey: "test", model: "claude-opus-5-5")
        let (data, transcript) = try tutor.buildRequest(context(), history: TutorTranscript())
        let body = try object(data)
        #expect(body["model"] as? String == "claude-opus-5-5")
        #expect(body["fallbacks"] as? String == "default")
        #expect((body["cache_control"] as? [String: String])?["type"] == "ephemeral")
        let output = try #require(body["output_config"] as? [String: Any])
        #expect(output["effort"] as? String == "medium")
        #expect((output["format"] as? [String: Any])?["type"] as? String == "json_schema")
        #expect(body["thinking"] == nil) // adaptive by default on Opus 5.5
        let messages = try #require(body["messages"] as? [[String: Any]])
        let content = try #require(messages.first?["content"] as? [[String: Any]])
        #expect(content.first?["type"] as? String == "image")
        let text = try #require(content.last?["text"] as? String)
        #expect(text.contains("\"level\":\"intermediate\"") && text.contains("天空为什么发灰") && text.contains("clippedHighlights"))
        #expect(transcript.messages.count == 1)
        #expect(tutor.usesFallbacks)
    }

    @Test func haikuOmitsEffortAndFallbacks() throws {
        let tutor = ClaudePhotoTutor(apiKey: "test", model: "claude-haiku-4-5")
        let body = try object(tutor.buildRequest(context(preview: nil), history: TutorTranscript()).0)
        #expect(body["fallbacks"] == nil)
        #expect((body["output_config"] as? [String: Any])?["effort"] == nil)
        let content = (body["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]
        #expect(content?.count == 1 && content?.first?["type"] as? String == "text")
    }

    @Test func schemaUsesOnlySupportedKeywords() throws {
        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                for banned in ["minimum", "maximum", "minLength", "maxLength", "multipleOf", "minItems", "maxItems"] {
                    #expect(dict[banned] == nil, "unsupported keyword \(banned)")
                }
                if dict["type"] as? String == "object" {
                    #expect(dict["additionalProperties"] as? Bool == false)
                    let properties = Set((dict["properties"] as? [String: Any] ?? [:]).keys)
                    #expect(Set(dict["required"] as? [String] ?? []) == properties)
                }
                dict.values.forEach(walk)
            } else if let array = node as? [Any] { array.forEach(walk) }
        }
        walk(ClaudePhotoTutor.answerSchema(.english))
        #expect(try JSONSerialization.data(withJSONObject: ClaudePhotoTutor.answerSchema(.english), options: .sortedKeys)
                == JSONSerialization.data(withJSONObject: ClaudePhotoTutor.answerSchema(.english), options: .sortedKeys))
    }

    @Test func followUpsAppendWithoutEditingEarlierTurns() throws {
        let tutor = ClaudePhotoTutor(apiKey: "test")
        let (first, afterUser) = try tutor.buildRequest(context(), history: TutorTranscript())
        let (_, assistant) = try ClaudePhotoTutor.parseResponse(response(answer: ["answer": "A", "suggestions": [], "concepts": [], "followUps": []]))
        var history = afterUser; history.messages.append(assistant)
        let (second, transcript) = try tutor.buildRequest(context("那云呢？", preview: nil), history: history)
        let a = try object(first), b = try object(second)
        #expect(transcript.messages.count == 3)
        // Same system prompt and identical earlier messages (byte-for-byte after key-sorted encoding).
        #expect(try JSONSerialization.data(withJSONObject: a["system"]!, options: .sortedKeys)
                == JSONSerialization.data(withJSONObject: b["system"]!, options: .sortedKeys))
        let firstMessages = try #require(a["messages"] as? [Any]), secondMessages = try #require(b["messages"] as? [Any])
        #expect(try JSONSerialization.data(withJSONObject: firstMessages[0], options: .sortedKeys)
                == JSONSerialization.data(withJSONObject: secondMessages[0], options: .sortedKeys))
        // The assistant turn is echoed with its thinking block and signature intact.
        let echoed = try #require((secondMessages[1] as? [String: Any])?["content"] as? [[String: Any]])
        #expect(echoed.first?["type"] as? String == "thinking" && echoed.first?["signature"] as? String == "sig-abc")
    }

    @Test func responsesDecodeClampAndRejectCleanly() throws {
        let answer: [String: Any] = [
            "answer": "先压高光。",
            "suggestions": [
                ["label": "高光 -30 · 蓝色明亮度 -15", "concept": "highlights",
                 "adjustments": [["parameter": "highlights", "delta": -30], ["parameter": "made_up", "delta": 5],
                                 ["parameter": "exposure", "delta": 99]],
                 "hsl": [["band": "blue", "component": "luminance", "delta": -15]]],
                ["label": "空的", "concept": "sky", "adjustments": [], "hsl": []]
            ],
            "concepts": ["highlights", "sky", "nonsense"],
            "followUps": ["为什么？"]
        ]
        let (decoded, _) = try ClaudePhotoTutor.parseResponse(response(answer: answer))
        #expect(decoded.answer == "先压高光。" && decoded.concepts == [.highlights, .sky] && decoded.followUps == ["为什么？"])
        #expect(decoded.suggestions.count == 1)
        let first = try #require(decoded.suggestions.first)
        #expect(first.concept == .highlights)
        #expect(first.suggestion.deltas[.highlights] == -30 && first.suggestion.deltas[.exposure] == 4)
        #expect(first.suggestion.hsl == [HSLChange(band: .blue, component: .luminance, delta: -15)])

        #expect(throws: TutorError.refused) { try ClaudePhotoTutor.parseResponse(self.response(answer: [:], stop: "refusal")) }
        #expect(throws: TutorError.truncated) { try ClaudePhotoTutor.parseResponse(self.response(answer: [:], stop: "max_tokens")) }
        #expect(throws: TutorError.self) { try ClaudePhotoTutor.parseResponse(Data("not json".utf8)) }
    }

    @Test func previewIsSmallJPEGWithoutMetadata() throws {
        let image = CIImage(color: CIColor(red: 0.4, green: 0.5, blue: 0.6)).cropped(to: CGRect(x: 0, y: 0, width: 3000, height: 2000))
        let jpeg = try #require(TutorPreview.jpeg(image))
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect((properties[kCGImagePropertyPixelWidth] as? Int) == 1024)
        #expect(properties[kCGImagePropertyGPSDictionary] == nil && properties[kCGImagePropertyMakerAppleDictionary] == nil)
        #expect(jpeg.count < 200_000)
    }

    @Test func httpRoundTripSendsHeadersAndMapsErrors() async throws {
        URLProtocol.registerClass(FakeAnthropic.self)
        defer { URLProtocol.unregisterClass(FakeAnthropic.self) }
        var tutor = ClaudePhotoTutor(apiKey: "sk-test", model: "claude-opus-5-5")
        tutor.endpoint = URL(string: "https://tutor.test/v1/messages")!
        FakeAnthropic.status = 200
        FakeAnthropic.body = try response(answer: ["answer": "好的", "suggestions": [], "concepts": ["sky"], "followUps": []])
        let (answer, transcript) = try await tutor.ask(context(), history: TutorTranscript())
        #expect(answer.answer == "好的" && answer.model == "claude-opus-5-5" && transcript.turns == 1)
        let request = try #require(FakeAnthropic.lastRequest)
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")

        FakeAnthropic.status = 401
        FakeAnthropic.body = Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8)
        await #expect(throws: TutorError.http(401, "invalid x-api-key")) { _ = try await tutor.ask(self.context(), history: TutorTranscript()) }
        await #expect(throws: TutorError.missingKey) { _ = try await ClaudePhotoTutor(apiKey: "").ask(self.context(), history: TutorTranscript()) }
    }
}
