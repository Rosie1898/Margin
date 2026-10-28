import Foundation
import PDFKit
import CryptoKit
import CoreText

@main
struct SampleNavigationTests {
    @MainActor static func main() async throws {
        precondition(CommandLine.arguments.count == 3, "Usage: sample-navigation-tests PROJECT_ROOT SCRATCH_DIRECTORY")
        let project = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let scratch = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let run = scratch.appendingPathComponent("sample-navigation-\(UUID().uuidString)", isDirectory: true)
        let folder = run.appendingPathComponent("Library", isDirectory: true)
        let nested = folder.appendingPathComponent("Nested/Deeper", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let fixture = try Data(contentsOf: project.appendingPathComponent("Tests/Fixtures/selection.pdf"))
        let original = folder.appendingPathComponent("Reading.pdf")
        let nestedCopy = nested.appendingPathComponent("Other.pdf")
        try fixture.write(to: original); try fixture.write(to: nestedCopy)
        let sample = run.appendingPathComponent(SampleDocument.filename)
        let sampleBytes = syntheticSample()
        try sampleBytes.write(to: sample)
        let samplePDF = PDFDocument(data: sampleBytes)!
        let highlight = SampleDocument.highlight(in: samplePDF)!
        precondition(samplePDF.pageCount == 12 && highlight.page == 2)
        precondition(highlight.text.hasPrefix("I do not see how one can look at figures like these"))
        precondition(highlight.text.contains("about anything rise.") || highlight.text.contains("about anything else."))
        precondition(highlight.rects.count >= 6 && highlight.rects.allSatisfy { $0.page == 2 }, "The full classic paragraph must have real line anchors")
        let localData = run.appendingPathComponent("LocalData", isDirectory: true)
        let store = ReaderStore(dataDirectory: localData, sampleURL: sample)
        await store.setFolder(folder)
        await store.open(original)
        store.pageChanged(1)
        let originalID = store.documentID!
        let originalDocument = store.document
        let bookmark = store.library.folderBookmark
        let paths = store.files.map(\.relativePath)
        precondition(paths.contains("Nested/Deeper/Other.pdf"))
        await store.openDemo()
        precondition(store.isShowingDemo && store.documentID != originalID)
        precondition(store.library.folderPath == folder.path && store.library.folderBookmark == bookmark)
        precondition(store.library.selectedPath == original.path && store.files.map(\.relativePath) == paths)
        precondition(store.annotations.count == 1 && store.annotations[0].rects == highlight.rects)
        precondition(store.currentPage == 2 && store.navigationRect == highlight.rects.first)
        let sampleID = store.documentID!
        let seededID = store.annotations[0].id
        store.pageChanged(4)
        await store.closeDemo()
        precondition(!store.isShowingDemo && store.document === originalDocument && store.documentID == originalID && store.currentPage == 1)
        await store.openDemo()
        precondition(store.annotations.count == 1 && store.currentPage == 4, "Opening again preserves sample progress without duplicating the highlight")
        precondition(store.deleteAnnotation(seededID))
        let reopened = ReaderStore(dataDirectory: localData, sampleURL: sample)
        await reopened.restore()
        precondition(!reopened.isShowingDemo && reopened.library.folderPath == folder.path && reopened.library.selectedPath == original.path)
        precondition(reopened.documentID == originalID && reopened.currentPage == 1, "Restarting during a sample must restore the normal reading session")
        await reopened.openDemo()
        precondition(reopened.annotations.isEmpty && reopened.record!.annotations.count == 1 && reopened.record!.annotations[0].deletedAt != nil)
        await reopened.open(nestedCopy)
        precondition(!reopened.isShowingDemo && reopened.library.selectedPath == nestedCopy.path && reopened.currentPage == 1)
        // The ledger also survives a future explicit removal of a tombstone.
        reopened.library.documents[sampleID]!.annotations = []
        reopened.save()
        await reopened.openDemo()
        precondition(reopened.annotations.isEmpty)
        let afterDeletion = ReaderStore(dataDirectory: localData, sampleURL: sample)
        await afterDeletion.restore(); await afterDeletion.openDemo()
        precondition(afterDeletion.annotations.isEmpty)
        await afterDeletion.closeDemo()

        // Closing a sample while its content hash is still loading wins over the
        // detached work. No late completion may replace the returned document.
        let opening = Task { await afterDeletion.openDemo() }
        for _ in 0..<100 where !afterDeletion.isShowingDemo { await Task.yield() }
        precondition(afterDeletion.isShowingDemo)
        await afterDeletion.closeDemo()
        await opening.value
        precondition(!afterDeletion.isShowingDemo && afterDeletion.documentID == originalID)

        await afterDeletion.openDemo()
        let otherFolder = run.appendingPathComponent("NewFolder", isDirectory: true)
        try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: true)
        try fixture.write(to: otherFolder.appendingPathComponent("New.pdf"))
        await afterDeletion.setFolder(otherFolder)
        precondition(!afterDeletion.isShowingDemo && afterDeletion.library.folderPath == otherFolder.path)

        let firstRun = ReaderStore(dataDirectory: run.appendingPathComponent("FirstRun"), sampleURL: sample)
        await firstRun.restore()
        precondition(firstRun.isShowingDemo && firstRun.library.folderPath == nil && firstRun.library.selectedPath == nil && firstRun.files.isEmpty)
        await firstRun.closeDemo()
        precondition(firstRun.document == nil && !firstRun.isShowingDemo)

        // A normal library may contain an identical copy of the sample paper.
        // Sample navigation must not change that copy's saved reading position.
        let sameFolder = run.appendingPathComponent("SamePaper", isDirectory: true)
        try FileManager.default.createDirectory(at: sameFolder, withIntermediateDirectories: true)
        let samePaper = sameFolder.appendingPathComponent("Lucas.pdf")
        try sampleBytes.write(to: samePaper)
        let sameStore = ReaderStore(dataDirectory: run.appendingPathComponent("SameData"), sampleURL: sample)
        await sameStore.setFolder(sameFolder)
        sameStore.pageChanged(10)
        await sameStore.openDemo(); sameStore.pageChanged(5)
        precondition(sameStore.library.selectedPath == samePaper.path && sameStore.record?.page == 10)
        await sameStore.closeDemo()
        precondition(sameStore.currentPage == 10 && sameStore.record?.path == samePaper.path)

        let invalidSample = run.appendingPathComponent("Invalid.pdf")
        try Data("Not a PDF".utf8).write(to: invalidSample)
        let failedStore = ReaderStore(dataDirectory: localData, sampleURL: invalidSample)
        await failedStore.restore()
        let beforeFailure = failedStore.documentID
        await failedStore.openDemo()
        precondition(!failedStore.isShowingDemo && failedStore.documentID == beforeFailure && !failedStore.isOpening && failedStore.error != nil)

        let legacyData = run.appendingPathComponent("LegacyData", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyData, withIntermediateDirectories: true)
        var legacy = LibraryState()
        legacy.folderPath = "/Applications/Margin.app/Contents/Resources/Samples"
        legacy.selectedPath = legacy.folderPath! + "/Welcome to Leaf.pdf"
        try JSONEncoder().encode(legacy).write(to: legacyData.appendingPathComponent("library.json"))
        let migrated = ReaderStore(dataDirectory: legacyData, sampleURL: sample)
        await migrated.restore()
        precondition(migrated.isShowingDemo && migrated.library.folderPath == nil && migrated.library.selectedPath == nil)

        let sampleAfter = try Data(contentsOf: sample)
        let originalAfter = try Data(contentsOf: original)
        precondition(sampleAfter == sampleBytes && originalAfter == fixture, "Neither sample highlights nor reading modify PDF bytes")
        try await downloadChecks(run: run, original: original, folder: folder, bytes: sampleBytes)
        print("SAMPLE_NAVIGATION_PASSED: original folder/page restoration, restart, first-run/legacy migration, one-time sample paragraph highlight, deletion, download consent/cache/integrity/cancellation, races and unchanged PDFs; externalAPICalls=0")
    }
    /// Generated test document: no third-party paper is needed by the tests.
    static func syntheticSample() -> Data {
        let data = NSMutableData()
        var media = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &media, nil)!
        let font = CTFontCreateWithName("Helvetica" as CFString, 15, nil)
        for page in 0..<12 {
            context.beginPDFPage(nil)
            let lines = page == 2 ? [
                "I do not see how one can look at figures like these",
                "Synthetic paragraph for navigation checks.",
                "The next lines exercise multiple highlight anchors.",
                "This is an original test fixture, not a paper copy.",
                "Selections should keep every line in the passage.",
                "The final marker is about anything else."
            ] : ["Sample navigation test page \(page + 1)"]
            for (index, text) in lines.enumerated() {
                let value = CFAttributedStringCreate(nil, text as CFString, [kCTFontAttributeName: font] as CFDictionary)!
                context.textMatrix = .identity
                context.textPosition = CGPoint(x: 45, y: 700 - index * 30)
                CTLineDraw(CTLineCreateWithAttributedString(value), context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    @MainActor static func downloadChecks(run: URL, original: URL, folder: URL, bytes: Data) async throws {
        let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let counts = SampleDownloadCounts()
        var approvals = 0
        let local = run.appendingPathComponent("DownloadData")
        let store = ReaderStore(dataDirectory: local, sampleDownload: { source in
            precondition(source == SampleDocument.sourceURL)
            await counts.increment()
            return bytes
        }, sampleExpectedSHA256: expected, sampleDownloadApproval: { approvals += 1; return true })
        await store.restore()
        let startupDownloads = await counts.value
        precondition(!store.isShowingDemo && approvals == 0 && startupDownloads == 0, "First launch never asks for or starts a download")
        await store.setFolder(folder); await store.open(original)
        let originalID = store.documentID
        await store.openDemo()
        let firstDownloads = await counts.value
        precondition(store.isShowingDemo && approvals == 1 && firstDownloads == 1)
        let cache = SampleDocument.cachedURL(in: local)
        let cachedBytes = try Data(contentsOf: cache)
        precondition(cachedBytes == bytes, "Cache preserves downloaded bytes exactly")
        await store.closeDemo()
        precondition(store.documentID == originalID && store.library.folderPath == folder.path)
        await store.openDemo(); await store.closeDemo()
        let cachedDownloads = await counts.value
        precondition(approvals == 1 && cachedDownloads == 1, "A verified cache works offline without another prompt")
        try Data("corrupt cache".utf8).write(to: cache)
        await store.openDemo(); await store.closeDemo()
        let recoveredDownloads = await counts.value
        precondition(approvals == 2 && recoveredDownloads == 2 && SampleDocument.verifiedCache(cache, expectedSHA256: expected) != nil)

        let denied = ReaderStore(dataDirectory: run.appendingPathComponent("DeniedDownload"), sampleDownload: { _ in
            preconditionFailure("A denied download must never access the network")
        }, sampleDownloadApproval: { false })
        await denied.setFolder(folder); await denied.open(original)
        await denied.openDemo()
        precondition(!denied.isShowingDemo && !denied.isOpening && denied.documentID == originalID && denied.error == nil)

        let mismatchData = run.appendingPathComponent("MismatchDownload")
        let mismatch = ReaderStore(dataDirectory: mismatchData, sampleDownload: { _ in bytes }, sampleExpectedSHA256: String(repeating: "0", count: 64), sampleDownloadApproval: { true })
        await mismatch.setFolder(folder); await mismatch.open(original); await mismatch.openDemo()
        precondition(!mismatch.isShowingDemo && mismatch.documentID == originalID && mismatch.error != nil)
        precondition(!FileManager.default.fileExists(atPath: SampleDocument.cachedURL(in: mismatchData).path), "Unverified bytes must never enter the cache")

        for closeSample in [false, true] {
            let gate = SampleDownloadGate()
            let cancelData = run.appendingPathComponent(closeSample ? "CloseDownload" : "NavigateDownload")
            let pending = ReaderStore(dataDirectory: cancelData, sampleDownload: { _ in await gate.wait() }, sampleExpectedSHA256: expected, sampleDownloadApproval: { true })
            await pending.setFolder(folder); await pending.open(original)
            let opening = Task { await pending.openDemo() }
            for _ in 0..<200 {
                if await gate.started { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let started = await gate.started
            precondition(started && pending.isShowingDemo && pending.isOpening)
            if closeSample { await pending.closeDemo() } else { await pending.open(original) }
            await gate.finish(bytes)
            await opening.value
            precondition(!pending.isShowingDemo && !pending.isOpening && pending.documentID == originalID && pending.error == nil)
            precondition(!FileManager.default.fileExists(atPath: SampleDocument.cachedURL(in: cancelData).path), "Late cancelled downloads cannot open or cache a sample")
        }
    }

}


actor SampleDownloadCounts {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// Deliberately ignores cancellation to test the store's late-result guard.
actor SampleDownloadGate {
    private(set) var started = false
    private var continuation: CheckedContinuation<Data, Never>?
    func wait() async -> Data {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish(_ bytes: Data) { continuation?.resume(returning: bytes); continuation = nil }
}
