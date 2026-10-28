import Foundation
import CoreGraphics
import CoreText
import PDFKit
import Vision

/// Local, derived reading data only. No source-file writes and no network calls.
struct OCRBounds: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    init(_ rect: CGRect) { x = rect.minX; y = rect.minY; width = rect.width; height = rect.height }
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var isFinite: Bool { [x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0 }
}

struct OCRTextWord: Codable, Equatable, Sendable {
    var text: String
    var bounds: OCRBounds
}

struct OCRTextLine: Codable, Equatable, Sendable {
    var text: String
    /// Unit coordinates in the upright, cropped page image; origin is bottom left.
    var bounds: OCRBounds
    var confidence: Float
    var words: [OCRTextWord] = []
}

struct OCRRecognitionProfile: Codable, Equatable, Sendable {
    var revision: Int
    var languages: [String]
    var automaticallyDetectsLanguage: Bool
}

struct OCRPageCache: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2
    var schemaVersion = currentSchemaVersion
    var mediaBox: OCRBounds
    var cropBox: OCRBounds
    var rotation: Int
    var recognitionRevision: Int
    var recognitionLanguages: [String]
    var recognitionProfile: OCRRecognitionProfile? = nil
    var lines: [OCRTextLine]

    func matches(page: PDFPage, profile: OCRRecognitionProfile? = nil) -> Bool {
        guard schemaVersion == Self.currentSchemaVersion, let ref = page.pageRef,
              profile == nil || (recognitionProfile == profile && recognitionRevision == profile?.revision && recognitionLanguages == profile?.languages),
              mediaBox.isFinite, cropBox.isFinite,
              mediaBox == OCRBounds(ref.getBoxRect(.mediaBox)),
              cropBox == OCRBounds(ref.getBoxRect(.cropBox)), rotation == page.rotation,
              lines.count <= 10_000, lines.reduce(0, { $0 + $1.text.utf16.count }) <= 1_000_000 else { return false }
        return lines.allSatisfy { line in
            let rect = line.bounds.rect
            return line.bounds.isFinite && !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                line.confidence.isFinite && (0...1).contains(line.confidence) &&
                CGRect(x: -0.001, y: -0.001, width: 1.002, height: 1.002).contains(rect) &&
                line.words.count <= 5_000 &&
                (line.words.isEmpty || line.words.map(\.text).joined() == line.text.filter { !$0.isWhitespace }) &&
                line.words.allSatisfy { word in
                    word.bounds.isFinite && !word.text.isEmpty &&
                        CGRect(x: -0.001, y: -0.001, width: 1.002, height: 1.002).contains(word.bounds.rect)
                }
        }
    }
}

enum OCRPageResult: Sendable {
    case nativeText
    case noText(OCRPageCache)
    /// The data contains one derived page, in the source page's coordinate system.
    case recognized(OCRPageCache, Data)
}

enum LocalOCRError: LocalizedError {
    case unavailablePage, invalidGeometry, renderFailed, invalidCache, pdfFailed, unsupportedLanguage
    var errorDescription: String? {
        switch self {
        case .unavailablePage: "The PDF page is unavailable for local text recognition."
        case .invalidGeometry: "The PDF page has unsupported geometry."
        case .renderFailed: "The PDF page could not be rendered for local text recognition."
        case .invalidCache: "Saved recognition data does not match this PDF page."
        case .pdfFailed: "The recognized text could not be added to a local reading copy."
        case .unsupportedLanguage: "The selected OCR language is unavailable on this Mac. Choose Automatic or another available language."
        }
    }
}

enum LocalOCR {
    /// The caller owns this PDFPage and must not share it with a live PDFView.
    /// A nonisolated async function keeps the expensive Vision work off the UI actor.
    static func recognize(page: PDFPage, preferredLanguages: [String] = Locale.preferredLanguages, profile: OCRRecognitionProfile? = nil) async throws -> OCRPageResult {
        try Task.checkCancellation()
        if hasNativeText(page) { return .nativeText }
        // OCR may run while another app is frontmost; prevent App Nap from
        // throttling this user-requested work without blocking idle system sleep.
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Recognize PDF text locally")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        guard let ref = page.pageRef else { throw LocalOCRError.unavailablePage }
        let geometry = try pageGeometry(page)
        let image = try render(page: page, maxDimension: 4096, scale: 3)
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        let profile = try profile ?? recognitionProfile(preferredLanguages: preferredLanguages)
        request.revision = profile.revision
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = profile.automaticallyDetectsLanguage
        request.minimumTextHeight = 0.002
        request.recognitionLanguages = profile.languages
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            do { try handler.perform([request]) }
            catch { try Task.checkCancellation(); throw error }
            try Task.checkCancellation()
        } onCancel: {
            request.cancel()
        }
        let lines = (request.results ?? []).compactMap { observation -> OCRTextLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            let bounds = observation.boundingBox.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !text.isEmpty, !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return nil }
            // Separate word boxes make partial-word/word selection follow the scan's
            // spacing instead of depending on a substitute font's advance widths.
            let original = candidate.string
            let expression = try! NSRegularExpression(pattern: "\\S+")
            let matches = expression.matches(in: original, range: NSRange(original.startIndex..., in: original))
            let words = matches.compactMap { match -> OCRTextWord? in
                guard let range = Range(match.range, in: original),
                      let observation = try? candidate.boundingBox(for: range) else { return nil }
                let wordBox = observation.boundingBox.intersection(bounds)
                guard !wordBox.isNull, wordBox.width > 0 else { return nil }
                return OCRTextWord(text: String(original[range]), bounds: OCRBounds(CGRect(x: wordBox.minX, y: bounds.minY, width: wordBox.width, height: bounds.height)))
            }
            return OCRTextLine(text: text, bounds: OCRBounds(bounds), confidence: candidate.confidence, words: words.count > 1 && words.count == matches.count ? words : [])
        }
        let cache = OCRPageCache(mediaBox: OCRBounds(ref.getBoxRect(.mediaBox)), cropBox: OCRBounds(ref.getBoxRect(.cropBox)),
                                 rotation: geometry.rotation, recognitionRevision: request.revision,
                                 recognitionLanguages: request.recognitionLanguages, recognitionProfile: profile, lines: lines)
        try Task.checkCancellation()
        guard !lines.isEmpty else { return .noText(cache) }
        return .recognized(cache, try makeSelectablePDFData(from: page, cache: cache))
    }

    static func hasNativeText(_ page: PDFPage) -> Bool {
        // Skip any usable existing text layer, including an OCR layer made by another app.
        !(page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func availableLanguages() throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        return try request.supportedRecognitionLanguages()
    }

    static func recognitionProfile(preferredLanguages: [String] = Locale.preferredLanguages, language: String = "") throws -> OCRRecognitionProfile {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let supported = try request.supportedRecognitionLanguages()
        return try recognitionProfile(preferredLanguages: preferredLanguages, language: language, supported: supported, revision: request.revision)
    }

    /// Explicit choices must match the actual installed Vision model. Never fall
    /// back to another language or script while presenting it as the user's choice.
    static func recognitionProfile(preferredLanguages: [String], language: String, supported: [String], revision: Int) throws -> OCRRecognitionProfile {
        if language.isEmpty {
            return OCRRecognitionProfile(revision: revision, languages: supportedLanguages(preferred: preferredLanguages, supported: supported), automaticallyDetectsLanguage: true)
        }
        guard let selected = supported.first(where: { $0.caseInsensitiveCompare(language) == .orderedSame }) else { throw LocalOCRError.unsupportedLanguage }
        return OCRRecognitionProfile(revision: revision, languages: [selected], automaticallyDetectsLanguage: false)
    }

    static func supportedLanguages(preferred: [String], supported: [String]) -> [String] {
        var selected: [String] = []
        for language in preferred + ["en-US"] {
            let normalized = language.replacingOccurrences(of: "_", with: "-")
            let base = normalized.split(separator: "-").first.map { String($0).lowercased() } ?? normalized.lowercased()
            let lower = normalized.lowercased()
            let parts = lower.split(separator: "-").map(String.init)
            let chineseScript: String? = base == "zh" ?
                (parts.contains("hans") ? "zh-Hans" : ["hant", "tw", "hk", "mo"].contains { parts.contains($0) } ? "zh-Hant" : "zh-Hans") : nil
            let matching = supported.first { $0.caseInsensitiveCompare(normalized) == .orderedSame }
                ?? chineseScript.flatMap { script in supported.first { $0.caseInsensitiveCompare(script) == .orderedSame } }
                ?? (base == "zh" ? nil : supported.first { $0.split(separator: "-").first.map { String($0).lowercased() } == base })
            if let matching, !selected.contains(matching) { selected.append(matching) }
        }
        return selected.isEmpty ? Array(supported.prefix(1)) : selected
    }

    static func makeSelectablePage(from page: PDFPage, cache: OCRPageCache) throws -> PDFPage {
        guard let result = PDFDocument(data: try makeSelectablePDFData(from: page, cache: cache))?.page(at: 0) else { throw LocalOCRError.pdfFailed }
        return result
    }

    static func makeSelectablePDFData(from page: PDFPage, cache: OCRPageCache) throws -> Data {
        guard cache.matches(page: page), let ref = page.pageRef else { throw LocalOCRError.invalidCache }
        let geometry = try pageGeometry(page)
        let data = NSMutableData()
        var mediaBox = cache.mediaBox.rect
        var cropBox = cache.cropBox.rect
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { throw LocalOCRError.pdfFailed }
        let pageInfo: [String: Any] = [
            kCGPDFContextMediaBox as String: NSData(bytes: &mediaBox, length: MemoryLayout<CGRect>.size),
            kCGPDFContextCropBox as String: NSData(bytes: &cropBox, length: MemoryLayout<CGRect>.size)
        ]
        context.beginPDFPage(pageInfo as CFDictionary)
        // Drawing the original PDF content preserves image detail and vector graphics.
        // Rotation remains page metadata, rather than being baked into the content.
        context.drawPDFPage(ref)
        context.saveGState()
        context.concatenate(geometry.toDisplay.inverted())
        context.setTextDrawingMode(.invisible)
        for line in cache.lines {
            try Task.checkCancellation()
            let pieces = line.words.isEmpty ? [OCRTextWord(text: line.text, bounds: line.bounds)] : line.words
            for (index, piece) in pieces.enumerated() {
                let box = CGRect(x: piece.bounds.x * geometry.displaySize.width,
                                 y: piece.bounds.y * geometry.displaySize.height,
                                 width: piece.bounds.width * geometry.displaySize.width,
                                 height: piece.bounds.height * geometry.displaySize.height)
                drawInvisibleText(piece.text, in: box, appendSpace: index < pieces.count - 1, context: context)
            }
        }
        context.restoreGState()
        context.endPDFPage()
        context.closePDF()
        // PDFKit writes /Rotate and the remaining page boxes using its supported API.
        guard let derived = PDFDocument(data: data as Data), let result = derived.page(at: 0) else { throw LocalOCRError.pdfFailed }
        result.rotation = cache.rotation
        for box in [PDFDisplayBox.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox] {
            result.setBounds(page.bounds(for: box), for: box)
        }
        // Embedded source annotations remain visible and interactive in the reading copy.
        for annotation in page.annotations {
            if let copy = annotation.copy() as? PDFAnnotation {
                // PDFKit's annotation copy can retain indirect action dictionaries
                // from the source document; rebuild URL actions for serialization.
                if let url = annotation.url { copy.action = PDFActionURL(url: url) }
                result.addAnnotation(copy)
            }
        }
        try Task.checkCancellation()
        guard let encoded = derived.dataRepresentation() else { throw LocalOCRError.pdfFailed }
        try Task.checkCancellation()
        return encoded
    }

    /// Used by the engine and by visual regression checks; output is upright and cropped.
    static func render(page: PDFPage, maxDimension: Int = 4096, scale: CGFloat = 3) throws -> CGImage {
        guard let ref = page.pageRef else { throw LocalOCRError.unavailablePage }
        let geometry = try pageGeometry(page)
        let desired = max(0.25, min(scale, CGFloat(maxDimension) / max(geometry.displaySize.width, geometry.displaySize.height)))
        let width = max(1, Int(ceil(geometry.displaySize.width * desired)))
        let height = max(1, Int(ceil(geometry.displaySize.height * desired)))
        guard width <= 8192, height <= 8192,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw LocalOCRError.renderFailed }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.concatenate(ref.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: width, height: height), rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(ref)
        guard let image = context.makeImage() else { throw LocalOCRError.renderFailed }
        return image
    }

    private struct Geometry {
        var rotation: Int
        var displaySize: CGSize
        var toDisplay: CGAffineTransform
    }

    private static func pageGeometry(_ page: PDFPage) throws -> Geometry {
        guard let ref = page.pageRef else { throw LocalOCRError.unavailablePage }
        let media = ref.getBoxRect(.mediaBox), crop = ref.getBoxRect(.cropBox)
        guard OCRBounds(media).isFinite, OCRBounds(crop).isFinite,
              crop.width <= 100_000, crop.height <= 100_000,
              page.rotation % 90 == 0 else { throw LocalOCRError.invalidGeometry }
        let rotation = ((page.rotation % 360) + 360) % 360
        let size = rotation == 90 || rotation == 270 ? CGSize(width: crop.height, height: crop.width) : crop.size
        let transform = ref.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true)
        guard abs(transform.a * transform.d - transform.b * transform.c) > 0.000001 else { throw LocalOCRError.invalidGeometry }
        return Geometry(rotation: page.rotation, displaySize: size, toDisplay: transform)
    }

    private static func drawInvisibleText(_ text: String, in box: CGRect, appendSpace: Bool = false, context: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
        let attributes = [kCTFontAttributeName: font] as CFDictionary
        let string = CFAttributedStringCreate(nil, text as CFString, attributes)!
        let metrics = CTLineCreateWithAttributedString(string)
        let drawingString = CFAttributedStringCreate(nil, (text + (appendSpace ? " " : "")) as CFString, attributes)!
        let line = CTLineCreateWithAttributedString(drawingString)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(metrics, &ascent, &descent, &leading))
        guard width > 0, ascent + descent > 0 else { return }
        context.saveGState()
        context.translateBy(x: box.minX, y: box.minY)
        context.scaleBy(x: box.width / width, y: box.height / (ascent + descent))
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: 0, y: descent)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
