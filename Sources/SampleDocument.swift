import Foundation
import PDFKit
import CryptoKit

enum SampleDocument {
    static let filename = "Robert Lucas - On the Mechanics of Economic Development.pdf"
    static let sourceURL = URL(string: "https://web.stanford.edu/~klenow/Lucas_Mechanics.pdf")!
    static let sourceSHA256 = "fdcbbb2cb512ed5707a40f94151c8d8aed5355b48e1971c4d858774a6fc91365"
    typealias Download = @Sendable (URL) async throws -> Data

    enum DownloadError: Error {
        case invalidResponse, invalidPDF, sourceChanged
    }

    static func cachedURL(in dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent("Samples", isDirectory: true).appendingPathComponent(filename)
    }

    /// Validate every cache hit. Downloaded source bytes are never transformed.
    static func verifiedCache(_ url: URL, expectedSHA256: String = sourceSHA256) -> URL? {
        guard let bytes = try? Data(contentsOf: url), (try? validate(bytes, expectedSHA256: expectedSHA256)) != nil else { return nil }
        return url
    }

    static func validate(_ data: Data, expectedSHA256: String) throws {
        guard !data.isEmpty, data.count <= 50 * 1_024 * 1_024,
              let pdf = PDFDocument(data: data), !pdf.isLocked, pdf.pageCount > 0 else { throw DownloadError.invalidPDF }
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == expectedSHA256 else { throw DownloadError.sourceChanged }
    }

    static func download(_ source: URL) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 90
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: source)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw DownloadError.invalidResponse }
        return data
    }

    static func fetch(to destination: URL, expectedSHA256: String = sourceSHA256, using download: Download = { try await SampleDocument.download($0) }) async throws -> URL {
        let data = try await download(sourceURL)
        try Task.checkCancellation()
        try validate(data, expectedSHA256: expectedSHA256)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Task.checkCancellation()
        try data.write(to: destination, options: .atomic)
        return destination
    }

    static let seedKey = "lucas-1988-development-v1"
    static let annotationID = UUID(uuidString: "E6170B77-72D0-47F7-823A-CF279301F820")!

    static func isLegacySampleFolder(_ url: URL) -> Bool {
        let resources = url.deletingLastPathComponent()
        let contents = resources.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        return url.lastPathComponent == "Samples" && resources.lastPathComponent == "Resources"
            && contents.lastPathComponent == "Contents" && ["Margin.app", "Leaf Reader.app"].contains(app.lastPathComponent)
    }

    /// Keep the PDF's original OCR text and page geometry. The scanned paper
    /// reads “else” in print, while its existing text layer can read “rise”.
    static func highlight(in document: PDFDocument) -> SelectionSnapshot? {
        let start = try! NSRegularExpression(pattern: "I\\s+do\\s+not\\s+see\\s+how\\s+one\\s+can\\s+look\\s+at\\s+figures\\s+like\\s+these", options: .caseInsensitive)
        let end = try! NSRegularExpression(pattern: "about\\s+anything\\s+(?:else|rise)\\.", options: .caseInsensitive)
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let text = page.string else { continue }
            let source = text as NSString
            let full = NSRange(location: 0, length: source.length)
            guard let opening = start.firstMatch(in: text, range: full) else { continue }
            let remainder = NSRange(location: opening.range.location, length: source.length - opening.range.location)
            guard let ending = end.firstMatch(in: text, range: remainder),
                  let selection = page.selection(for: NSRange(location: opening.range.location, length: NSMaxRange(ending.range) - opening.range.location)),
                  let quote = selection.string, !quote.isEmpty else { continue }
            var seen: Set<PageRect> = []
            let rects = selection.selectionsByLine().compactMap { line -> PageRect? in
                let bounds = line.bounds(for: page)
                guard !bounds.isNull, !bounds.isInfinite, bounds.width > 0, bounds.height > 0,
                      [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy({ $0.isFinite }) else { return nil }
                let rect = PageRect(page: index, rect: bounds)
                return seen.insert(rect).inserted ? rect : nil
            }
            guard !rects.isEmpty else { continue }
            return SelectionSnapshot(text: quote, rects: rects, pageText: String(text.prefix(12_000)))
        }
        return nil
    }
}
