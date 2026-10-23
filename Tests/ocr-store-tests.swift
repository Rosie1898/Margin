import Foundation
import AppKit
import PDFKit
import CoreGraphics
import CoreText
import CryptoKit

private struct OCRStoreFailure: Error, CustomStringConvertible {
    var description: String
}

@main
struct OCRStoreTests {
    @MainActor static func main() async {
        do {
            precondition(CommandLine.arguments.count == 3, "Usage: ocr-store-tests PROJECT_ROOT SCRATCH_DIRECTORY")
            let scratch = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            let run = scratch.appendingPathComponent("ocr-store-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
            try await runChecks(in: run)
            print("OCR_STORE_PASSED: automatic local OCR, selection anchors and three annotation kinds, cache reopening/rebuild, cancellation and document-switch isolation, native-page skip, unchanged PDFs; external API calls=0")
        } catch {
            fputs("OCR_STORE_FAILED: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw OCRStoreFailure(description: message) }
    }

    @MainActor private static func waitForOCR(_ store: ReaderStore, label: String) async throws {
        let deadline = Date().addingTimeInterval(45)
        while store.ocrTask != nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        try check(store.ocrTask == nil, "\(label): OCR did not finish within 45 seconds")
        try check(store.ocrStatus == .ready, "\(label): expected ready, received \(store.ocrStatus)")
        try check(store.error == nil, "\(label): unexpected store error \(store.error ?? "")")
    }

    @MainActor static func runChecks(in run: URL) async throws {
        let manager = FileManager.default
        let runID = UUID().uuidString
        let progressURL = run.appendingPathComponent("ocr-store-progress.jsonl")
        try Data().write(to: progressURL, options: .atomic)
        func mark(_ stage: String) throws {
            let entry = ["runID": runID, "stage": stage, "time": ISO8601DateFormatter().string(from: Date())]
            var data = try Data(contentsOf: progressURL)
            data.append(try JSONSerialization.data(withJSONObject: entry, options: .sortedKeys))
            data.append(10)
            try data.write(to: progressURL, options: .atomic)
        }
        try mark("started")
        let scanBytes = try fixture(scanned: true)
        let nativeBytes = try fixture(scanned: false)
        let scanURL = run.appendingPathComponent("Scanned Paper.pdf")
        let nativeURL = run.appendingPathComponent("Native Paper.pdf")
        try scanBytes.write(to: scanURL)
        try nativeBytes.write(to: nativeURL)
        try check(PDFDocument(data: scanBytes)?.page(at: 0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
                  "The scan fixture must start with no selectable text")
        let dataDirectory = run.appendingPathComponent("ReaderData", isDirectory: true)
        let store = ReaderStore(dataDirectory: dataDirectory)
        await store.open(scanURL)
        try check(store.currentPageNeedsOCR && store.ocrTask != nil, "Opening an image-only PDF must schedule local OCR automatically")
        try mark("automatic_ocr_started")
        try await waitForOCR(store, label: "automatic scan")
        try mark("automatic_ocr_completed")
        let scanIdentity = store.documentID!
        try check(scanIdentity == SHA256.hash(data: scanBytes).map { String(format: "%02x", $0) }.joined(),
                  "OCR must preserve the original-file document identity")
        try check(!store.currentPageNeedsOCR && store.documentRevision > 0, "Installing selectable text must update the visible document revision")
        guard let document = store.document,
              let selection = document.findString("Economic growth", withOptions: .caseInsensitive).first,
              let snapshot = PDFCanvas.snapshot(from: selection, document: document) else {
            throw OCRStoreFailure(description: "Real OCR output must support a normal PDFCanvas selection snapshot")
        }
        try check(snapshot.text.localizedCaseInsensitiveContains("Economic growth") && snapshot.pageText.contains(snapshot.text),
                  "The selection quote and page context must come from the recognized page")
        let crop = document.page(at: 0)!.bounds(for: .cropBox)
        try check(!snapshot.rects.isEmpty && snapshot.rects.allSatisfy {
            $0.page == 0 && $0.width > 0 && $0.height > 0 && crop.intersects($0.cgRect)
        }, "OCR selections must retain usable anchors in original-page coordinates")
        var annotationIDs: [UUID] = []
        for kind in [AnnotationKind.highlight, .comment, .question] {
            store.receiveSelection(snapshot)
            guard let id = store.createAnnotation(kind) else {
                throw OCRStoreFailure(description: "OCR selection did not create \(kind)")
            }
            annotationIDs.append(id)
        }
        store.mutateAnnotation(annotationIDs[1]) { $0.comment = "A local comment on recognized text." }
        let savedAnnotations = store.annotations
        try check(savedAnnotations.count == 3 && savedAnnotations.allSatisfy {
            $0.quote == snapshot.text && $0.rects == snapshot.rects && $0.pageText == snapshot.pageText
        }, "Highlight, comment and question must preserve the same recognized quote and line anchors")
        try check(savedAnnotations.last?.messages.isEmpty == true && store.sending.isEmpty,
                  "Creating a question must not send any AI request")
        try mark("annotation_anchors_verified")

        let cacheDirectory = dataDirectory.appendingPathComponent("OCR", isDirectory: true).appendingPathComponent(scanIdentity, isDirectory: true)
        let cacheURL = cacheDirectory.appendingPathComponent("page-0.json")
        let cacheBytes = try Data(contentsOf: cacheURL)
        let cache = try JSONDecoder().decode(OCRPageCache.self, from: cacheBytes)
        try check(!cache.lines.isEmpty && cache.matches(page: PDFDocument(data: scanBytes)!.page(at: 0)!),
                  "Successful recognition must save a geometry-validated cache")

        // A successful cache hit must not rewrite the cache. An old modification
        // date distinguishes reuse from a second Vision pass writing equal bytes.
        let oldDate = Date(timeIntervalSince1970: 946_684_800)
        try manager.setAttributes([.modificationDate: oldDate], ofItemAtPath: cacheURL.path)
        let reopened = ReaderStore(dataDirectory: dataDirectory)
        await reopened.open(scanURL)
        try await waitForOCR(reopened, label: "cached reopening")
        let afterCacheHit = try Data(contentsOf: cacheURL)
        let cacheDate = try manager.attributesOfItem(atPath: cacheURL.path)[.modificationDate] as? Date
        try check(afterCacheHit == cacheBytes && cacheDate == oldDate, "Reopening must reuse the saved OCR cache without another recognition write")
        try check(reopened.annotations == savedAnnotations, "Reopening an OCR document must retain annotation IDs, kinds, comments and anchors")
        reopened.focusAnnotation(annotationIDs[1])
        try check(reopened.navigationRect == snapshot.rects.first, "Clicking an OCR comment must still target its original-page anchor")
        try mark("cached_reopening_verified")

        var invalidCache = cache
        invalidCache.schemaVersion = -1
        try JSONEncoder().encode(invalidCache).write(to: cacheURL, options: .atomic)
        let rebuilt = ReaderStore(dataDirectory: dataDirectory)
        await rebuilt.open(scanURL)
        try await waitForOCR(rebuilt, label: "invalid-cache rebuild")
        let rebuiltCache = try JSONDecoder().decode(OCRPageCache.self, from: Data(contentsOf: cacheURL))
        try check(rebuiltCache.schemaVersion == OCRPageCache.currentSchemaVersion && !rebuiltCache.lines.isEmpty,
                  "An incompatible cache must be replaced by a fresh valid OCR result")
        try check(rebuilt.annotations == savedAnnotations && rebuilt.document?.findString("Economic growth", withOptions: .caseInsensitive).isEmpty == false,
                  "Rebuilding recognition must preserve annotations and restore selectable text")
        try mark("invalid_cache_rebuilt")

        let cancelled = ReaderStore(dataDirectory: run.appendingPathComponent("CancelledData", isDirectory: true))
        await cancelled.open(scanURL)
        let cancelledTask = cancelled.ocrTask
        let cancelledRevision = cancelled.documentRevision
        cancelled.cancelOCR()
        await cancelledTask?.value
        try check(cancelled.ocrTask == nil && cancelled.ocrStatus == .cancelled && cancelled.documentRevision == cancelledRevision,
                  "Cancelling automatic OCR must prevent any late installation or status overwrite")
        try check(!LocalOCR.hasNativeText(cancelled.document!.page(at: 0)!), "Cancelling before recognition must leave the displayed scan unchanged")
        // Also exercise cancellation after starting an immediate worker rather
        // than only the automatic debounce task.
        cancelled.recognizeCurrentPage()
        let immediateTask = cancelled.ocrTask
        cancelled.cancelOCR()
        await immediateTask?.value
        try check(cancelled.ocrStatus == .cancelled && cancelled.documentRevision == cancelledRevision,
                  "An immediately started, cancelled worker must not replace the page")
        try mark("cancellation_verified")

        let switched = ReaderStore(dataDirectory: run.appendingPathComponent("SwitchedData", isDirectory: true))
        await switched.open(scanURL)
        switched.recognizeCurrentPage()
        let oldWorker = switched.ocrTask
        await switched.open(nativeURL)
        let nativeDocument = switched.document
        let nativeIdentity = switched.documentID
        let nativeRevision = switched.documentRevision
        await oldWorker?.value
        try check(switched.document === nativeDocument && switched.documentID == nativeIdentity && switched.documentRevision == nativeRevision,
                  "A previous file's worker must never install a page into the newly opened document")
        try check(switched.ocrTask == nil && switched.ocrStatus == .idle && !switched.currentPageNeedsOCR,
                  "Switching to native text must leave OCR idle without stale completion status")
        try mark("document_switch_verified")

        let mixed = PDFDocument()
        mixed.insert(PDFDocument(data: nativeBytes)!.page(at: 0)!, at: 0)
        mixed.insert(PDFDocument(data: scanBytes)!.page(at: 0)!, at: 1)
        let mixedBytes = mixed.dataRepresentation()!
        let mixedURL = run.appendingPathComponent("Mixed Paper.pdf")
        try mixedBytes.write(to: mixedURL)
        let mixedDataDirectory = run.appendingPathComponent("MixedData", isDirectory: true)
        let mixedStore = ReaderStore(dataDirectory: mixedDataDirectory)
        await mixedStore.open(mixedURL)
        let nativePage = mixedStore.document!.page(at: 0)!
        let nativeText = nativePage.string
        try check(mixedStore.ocrTask == nil, "A mixed document's native first page must not trigger automatic OCR")
        mixedStore.recognizeDocument()
        try await waitForOCR(mixedStore, label: "mixed document")
        try check(mixedStore.document!.page(at: 0) === nativePage && nativePage.string == nativeText,
                  "Whole-document OCR must preserve original native-text pages")
        try check(LocalOCR.hasNativeText(mixedStore.document!.page(at: 1)!), "Whole-document OCR must recognize the scanned page")
        let mixedCache = mixedDataDirectory.appendingPathComponent("OCR", isDirectory: true).appendingPathComponent(mixedStore.documentID!, isDirectory: true)
        try check(!manager.fileExists(atPath: mixedCache.appendingPathComponent("page-0.json").path) && manager.fileExists(atPath: mixedCache.appendingPathComponent("page-1.json").path),
                  "Whole-document OCR must cache only pages that needed recognition")
        let mixedRevision = mixedStore.documentRevision
        mixedStore.recognizeDocument()
        try await waitForOCR(mixedStore, label: "repeated mixed document")
        try check(mixedStore.documentRevision == mixedRevision, "Repeating OCR must not replace already selectable pages")
        try mark("mixed_document_verified")

        let finalScanBytes = try Data(contentsOf: scanURL)
        let finalNativeBytes = try Data(contentsOf: nativeURL)
        let finalMixedBytes = try Data(contentsOf: mixedURL)
        try check(finalScanBytes == scanBytes && finalNativeBytes == nativeBytes && finalMixedBytes == mixedBytes,
                  "Recognition, annotations, cancellation and cache rebuilds must never change original PDF bytes")
        let report: [String: Any] = [
            "passed": true, "runID": runID, "completedAt": ISO8601DateFormatter().string(from: Date()),
            "externalAPICalls": 0, "originalPDFsUnchanged": true,
            "annotationKinds": ["highlight", "comment", "question"],
            "cacheHitPreservedModificationDate": true, "invalidCacheRebuilt": true,
            "cancelAndSwitchPreventedLateInstallation": true, "nativePagePreserved": true
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: run.appendingPathComponent("ocr-store-result.json"))
        try mark("completed")
    }

    /// The scanned fixture contains only a raster image. Its counterpart uses
    /// real PDF text, allowing the same visible words to test native-page skip.
    private static func fixture(scanned: Bool) throws -> Data {
        let media = CGRect(x: 0, y: 0, width: 600, height: 780)
        let bytes = NSMutableData()
        var mediaBox = media
        guard let consumer = CGDataConsumer(data: bytes as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw OCRStoreFailure(description: "Could not create local PDF fixture")
        }
        context.beginPDFPage(nil)
        if scanned {
            guard let raster = CGContext(data: nil, width: 1200, height: 1560, bitsPerComponent: 8, bytesPerRow: 4800,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw OCRStoreFailure(description: "Could not create local scan raster")
            }
            raster.scaleBy(x: 2, y: 2)
            drawFixture(in: raster, bounds: media)
            context.draw(raster.makeImage()!, in: media)
        } else { drawFixture(in: context, bounds: media) }
        context.endPDFPage(); context.closePDF()
        return bytes as Data
    }

    private static func drawFixture(in context: CGContext, bounds: CGRect) {
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(bounds)
        let font = CTFontCreateWithName("Helvetica" as CFString, 25, nil)
        for (index, text) in ["Economic growth expands", "human possibilities.", "Read and discuss on your Mac."].enumerated() {
            let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 0, alpha: 1)] as CFDictionary
            let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attributes)!)
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: 50, y: 620 - index * 45)
            CTLineDraw(line, context)
        }
    }
}
