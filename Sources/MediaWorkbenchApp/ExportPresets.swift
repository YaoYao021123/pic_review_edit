import Foundation
import MediaCore

/// A saved set of photo export choices: format, size, resolution, file names and watermark.
/// The destination and video codec stay as they are when a preset is chosen.
struct ExportPreset: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var image: ImageExportOptions
    var naming: String

    var isBuiltIn: Bool { id.hasPrefix("builtin.") }

    static var builtIns: [ExportPreset] {
        var original = ImageExportOptions()
        original.quality = 0.95
        var social = ImageExportOptions()
        social.quality = 0.92; social.maxLongEdge = 2048; social.removeLocation = true
        var print = ImageExportOptions()
        print.quality = 1; print.dpi = 300
        return [
            ExportPreset(id: "builtin.original", name: L("原始尺寸 · 高质量"), image: original, naming: ExportNaming.defaultPattern),
            ExportPreset(id: "builtin.social", name: L("社交平台 · 长边 2048"), image: social, naming: ExportNaming.defaultPattern),
            ExportPreset(id: "builtin.print", name: L("打印 · 300 dpi"), image: print, naming: "{date}-{name}")
        ]
    }

    func matches(_ settings: ExportSettings) -> Bool { settings.image == image && settings.naming == naming }

    func applied(to settings: ExportSettings) -> ExportSettings {
        var result = settings
        result.image = image
        result.naming = naming
        return result
    }
}

enum ExportPresetStore {
    private static let key = "guangji.exportPresets"

    static func load() -> [ExportPreset] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode([ExportPreset].self, from: data) else { return [] }
        return saved.filter { !$0.isBuiltIn }
    }

    static func save(_ presets: [ExportPreset]) {
        if let data = try? JSONEncoder().encode(presets.filter { !$0.isBuiltIn }) { UserDefaults.standard.set(data, forKey: key) }
    }
}
