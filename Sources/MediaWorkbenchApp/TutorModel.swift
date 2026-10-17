import AVFoundation
import CoreImage
import Foundation
import MediaCore
import Observation
import Security

/// The user's own API key, kept in the macOS Keychain (never in files or defaults).
enum KeychainStore {
    private static let service = "local.mediaworkbench.prototype.anthropic"
    private static let account = "api-key"

    static func read() -> String? {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                      kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        delete()
        let attributes: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                           kSecAttrAccount: account, kSecValueData: Data(key.utf8),
                                           kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        SecItemDelete(query as CFDictionary)
    }
}

struct TutorSettings: Codable, Equatable {
    /// Off until the user turns it on and agrees to what is sent.
    var enabled = false
    var model = ClaudePhotoTutor.defaultModel
    var sendPreview = true
}

struct TutorTurn: Identifiable {
    let id = UUID()
    let question: String
    var answer: TutorAnswer?
    var error: String?
    var sentPreview: Bool
}

/// "Ask about this photo": an opt-in conversation per open document.
@MainActor
@Observable
final class TutorModel {
    var settings: TutorSettings {
        didSet {
            if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "guangji.tutor") }
            if settings.model != oldValue.model { reset() }
        }
    }
    private(set) var hasKey = false
    private(set) var turns: [TutorTurn] = []
    private(set) var isAsking = false
    var draft = ""

    @ObservationIgnored private var transcript = TutorTranscript()
    @ObservationIgnored private var lastSentEdits: MediaEdits?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Development snapshots use the offline sample tutor.
    @ObservationIgnored private let sampleMode = ProcessInfo.processInfo.environment["GUANGJI_TUTOR_SAMPLE"] != nil

    static let maxTurns = 8

    init() {
        if let data = UserDefaults.standard.data(forKey: "guangji.tutor"),
           let stored = try? JSONDecoder().decode(TutorSettings.self, from: data) {
            settings = stored
        } else {
            settings = TutorSettings()
        }
        hasKey = sampleMode || KeychainStore.read()?.isEmpty == false
        if sampleMode { settings.enabled = true }
    }

    var isReady: Bool { settings.enabled && hasKey }
    var modelTitle: String { sampleMode ? L("示例回答（离线）") : ClaudePhotoTutor.models.first { $0.id == settings.model }?.title ?? settings.model }

    func saveKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        hasKey = KeychainStore.save(trimmed)
    }

    func removeKey() {
        KeychainStore.delete()
        hasKey = false
    }

    /// Starts a fresh conversation (new photo, new model, or the user asked).
    func reset() {
        task?.cancel(); task = nil
        turns = []; transcript = TutorTranscript(); lastSentEdits = nil; isAsking = false
    }

    private func backend() -> PhotoTutor? {
        if sampleMode { return SampleTutor() }
        guard let key = KeychainStore.read(), !key.isEmpty else { return nil }
        return ClaudePhotoTutor(apiKey: key, model: settings.model)
    }

    func ask(_ question: String, editor: EditorModel, profile: LearnerProfile, coachTips: [String],
             onAnswer: @escaping @MainActor (TutorAnswer) -> Void) {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, isReady, !isAsking, editor.isLoaded, turns.count < Self.maxTurns,
              let tutor = backend() else { return }
        draft = ""
        isAsking = true
        let edits = editor.edits
        // Re-send the picture only when the look changed since the last one we sent.
        let attachPreview = settings.sendPreview && edits != lastSentEdits
        turns.append(TutorTurn(question: text, sentPreview: attachPreview))
        let index = turns.count - 1
        let history = transcript
        task = Task {
            let preview = attachPreview ? await editor.tutorPreview() : nil
            let context = TutorContext(question: text, previewJPEG: preview, analysis: editor.scopes?.analysis, edits: edits,
                                       profile: profile, isVideo: editor.isVideo, pixelSize: editor.pixelSize, coachTips: coachTips)
            do {
                let (answer, next) = try await tutor.ask(context, history: history)
                guard !Task.isCancelled, turns.indices.contains(index) else { return }
                transcript = next
                if preview != nil { lastSentEdits = edits }
                turns[index].answer = answer
                onAnswer(answer)
            } catch is CancellationError {
            } catch {
                guard turns.indices.contains(index) else { return }
                turns[index].error = error.localizedDescription
            }
            isAsking = false
        }
    }
}

extension EditorModel {
    var pixelSize: CGSize? {
        metadata.map { CGSize(width: $0.displayWidth, height: $0.displayHeight) }
    }

    /// The current edited look as a small, metadata-free JPEG.
    func tutorPreview() async -> Data? {
        if let frame {
            let image = frame.image, headroom = frame.headroom
            return await Task.detached(priority: .userInitiated) { TutorPreview.jpeg(image, headroom: headroom) }.value
        }
        guard let item = player?.currentItem else { return nil }
        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.videoComposition = item.videoComposition
        generator.maximumSize = CGSize(width: 1024, height: 1024)
        generator.dynamicRangePolicy = .forceSDR
        generator.appliesPreferredTrackTransform = true
        let time = CMTime(seconds: position / max(0.01, playbackSpeed), preferredTimescale: 60000)
        guard let bitmap = try? await generator.image(at: time).image else { return nil }
        return await Task.detached(priority: .userInitiated) { TutorPreview.jpeg(CIImage(cgImage: bitmap)) }.value
    }
}
