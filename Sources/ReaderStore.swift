import Foundation
import SwiftUI
import PDFKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class ReaderStore: ObservableObject {
    @Published var library = LibraryState()
    @Published var files: [LibraryFile] = []
    @Published var document: PDFDocument?
    @Published var documentID: String?
    @Published var selection: SelectionSnapshot?
    @Published var selectedAnnotationID: UUID?
    @Published var currentPage = 0
    @Published var navigationToken = 0
    @Published var navigationRect: PageRect?
    @Published var isOpening = false
    @Published var isScanning = false
    @Published var ocrStatus: OCRStatus = .idle
    @Published var currentPageNeedsOCR = false
    @Published var documentRevision = 0
    var ocrTask: Task<Void, Never>?
    var ocrGeneration = UUID()
    var ocrWholeDocument = false
    var ocrOutcomes: [Int: OCRPageOutcome] = [:]
    var documentSourceURL: URL?
    @Published private(set) var isShowingDemo = false
    @Published var error: String?
    @Published var notice: String?
    @Published var selectedColor: HighlightColor = .mint
    @Published var drafts: [UUID: String] = [:]
    @Published var sending: Set<UUID> = []
    @Published var partials: [UUID: String] = [:]
    @Published var threadErrors: [UUID: String] = [:]
    @Published private(set) var backgroundImage: NSImage?
    let dataDirectory: URL
    private var openToken = UUID()
    private var scanToken = UUID()
    private var folderToken = UUID()
    private var canSave = true
    private var scopedFolder: URL?
    private let sampleURL: URL?
    private let sampleDownload: SampleDocument.Download
    private let sampleExpectedSHA256: String
    private let sampleDownloadApproval: (@MainActor () async -> Bool)?
    private var sampleTask: Task<URL?, Error>?
    private var sampleSeeds: Set<String>? = []
    private struct DemoReturnContext {
        var document: PDFDocument?
        var documentID: String?
        var page: Int
        var selectedAnnotationID: UUID?
        var sourceURL: URL?
    }
    private var demoReturnContext: DemoReturnContext?

    init(dataDirectory: URL, sampleURL: URL? = nil,
         sampleDownload: @escaping SampleDocument.Download = { try await SampleDocument.download($0) },
         sampleExpectedSHA256: String = SampleDocument.sourceSHA256,
         sampleDownloadApproval: (@MainActor () async -> Bool)? = nil) {
        self.dataDirectory = dataDirectory
        let bundledSample = Bundle.main.resourceURL?.appendingPathComponent("Samples").appendingPathComponent(SampleDocument.filename)
        self.sampleURL = sampleURL ?? bundledSample.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        self.sampleDownload = sampleDownload
        self.sampleExpectedSHA256 = sampleExpectedSHA256
        self.sampleDownloadApproval = sampleDownloadApproval
        do {
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            let url = dataDirectory.appendingPathComponent("library.json")
            if FileManager.default.fileExists(atPath: url.path) {
                library = try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: url))
            }
        } catch {
            self.error = localized("本地记录无法读取，已暂停写入以保护已有内容。\n", "Local data could not be read. Saving is paused to protect existing records.\n") + error.localizedDescription
            canSave = false
        }
        if let path = library.folderPath, SampleDocument.isLegacySampleFolder(URL(fileURLWithPath: path)) {
            // Older versions treated the app's Samples directory as the library.
            // Keep its annotations, but do not persist that implementation detail
            // as a user-selected folder after moving to an independent sample.
            library.folderPath = nil; library.folderBookmark = nil; library.selectedPath = nil
        }
        let seedsURL = dataDirectory.appendingPathComponent("sample-seeds.json")
        if FileManager.default.fileExists(atPath: seedsURL.path) {
            // A damaged seed ledger must never recreate a highlight the reader deleted.
            sampleSeeds = (try? Data(contentsOf: seedsURL)).flatMap { try? JSONDecoder().decode(Set<String>.self, from: $0) }
        }
        loadBackgroundImage()
    }
    var record: DocumentRecord? { documentID.flatMap { library.documents[$0] } }
    var annotations: [ReaderAnnotation] { (record?.annotations ?? []).filter { $0.deletedAt == nil } }
    var trashedAnnotations: [TrashedAnnotation] {
        library.documents.values.flatMap { record in
            record.annotations.filter { $0.deletedAt != nil }.map {
                TrashedAnnotation(documentID: record.id, documentTitle: record.title, documentPath: record.path, annotation: $0)
            }
        }.sorted { ($0.annotation.deletedAt ?? .distantPast) > ($1.annotation.deletedAt ?? .distantPast) }
    }
    var selectedAnnotation: ReaderAnnotation? { annotations.first { $0.id == selectedAnnotationID } }
    var pageCount: Int { document?.pageCount ?? 0 }
    var folderName: String { library.folderPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? localized("选择你的阅读文件夹", "Choose your reading folder") }
    func localized(_ chinese: String, _ english: String) -> String { ReaderUIStrings.text(chinese, english: english, language: library.settings.language) }

    func updateSettings(_ change: (inout ReaderSettings) -> Void) {
        guard canSave else { return }
        change(&library.settings); library.settings.normalize(); save()
    }
    var selectedHighlightColor: Color { Color(hex: library.settings.highlightColorHex ?? selectedColor.hex) }
    func chooseHighlightPreset(_ color: HighlightColor) {
        selectedColor = color
        updateSettings { $0.highlightColorHex = nil }
    }
    func chooseCustomHighlightColor(_ hex: String) {
        guard let value = normalizedHex(hex) else { return }
        updateSettings { $0.highlightColorHex = value }
    }
    func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.title = localized("选择背景图片", "Choose a background image")
        panel.message = localized("支持 PNG、JPEG、HEIC 和 TIFF，最大 40 MB。图片将复制到阅读器的本地资料目录。", "PNG, JPEG, HEIC or TIFF, up to 40 MB. A copy will be saved with your local reader data.")
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.importBackgroundImage(from: url) }
        }
    }
    @discardableResult func importBackgroundImage(from url: URL) -> Bool {
        guard canSave else { return false }
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do {
            let (bytes, image, fileExtension) = try Self.readBackgroundImage(url)
            let directory = dataDirectory.appendingPathComponent("Backgrounds", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let filename = UUID().uuidString + "." + fileExtension
            try bytes.write(to: directory.appendingPathComponent(filename), options: .atomic)
            library.settings.backgroundImage = filename; backgroundImage = image; save()
            notice = localized("背景图片已导入", "Background image imported")
            return true
        } catch { self.error = localized("背景图片无法导入：", "Could not import background image: ") + error.localizedDescription; return false }
    }
    func removeBackgroundImage() {
        guard canSave else { return }
        library.settings.backgroundImage = nil; backgroundImage = nil; save()
    }
    private func loadBackgroundImage() {
        guard let filename = library.settings.backgroundImage else { return }
        let url = dataDirectory.appendingPathComponent("Backgrounds", isDirectory: true).appendingPathComponent(filename)
        do { backgroundImage = try Self.readBackgroundImage(url).1 }
        catch { notice = localized("背景图片暂时无法读取，可在设置中重新导入。", "The background image could not be loaded. Import it again in Settings.") }
    }
    private static func readBackgroundImage(_ url: URL) throws -> (Data, NSImage, String) {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 40 * 1_024 * 1_024 else {
            throw NSError(domain: "LeafImage", code: 1, userInfo: [NSLocalizedDescriptionKey: "Image must be a regular file smaller than 40 MB."])
        }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= 40 * 1_024 * 1_024,
              let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let identifier = CGImageSourceGetType(source), let type = UTType(identifier as String),
              [UTType.png, .jpeg, .heic, .tiff].contains(where: { type.conforms(to: $0) }),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = props[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue * height.doubleValue <= 40_000_000 else {
            throw NSError(domain: "LeafImage", code: 2, userInfo: [NSLocalizedDescriptionKey: "Use a PNG, JPEG, HEIC or TIFF image with no more than 40 million pixels."])
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: 4_096]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw NSError(domain: "LeafImage", code: 3, userInfo: [NSLocalizedDescriptionKey: "The image could not be decoded."])
        }
        return (bytes, NSImage(cgImage: cgImage, size: .zero), type.preferredFilenameExtension ?? "png")
    }

    @discardableResult func save() -> Bool {
        guard canSave else { return false }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(library)
            try data.write(to: dataDirectory.appendingPathComponent("library.json"), options: .atomic)
            return true
        } catch { self.error = localized("保存失败：", "Could not save: ") + error.localizedDescription; return false }
    }
    func restore() async {
        let restoration = UUID(); folderToken = restoration
        if let bookmark = library.folderBookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale) {
                library.folderPath = url.path
                if url.startAccessingSecurityScopedResource() { scopedFolder = url }
                if stale { library.folderBookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) }
            }
        }
        if library.folderPath == nil { await openDemo(allowDownload: false); return }
        await refreshFolder()
        guard folderToken == restoration, !isShowingDemo else { return }
        if let path = library.selectedPath, FileManager.default.fileExists(atPath: path) { await open(URL(fileURLWithPath: path)) }
    }
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = localized("选择 PDF 文件夹", "Choose a PDF folder"); panel.message = localized("列出文件夹及其子文件夹中的 PDF。原文件不会被改写。", "Show PDFs in this folder and its subfolders. Original files are never modified.")
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = localized("打开文件夹", "Open Folder")
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            Task { @MainActor in await self?.setFolder(url) }
        }
    }
    func setFolder(_ url: URL) async {
        cancelSampleDownload()
        resetOCR()
        let folderChange = UUID(); folderToken = folderChange
        isShowingDemo = false; demoReturnContext = nil
        openToken = UUID(); scanToken = UUID(); isOpening = false; files = []
        scopedFolder?.stopAccessingSecurityScopedResource(); scopedFolder = nil
        if url.startAccessingSecurityScopedResource() { scopedFolder = url }
        library.folderPath = url.path
        library.folderBookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        library.selectedPath = nil
        document = nil; documentID = nil; documentSourceURL = nil; selection = nil; selectedAnnotationID = nil
        save(); await refreshFolder()
        guard folderToken == folderChange else { return }
        if let first = files.first { await open(first.url) }
    }
    /// Startup only uses an existing local sample. A public build downloads the
    /// paper from its source only after the reader explicitly opens the sample.
    func openDemo(allowDownload: Bool = true) async {
        guard !isShowingDemo else { return }
        let cacheURL = SampleDocument.cachedURL(in: dataDirectory)
        guard allowDownload || sampleURL != nil || FileManager.default.fileExists(atPath: cacheURL.path) else { return }
        demoReturnContext = DemoReturnContext(document: document, documentID: documentID, page: currentPage, selectedAnnotationID: selectedAnnotationID, sourceURL: documentSourceURL)
        resetOCR()
        folderToken = UUID()
        isShowingDemo = true
        let token = UUID(); openToken = token; isOpening = true
        let expected = sampleExpectedSHA256
        let download = sampleDownload
        let task = Task<URL?, Error> { @MainActor [weak self] in
            guard let self else { return nil }
            if let sampleURL = self.sampleURL { return sampleURL }
            let cached = await Task.detached { SampleDocument.verifiedCache(cacheURL, expectedSHA256: expected) }.value
            try Task.checkCancellation()
            if let cached { return cached }
            guard allowDownload, await self.confirmSampleDownload() else { return nil }
            try Task.checkCancellation()
            return try await SampleDocument.fetch(to: cacheURL, expectedSHA256: expected, using: download)
        }
        sampleTask = task
        do {
            let url = try await task.value
            guard token == openToken else { return }
            sampleTask = nil
            guard let url else { isOpening = false; restoreDemoContext(); return }
            let opened = await loadDocument(url, token: token, asDemo: true)
            if !opened, token == openToken { restoreDemoContext() }
        } catch {
            guard token == openToken else { return }
            sampleTask = nil; isOpening = false; restoreDemoContext()
            if !(error is CancellationError) {
                if let failure = error as? SampleDocument.DownloadError, case .sourceChanged = failure {
                    self.error = t("示例来源的文件已变化，无法验证内容，请稍后重试。")
                } else {
                    self.error = t("示例下载失败，请检查网络连接后重试。")
                }
            }
        }
    }
    private func confirmSampleDownload() async -> Bool {
        if let sampleDownloadApproval { return await sampleDownloadApproval() }
        let alert = NSAlert()
        alert.messageText = t("下载入门示例？")
        alert.informativeText = t("将从 Stanford 下载 Robert Lucas 的《On the Mechanics of Economic Development》。文件会保存在本机，之后可离线阅读。此下载不使用 ChatGPT。") + "\n\n" + SampleDocument.sourceURL.absoluteString
        alert.addButton(withTitle: t("下载"))
        alert.addButton(withTitle: t("取消"))
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
            }
        }
        return alert.runModal() == .alertFirstButtonReturn
    }
    private func cancelSampleDownload() {
        sampleTask?.cancel(); sampleTask = nil
    }
    func closeDemo() async {
        guard isShowingDemo else { return }
        cancelSampleDownload()
        resetOCR()
        openToken = UUID(); isOpening = false
        restoreDemoContext()
        // A demo may have interrupted the asynchronous first open of a folder.
        // The saved normal selection still takes precedence over the sample.
        if document == nil {
            if let path = library.selectedPath { await open(URL(fileURLWithPath: path)) }
            else if let first = files.first { await open(first.url) }
        }
    }
    private func restoreDemoContext() {
        guard isShowingDemo else { return }
        let context = demoReturnContext
        isShowingDemo = false; demoReturnContext = nil
        document = context?.document; documentID = context?.documentID
        documentSourceURL = context?.sourceURL
        currentPage = context?.page ?? 0; selectedAnnotationID = context?.selectedAnnotationID
        selection = nil; navigationRect = nil; navigationToken += 1
        scheduleCurrentPageOCR()
    }
    func refreshFolder() async {
        guard let path = library.folderPath else { return }
        let token = UUID(); scanToken = token; isScanning = true
        let unavailableFolder = localized("无法访问该文件夹，请重新选择。", "This folder cannot be accessed. Please choose it again.")
        let result: Result<[LibraryFile], Error> = await Task.detached(priority: .userInitiated) {
            do {
                let root = URL(fileURLWithPath: path)
                let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
                var encountered: Error?
                guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, e in encountered = e; return true }) else {
                    throw NSError(domain: "Leaf", code: 1, userInfo: [NSLocalizedDescriptionKey:unavailableFolder])
                }
                var items: [LibraryFile] = []
                while let url = enumerator.nextObject() as? URL {
                    guard url.pathExtension.lowercased() == "pdf" else { continue }
                    let values = try? url.resourceValues(forKeys: Set(keys))
                    guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
                    items.append(LibraryFile(url: url, relativePath: String(url.path.dropFirst(path.count + 1))))
                }
                if items.isEmpty, let encountered { throw encountered }
                return .success(items.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending })
            } catch { return .failure(error) }
        }.value
        guard scanToken == token else { return }
        isScanning = false
        switch result {
        case .success(let items): files = items
        case .failure(let failure): error = localized("文件夹读取失败：", "Could not read the folder: ") + failure.localizedDescription
        }
    }
    func open(_ url: URL) async {
        cancelSampleDownload()
        restoreDemoContext()
        resetOCR()
        folderToken = UUID()
        let token = UUID(); openToken = token; isOpening = true
        await loadDocument(url, token: token, asDemo: false)
    }
    @discardableResult private func loadDocument(_ url: URL, token: UUID, asDemo: Bool) async -> Bool {
        let identity: String?
        do {
            identity = try await Task.detached(priority: .userInitiated) {
                let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                var hash = SHA256()
                while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
                return hash.finalize().map { String(format:"%02x", $0) }.joined()
            }.value
        } catch { if token == openToken { isOpening = false; self.error = localized("无法打开 PDF：", "Could not open PDF: ") + error.localizedDescription; scheduleCurrentPageOCR() }; return false }
        guard token == openToken, let identity else { return false }
        guard let pdf = PDFDocument(url: url) else { isOpening = false; error = localized("这个文件无法作为 PDF 打开。", "This file could not be opened as a PDF."); scheduleCurrentPageOCR(); return false }
        guard !pdf.isLocked else { isOpening = false; error = localized("此 PDF 有密码保护。请先用预览解锁后再打开。", "This PDF is password protected. Unlock it in Preview before opening it here."); scheduleCurrentPageOCR(); return false }
        guard pdf.pageCount > 0 else { isOpening = false; error = localized("PDF 中没有可显示的页面。", "This PDF has no displayable pages."); scheduleCurrentPageOCR(); return false }
        var record = library.documents[identity] ?? DocumentRecord(id: identity, path: url.path, title: url.deletingPathExtension().lastPathComponent)
        if !asDemo { record.path = url.path; record.title = url.deletingPathExtension().lastPathComponent }
        record.page = min(max(record.page, 0), pdf.pageCount - 1)
        let seededHighlight = asDemo ? seedSampleHighlight(in: pdf, record: &record) : nil
        if let seededHighlight, demoReturnContext?.documentID != identity { record.page = seededHighlight.page }
        library.documents[identity] = record
        if !asDemo { library.selectedPath = url.path }
        selection = nil; selectedAnnotationID = nil; currentPage = record.page
        documentID = identity; document = pdf; documentSourceURL = url; navigationRect = nil; navigationToken += 1
        if let seededHighlight {
            currentPage = seededHighlight.page
            navigationRect = seededHighlight.rects.first
        }
        isOpening = false
        if save(), asDemo { saveSampleSeeds() }
        scheduleCurrentPageOCR()
        return true
    }
    private func seedSampleHighlight(in pdf: PDFDocument, record: inout DocumentRecord) -> ReaderAnnotation? {
        guard canSave, let seeds = sampleSeeds else { return nil }
        let key = SampleDocument.seedKey + ":" + record.id
        guard !seeds.contains(key) else { return nil }
        // A fixed identifier also prevents duplicates if a prior run saved the
        // annotation but closed before saving the separate seed ledger.
        if record.annotations.contains(where: { $0.id == SampleDocument.annotationID }) {
            sampleSeeds?.insert(key)
            return nil
        }
        guard let snapshot = SampleDocument.highlight(in: pdf) else { return nil }
        let highlight = ReaderAnnotation(id: SampleDocument.annotationID, kind: .highlight, quote: snapshot.text, rects: snapshot.rects, color: .yellow, pageText: snapshot.pageText, sourceFilename: record.title)
        record.annotations.append(highlight)
        sampleSeeds?.insert(key)
        return highlight
    }
    private func saveSampleSeeds() {
        guard canSave, let sampleSeeds else { return }
        do {
            let data = try JSONEncoder().encode(sampleSeeds.sorted())
            try data.write(to: dataDirectory.appendingPathComponent("sample-seeds.json"), options: .atomic)
        } catch { self.error = localized("保存失败：", "Could not save: ") + error.localizedDescription }
    }
    func pageChanged(_ page: Int) {
        guard currentPage != page, let id = documentID, var record = library.documents[id] else { return }
        if isShowingDemo, demoReturnContext?.documentID == id { currentPage = page; scheduleCurrentPageOCR(); return }
        currentPage = page; record.page = page; library.documents[id] = record; save()
        scheduleCurrentPageOCR()
    }
    func navigate(page: Int) {
        guard let pdf = document, page >= 0, page < pdf.pageCount, let p = pdf.page(at: page) else { return }
        navigationRect = PageRect(page: page, rect: p.bounds(for: .cropBox)); navigationToken += 1
    }
    func receiveSelection(_ value: SelectionSnapshot?) {
        if let value, !value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !value.rects.isEmpty { selection = value }
        else { selection = nil }
    }
    func mutateAnnotation(_ id: UUID, documentID requestedDocumentID: String? = nil, _ change: (inout ReaderAnnotation) -> Void) {
        guard let did = requestedDocumentID ?? documentID, var record = library.documents[did], let i = record.annotations.firstIndex(where: { $0.id == id }) else { return }
        change(&record.annotations[i]); library.documents[did] = record; save()
    }
    @discardableResult func createAnnotation(_ kind: AnnotationKind) -> UUID? {
        guard let snapshot = selection, let did = documentID, var record = library.documents[did], canSave else { return nil }
        let annotation = ReaderAnnotation(kind: kind, quote: snapshot.text, rects: snapshot.rects, color: selectedColor, pageText: String(snapshot.pageText.prefix(12000)), sourceFilename: record.title, customColorHex: library.settings.highlightColorHex)
        record.annotations.append(annotation); library.documents[did] = record
        selectedAnnotationID = annotation.id; selection = nil; save()
        notice = kind == .highlight ? localized("高亮已保存", "Highlight saved") : kind == .comment ? localized("在右侧写下你的评论", "Write your comment on the right") : localized("在右侧提出你的问题", "Ask your question on the right")
        return annotation.id
    }
    func focusAnnotation(_ id: UUID) {
        guard let annotation = annotations.first(where: { $0.id == id }) else { return }
        selectedAnnotationID = id; selection = nil
        navigationRect = annotation.rects.first; navigationToken += 1
    }
    @discardableResult func deleteAnnotation(_ id: UUID, documentID requestedDocumentID: String? = nil) -> Bool {
        guard canSave, let did = requestedDocumentID ?? documentID, var record = library.documents[did],
              let index = record.annotations.firstIndex(where: { $0.id == id && $0.deletedAt == nil }) else { return false }
        guard !sending.contains(id) else { notice = localized("请先停止生成，再删除这条讨论。", "Stop the reply before deleting this discussion."); return false }
        record.annotations[index].deletedAt = Date(); library.documents[did] = record
        if selectedAnnotationID == id { selectedAnnotationID = nil }
        save(); notice = localized("已移到回收站，可在设置中恢复。", "Moved to Trash. Restore it in Settings.")
        return true
    }
    func removeAnnotation(_ id: UUID) { deleteAnnotation(id) }
    @discardableResult func restoreAnnotation(_ id: UUID, documentID: String) -> Bool {
        guard canSave, var record = library.documents[documentID],
              let index = record.annotations.firstIndex(where: { $0.id == id && $0.deletedAt != nil }) else { return false }
        record.annotations[index].deletedAt = nil; library.documents[documentID] = record
        save(); notice = localized("已恢复，标注和完整对话均已保留。", "Restored with its annotation and full conversation.")
        return true
    }
    func sendQuestion(service: ChatService) async {
        guard let annotation = selectedAnnotation, annotation.kind == .question, let did = documentID,
              let record, !sending.contains(annotation.id), let draft = drafts[annotation.id]?.trimmingCharacters(in: .whitespacesAndNewlines), !draft.isEmpty else { return }
        let id = annotation.id
        guard service.authenticated && service.planEnabled else { error = localized("请先连接 ChatGPT 账号，再发送问题。", "Connect your ChatGPT account before sending a question."); return }
        guard !library.selectedModel.isEmpty else { error = localized("请先选择模型。", "Choose a model first."); return }
        let model = library.selectedModel, effort = library.selectedEffort
        sending.insert(id); threadErrors[id] = nil; partials[id] = ""
        drafts[id] = ""
        mutateAnnotation(id, documentID: did) { $0.messages.append(ChatMessage(role:"user", text:draft, model:model, effort:effort)) }
        do {
            let messages = try await service.send(threadID:id, documentID:did,
                context:["filename":annotation.sourceFilename ?? record.title, "quote":annotation.quote, "page":annotation.page + 1, "pageText":annotation.pageText],
                model:model, effort:effort, text:draft, onDelta:{ [weak self] text in self?.partials[id] = text })
            mutateAnnotation(id, documentID: did) { $0.messages = messages }
        } catch {
            threadErrors[id] = error.localizedDescription
            if let messages = try? await service.fetchThread(threadID:id), !messages.isEmpty {
                mutateAnnotation(id, documentID: did) { $0.messages = messages }
            } else {
                mutateAnnotation(id, documentID: did) { if !$0.messages.isEmpty { $0.messages[$0.messages.count-1].failed = true } }
            }
            drafts[id] = draft
        }
        sending.remove(id); partials[id] = nil
    }
    func reconcileThreads(service: ChatService) async {
        // Backend commits successful turns before publishing completion. Reconcile
        // on launch so closing a window during a reply never silently loses it.
        for (did, record) in library.documents {
            for annotation in record.annotations where annotation.kind == .question && annotation.deletedAt == nil {
                if let messages = try? await service.fetchThread(threadID:annotation.id), !messages.isEmpty {
                    mutateAnnotation(annotation.id, documentID: did) { $0.messages = messages }
                }
            }
        }
    }
    func updateModelPreferences(_ models: [CatalogModel]) {
        guard !models.isEmpty else { return }
        if !models.contains(where: { $0.id == library.selectedModel }) { library.selectedModel = models[0].id }
        if let model = models.first(where: { $0.id == library.selectedModel }), !model.efforts.contains(library.selectedEffort) {
            library.selectedEffort = model.defaultEffort.flatMap { model.efforts.contains($0) ? $0 : nil } ?? model.efforts.first ?? "auto"
        }
        save()
    }
}
