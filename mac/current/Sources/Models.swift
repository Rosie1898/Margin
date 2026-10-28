import Foundation
extension Notification.Name {
    static let leafPDFWillReplacePage = Notification.Name("leafPDFWillReplacePage")
}
import SwiftUI
import PDFKit

struct PageRect: Codable, Hashable {
    var page: Int
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    init(page: Int, rect: CGRect) {
        self.page = page; x = rect.origin.x; y = rect.origin.y
        width = rect.width; height = rect.height
    }
}

struct SelectionSnapshot: Equatable {
    var text: String
    var rects: [PageRect]
    var pageText: String
    var imageDataURL: String? = nil
    var page: Int { rects.first?.page ?? 0 }
}

enum AnnotationKind: String, Codable, CaseIterable {
    case highlight, comment, question
    var label: String { switch self { case .highlight: "高亮"; case .comment: "评论"; case .question: "AI 讨论" } }
    var icon: String { switch self { case .highlight: "highlighter"; case .comment: "text.bubble"; case .question: "sparkles" } }
}

enum HighlightColor: String, Codable, CaseIterable, Identifiable {
    case mint, yellow, blue, pink
    var id: String { rawValue }
    var label: String { switch self { case .mint: "薄荷绿"; case .yellow: "浅杏黄"; case .blue: "雾蓝"; case .pink: "浅玫瑰" } }
    var hex: String { switch self { case .mint: "A8DCC5"; case .yellow: "F4D884"; case .blue: "A8CFF0"; case .pink: "E9BBD2" } }
    var color: Color { Color(hex: hex) }
    var nsColor: NSColor { NSColor(hex: hex) }
}

struct ChatMessage: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var role: String
    var text: String
    var model: String? = nil
    var effort: String? = nil
    var createdAt: Date = Date()
    var failed: Bool = false
    var reference: ChatReferenceSummary? = nil
}

enum ChatContextScope: String, Codable, CaseIterable, Identifiable {
    case selection, page, nearby, custom, document
    var id: String { rawValue }
    var label: String {
        switch self {
        case .selection: "仅选中文字"
        case .page: "划线所在页"
        case .nearby: "前后各一页"
        case .custom: "指定页码"
        case .document: "整份文档"
        }
    }
}

struct ChatReferenceSummary: Codable, Equatable {
    var scope: ChatContextScope
    var pages: [Int]
    var totalPages: Int
}

struct ChatContextPreference: Codable, Equatable {
    var scope: ChatContextScope = .page
    var pageRange: String = ""

    /// Public page numbers are one-based, as shown in the reader footer.
    func pages(anchor: Int, total: Int) throws -> [Int] {
        guard total > 0, (1...total).contains(anchor) else { throw ChatContextError("请先打开 PDF。") }
        let result: [Int]
        switch scope {
        case .selection: result = []
        case .page: result = [anchor]
        case .nearby: result = Array(max(1, anchor - 1)...min(total, anchor + 1))
        case .document:
            guard total <= 200 else { throw ChatContextError("参考范围最多 200 页，请缩小范围。") }
            result = Array(1...total)
        case .custom:
            let normalized = pageRange.replacingOccurrences(of: "，", with: ",").replacingOccurrences(of: "、", with: ",")
                .replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
            var unique = Set<Int>()
            for item in normalized.split(separator: ",", omittingEmptySubsequences: false) {
                let ends = item.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                guard (1...2).contains(ends.count), let first = Int(ends[0]), first >= 1,
                      let last = Int(ends.last!), last >= first, last <= total else {
                    throw ChatContextError("请输入有效页码，例如 1-3, 5。")
                }
                guard last - first < 200 else { throw ChatContextError("参考范围最多 200 页，请缩小范围。") }
                unique.formUnion(first...last)
                guard unique.count <= 200 else { throw ChatContextError("参考范围最多 200 页，请缩小范围。") }
            }
            result = unique.sorted()
            guard !result.isEmpty else { throw ChatContextError("请输入有效页码，例如 1-3, 5。") }
        }
        return result
    }
}

struct ChatContextError: Error {
    var key: String
    var detail: String
    init(_ key: String, detail: String = "") { self.key = key; self.detail = detail }
}

struct ChatReference {
    var summary: ChatReferenceSummary
    var texts: [String]
    var payload: [String: Any] {
        ["scope": summary.scope.rawValue, "totalPages": summary.totalPages,
         "pages": zip(summary.pages, texts).map { ["page": $0.0, "text": $0.1] as [String: Any] }]
    }
    @MainActor static func build(preference: ChatContextPreference, annotation: ReaderAnnotation, document: PDFDocument) throws -> ChatReference {
        let numbers = try preference.pages(anchor: annotation.page + 1, total: document.pageCount)
        var texts: [String] = [], missing: [Int] = [], count = 0
        for number in numbers {
            let text = (document.page(at: number - 1)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { missing.append(number) }
            count += text.utf16.count
            guard count <= 100_000 else { throw ChatContextError("参考文字超过 100,000 字符，请缩小页码范围。") }
            texts.append(text)
        }
        guard missing.isEmpty else {
            throw ChatContextError("以下页面尚无可用文字，请先运行本地 OCR 或调整范围：", detail: missing.map(String.init).joined(separator: ", "))
        }
        return ChatReference(summary: ChatReferenceSummary(scope: preference.scope, pages: numbers, totalPages: document.pageCount), texts: texts)
    }
}

struct ReaderAnnotation: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var kind: AnnotationKind
    var quote: String
    var rects: [PageRect]
    var color: HighlightColor
    var comment: String = ""
    var messages: [ChatMessage] = []
    var collapsed: Bool = false
    var createdAt: Date = Date()
    var pageText: String = ""
    var sourceFilename: String? = nil
    var deletedAt: Date? = nil
    var customColorHex: String? = nil
    var contextPreference: ChatContextPreference? = nil
    var page: Int { rects.first?.page ?? 0 }
    var effectiveColorHex: String { normalizedHex(customColorHex) ?? color.hex }
    var effectiveColor: Color { Color(hex: effectiveColorHex) }
    var effectiveNSColor: NSColor { NSColor(hex: effectiveColorHex) }
}

func normalizedHex(_ value: String?) -> String? {
    guard let value else { return nil }
    let clean = value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
    return clean.count == 6 && clean.allSatisfy({ $0.isASCII && $0.isHexDigit }) ? clean : nil
}

enum ReaderLanguage: String, Codable, CaseIterable, Identifiable {
    case system, zhHans, zhHant, en, ja, ko, fr, de, es, pt
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: "跟随系统 / System"
        case .zhHans: "简体中文"
        case .zhHant: "繁體中文"
        case .en: "English"
        case .ja: "日本語"
        case .ko: "한국어"
        case .fr: "Français"
        case .de: "Deutsch"
        case .es: "Español"
        case .pt: "Português"
        }
    }
    /// Resolve the first supported preferred language, honoring Chinese script
    /// identifiers before region defaults (TW/HK/MO use Traditional Chinese).
    func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> ReaderLanguage {
        guard self == .system else { return self }
        for identifier in preferredLanguages {
            let parts = identifier.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-").map(String.init)
            guard let base = parts.first else { continue }
            if base == "zh" {
                if parts.contains("hans") { return .zhHans }
                if parts.contains("hant") || parts.contains(where: { ["tw", "hk", "mo"].contains($0) }) { return .zhHant }
                return .zhHans
            }
            if let supported = ReaderLanguage(rawValue: base), supported != .system { return supported }
        }
        return .en
    }
    var usesEnglish: Bool { resolved() == .en }
    var localeIdentifier: String {
        switch resolved() {
        case .zhHans: "zh-Hans"
        case .zhHant: "zh-Hant"
        case .system: "en"
        default: resolved().rawValue
        }
    }
}

struct ReaderSettings: Codable, Equatable {
    var language: ReaderLanguage = .system
    /// Empty selects Vision's automatic detection using the system preferences.
    var ocrLanguage: String = ""
    /// Sent afresh with every question, including existing conversations.
    var customInstructions: String = ""
    static let customInstructionsLimit = 16000
    var customInstructionsTooLong: Bool { customInstructions.utf16.count > Self.customInstructionsLimit }
    var textSize: Double = 13
    var themeHex: String = "F5F7F3"
    var backgroundImage: String? = nil
    var centerOpacity: Double = 0.94
    var sidesOpacity: Double = 0.94
    var trashRetentionDays: Int = 30
    var highlightColorHex: String? = nil
    var paneProportions: [Double]? = nil

    init() {}
    private enum CodingKeys: String, CodingKey { case language, ocrLanguage, customInstructions, textSize, themeHex, backgroundImage, centerOpacity, sidesOpacity, trashRetentionDays, highlightColorHex, paneProportions }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        language = try values.decodeIfPresent(ReaderLanguage.self, forKey: .language) ?? .system
        ocrLanguage = try values.decodeIfPresent(String.self, forKey: .ocrLanguage) ?? ""
        customInstructions = try values.decodeIfPresent(String.self, forKey: .customInstructions) ?? ""
        textSize = try values.decodeIfPresent(Double.self, forKey: .textSize) ?? 13
        themeHex = try values.decodeIfPresent(String.self, forKey: .themeHex) ?? "F5F7F3"
        backgroundImage = try values.decodeIfPresent(String.self, forKey: .backgroundImage)
        centerOpacity = try values.decodeIfPresent(Double.self, forKey: .centerOpacity) ?? 0.94
        sidesOpacity = try values.decodeIfPresent(Double.self, forKey: .sidesOpacity) ?? 0.94
        trashRetentionDays = try values.decodeIfPresent(Int.self, forKey: .trashRetentionDays) ?? 30
        highlightColorHex = try values.decodeIfPresent(String.self, forKey: .highlightColorHex)
        // A missing or damaged layout preference must not prevent reading notes.
        paneProportions = try? values.decode([Double].self, forKey: .paneProportions)
        normalize()
    }
    mutating func normalize() {
        if ocrLanguage.count > 80 || !ocrLanguage.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) { ocrLanguage = "" }
        textSize = textSize.isFinite ? min(max(textSize, 11), 20) : 13
        centerOpacity = centerOpacity.isFinite ? min(max(centerOpacity, 0), 1) : 0.94
        sidesOpacity = sidesOpacity.isFinite ? min(max(sidesOpacity, 0), 1) : 0.94
        let clean = themeHex.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
        themeHex = clean.count == 6 && clean.allSatisfy({ $0.isHexDigit && $0.isASCII }) ? clean : "F5F7F3"
        if let filename = backgroundImage, filename.isEmpty || filename != URL(fileURLWithPath: filename).lastPathComponent || filename.hasPrefix(".") { backgroundImage = nil }
        if ![7, 30, 90].contains(trashRetentionDays) { trashRetentionDays = 30 }
        highlightColorHex = normalizedHex(highlightColorHex)
        paneProportions = Self.normalizedPaneProportions(paneProportions)
    }

    static func normalizedPaneProportions(_ values: [Double]?) -> [Double]? {
        guard let values, values.count == 3, values.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        let total = values.reduce(0, +)
        guard total.isFinite, total > 0 else { return nil }
        return values.map { $0 / total }
    }
}

/// RGB interpolation and contrast tokens match win/src/renderer/theme.mjs.
/// Keep this with the models so the existing native test compile lists include it.
struct ReaderThemePreset {
    var hex, label, accent: String
}

struct ReaderTheme: Equatable {
    static let presets: [ReaderThemePreset] = [
        .init(hex:"F5F7F3", label:"苔绿", accent:"518C76"), .init(hex:"E5ECF3", label:"雾蓝", accent:"587E9F"),
        .init(hex:"EBE9ED", label:"灰紫", accent:"81718C"), .init(hex:"EEEAEC", label:"灰粉", accent:"977B87"),
        .init(hex:"E9EAEC", label:"灰色", accent:"707782"), .init(hex:"253247", label:"深蓝", accent:"A8BCD6"),
        .init(hex:"202124", label:"黑色", accent:"B5B8BE")
    ]
    var base, accent, ink, muted, sidebar, center, canvas, card, raised, border, hover, selected, userBubble, aiBubble, error: String
    var dark: Bool

    init(_ hex: String) {
        let base = normalizedHex(hex) ?? "F5F7F3"
        let dark = Self.luminance(base) < 0.23
        let accent = Self.presets.first(where: { $0.hex == base })?.accent
            ?? Self.mix(base, dark ? "DFE5EF" : "25342E", dark ? 0.72 : 0.60)
        let ink = dark ? "E6EBF0" : base == "F5F7F3" ? "283C36" : Self.mix(accent, "182027", 0.78)
        self.base = base; self.dark = dark; self.accent = accent; self.ink = ink
        muted = Self.mix(ink, base, dark ? 0.32 : 0.48)
        sidebar = Self.mix(base, "FFFFFF", dark ? 0.02 : 0.12)
        center = Self.mix(base, "FFFFFF", dark ? 0.04 : 0.72)
        canvas = dark ? Self.mix(base, "000000", 0.10) : Self.mix(base, ink, 0.045)
        card = Self.mix(base, "FFFFFF", dark ? 0.075 : 0.82)
        raised = Self.mix(base, "FFFFFF", dark ? 0.11 : 0.92)
        border = Self.mix(base, dark ? "FFFFFF" : ink, dark ? 0.20 : 0.15)
        hover = Self.mix(base, accent, dark ? 0.14 : 0.10)
        selected = Self.mix(base, accent, dark ? 0.23 : 0.18)
        userBubble = Self.mix(base, accent, dark ? 0.13 : 0.085)
        aiBubble = Self.mix(base, accent, dark ? 0.20 : 0.145)
        error = dark ? "E4B49B" : "9D624B"
    }
    private static func rgb(_ hex: String) -> [Double] {
        let value = UInt32(normalizedHex(hex) ?? "F5F7F3", radix: 16)!
        return [Double((value >> 16) & 255), Double((value >> 8) & 255), Double(value & 255)]
    }
    static func mix(_ a: String, _ b: String, _ amount: Double) -> String {
        zip(rgb(a), rgb(b)).map { pair in String(format: "%02X", Int((pair.0 + (pair.1 - pair.0) * amount).rounded())) }.joined()
    }
    static func luminance(_ hex: String) -> Double {
        let values = rgb(hex).map { $0 / 255 }.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return values[0] * 0.2126 + values[1] * 0.7152 + values[2] * 0.0722
    }
    static func readableInk(on hex: String) -> String { luminance(hex) < 0.179 ? "FFFFFF" : "000000" }
    func bubbleInk(on hex: String) -> String { Self.readableInk(on:hex) }
    func bubbleMuted(on hex: String) -> String {
        let ink = bubbleInk(on:hex), background = Self.luminance(hex)
        for step in stride(from: 7, through: 0, by: -1) {
            let candidate = Self.mix(ink, hex, Double(step) * 0.05)
            let foreground = Self.luminance(candidate)
            if (max(foreground, background) + 0.05) / (min(foreground, background) + 0.05) >= 4.5 { return candidate }
        }
        return ink
    }
}

struct TrashedAnnotation: Identifiable {
    var documentID: String
    var documentTitle: String
    var documentPath: String
    var annotation: ReaderAnnotation
    var id: UUID { annotation.id }
    func cleanupDate(retentionDays: Int) -> Date { (annotation.deletedAt ?? .distantFuture).addingTimeInterval(Double(retentionDays) * 86_400) }
    func isExpired(retentionDays: Int, now: Date = Date()) -> Bool { cleanupDate(retentionDays: retentionDays) <= now }
}

struct DocumentRecord: Codable, Identifiable {
    var id: String
    var path: String
    var title: String
    var page: Int = 0
    var annotations: [ReaderAnnotation] = []
}

struct LibraryState: Codable {
    var version = 3
    var folderPath: String? = nil
    var folderBookmark: Data? = nil
    var selectedPath: String? = nil
    var documents: [String: DocumentRecord] = [:]
    var userBubble: String = "EAF1FB"
    var aiBubble: String = "E8F3ED"
    var selectedModel: String = ""
    var selectedEffort: String = "low"
    var settings = ReaderSettings()

    init() {}
    private enum CodingKeys: String, CodingKey { case version, folderPath, folderBookmark, selectedPath, documents, userBubble, aiBubble, selectedModel, selectedEffort, settings }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let savedVersion = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard (1...3).contains(savedVersion) else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: values, debugDescription: "This library was created by a newer version of the reader.")
        }
        version = 3
        folderPath = try values.decodeIfPresent(String.self, forKey: .folderPath)
        folderBookmark = try values.decodeIfPresent(Data.self, forKey: .folderBookmark)
        selectedPath = try values.decodeIfPresent(String.self, forKey: .selectedPath)
        documents = try values.decodeIfPresent([String: DocumentRecord].self, forKey: .documents) ?? [:]
        userBubble = try values.decodeIfPresent(String.self, forKey: .userBubble) ?? "EAF1FB"
        aiBubble = try values.decodeIfPresent(String.self, forKey: .aiBubble) ?? "E8F3ED"
        selectedModel = try values.decodeIfPresent(String.self, forKey: .selectedModel) ?? ""
        selectedEffort = try values.decodeIfPresent(String.self, forKey: .selectedEffort) ?? "low"
        settings = try values.decodeIfPresent(ReaderSettings.self, forKey: .settings) ?? ReaderSettings()
    }
}

struct LibraryFile: Identifiable, Hashable {
    var url: URL
    var relativePath: String
    var id: String { url.path }
    var title: String { url.deletingPathExtension().lastPathComponent }
}

struct CatalogModel: Decodable, Identifiable {
    var id: String
    var name: String
    var efforts: [String]
    var defaultEffort: String?
}

extension Color {
    init(hex: String) { self.init(nsColor: NSColor(hex: hex)) }
}
extension NSColor {
    convenience init(hex: String) {
        let clean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let value = UInt64(clean, radix: 16) ?? 0xE8F3ED
        self.init(srgbRed: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, alpha: 1)
    }
    var hex: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}
