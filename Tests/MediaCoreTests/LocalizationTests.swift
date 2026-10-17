import Foundation
import Testing
@testable import MediaCore

/// Guards the English table: every value must keep its key's format placeholders, or
/// String(localized:) would read the wrong arguments. `scripts/localize.py check` also
/// verifies that every key in the code has a translation.
struct LocalizationTests {
    private let english = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Localization/en.lproj")

    private func placeholders(_ text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:ll|l|h)?[dfs@uxXeEgGc]"#)
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }.sorted()
    }

    @Test func testEnglishStringsKeepPlaceholders() throws {
        let table = try #require(NSDictionary(contentsOf: english.appendingPathComponent("Localizable.strings")) as? [String: String])
        #expect(table.count > 1000)
        for (key, value) in table {
            #expect(placeholders(key) == placeholders(value), "\(key) → \(value)")
        }
    }

    @Test func testPluralRulesAreWellFormed() throws {
        let plurals = try #require(NSDictionary(contentsOf: english.appendingPathComponent("Localizable.stringsdict")) as? [String: [String: Any]])
        for (key, entry) in plurals {
            let format = try #require(entry["NSStringLocalizedFormatKey"] as? String)
            let rule = try #require(entry["n"] as? [String: String], "\(key)")
            #expect(format.contains("#@n@"))
            #expect(rule["one"]?.contains("%lld") == true && rule["other"]?.contains("%lld") == true)
        }
    }

    @Test func testWithoutABundleTheChineseSourceTextIsShown() {
        #expect(L("曝光") == "曝光")
        #expect(L("已添加 \(3) 项") == "已添加 3 项")
        #expect(AppLanguage.current == .chinese)
    }
}
