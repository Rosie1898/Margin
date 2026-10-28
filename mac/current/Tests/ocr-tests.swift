import Foundation
import AppKit
import PDFKit
import CoreGraphics
import CoreText

private struct Failure: Error, CustomStringConvertible { var description: String }
private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws { if !condition() { throw Failure(description: message) } }

@main
struct OCRTests {
    static func main() async {
        do {
            let scratch = URL(fileURLWithPath: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/tmp/margin-ocr-tests", isDirectory: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            try await run(scratch: scratch)
            print("PASS local OCR: text selection, crop/rotation geometry, visual preservation, native skip, cache validation, cancellation, real Vision recognition; external API calls=0")
        } catch {
            fputs("FAIL OCR: \(error)\n", stderr)
            exit(1)
        }
    }

    @MainActor static func run(scratch: URL) async throws {
        func stage(_ message: String) {
            let url = scratch.appendingPathComponent("progress.log")
            let line = "\(Date()) \(message)\n"
            if let handle = try? FileHandle(forWritingTo: url) { _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(line.utf8)); try? handle.close() }
            else { try? line.write(to: url, atomically: true, encoding: .utf8) }
        }
        stage("begin")
        let sourceData = try fixture(scanned: true)
        let sourceURL = scratch.appendingPathComponent("Scan Fixture.pdf")
        try sourceData.write(to: sourceURL)
        let sourceDocument = PDFDocument(data: sourceData)!
        let source = sourceDocument.page(at: 0)!
        defer { withExtendedLifetime(sourceDocument) {} }
        try check(!LocalOCR.hasNativeText(source), "Raster fixture must have no text layer")
        try check(LocalOCR.supportedLanguages(preferred: ["zh-TW", "fr-CA", "en-GB", "zz"], supported: ["en-US", "zh-Hans", "zh-Hant", "fr-FR"]) == ["zh-Hant", "fr-FR", "en-US"], "Language choices must match available OCR models and avoid duplicates")
        try check(LocalOCR.supportedLanguages(preferred: ["zh-Hans-TW"], supported: ["en-US", "zh-Hans", "zh-Hant"]) == ["zh-Hans", "en-US"], "Explicit Chinese script must take priority over region")
        try check(LocalOCR.supportedLanguages(preferred: ["zh-Hant"], supported: ["en-US", "zh-Hans"]) == ["en-US"], "Unavailable Traditional Chinese must not silently use Simplified Chinese")
        let modelLanguages = ["en-US", "zh-Hans", "zh-Hant", "ja-JP", "ko-KR", "fr-FR", "de-DE", "es-ES", "pt-BR"]
        for language in modelLanguages {
            let profile = try LocalOCR.recognitionProfile(preferredLanguages: ["en-US"], language: language, supported: modelLanguages, revision: 3)
            try check(profile.languages == [language] && !profile.automaticallyDetectsLanguage, "An explicit supported language must be used without another language or automatic detection")
        }
        let automaticProfile = try LocalOCR.recognitionProfile(preferredLanguages: ["zh-TW"], language: "", supported: modelLanguages, revision: 3)
        try check(automaticProfile.languages == ["zh-Hant", "en-US"] && automaticProfile.automaticallyDetectsLanguage, "Automatic OCR should use system preferences and available models")
        do {
            _ = try LocalOCR.recognitionProfile(preferredLanguages: ["en-US"], language: "zz-ZZ", supported: modelLanguages, revision: 3)
            throw Failure(description: "An unavailable explicit OCR language must fail instead of silently substituting another model")
        } catch LocalOCRError.unsupportedLanguage {}
        let text = "Economic growth expands human possibilities."
        let normalized = CGRect(x: 0.08, y: 0.72, width: 0.84, height: 0.065)
        for rotation in [0, 90, 180, 270] {
            stage("rotation \(rotation) start")
            let document = PDFDocument(data: sourceData)!
            document.page(at: 0)!.rotation = rotation
            let encoded = document.dataRepresentation()!
            let pageDocument = PDFDocument(data: encoded)!
            let page = pageDocument.page(at: 0)!
            defer { withExtendedLifetime(pageDocument) {} }
            let ref = page.pageRef!
            let cache = OCRPageCache(mediaBox: OCRBounds(ref.getBoxRect(.mediaBox)), cropBox: OCRBounds(ref.getBoxRect(.cropBox)), rotation: page.rotation,
                                     recognitionRevision: 3, recognitionLanguages: ["en-US"],
                                     lines: [OCRTextLine(text: text, bounds: OCRBounds(normalized), confidence: 1)])
            try check(cache.matches(page: page), "Correct cache geometry should validate")
            let roundTrip = try JSONDecoder().decode(OCRPageCache.self, from: JSONEncoder().encode(cache))
            try check(roundTrip == cache, "OCR geometry and recognized text must round-trip losslessly")
            let derivedData = try LocalOCR.makeSelectablePDFData(from: page, cache: roundTrip)
            try derivedData.write(to: scratch.appendingPathComponent("Derived \(rotation).pdf"))
            let derivedDocument = PDFDocument(data: derivedData)!
            let derived = derivedDocument.page(at: 0)!
            defer { withExtendedLifetime(derivedDocument) {} }
            try check(derived.annotations.count == page.annotations.count && derived.annotations.first?.url == page.annotations.first?.url,
                      "Original PDF annotations and link URLs must survive derivation")
            try check(derived.rotation == rotation, "Derived page must preserve rotation \(rotation)")
            try check(derived.bounds(for: .mediaBox) == page.bounds(for: .mediaBox) && derived.bounds(for: .cropBox) == page.bounds(for: .cropBox), "Derived page must preserve original media/crop boxes")
            try check(derived.string?.contains(text) == true, "PDFKit must extract hidden OCR text at rotation \(rotation): \(derived.string ?? "nil")")
            let selection = derivedDocument.findString("growth", withOptions: []).first
            try check(selection?.string == "growth", "PDFKit must support word-level search and selection")
            let full = derived.selection(for: NSRange(location: 0, length: (derived.string! as NSString).length))!
            let bounds = full.bounds(for: derived)
            let crop = ref.getBoxRect(.cropBox)
            let size = rotation == 90 || rotation == 270 ? CGSize(width: crop.height, height: crop.width) : crop.size
            let transform = ref.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true)
            let expected = CGRect(x: normalized.minX * size.width, y: normalized.minY * size.height, width: normalized.width * size.width, height: normalized.height * size.height).applying(transform.inverted())
            try check(abs(bounds.midX - expected.midX) < 2 && abs(bounds.midY - expected.midY) < 2,
                      "Selection geometry must return original-page coordinates at rotation \(rotation): \(bounds) vs \(expected)")
            try check(bounds.intersection(expected).width * bounds.intersection(expected).height / (expected.width * expected.height) > 0.9,
                      "Selection must cover the recognized text region")
            let originalImage = try LocalOCR.render(page: page, maxDimension: 1200, scale: 1.5)
            let derivedImage = try LocalOCR.render(page: derived, maxDimension: 1200, scale: 1.5)
            let difference = try meanDifference(originalImage, derivedImage)
            try check(difference < 0.02, "Invisible OCR must not change the visible page (rotation \(rotation), mean channel difference \(difference))")
            var mismatched = cache
            mismatched.cropBox.x += 1
            try check(!mismatched.matches(page: page), "Cache from different geometry must be rejected")
            var badBounds = cache
            badBounds.lines[0].bounds.width = 2
            try check(!badBounds.matches(page: page), "Malformed normalized bounds must be rejected")
        }
        stage("all geometry checks passed; unicode next")
        let spacedCache = OCRPageCache(mediaBox: OCRBounds(source.pageRef!.getBoxRect(.mediaBox)), cropBox: OCRBounds(source.pageRef!.getBoxRect(.cropBox)), rotation: source.rotation,
                                       recognitionRevision: 3, recognitionLanguages: ["en-US"],
                                       lines: [OCRTextLine(text: "Economic growth expands", bounds: OCRBounds(normalized), confidence: 1, words: [
                                        OCRTextWord(text: "Economic", bounds: OCRBounds(CGRect(x: 0.08, y: 0.72, width: 0.24, height: 0.065))),
                                        OCRTextWord(text: "growth", bounds: OCRBounds(CGRect(x: 0.36, y: 0.72, width: 0.20, height: 0.065))),
                                        OCRTextWord(text: "expands", bounds: OCRBounds(CGRect(x: 0.60, y: 0.72, width: 0.28, height: 0.065)))])])
        let spacedPDF = PDFDocument(data: try LocalOCR.makeSelectablePDFData(from: source, cache: spacedCache))!
        try check(spacedPDF.string?.contains("Economic growth expands") == true, "Cached word boxes must preserve literal spaces in the extracted quote: \(spacedPDF.string ?? "nil")")
        try check(spacedPDF.findString("growth", withOptions: []).first?.string == "growth", "Explicit spaces must not pollute selected words")
        let unicodeCache = OCRPageCache(mediaBox: OCRBounds(source.pageRef!.getBoxRect(.mediaBox)), cropBox: OCRBounds(source.pageRef!.getBoxRect(.cropBox)), rotation: source.rotation,
                                       recognitionRevision: 3, recognitionLanguages: ["zh-Hans"],
                                       lines: [OCRTextLine(text: "滚滚长江东逝水", bounds: OCRBounds(normalized), confidence: 1)])
        let unicodePage = try LocalOCR.makeSelectablePage(from: source, cache: unicodeCache)
        try check(unicodePage.string?.contains("滚滚长江东逝水") == true, "Unicode hidden text must remain extractable")
        stage("unicode passed; native text skip next")
        let nativeData = try fixture(scanned: false)
        let native = PDFDocument(data: nativeData)!.page(at: 0)!
        let nativeResult = try await LocalOCR.recognize(page: native)
        if case .nativeText = nativeResult {} else { throw Failure(description: "Existing PDF text must skip Vision") }
        stage("native skip passed; cancellation next")
        let cancelled = Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            return try await LocalOCR.recognize(page: source)
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw Failure(description: "Cancelled OCR task must not continue") }
        catch is CancellationError {}
        stage("cancellation passed; starting Vision")
        print("OCR geometry and selection checks passed; starting local Vision fixture.")
        fflush(stdout)
        let result = try await LocalOCR.recognize(page: source, preferredLanguages: ["en-US"])
        stage("Vision returned")
        guard case .recognized(let cache, let derivedData) = result else { throw Failure(description: "Vision must recognize the image-only fixture") }
        let recognized = cache.lines.map(\.text).joined(separator: "\n")
        let actualProfile = try LocalOCR.recognitionProfile(preferredLanguages: ["en-US"])
        try check(cache.matches(page: source, profile: actualProfile), "Fresh Vision output must carry the exact recognition profile")
        var otherProfile = actualProfile; otherProfile.automaticallyDetectsLanguage.toggle()
        try check(!cache.matches(page: source, profile: otherProfile), "Automatic and explicit recognition must not reuse each other's cache")
        otherProfile = actualProfile; otherProfile.languages = ["zz-ZZ"]
        try check(!cache.matches(page: source, profile: otherProfile), "A cache from another language must miss")
        otherProfile = actualProfile; otherProfile.revision += 1
        try check(!cache.matches(page: source, profile: otherProfile), "A cache from another Vision revision must miss")
        var legacyCache = cache; legacyCache.schemaVersion = 1; legacyCache.recognitionProfile = nil
        let legacyDecoded = try JSONDecoder().decode(OCRPageCache.self, from: JSONEncoder().encode(legacyCache))
        try check(!legacyDecoded.matches(page: source, profile: actualProfile), "Legacy caches must decode safely but never match a current recognition profile")
        try check(recognized.localizedCaseInsensitiveContains("Economic growth"), "Vision OCR did not recognize expected image text: \(recognized)")
        try check(recognized.localizedCaseInsensitiveContains("human possibilities"), "Vision should retain the second part of the sentence")
        let selectable = PDFDocument(data: derivedData)!
        try check(selectable.findString("Economic", withOptions: []).first != nil, "Real Vision output must be selectable in PDFKit")
        try check(selectable.string?.localizedCaseInsensitiveContains("Economic growth") == true, "Word-level positioning must preserve spaces and reading order: \(selectable.string ?? "nil")")
        if let word = cache.lines.flatMap(\.words).first(where: { $0.text == "growth" }),
           let selected = selectable.findString("growth", withOptions: []).first,
           let page = selectable.page(at: 0) {
            let crop = source.pageRef!.getBoxRect(.cropBox)
            let transform = source.pageRef!.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: crop.size), rotate: 0, preserveAspectRatio: true)
            let expected = CGRect(x: word.bounds.x * crop.width, y: word.bounds.y * crop.height, width: word.bounds.width * crop.width, height: word.bounds.height * crop.height).applying(transform.inverted())
            let selectedBox = selected.bounds(for: page)
            try check(abs(selectedBox.midX - expected.midX) < 2 && abs(selectedBox.midY - expected.midY) < 2,
                      "A selected OCR word must track its own detected location")
        } else { throw Failure(description: "Vision should supply a word-level box for growth") }
        stage("word selection passed; blank page next")
        let blankData = try fixture(scanned: true, blank: true)
        let blank = PDFDocument(data: blankData)!.page(at: 0)!
        let emptyResult = try await LocalOCR.recognize(page: blank)
        if case .noText(let emptyCache) = emptyResult { try check(emptyCache.lines.isEmpty && emptyCache.matches(page: blank), "Blank recognition should be cacheable") }
        else { throw Failure(description: "Blank scanned page must finish as noText") }
        stage("blank page passed; Chinese scan next")
        let chineseData = try fixture(scanned: true, chinese: true)
        try chineseData.write(to: scratch.appendingPathComponent("Chinese Scan Fixture.pdf"))
        let chineseDocument = PDFDocument(data: chineseData)!
        defer { withExtendedLifetime(chineseDocument) {} }
        let chineseResult = try await LocalOCR.recognize(page: chineseDocument.page(at: 0)!, preferredLanguages: ["zh-Hans", "en-US"])
        guard case .recognized(let chineseCache, let chinesePDF) = chineseResult else { throw Failure(description: "Vision must recognize the Chinese image-only fixture") }
        let chineseText = chineseCache.lines.map(\.text).joined(separator: "\n")
        try check(chineseText.contains("滚滚长江东逝水"), "Real Chinese OCR did not recognize the expected verse: \(chineseText)")
        let chineseSelectable = PDFDocument(data: chinesePDF)!
        try check(chineseSelectable.findString("长江", withOptions: []).first != nil, "Chinese OCR must support selecting a short phrase")
        try chinesePDF.write(to: scratch.appendingPathComponent("Chinese Recognized Fixture.pdf"))
        let originalAfter = try Data(contentsOf: sourceURL)
        try check(originalAfter == sourceData, "OCR must leave original PDF bytes unchanged")
        try derivedData.write(to: scratch.appendingPathComponent("Recognized Fixture.pdf"))
        stage("all checks passed")
        let record: [String: Any] = ["passed": true, "originalBytesUnchanged": true, "externalAPICalls": 0, "recognizedLines": cache.lines.count, "recognizedWords": cache.lines.flatMap(\.words).count, "blankPageFinished": true, "chineseRecognizedText": chineseText, "recognizedText": recognized, "rotationChecks": [0,90,180,270]]
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: scratch.appendingPathComponent("ocr-test-result.json"))
    }

    static func fixture(scanned: Bool, blank: Bool = false, chinese: Bool = false) throws -> Data {
        let media = CGRect(x: 12, y: 18, width: 600, height: 780)
        let crop = CGRect(x: 42, y: 48, width: 540, height: 720)
        let data = NSMutableData()
        var box = media
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        if scanned {
            let imageContext = CGContext(data: nil, width: 1200, height: 1560, bitsPerComponent: 8, bytesPerRow: 1200 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            imageContext.setFillColor(CGColor(gray: 1, alpha: 1)); imageContext.fill(CGRect(x: 0, y: 0, width: 1200, height: 1560))
            imageContext.scaleBy(x: 2, y: 2)
            if !blank { drawFixture(in: imageContext, chinese: chinese) }
            context.draw(imageContext.makeImage()!, in: media)
        } else {
            context.translateBy(x: media.minX, y: media.minY)
            drawFixture(in: context)
        }
        context.endPDFPage(); context.closePDF()
        let pdf = PDFDocument(data: data as Data)!
        pdf.page(at: 0)!.setBounds(crop, for: .cropBox)
        let link = PDFAnnotation(bounds: CGRect(x: 70, y: 70, width: 30, height: 20), forType: .link, withProperties: nil)
        link.url = URL(string: "https://example.com/read")
        pdf.page(at: 0)!.addAnnotation(link)
        return pdf.dataRepresentation()!
    }

    static func drawFixture(in context: CGContext, chinese: Bool = false) {
        context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 35, y: 700, width: 530, height: 5))
        let font = CTFontCreateWithName((chinese ? "PingFangSC-Regular" : "Helvetica") as CFString, chinese ? 28 : 23, nil)
        let lines = chinese ? ["滚滚长江东逝水"] : ["Economic growth expands", "human possibilities.", "Local OCR keeps this page on your Mac."]
        for (index, text) in lines.enumerated() {
            let string = CFAttributedStringCreate(nil, text as CFString, [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 0, alpha: 1)] as CFDictionary)!
            let line = CTLineCreateWithAttributedString(string)
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: 48, y: 610 - index * 45)
            CTLineDraw(line, context)
        }
        context.setFillColor(CGColor(red: 0.9, green: 0.5, blue: 0.2, alpha: 1)); context.fill(CGRect(x: 40, y: 45, width: 30, height: 20))
        context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 510, y: 65, width: 35, height: 28))
    }

    static func meanDifference(_ first: CGImage, _ second: CGImage) throws -> Double {
        try check(first.width == second.width && first.height == second.height, "Rendered dimensions must stay unchanged")
        let lhs = first.dataProvider!.data! as Data, rhs = second.dataProvider!.data! as Data
        try check(lhs.count == rhs.count, "Raster formats must match")
        let total = zip(lhs, rhs).reduce(UInt64(0)) { $0 + UInt64(abs(Int($1.0) - Int($1.1))) }
        return Double(total) / Double(lhs.count)
    }
}
