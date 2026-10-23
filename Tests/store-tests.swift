import Foundation
import PDFKit
import CryptoKit

@main
struct StoreTests {
    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    @MainActor static func selection(_ store: ReaderStore, page index: Int = 0) -> SelectionSnapshot {
        let page = store.document!.page(at: index)!
        let text = page.string!
        let firstLine = text.split(separator: "\n").first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })!
        let selected = page.selection(for: (text as NSString).range(of: String(firstLine)))!
        let rects = selected.selectionsByLine().flatMap { line in
            line.pages.map { PageRect(page: store.document!.index(for: $0), rect: line.bounds(for: $0)) }
        }
        return SelectionSnapshot(text: selected.string!, rects: rects, pageText: String(text.prefix(12_000)))
    }

    @MainActor static func main() async throws {
        precondition(CommandLine.arguments.count == 3, "Usage: store-tests PROJECT_ROOT SCRATCH_DIRECTORY")
        let project = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let scratch = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let demo = project.appendingPathComponent("Tests/Fixtures/welcome.pdf")
        let sourceBytes = try Data(contentsOf: demo)
        let sourceSHA = sha(sourceBytes)
        let run = scratch.appendingPathComponent("store-qa-\(UUID().uuidString)", isDirectory: true)
        let folder = run.appendingPathComponent("Library", isDirectory: true)
        let nested = folder.appendingPathComponent("Nested", isDirectory: true)
        let localData = run.appendingPathComponent("LocalData", isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: nested, withIntermediateDirectories: true)
        let originalCopy = folder.appendingPathComponent("A Welcome.pdf")
        let identicalCopy = nested.appendingPathComponent("A Welcome.pdf")
        let independent = folder.appendingPathComponent("B Independent.pdf")
        try sourceBytes.write(to: originalCopy)
        try sourceBytes.write(to: identicalCopy)
        let second = PDFDocument(data: sourceBytes)!
        var attributes = second.documentAttributes ?? [:]
        attributes[PDFDocumentAttribute.titleAttribute] = "Independent QA copy"
        second.documentAttributes = attributes
        precondition(second.write(to: independent))
        let secondBytes = try Data(contentsOf: independent)
        precondition(sha(secondBytes) != sourceSHA)
        try Data("not a PDF".utf8).write(to: folder.appendingPathComponent("ignore.txt"))

        let store = ReaderStore(dataDirectory: localData)
        await store.setFolder(folder)
        precondition(store.error == nil, store.error ?? "")
        precondition(store.files.count == 3)
        precondition(store.files.contains { $0.relativePath == "Nested/A Welcome.pdf" })
        precondition(store.documentID == sourceSHA)
        precondition(store.document!.pageCount >= 2, "Demo must have multiple pages to test restoration")

        let anchored = selection(store)
        store.receiveSelection(anchored)
        store.selectedColor = .blue
        let commentID = store.createAnnotation(.comment)!
        store.mutateAnnotation(commentID) { $0.comment = "Persistence QA: 普通评论，含中文与公式 x²。" }
        store.receiveSelection(anchored)
        store.selectedColor = .yellow
        let highlightID = store.createAnnotation(.highlight)!
        store.receiveSelection(selection(store, page: 1))
        let questionID = store.createAnnotation(.question)!
        store.mutateAnnotation(questionID) {
            $0.messages = [ChatMessage(role: "user", text: "Synthetic local transcript; no network call."), ChatMessage(role: "assistant", text: "Saved answer.", model: "test-only", effort: "low")]
            $0.collapsed = true
        }
        store.pageChanged(1)
        let recorded = store.record!
        precondition(recorded.annotations.count == 3)
        precondition(recorded.page == 1)

        await store.open(independent)
        let independentID = store.documentID!
        precondition(independentID != sourceSHA && store.annotations.isEmpty)
        store.receiveSelection(selection(store))
        let independentComment = store.createAnnotation(.comment)!
        store.mutateAnnotation(independentComment) { $0.comment = "Only in the independent PDF." }
        precondition(store.library.documents[sourceSHA]!.annotations.count == 3)

        await store.open(identicalCopy)
        precondition(store.documentID == sourceSHA)
        precondition(store.annotations == recorded.annotations, "Byte-identical copy must share content identity")
        precondition(store.currentPage == 1)
        let renamed = folder.appendingPathComponent("Renamed Welcome.pdf")
        try manager.moveItem(at: originalCopy, to: renamed)
        await store.refreshFolder()
        await store.open(renamed)
        precondition(store.documentID == sourceSHA)
        precondition(store.annotations == recorded.annotations, "Renaming must retain anchors and comments")
        precondition(store.record!.path == renamed.path)
        precondition(store.annotations.allSatisfy { $0.sourceFilename == "A Welcome" }, "AI source filename must stay immutable across PDF renames")
        store.focusAnnotation(commentID)
        precondition(store.navigationRect == anchored.rects.first)
        precondition(store.selectedAnnotation?.id == commentID)
        store.pageChanged(1)
        store.library.userBubble = "EAF1FB"
        store.library.aiBubble = "E8F3ED"
        store.library.selectedModel = "test-only"
        store.library.selectedEffort = "high"
        store.updateSettings {
            $0.language = .en; $0.textSize = 17; $0.themeHex = "#DDE8F5"
            $0.centerOpacity = 0.55; $0.sidesOpacity = 0.72; $0.trashRetentionDays = 90
        }
        let backgroundSource = run.appendingPathComponent("test-background.png")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let fixtureColor = NSColor(srgbRed: 0.68, green: 0.85, blue: 0.76, alpha: 1)
        for x in 0..<2 { for y in 0..<2 { bitmap.setColor(fixtureColor, atX: x, y: y) } }
        let backgroundBytes = bitmap.representation(using: .png, properties: [:])!
        try backgroundBytes.write(to: backgroundSource)
        precondition(store.importBackgroundImage(from: backgroundSource))
        precondition(store.backgroundImage != nil)
        let backgroundName = store.library.settings.backgroundImage!
        let savedBackground = localData.appendingPathComponent("Backgrounds").appendingPathComponent(backgroundName)
        let savedBackgroundBytes = try Data(contentsOf: savedBackground)
        precondition(savedBackgroundBytes == backgroundBytes)
        try manager.removeItem(at: backgroundSource)
        precondition(!store.importBackgroundImage(from: demo), "PDFs must not be accepted as background images")
        precondition(store.library.settings.backgroundImage == backgroundName && store.backgroundImage != nil)
        store.error = nil
        store.save()

        let reopened = ReaderStore(dataDirectory: localData)
        await reopened.restore()
        precondition(reopened.error == nil, reopened.error ?? "")
        precondition(reopened.library.folderPath == folder.path)
        precondition(reopened.library.selectedPath == renamed.path)
        precondition(reopened.documentID == sourceSHA)
        precondition(reopened.currentPage == 1)
        precondition(reopened.annotations == recorded.annotations)
        precondition(reopened.library.documents[independentID]!.annotations.first?.id == independentComment)
        precondition(reopened.library.selectedModel == "test-only" && reopened.library.selectedEffort == "high")
        precondition(reopened.library.settings == store.library.settings, "All settings must survive restart")
        precondition(reopened.backgroundImage != nil, "Imported background must load from its local copy after source removal")
        precondition(reopened.library.settings.themeHex == "DDE8F5")
        precondition(reopened.localized("中文", "English") == "English")
        precondition(reopened.annotations.first { $0.id == questionID }!.collapsed)
        precondition(reopened.annotations.first { $0.id == commentID }!.rects == anchored.rects)

        // Version 1 had neither settings nor deletedAt. Migration must preserve
        // every original annotation and chat message rather than starting fresh.
        var oldState = try JSONSerialization.jsonObject(with: JSONEncoder().encode(store.library)) as! [String: Any]
        oldState["version"] = 1; oldState.removeValue(forKey: "settings")
        var oldDocuments = oldState["documents"] as! [String: [String: Any]]
        for (key, var oldDocument) in oldDocuments {
            oldDocument["annotations"] = (oldDocument["annotations"] as! [[String: Any]]).map { annotation in
                var old = annotation; old.removeValue(forKey: "deletedAt"); return old
            }
            oldDocuments[key] = oldDocument
        }
        oldState["documents"] = oldDocuments
        let migrationDirectory = run.appendingPathComponent("LegacyData", isDirectory: true)
        try manager.createDirectory(at: migrationDirectory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: oldState).write(to: migrationDirectory.appendingPathComponent("library.json"))
        let migrated = ReaderStore(dataDirectory: migrationDirectory)
        precondition(migrated.error == nil && migrated.library.version == 3)
        precondition(migrated.library.settings == ReaderSettings())
        precondition(migrated.library.documents[sourceSHA]!.annotations == recorded.annotations)
        migrated.save()
        precondition(ReaderStore(dataDirectory: migrationDirectory).library.documents[sourceSHA]!.annotations == recorded.annotations)
        var futureState = oldState; futureState["version"] = 99
        let futureDirectory = run.appendingPathComponent("FutureData", isDirectory: true)
        try manager.createDirectory(at: futureDirectory, withIntermediateDirectories: true)
        let futureBytes = try JSONSerialization.data(withJSONObject: futureState)
        let futureFile = futureDirectory.appendingPathComponent("library.json")
        try futureBytes.write(to: futureFile)
        let futureStore = ReaderStore(dataDirectory: futureDirectory)
        precondition(futureStore.error != nil)
        futureStore.save()
        let futureBytesAfter = try Data(contentsOf: futureFile)
        precondition(futureBytesAfter == futureBytes, "A newer library version must not be overwritten")

        // Deletion is a tombstone. Even an expired item remains recoverable;
        // this version does not perform irreversible background cleanup.
        let backendDirectory = localData.appendingPathComponent("Backend/conversations", isDirectory: true)
        try manager.createDirectory(at: backendDirectory, withIntermediateDirectories: true)
        let backendHistory = backendDirectory.appendingPathComponent(questionID.uuidString.lowercased() + ".json")
        let opaqueHistory = Data("{\"opaqueHistory\":\"synthetic-preservation-check\"}".utf8)
        try opaqueHistory.write(to: backendHistory)
        reopened.sending.insert(questionID)
        precondition(!reopened.deleteAnnotation(questionID), "Generating discussions must not be deletable")
        precondition(reopened.annotations.contains { $0.id == questionID })
        reopened.sending.remove(questionID)
        reopened.removeAnnotation(highlightID)
        precondition(reopened.annotations.count == 2)
        precondition(reopened.deleteAnnotation(commentID))
        precondition(reopened.deleteAnnotation(questionID))
        precondition(reopened.deleteAnnotation(independentComment, documentID: independentID))
        precondition(reopened.annotations.isEmpty)
        precondition(reopened.trashedAnnotations.count == 4, "Trash must include other documents")
        reopened.mutateAnnotation(questionID) { $0.deletedAt = Date().addingTimeInterval(-100 * 86_400) }
        let afterDelete = ReaderStore(dataDirectory: localData)
        await afterDelete.restore()
        precondition(afterDelete.library.documents[sourceSHA]!.annotations.count == 3, "Deleted items must stay on disk")
        precondition(afterDelete.annotations.isEmpty && afterDelete.trashedAnnotations.count == 4)
        precondition(afterDelete.trashedAnnotations.first { $0.id == questionID }!.isExpired(retentionDays: 90))
        precondition(afterDelete.restoreAnnotation(questionID, documentID: sourceSHA))
        precondition(afterDelete.restoreAnnotation(commentID, documentID: sourceSHA))
        precondition(afterDelete.restoreAnnotation(highlightID, documentID: sourceSHA))
        precondition(afterDelete.restoreAnnotation(independentComment, documentID: independentID))
        precondition(!afterDelete.restoreAnnotation(questionID, documentID: sourceSHA), "Restoration must be idempotent")
        precondition(afterDelete.annotations == recorded.annotations, "Restore must preserve UUID, anchor, comments, chat, color and collapsed state")
        precondition(afterDelete.trashedAnnotations.isEmpty)
        let backendHistoryAfter = try Data(contentsOf: backendHistory)
        precondition(backendHistoryAfter == opaqueHistory, "Soft deletion and restoration must not modify model history")
        let afterRestore = ReaderStore(dataDirectory: localData)
        precondition(afterRestore.library.documents[sourceSHA]!.annotations == recorded.annotations)
        afterRestore.removeBackgroundImage()
        precondition(afterRestore.backgroundImage == nil && afterRestore.library.settings.backgroundImage == nil)
        precondition(FileManager.default.fileExists(atPath: savedBackground.path), "Removing a background must not delete source or old image files")
        afterRestore.updateSettings { $0.textSize = 200; $0.centerOpacity = -1; $0.sidesOpacity = 3; $0.themeHex = "oops"; $0.backgroundImage = "../../outside.png"; $0.trashRetentionDays = 1 }
        precondition(afterRestore.library.settings.textSize == 20 && afterRestore.library.settings.centerOpacity == 0 && afterRestore.library.settings.sidesOpacity == 1)
        precondition(afterRestore.library.settings.themeHex == "F5F7F3" && afterRestore.library.settings.backgroundImage == nil && afterRestore.library.settings.trashRetentionDays == 30)

        let colorData = run.appendingPathComponent("CustomColorData", isDirectory:true)
        let colors = ReaderStore(dataDirectory:colorData)
        await colors.open(renamed)
        colors.chooseCustomHighlightColor("#ab72d4")
        colors.receiveSelection(anchored)
        let customID = colors.createAnnotation(.comment)!
        precondition(colors.annotations.first!.effectiveColorHex == "AB72D4")
        let customBefore = colors.annotations.first!
        precondition(colors.deleteAnnotation(customID))
        let restoredColors = ReaderStore(dataDirectory:colorData)
        precondition(restoredColors.library.settings.highlightColorHex == "AB72D4")
        precondition(restoredColors.restoreAnnotation(customID,documentID:sourceSHA))
        precondition(restoredColors.library.documents[sourceSHA]!.annotations.first! == customBefore)
        restoredColors.chooseCustomHighlightColor("invalid")
        precondition(restoredColors.library.settings.highlightColorHex == "AB72D4")
        restoredColors.chooseHighlightPreset(.yellow)
        precondition(restoredColors.library.settings.highlightColorHex == nil)
        var malformedColor = customBefore
        malformedColor.customColorHex = "not-a-color"
        precondition(malformedColor.effectiveColorHex == malformedColor.color.hex)

        let corruptDirectory = run.appendingPathComponent("CorruptData", isDirectory: true)
        try manager.createDirectory(at: corruptDirectory, withIntermediateDirectories: true)
        let corruptFile = corruptDirectory.appendingPathComponent("library.json")
        let corruptBytes = Data("{unfinished existing user data".utf8)
        try corruptBytes.write(to: corruptFile)
        let corruptStore = ReaderStore(dataDirectory: corruptDirectory)
        precondition(corruptStore.error != nil)
        await corruptStore.setFolder(folder)
        corruptStore.receiveSelection(selection(corruptStore))
        precondition(corruptStore.createAnnotation(.comment) == nil)
        let protectedBytes = try Data(contentsOf: corruptFile)
        precondition(protectedBytes == corruptBytes, "Unreadable existing records must never be overwritten")

        let sourceAfter = try Data(contentsOf: demo)
        let renamedAfter = try Data(contentsOf: renamed)
        let identicalAfter = try Data(contentsOf: identicalCopy)
        let independentAfter = try Data(contentsOf: independent)
        precondition(sha(sourceAfter) == sourceSHA)
        precondition(sha(renamedAfter) == sourceSHA && sha(identicalAfter) == sourceSHA)
        precondition(independentAfter == secondBytes)
        let report: [String: Any] = [
            "status": "passed", "networkCalls": 0, "sourceSHA256": sourceSHA,
            "checks": ["folder recursive listing", "content identity", "duplicate basename safety", "rename/copy identity", "immutable original annotation filename", "comment/highlight/thread roundtrip", "document isolation", "page restore", "anchor navigation", "version 1 migration", "future version protection", "settings persistence and bounds", "background local copy and validation", "soft deletion across documents", "restore complete expired discussion", "sending deletion guard", "backend history unchanged", "corrupt JSON protection", "source PDF unchanged"],
            "fixture": demo.path, "stateDirectory": localData.path
        ]
        let result = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try result.write(to: scratch.appendingPathComponent("store-tests-result.json"), options: .atomic)
        print("STORE_TESTS_PASSED: legacy migration, settings and local image persistence, safe image validation, multi-document trash, full annotation/chat restoration after expiry, generating-thread deletion guard, original backend history and PDFs unchanged, folder/SHA/page/anchor/corrupt-state checks; no network calls")
    }
}
