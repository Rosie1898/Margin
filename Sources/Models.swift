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
    var textSize: Double = 13
    var themeHex: String = "F5F7F3"
    var backgroundImage: String? = nil
    var centerOpacity: Double = 0.94
    var sidesOpacity: Double = 0.94
    var trashRetentionDays: Int = 30
    var highlightColorHex: String? = nil
    var paneProportions: [Double]? = nil

    init() {}
    private enum CodingKeys: String, CodingKey { case language, textSize, themeHex, backgroundImage, centerOpacity, sidesOpacity, trashRetentionDays, highlightColorHex, paneProportions }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        language = try values.decodeIfPresent(ReaderLanguage.self, forKey: .language) ?? .system
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
