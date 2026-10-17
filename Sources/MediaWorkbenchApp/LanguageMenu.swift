import AppKit
import MediaCore
import SwiftUI

/// Interface language override (app menu › Language · 语言). Follows the system by
/// default; macOS also offers this per app in System Settings › General › Language & Region.
enum InterfaceLanguage: String, CaseIterable, Identifiable {
    case system, english = "en", chinese = "zh-Hans"
    var id: String { rawValue }

    /// Each language is named in itself, so the menu is readable whichever is showing.
    var title: String {
        switch self {
        case .system: L("跟随系统")
        case .english: "English"
        case .chinese: "简体中文" // loc:ignore (a language names itself)
        }
    }

    /// The app's own override, ignoring the system-wide language list.
    static var chosen: InterfaceLanguage {
        guard let id = Bundle.main.bundleIdentifier,
              let languages = UserDefaults.standard.persistentDomain(forName: id)?["AppleLanguages"] as? [String],
              let first = languages.first else { return .system }
        return first.hasPrefix("zh") ? .chinese : .english
    }

    @MainActor
    static func choose(_ language: InterfaceLanguage) {
        guard language != chosen else { return }
        if language == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
        }
        let alert = NSAlert()
        alert.messageText = L("重新打开光集后切换语言")
        alert.informativeText = L("你的素材库、编辑和设置都会保留。")
        alert.addButton(withTitle: L("现在重新打开"))
        alert.addButton(withTitle: L("稍后"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        relaunch()
    }

    @MainActor
    private static func relaunch() {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { NSApp.terminate(nil); return }
        // Start the new copy once this one has quit, so the two never edit the library together.
        let script = "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open -n \"\(bundle.path)\""
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        try? task.run()
        NSApp.terminate(nil)
    }
}

struct LanguageCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Menu {
                ForEach(InterfaceLanguage.allCases) { language in
                    Button { InterfaceLanguage.choose(language) } label: {
                        if language == InterfaceLanguage.chosen { Label(language.title, systemImage: "checkmark") } else { Text(language.title) }
                    }
                }
            } label: {
                Text(verbatim: "Language · 语言") // loc:ignore (readable in both languages)
            }
        }
    }
}
