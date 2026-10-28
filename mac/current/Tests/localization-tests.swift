import Foundation

@main
struct LocalizationTests {
    @MainActor static func main() throws {
        precondition(ReaderLanguage.allCases.count == 10)
        precondition(ReaderSettings().language == .system, "A new library must follow the system language")
        let settingsWithoutLanguage = try JSONDecoder().decode(ReaderSettings.self, from: Data("{}".utf8))
        precondition(settingsWithoutLanguage.language == .system, "Older settings without a language preference must follow the system")
        precondition(settingsWithoutLanguage.ocrLanguage.isEmpty, "Older settings must keep automatic OCR language detection")
        precondition(settingsWithoutLanguage.customInstructions.isEmpty, "Older settings must default to no personalization")
        var personalized = ReaderSettings()
        personalized.customInstructions = String(repeating: "🧭", count: 8000)
        precondition(!personalized.customInstructionsTooLong, "The limit must use UTF-16 like the backend")
        personalized.customInstructions += "x"; personalized.normalize()
        precondition(personalized.customInstructionsTooLong && personalized.customInstructions.hasSuffix("x"), "Never silently truncate user instructions")
        var ocrSettings = ReaderSettings(); ocrSettings.ocrLanguage = "zh-Hant"
        let restoredOCR = try JSONDecoder().decode(ReaderSettings.self, from: JSONEncoder().encode(ocrSettings))
        precondition(restoredOCR.ocrLanguage == "zh-Hant", "OCR language must persist independently of interface language")
        ocrSettings.ocrLanguage = "../../invalid"; ocrSettings.normalize()
        precondition(ocrSettings.ocrLanguage.isEmpty, "Malformed OCR model identifiers must be rejected")
        let resolutionCases: [([String], ReaderLanguage)] = [
            (["zh-TW"], .zhHant), (["zh-HK"], .zhHant), (["zh-MO"], .zhHant),
            (["zh-Hant-US"], .zhHant), (["zh-Hans-TW"], .zhHans), (["zh_CN"], .zhHans),
            (["ja-JP"], .ja), (["ko-KR"], .ko), (["fr-CA"], .fr), (["de-DE"], .de),
            (["es-MX"], .es), (["pt-BR"], .pt), (["it-IT", "de-AT"], .de), ([], .en)
        ]
        for (preferred, expected) in resolutionCases {
            precondition(ReaderLanguage.system.resolved(preferredLanguages: preferred) == expected, "Incorrect system language resolution: \(preferred)")
        }
        precondition(ReaderLanguage.en.resolved(preferredLanguages: ["ja-JP"]) == .en)
        let labelDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("margin-language-labels-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: labelDirectory) }
        let labelStore = ReaderStore(dataDirectory: labelDirectory)
        for language in ReaderLanguage.allCases {
            var settings = ReaderSettings(); settings.language = language
            let restored = try JSONDecoder().decode(ReaderSettings.self, from: JSONEncoder().encode(settings))
            precondition(restored.language == language, "Language preference must survive a saved settings roundtrip")
            labelStore.library.settings.language = language
            let locale = Locale(identifier: language.localeIdentifier)
            precondition(labelStore.ocrLanguageName("vi-VT") == locale.localizedString(forLanguageCode: "vi"),
                         "An unrecognized Vision region must still show the localized language name")
            precondition(labelStore.ocrLanguageName("zh-Hant") == locale.localizedString(forIdentifier: "zh-Hant"),
                         "Known OCR identifiers must retain their script-specific labels")
            precondition(labelStore.ocrLanguageName("zz-ZZ") == "zz-ZZ", "Unknown languages must retain their model identifier")
        }
        precondition(Set(ReaderUIStrings.translations.keys) == ReaderUIStrings.keys)
        for key in ReaderUIStrings.keys {
            precondition(ReaderUIStrings.translations[key]!.count == ReaderUIStrings.translatedLanguages.count)
            for language in ReaderLanguage.allCases where language != .system {
                let translation = ReaderUIStrings.translation(key, language: language)
                precondition(translation != nil && !translation!.isEmpty, "Missing \(language.rawValue): \(key)")
                if key.contains("{0}") {
                    precondition(translation!.contains("{0}"), "A numeric template lost its placeholder")
                    let interpolated = key.replacingOccurrences(of: "{0}", with: "123")
                    precondition(ReaderUIStrings.text(interpolated, language: language) == translation!.replacingOccurrences(of: "{0}", with: "123"))
                }
            }
        }
        precondition(ReaderUIStrings.text("设置", language: .ja) == "設定")
        precondition(ReaderUIStrings.text("设置", language: .ko) == "설정")
        precondition(ReaderUIStrings.text("设置", language: .fr) == "Réglages")
        precondition(ReaderUIStrings.text("设置", language: .de) == "Einstellungen")
        precondition(ReaderUIStrings.text("设置", language: .es) == "Ajustes")
        precondition(ReaderUIStrings.text("设置", language: .pt) == "Configurações")
        precondition(ReaderUIStrings.text("设置", language: .zhHant) == "設置")
        for scope in ChatContextScope.allCases {
            precondition(ReaderUIStrings.keys.contains(scope.label), "Untranslated context scope: \(scope.label)")
        }
        for key in ["OCR 语言", "不可用"] + ReaderTheme.presets.map(\.label) {
            precondition(ReaderUIStrings.keys.contains(key), "Missing OCR/theme label: \(key)")
        }
        for key in ["请先打开 PDF。", "参考范围最多 200 页，请缩小范围。", "请输入有效页码，例如 1-3, 5。",
                    "参考文字超过 100,000 字符，请缩小页码范围。", "以下页面尚无可用文字，请先运行本地 OCR 或调整范围："] {
            precondition(ReaderUIStrings.keys.contains(key), "Untranslated context error: \(key)")
        }
        precondition(ReaderUIStrings.text("第 24 页 · 引用原文", language: .fr) == "Page 24 · Passage d’origine")
        precondition(ReaderUIStrings.text("12 份 PDF · 本地保存", language: .ja) == "12 件の PDF · ローカル保存")
        let technicalDetail = " HTTP 503 / request-123"
        let warning = ReaderUIStrings.text("暂时无法恢复登录，已保留钥匙串中的凭据。" + technicalDetail, language: .fr)
        precondition(warning.hasPrefix("La connexion") && warning.hasSuffix(technicalDetail), "Translate the known warning while preserving external diagnostic details")

        // Audit app-owned static strings directly. A new button must be added to
        // the catalog instead of silently falling back to English in other UIs.
        if CommandLine.arguments.count > 1 {
            let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            let expression = try NSRegularExpression(pattern: #"(?:\bT|\bL|\bt|\blocalize|\blocalized)\(\s*"((?:\\.|[^"\\])*)""#)
            var missing: Set<String> = []
            for filename in ["ReaderApp.swift", "SettingsPanel.swift", "ReaderStore.swift", "AnnotationColorControl.swift", "ChatContextControl.swift"] {
                let source = try String(contentsOf: root.appendingPathComponent("Sources/" + filename), encoding: .utf8)
                for match in expression.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                    guard let range = Range(match.range(at: 1), in: source) else { continue }
                    let literal = String(source[range])
                    if literal.contains("\\(") { continue }
                    let key = try JSONDecoder().decode(String.self, from: Data(("\"" + literal + "\"").utf8))
                    if !ReaderUIStrings.keys.contains(key) { missing.insert(key) }
                }
            }
            precondition(missing.isEmpty, "Untranslated app UI strings: \(missing.sorted())")
        }
        print("LOCALIZATION_TESTS_PASSED: \(ReaderUIStrings.keys.count) complete keys in 9 languages; system/script/region resolution; numeric templates; main/settings/store static-string coverage")
    }
}
