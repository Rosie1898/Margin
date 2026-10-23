import Foundation
import PDFKit
import CryptoKit

enum OCRStatus: Equatable {
    case idle
    case recognizing(page: Int, completed: Int, total: Int)
    case ready
    case noText
    case failed(String)
    case cancelled
}

enum OCRPageOutcome {
    case ready, noText, failed(String)
}

/// OCR is independent of ChatService. Only recognition geometry/text is cached;
/// the original PDF is opened read-only and remains the visual source of truth.
extension ReaderStore {
    var isRecognizingOCR: Bool {
        if case .recognizing = ocrStatus { return true }
        return false
    }

    func resetOCR() {
        ocrTask?.cancel(); ocrTask = nil
        ocrGeneration = UUID(); ocrWholeDocument = false
        ocrOutcomes = [:]; ocrStatus = .idle; currentPageNeedsOCR = false
    }

    func cancelOCR() {
        ocrTask?.cancel(); ocrTask = nil
        ocrGeneration = UUID(); ocrWholeDocument = false
        ocrStatus = .cancelled
    }

    func scheduleCurrentPageOCR() {
        guard !isOpening, let page = document?.page(at: currentPage) else {
            currentPageNeedsOCR = false
            return
        }
        currentPageNeedsOCR = !Self.hasSelectableText(page)
        guard !ocrWholeDocument else { return }
        ocrTask?.cancel(); ocrTask = nil; ocrGeneration = UUID()
        if !currentPageNeedsOCR { ocrStatus = .idle; return }
        if let outcome = ocrOutcomes[currentPage] {
            showOCRResult(outcome)
            return
        }
        startOCR(pages: [currentPage], wholeDocument: false, delay: true)
    }

    func recognizeCurrentPage() {
        guard currentPageNeedsOCR else { return }
        startOCR(pages: [currentPage], wholeDocument: false, delay: false, retryEmpty: true)
    }

    func recognizeDocument() {
        guard let document, !isOpening else { return }
        startOCR(pages: Array(0..<document.pageCount), wholeDocument: true, delay: false, retryEmpty: true)
    }

    private static func hasSelectableText(_ page: PDFPage) -> Bool {
        !(page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func showOCRResult(_ outcome: OCRPageOutcome) {
        switch outcome {
        case .ready: ocrStatus = .ready
        case .noText: ocrStatus = .noText
        case .failed(let detail): ocrStatus = .failed(detail)
        }
    }

    private func startOCR(pages: [Int], wholeDocument: Bool, delay: Bool, retryEmpty: Bool = false) {
        guard let url = documentSourceURL, let identity = documentID, document != nil, !pages.isEmpty else { return }
        ocrTask?.cancel()
        let generation = UUID(); ocrGeneration = generation; ocrWholeDocument = wholeDocument
        let cacheDirectory = dataDirectory.appendingPathComponent("OCR", isDirectory: true).appendingPathComponent(identity, isDirectory: true)
        let languages = Locale.preferredLanguages
        ocrStatus = delay ? .idle : .recognizing(page: pages[0], completed: 0, total: pages.count)
        // A separate PDFDocument is exclusively owned by this worker. PDFKit's
        // displayed document and its annotations are only touched on MainActor.
        ocrTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                if delay { try await Task.sleep(for: .milliseconds(450)) }
                try Task.checkCancellation()
                let bytes = try Data(contentsOf: url)
                try Task.checkCancellation()
                let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                try Task.checkCancellation()
                guard digest == identity else { throw OCRStorageError.sourceChanged }
                guard let source = PDFDocument(data: bytes), !source.isLocked else { throw OCRStorageError.unreadable }
                var lastFailure: String?
                for (completed, index) in pages.enumerated() {
                    try Task.checkCancellation()
                    guard let page = source.page(at: index) else { continue }
                    await self?.reportOCRProgress(page: index, completed: completed, total: pages.count, generation: generation)
                    do {
                        let result = try await OCRCacheStorage.recognize(page: page, pageIndex: index, directory: cacheDirectory, languages: languages, retryEmpty: retryEmpty)
                        try Task.checkCancellation()
                        await self?.acceptOCR(result, page: index, identity: identity, generation: generation)
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        try Task.checkCancellation()
                        lastFailure = error.localizedDescription
                        await self?.recordOCRFailure(error.localizedDescription, page: index, generation: generation)
                    }
                }
                await self?.finishOCR(generation: generation, failure: lastFailure)
            } catch is CancellationError { /* A newer request owns the UI. */ }
            catch {
                guard !Task.isCancelled else { return }
                await self?.finishOCR(generation: generation, failure: error.localizedDescription)
            }
        }
    }

    private func reportOCRProgress(page: Int, completed: Int, total: Int, generation: UUID) {
        guard generation == ocrGeneration else { return }
        ocrStatus = .recognizing(page: page, completed: completed, total: total)
    }

    private func acceptOCR(_ result: OCRPageResult, page index: Int, identity: String, generation: UUID) {
        guard generation == ocrGeneration, identity == documentID, let document,
              index >= 0, index < document.pageCount else { return }
        switch result {
        case .nativeText: ocrOutcomes[index] = .ready
        case .noText: ocrOutcomes[index] = .noText
        case .recognized(_, let bytes):
            guard let derived = PDFDocument(data: bytes), let replacement = derived.page(at: 0) else {
                ocrOutcomes[index] = .failed(OCRStorageError.unreadable.localizedDescription)
                return
            }
            // Skip pages that already have an installed OCR layer. Repeating a
            // whole-document run must not clear a selection or duplicate marks.
            if let old = document.page(at: index), !Self.hasSelectableText(old) {
                NotificationCenter.default.post(name: .leafPDFWillReplacePage, object: identity)
                // Source annotations belong to the full displayed document.
                // Copy them here so internal link destinations remain attached
                // to their actual target pages, rather than a single-page PDF.
                for annotation in replacement.annotations { replacement.removeAnnotation(annotation) }
                for annotation in old.annotations {
                    let name = annotation.value(forAnnotationKey: .name) as? String ?? ""
                    guard !name.hasPrefix("leaf-reader:"), let copy = annotation.copy() as? PDFAnnotation else { continue }
                    if let url = annotation.url { copy.action = PDFActionURL(url: url) }
                    replacement.addAnnotation(copy)
                }
                for pageIndex in 0..<document.pageCount {
                    let page = pageIndex == index ? replacement : document.page(at: pageIndex)
                    for annotation in page?.annotations ?? [] {
                        if let action = annotation.action as? PDFActionGoTo, action.destination.page === old {
                            let destination = PDFDestination(page: replacement, at: action.destination.point)
                            destination.zoom = action.destination.zoom
                            action.destination = destination
                        }
                    }
                }
                document.removePage(at: index)
                document.insert(replacement, at: index)
                documentRevision += 1
            }
            ocrOutcomes[index] = .ready
        }
        if index == currentPage, let current = document.page(at: index) {
            currentPageNeedsOCR = !Self.hasSelectableText(current)
        }
    }

    private func recordOCRFailure(_ detail: String, page: Int, generation: UUID) {
        guard generation == ocrGeneration else { return }
        ocrOutcomes[page] = .failed(detail)
    }

    private func finishOCR(generation: UUID, failure: String?) {
        guard generation == ocrGeneration else { return }
        ocrTask = nil; ocrWholeDocument = false
        if let failure { ocrStatus = .failed(failure) }
        else if let outcome = ocrOutcomes[currentPage] { showOCRResult(outcome) }
        else { scheduleCurrentPageOCR() }
    }
}

enum OCRStorageError: LocalizedError {
    case sourceChanged, unreadable
    var errorDescription: String? {
        switch self {
        case .sourceChanged: return "The PDF has changed on disk. Reopen it before recognizing text."
        case .unreadable: return "The PDF page could not be read."
        }
    }
}

enum OCRCacheStorage {
    static func recognize(page: PDFPage, pageIndex: Int, directory: URL, languages: [String], retryEmpty: Bool) async throws -> OCRPageResult {
        try Task.checkCancellation()
        if !(page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .nativeText }
        let file = directory.appendingPathComponent("page-\(pageIndex).json")
        if let data = try? Data(contentsOf: file), let cached = try? JSONDecoder().decode(OCRPageCache.self, from: data), cached.matches(page: page) {
            if !cached.lines.isEmpty {
                let derived = try LocalOCR.makeSelectablePDFData(from: page, cache: cached)
                return .recognized(cached, derived)
            }
            if !retryEmpty { return .noText(cached) }
        }
        let result = try await LocalOCR.recognize(page: page, preferredLanguages: languages)
        try Task.checkCancellation()
        let cache: OCRPageCache
        switch result {
        case .nativeText: return result
        case .noText(let value), .recognized(let value, _): cache = value
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(cache).write(to: file, options: .atomic)
        return result
    }
}
