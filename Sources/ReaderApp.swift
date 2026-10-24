import SwiftUI
import PDFKit
import AppKit

private let ink = Color(hex:"283C36")
private let muted = Color(hex:"7B8983")
private let accent = Color(hex:"518C76")
private let paper = Color(hex:"FBFCFA")

final class AppDelegate: NSObject, NSApplicationDelegate {
    var stop: (() -> Void)?
    var shutdown: (() async -> Bool)?
    private var waitingForShutdown = false
    private var allowTermination = false
    private var applicationIcon: NSImage?
    func applicationWillFinishLaunching(_ notification: Notification) {
        refreshApplicationIcon()
        for name in [NSWindow.willMiniaturizeNotification, NSWindow.didMiniaturizeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowMiniaturized(_:)), name: name, object: nil)
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        refreshApplicationIcon()
    }
    @objc private func windowMiniaturized(_ notification: Notification) {
        refreshApplicationIcon(window: notification.object as? NSWindow)
    }
    private func refreshApplicationIcon(window: NSWindow? = nil) {
        if applicationIcon == nil, let url = Bundle.main.url(forResource: Branding.iconResource, withExtension: "icns") {
            applicationIcon = NSImage(contentsOf: url)
        }
        guard let applicationIcon else { return }
        NSApplication.shared.applicationIconImage = applicationIcon
        NSApplication.shared.dockTile.display()
        if let window {
            // Refresh the application badge while preserving the live window preview.
            window.dockTile.showsApplicationBadge = true
            window.dockTile.display()
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if allowTermination { return .terminateNow }
        guard let shutdown else { return .terminateNow }
        guard !waitingForShutdown else { return .terminateCancel }
        waitingForShutdown = true
        Task { @MainActor in
            let ready = await shutdown()
            waitingForShutdown = false
            if ready {
                allowTermination = true
                sender.terminate(nil)
            }
        }
        // Keep the normal run loop active while Foundation delivers child exit
        // and Swift concurrency resumes the Keychain drain task.
        return .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) { stop?() }
}

@main
struct LeafReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store: ReaderStore
    @StateObject private var service: ChatService
    init() {
        let data = ProcessInfo.processInfo.environment["LEAF_DATA_DIR"].map { URL(fileURLWithPath:$0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LeafReader", isDirectory:true)
        _store = StateObject(wrappedValue:ReaderStore(dataDirectory:data))
        _service = StateObject(wrappedValue:ChatService(dataDirectory:data))
    }
    private func T(_ text: String) -> String { store.t(text) }
    var body: some Scene {
        WindowGroup(Branding.displayName) {
            ReaderWindow(store:store, service:service)
                .frame(minWidth:1000, minHeight:700)
                .task {
                    delegate.stop = { store.cancelOCR(); store.save(); service.stop() }
                    delegate.shutdown = {
                        store.cancelOCR()
                        store.save()
                        let ready = await service.shutdown()
                        if !ready {
                            let alert = NSAlert()
                            alert.messageText = store.t("暂时无法退出")
                            alert.informativeText = service.error ?? store.t("登录尚未安全保存，已取消退出。请解锁钥匙串后重试。")
                            alert.addButton(withTitle: store.t("好"))
                            alert.runModal()
                        }
                        return ready
                    }
                    async let startup: Void = service.start()
                    await store.restore()
                    await startup
                    await store.reconcileThreads(service:service)
                }
        }
        .defaultSize(width:1380, height:900)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .appSettings) { Button(T("设置…")) { NotificationCenter.default.post(name: .marginOpenSettings, object: nil) }.keyboardShortcut(",", modifiers: .command) }
            CommandGroup(replacing:.newItem) {
                Button(T("选择 PDF 文件夹…")) { store.chooseFolder() }.keyboardShortcut("o", modifiers:[.command,.shift])
            }
            CommandGroup(after:.textEditing) {
                Divider()
                Button(T("搜索 PDF")) { NotificationCenter.default.post(name:.marginFind,object:nil) }.keyboardShortcut("f",modifiers:.command).disabled(store.document == nil)
                Button(T("下一处")) { NotificationCenter.default.post(name:.marginFindNext,object:nil) }.keyboardShortcut("g",modifiers:.command).disabled(store.document == nil)
                Button(T("上一处")) { NotificationCenter.default.post(name:.marginFindPrevious,object:nil) }.keyboardShortcut("g",modifiers:[.command,.shift]).disabled(store.document == nil)
            }
            CommandMenu(T("阅读")) {
                Button(T("高亮选中文字")) { store.createAnnotation(.highlight) }.keyboardShortcut("h",modifiers:[.command,.shift]).disabled(store.selection == nil)
                Button(T("评论选中文字")) { store.createAnnotation(.comment) }.keyboardShortcut("m",modifiers:[.command,.shift]).disabled(store.selection == nil)
                Button(T("向 AI 提问")) { store.createAnnotation(.question) }.keyboardShortcut("k",modifiers:[.command]).disabled(store.selection == nil)
            }
        }
    }
}

@MainActor
final class ReaderPresentation: ObservableObject {
    @Published var search = ""
    @Published var showPDFSearch = false
    @Published var pdfSearchFocus = 0
    @Published var expandedFolders: Set<String> = []
    @Published var collapsedSearchFolders: Set<String> = []
    @Published var showSettings = false
    @Published var settingsSection: SettingsSection = .general
    @Published var lastDeleted: (id: UUID, documentID: String)?
    @Published var expandedMessages: Set<UUID> = []
    @Published var zoomScale: CGFloat = 1
    @Published var selectionAnchor: SelectionActionAnchor?
    private var deletionNoticeTask: Task<Void, Never>?

    func showDeleted(_ id: UUID, documentID: String) {
        deletionNoticeTask?.cancel()
        lastDeleted = (id, documentID)
        deletionNoticeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            self?.lastDeleted = nil
        }
    }

    func dismissDeletionNotice() {
        deletionNoticeTask?.cancel()
        lastDeleted = nil
    }
}

struct ReaderWindow: View {
    @ObservedObject var store: ReaderStore
    @ObservedObject var service: ChatService
    @StateObject private var presentation = ReaderPresentation()
    @StateObject private var pdfSearch = PDFSearchState()
    var body: some View {
        ZStack {
            Color(hex:store.library.settings.themeHex)
            if let image = store.backgroundImage {
                GeometryReader { geometry in
                    Image(nsImage:image).resizable().aspectRatio(contentMode:.fill)
                        .frame(width:geometry.size.width,height:geometry.size.height).clipped()
                }.allowsHitTesting(false)
            }
            ReaderSplitView(initialProportions: store.library.settings.paneProportions,
                            onProportionsChange: { proportions in
                                store.updateSettings { $0.paneProportions = proportions }
                            }) {
                libraryPane.frame(maxWidth:.infinity,maxHeight:.infinity)
            } center: {
                readingPane.frame(maxWidth:.infinity,maxHeight:.infinity)
            } right: {
                discussionPane.frame(maxWidth:.infinity,maxHeight:.infinity)
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
        }
        .tint(accent).foregroundStyle(ink)
        .environment(\.locale,Locale(identifier:store.library.settings.language.localeIdentifier))
        .toolbar {
            ToolbarItem(placement: .principal) {
                BrandTitle()
            }
        }
        .sheet(isPresented:$presentation.showSettings) { SettingsPanel(store:store,section:$presentation.settingsSection) {presentation.showSettings=false} }
        .onReceive(NotificationCenter.default.publisher(for:.marginOpenSettings)) { _ in presentation.settingsSection = .general; presentation.showSettings=true }
        .onReceive(NotificationCenter.default.publisher(for:.marginFind)) { _ in
            guard store.document != nil else { return }
            presentation.showPDFSearch = true; presentation.pdfSearchFocus += 1
        }
        .onReceive(NotificationCenter.default.publisher(for:.marginFindNext)) { _ in pdfSearch.next() }
        .onReceive(NotificationCenter.default.publisher(for:.marginFindPrevious)) { _ in pdfSearch.previous() }
        .onChange(of:store.documentID) { _,_ in pdfSearch.clear(); presentation.selectionAnchor = nil }
        .alert(T("需要留意"), isPresented:Binding(get:{ store.error != nil },set:{if !$0 {store.error=nil}})) { Button(T("好")) {store.error=nil} } message: { Text(store.error ?? "") }
        .onChange(of:store.library.folderPath) { _, _ in
            presentation.expandedFolders = []
            presentation.collapsedSearchFolders = []
            presentation.search = ""
            revealSelectedFile()
        }
        .onChange(of:store.files) { _, _ in revealSelectedFile() }
        .onChange(of:store.library.selectedPath) { _, _ in revealSelectedFile() }
        .onChange(of:presentation.search) { _, _ in presentation.collapsedSearchFolders = [] }
        .onChange(of:store.selection) { _, value in if value == nil { presentation.selectionAnchor = nil } }
        .onChange(of:store.documentID) { _, _ in presentation.selectionAnchor = nil; presentation.dismissDeletionNotice() }
        .onChange(of:service.models.map(\.id)) { _, _ in store.updateModelPreferences(service.models) }
        .onChange(of:service.authenticated) { _, value in if value { Task { await service.refreshModels(); store.updateModelPreferences(service.models) } } }
    }
    private var libraryPane: some View {
        VStack(alignment:.leading,spacing:0) {
            Button(action:store.chooseFolder) { Label(T("选择本地文件夹"),systemImage:"folder.badge.plus").frame(maxWidth:.infinity).padding(.vertical,8).contentShape(Rectangle()) }.buttonStyle(.bordered).padding(.horizontal,16).padding(.top,18)
            HStack { Text(store.folderName).lineLimit(1); Spacer(); Button { Task { await store.refreshFolder() } } label:{controlIcon("arrow.clockwise")} .buttonStyle(.plain).disabled(store.isScanning).help(T("刷新文件列表")) }.font(.system(size:fontSize(11))).foregroundStyle(muted).padding(.horizontal,20).padding(.top,22).padding(.bottom,10)
            HStack(spacing:6) { Image(systemName:"magnifyingglass"); TextField(T("查找 PDF"),text:$presentation.search).textFieldStyle(.plain) }.font(.system(size:fontSize(12))).padding(9).background(.white.opacity(0.75),in:RoundedRectangle(cornerRadius:8)).padding(.horizontal,16).padding(.bottom,12)
            ScrollView {
                LazyVStack(spacing:5) {
                    ForEach(outlineRows) { row in
                        libraryRow(row)
                    }
                    if !store.files.isEmpty && outlineRows.isEmpty {
                        Text(T("没有匹配的 PDF")).font(.system(size:fontSize(12))).foregroundStyle(muted).padding(.top,24)
                    }
                    if store.files.isEmpty { Text(store.isScanning ? T("正在读取文件夹…") : T("这里还没有 PDF\n选择一个文件夹，开始阅读。")).font(.system(size:fontSize(12))).foregroundStyle(muted).multilineTextAlignment(.center).padding(.top,30) }
                }.padding(.horizontal,10)
            }
            VStack(alignment:.leading,spacing:9) {
                Divider().opacity(0.5)
                HStack { Image(systemName:"internaldrive"); Text(store.localized("\(store.files.count) 份 PDF · 本地保存","\(store.files.count) PDFs · Saved locally")) }.font(.system(size:fontSize(10))).foregroundStyle(muted)
                HStack(spacing:12) {
                    Button { presentation.settingsSection = .general; presentation.showSettings=true } label: {
                        Image(systemName:"gearshape").font(.system(size:16))
                            .frame(width:32,height:32).contentShape(Rectangle())
                    }.buttonStyle(.plain).help(T("设置")).accessibilityLabel(T("设置"))
                    Spacer(minLength:0)
                    Button { Task { if store.isShowingDemo { await store.closeDemo() } else { await store.openDemo() } } } label: {
                        Label(T(store.isShowingDemo ? "退出示例" : "打开入门示例"),systemImage:store.isShowingDemo ? "arrow.uturn.backward" : "book.closed")
                            .padding(.vertical,6).contentShape(Rectangle())
                    }.font(.system(size:fontSize(11))).buttonStyle(.plain).foregroundStyle(accent)
                }
            }.padding(18)
        }.background(Color(hex:store.library.settings.themeHex).opacity(store.library.settings.sidesOpacity))
    }
    private var outlineRows: [LibraryOutlineRow] {
        LibraryOutlineRow.visible(nodes:LibraryOutlineNode.make(files:store.files,search:presentation.search),
                                  expandedFolders:presentation.expandedFolders,
                                  searchActive:!presentation.search.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
                                  collapsedSearchFolders:presentation.collapsedSearchFolders)
    }
    private func revealSelectedFile() {
        guard let file = store.files.first(where: { $0.url.path == store.library.selectedPath }) else { return }
        presentation.expandedFolders.formUnion(LibraryOutlineNode.ancestors(of:file))
    }
    private func toggleFolder(_ row: LibraryOutlineRow) {
        if presentation.search.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
            if row.expanded { presentation.expandedFolders.remove(row.id) }
            else { presentation.expandedFolders.insert(row.id) }
        } else {
            if row.expanded { presentation.collapsedSearchFolders.insert(row.id) }
            else { presentation.collapsedSearchFolders.remove(row.id) }
        }
    }
    @ViewBuilder private func libraryRow(_ row: LibraryOutlineRow) -> some View {
        if let file = row.node.file {
            let selected = !store.isShowingDemo && store.library.selectedPath == file.url.path
            Button { Task { await store.open(file.url) } } label: {
                HStack(alignment:.top,spacing:8) {
                    Image(systemName:"doc.richtext").font(.system(size:fontSize(16),weight:.light)).foregroundStyle(selected ? accent : muted).frame(width:18).padding(.top,1)
                    Text(file.title).font(.system(size:fontSize(12),weight:.medium)).lineLimit(2).multilineTextAlignment(.leading)
                    Spacer(minLength:0)
                }.padding(.vertical,10).padding(.horizontal,10).padding(.leading,CGFloat(row.depth) * 14)
                    .frame(maxWidth:.infinity,alignment:.leading)
                    .background(selected ? Color(hex:"E1EDE5") : .clear,in:RoundedRectangle(cornerRadius:9)).contentShape(Rectangle())
            }.buttonStyle(.plain).help(file.relativePath)
        } else {
            Button { toggleFolder(row) } label: {
                HStack(spacing:7) {
                    Image(systemName:row.expanded ? "chevron.down" : "chevron.right").font(.system(size:9,weight:.semibold)).frame(width:10)
                    Image(systemName:row.expanded ? "folder.fill" : "folder").font(.system(size:fontSize(15))).foregroundStyle(accent)
                    Text(row.node.name).font(.system(size:fontSize(12),weight:.medium)).lineLimit(1)
                    Spacer(minLength:0)
                }.padding(.vertical,10).padding(.horizontal,10).padding(.leading,CGFloat(row.depth) * 14)
                    .frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help(T(row.expanded ? "折叠文件夹" : "展开文件夹") + " · " + row.node.name)
        }
    }
    private var readingPane: some View {
        VStack(spacing:0) {
            HStack(spacing:10) {
                if store.isShowingDemo {
                    Button { Task { await store.closeDemo() } } label: {
                        Image(systemName:"arrow.left").frame(width:26,height:26).contentShape(Rectangle())
                    }.buttonStyle(.plain).help(T("返回阅读")).accessibilityLabel(T("返回阅读"))
                }
                Text(store.record?.title ?? T("你的阅读空间")).font(.system(size:fontSize(14),weight:.semibold)).lineLimit(1)
                if store.isShowingDemo { Text(T("示例")).font(.system(size:fontSize(10))).foregroundStyle(accent).padding(.horizontal,7).padding(.vertical,3).background(accent.opacity(0.1),in:Capsule()) }
                Spacer(minLength:4)
                if store.isOpening { ProgressView().controlSize(.small) }
                Button { presentation.showPDFSearch = true; presentation.pdfSearchFocus += 1 } label:{ controlIcon("magnifyingglass") }.buttonStyle(.plain).help(T("搜索 PDF")).disabled(store.document == nil)
                ocrMenu
                Button { post(.leafPDFZoomOut) } label:{ controlIcon("minus.magnifyingglass") }.buttonStyle(.plain).help(T("缩小"))
                Text("\(Int((presentation.zoomScale * 100).rounded()))%")
                    .font(.system(size:fontSize(10),design:.monospaced)).foregroundStyle(muted).frame(minWidth:37)
                    .accessibilityLabel(T("缩放比例"))
                Button { post(.leafPDFZoomIn) } label:{ controlIcon("plus.magnifyingglass") }.buttonStyle(.plain).help(T("放大"))
                Button { post(.leafPDFFit) } label:{ controlIcon("arrow.up.left.and.arrow.down.right") }.buttonStyle(.plain).help(T("适合窗口"))
            }.padding(.horizontal,20).padding(.vertical,17)
            Divider().opacity(0.4)
            if presentation.showPDFSearch, store.document != nil {
                PDFSearchBar(search:pdfSearch,focusToken:presentation.pdfSearchFocus,localize:T) {
                    presentation.showPDFSearch = false; pdfSearch.clear()
                }
            }
            if let document = store.document, let id = store.documentID {
                PDFCanvas(document:document,documentID:id,annotations:store.annotations,selectedAnnotationID:store.selectedAnnotationID,initialPage:store.currentPage,navigationToken:store.navigationToken,navigationRect:store.navigationRect,documentRevision:store.documentRevision,canvasBackground:.clear,searchState:pdfSearch,onScale:{presentation.zoomScale=$0},onSelection:store.receiveSelection,onPage:store.pageChanged,onAnnotationClick:store.focusAnnotation,hasStoredSelection:store.selection != nil,onSelectionActions:{ snapshot, anchor in
                    if let snapshot { store.receiveSelection(snapshot) }
                    presentation.selectionAnchor = anchor
                })
                    .frame(maxWidth:.infinity,maxHeight:.infinity)
                    .overlay(alignment:.topLeading) {
                        GeometryReader { geometry in
                            if let anchor = presentation.selectionAnchor, store.selection != nil {
                                SelectionToolbarLayout(anchor:anchor,viewport:geometry.size) {
                                    SelectionActionSurface { selectionToolbar }
                                }
                            }
                        }
                    }
            } else {
                VStack(spacing:18) { Image(systemName:"book.pages").font(.system(size:fontSize(58),weight:.ultraLight)).foregroundStyle(accent); Text(T("让问题留在它出现的地方")).font(.system(size:fontSize(19),weight:.medium)); Text(T("选择左侧的 PDF，拖选文字后\n就可以高亮、评论，或开始一段 AI 讨论。")).font(.system(size:fontSize(13))).foregroundStyle(muted).multilineTextAlignment(.center); Button(T("选择文件夹"),action:store.chooseFolder).buttonStyle(.borderedProminent) }.frame(maxWidth:.infinity,maxHeight:.infinity).background(Color(hex:"E9EEEA"))
            }
            HStack(spacing:14) {
                if let deleted = presentation.lastDeleted {
                    Text(T("已移到回收站，可在设置中恢复。")).font(.system(size:fontSize(10))).foregroundStyle(muted).lineLimit(1)
                    Button(T("撤销")) { _ = store.restoreAnnotation(deleted.id,documentID:deleted.documentID); presentation.dismissDeletionNotice() }.buttonStyle(.plain).font(.system(size:fontSize(11))).foregroundStyle(accent)
                } else {
                    ocrFooter
                }
                Spacer()
                Button { store.navigate(page:store.currentPage-1) } label:{ controlIcon("chevron.left") }.disabled(store.currentPage<=0).buttonStyle(.plain)
                Text("\(store.pageCount == 0 ? 0 : store.currentPage+1) / \(store.pageCount)").font(.system(size:fontSize(11),design:.monospaced)).foregroundStyle(muted)
                Button { store.navigate(page:store.currentPage+1) } label:{ controlIcon("chevron.right") }.disabled(store.currentPage>=store.pageCount-1).buttonStyle(.plain)
            }.padding(.horizontal,18).padding(.vertical,12)
        }.background(.white.opacity(store.library.settings.centerOpacity))
    }
    private var ocrMenu: some View {
        Menu {
            Button(T("识别本页文字"),action:store.recognizeCurrentPage)
                .disabled(!store.currentPageNeedsOCR || store.isRecognizingOCR)
            Button(T("识别整份 PDF"),action:store.recognizeDocument)
                .disabled(store.isRecognizingOCR)
            if store.isRecognizingOCR {
                Divider()
                Button(T("取消文字识别"),action:store.cancelOCR)
            }
        } label: {
            controlIcon("text.viewfinder")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width:26)
        .disabled(store.document == nil || store.isOpening)
        .help(T("OCR 在本机完成，不消耗 ChatGPT 用量，也不会修改原始 PDF。"))
        .accessibilityLabel(T("本地文字识别"))
    }
    @ViewBuilder private var ocrFooter: some View {
        switch store.ocrStatus {
        case let .recognizing(page,completed,total):
            HStack(spacing:7) {
                ProgressView().controlSize(.mini)
                Text(T("本地 OCR") + " · " + T("第 \(page + 1) 页"))
                    .lineLimit(1).truncationMode(.middle)
                if total > 1 {
                    Text("\(completed) / \(total)")
                        .monospacedDigit().fixedSize()
                        .accessibilityLabel(T("已处理 \(completed) 页") + " · " + T("共 \(total) 页"))
                }
                Button(T("取消"),action:store.cancelOCR).buttonStyle(.plain)
                    .foregroundStyle(accent).fixedSize()
            }.font(.system(size:fontSize(10))).foregroundStyle(muted)
        case .noText:
            ocrRetryStatus("未识别到文字")
        case let .failed(message):
            ocrRetryStatus("文字识别失败").help(message)
        case .cancelled:
            ocrRetryStatus("文字识别已取消")
        case .idle, .ready:
            EmptyView()
        }
    }
    private func ocrRetryStatus(_ message: String) -> some View {
        HStack(spacing:9) {
            Text(T(message)).lineLimit(1)
            if store.currentPageNeedsOCR {
                Button(T("重试"),action:store.recognizeCurrentPage).buttonStyle(.plain)
                    .foregroundStyle(accent).fixedSize()
            }
        }.font(.system(size:fontSize(10))).foregroundStyle(muted)
    }
    private var selectionToolbar: some View {
        VStack(spacing:7) {
            ViewThatFits(in:.horizontal) {
                HStack(spacing:2) { selectionActions }
                VStack(alignment:.leading,spacing:2) { selectionActions }
            }
            Divider().opacity(0.5)
            HStack(spacing:6) {
                ForEach(HighlightColor.allCases) { color in
                    Button { store.chooseHighlightPreset(color) } label: {
                        Circle().fill(color.color).frame(width:16,height:16)
                            .overlay(Circle().stroke(store.library.settings.highlightColorHex == nil && store.selectedColor == color ? accent : .clear,lineWidth:1.5).padding(-3))
                            .frame(width:28,height:26).contentShape(Rectangle())
                    }.buttonStyle(.plain).help(T(color.label)).accessibilityLabel(T(color.label))
                }
                AnnotationColorControl(hex:Binding(get:{store.library.settings.highlightColorHex ?? store.selectedColor.hex},set:{store.chooseCustomHighlightColor($0)}),title:T("自定义标注颜色"),localize:T)
            }
        }.padding(9)
            .background(.regularMaterial,in:RoundedRectangle(cornerRadius:12))
            .overlay(RoundedRectangle(cornerRadius:12).stroke(accent.opacity(0.18)))
            .shadow(color:.black.opacity(0.12),radius:10,y:3)
            .accessibilityElement(children:.contain)
    }
    @ViewBuilder private var selectionActions: some View {
        selectionAction("高亮",icon:"highlighter",kind:.highlight,shortcut:"⌘⇧H")
        selectionAction("评论",icon:"text.bubble",kind:.comment,shortcut:"⌘⇧M")
        selectionAction("问 AI",icon:"sparkles",kind:.question,shortcut:"⌘K")
    }
    private func selectionAction(_ title: String, icon: String, kind: AnnotationKind, shortcut: String) -> some View {
        Button {
            presentation.selectionAnchor = nil
            store.createAnnotation(kind)
        } label: {
            Label(T(title),systemImage:icon).font(.system(size:fontSize(12),weight:.medium))
                .padding(.horizontal,11).frame(height:30).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(kind == .question ? accent : ink).help(shortcut)
    }
    private var discussionPane: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack { Image(systemName:"text.bubble.fill").foregroundStyle(accent); Text(T("笔记与讨论")).font(.system(size:fontSize(15),weight:.semibold)); Spacer(); Button { presentation.settingsSection = .trash; presentation.showSettings = true } label: {controlIcon("trash")}.buttonStyle(.plain).help(T("最近删除")); Text("\(store.annotations.count)").font(.system(size:fontSize(11))).foregroundStyle(muted).padding(5).background(Color(hex:"EDF2EE"),in:Circle()) }.padding(20)
            accountAndModels.padding(.horizontal,18).padding(.bottom,15)
            Divider().opacity(0.4)
            if let annotation = store.selectedAnnotation {
                annotationDetail(annotation)
            } else {
                annotationList
            }
        }.background(.white.opacity(store.library.settings.sidesOpacity))
    }
    private var accountAndModels: some View {
        VStack(alignment:.leading,spacing:9) {
            HStack(spacing:7) {
                Circle().fill(service.authenticated && service.planEnabled ? accent : Color(hex:"B5BEB8")).frame(width:6,height:6)
                Text(service.authenticated ? T("ChatGPT 已连接") : T("连接 ChatGPT 后即可提问")).font(.system(size:fontSize(11))).foregroundStyle(muted)
                Spacer()
                if service.authenticated { Menu { Button(T("刷新模型")) { Task { await service.refreshModels() } }; Button(T("退出登录")) { Task { await service.logout() } } } label:{ controlIcon("ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width:26) }
                else { Button(T("登录")) { Task { if let url=await service.beginLogin() { NSWorkspace.shared.open(url) } } }.font(.system(size:fontSize(11),weight:.medium)).buttonStyle(.plain).foregroundStyle(accent).disabled(!service.connected) }
            }
            if !service.models.isEmpty {
                HStack(spacing:8) {
                    Picker(T("模型"), selection:Binding(get:{store.library.selectedModel},set:{store.library.selectedModel=$0;store.updateModelPreferences(service.models)})) { ForEach(service.models) { model in Text(model.name).tag(model.id) } }.labelsHidden().frame(maxWidth:.infinity)
                    Picker(T("推理强度"),selection:Binding(get:{store.library.selectedEffort},set:{store.library.selectedEffort=$0;store.save()})) { ForEach(service.models.first(where:{$0.id==store.library.selectedModel})?.efforts ?? ["auto"],id:\.self) { Text(effortLabel($0)).tag($0) } }.labelsHidden().frame(width:82)
                }.controlSize(.small).padding(.top,5)
            } else if !service.authMessage.isEmpty { Text(T(service.authMessage)).font(.system(size:fontSize(10))).foregroundStyle(muted).lineLimit(3) }
            if let error=service.error { Text(T(error)).font(.system(size:fontSize(10))).foregroundStyle(Color(hex:"AA6F53")).lineLimit(4) }
        }
    }
    private var annotationList: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:12) {
                if store.annotations.isEmpty {
                    VStack(spacing:14) { Image(systemName:"quote.bubble").font(.system(size:fontSize(38),weight:.ultraLight)).foregroundStyle(Color(hex:"A6BFB0")); Text(T("先从一段文字开始")).font(.system(size:fontSize(14),weight:.medium)); Text(T("在 PDF 中拖选文字，选择“评论”或“问 AI”。\n每段讨论都能回到原文的位置。")).font(.system(size:fontSize(11))).foregroundStyle(muted).multilineTextAlignment(.center) }.frame(maxWidth:.infinity).padding(.top,65)
                }
                ForEach(store.annotations.sorted { a,b in a.page==b.page ? a.createdAt<b.createdAt : a.page<b.page }) { annotation in
                    Button { store.focusAnnotation(annotation.id) } label: {
                        VStack(alignment:.leading,spacing:9) {
                            HStack { Label(T(annotation.kind.label),systemImage:annotation.kind.icon).font(.system(size:fontSize(10),weight:.medium)).foregroundStyle(accent); Spacer(); Text(store.localized("第 \(annotation.page+1) 页","Page \(annotation.page+1)")).font(.system(size:fontSize(10))).foregroundStyle(muted) }
                            HStack(spacing:10) { RoundedRectangle(cornerRadius:2).fill(annotation.effectiveColor).frame(width:3); Text(annotation.quote).font(.system(size:fontSize(12))).lineLimit(3).multilineTextAlignment(.leading).frame(maxWidth:.infinity,alignment:.leading) }.fixedSize(horizontal:false,vertical:true)
                            if annotation.kind == .comment && !annotation.comment.isEmpty { Text(annotation.comment).font(.system(size:fontSize(11))).foregroundStyle(muted).lineLimit(2) }
                            if annotation.kind == .question { HStack { Text(annotation.messages.isEmpty ? T("尚未提问") : store.localized("\(annotation.messages.count) 条发言","\(annotation.messages.count) messages")); Spacer(); Image(systemName:"arrow.up.left") }.font(.system(size:fontSize(10))).foregroundStyle(muted) }
                        }.padding(14).frame(maxWidth:.infinity,alignment:.leading).background(.white,in:RoundedRectangle(cornerRadius:12)).overlay(RoundedRectangle(cornerRadius:12).stroke(Color(hex:"E5EBE5"))).contentShape(Rectangle())
                    }.buttonStyle(.plain).contextMenu {
                        Button(T("定位原文")) {store.focusAnnotation(annotation.id)}
                        Button(T("移到最近删除"),role:.destructive) {trash(annotation)}.disabled(store.sending.contains(annotation.id))
                    }
                }
            }.padding(16)
        }
    }
    private func annotationDetail(_ annotation: ReaderAnnotation) -> some View {
        VStack(spacing:0) {
            ViewThatFits(in:.horizontal) {
                HStack(spacing:8) { allNotesButton; annotationTools(annotation) }
                VStack(alignment:.leading,spacing:8) {
                    allNotesButton
                    HStack { Spacer(minLength:0); annotationTools(annotation) }
                }
            }.font(.system(size:fontSize(11))).padding(.horizontal,18).padding(.vertical,13)
            VStack(alignment:.leading,spacing:8) { HStack { Text(store.localized("第 \(annotation.page+1) 页 · 引用原文","Page \(annotation.page+1) · Source passage")).font(.system(size:fontSize(10),weight:.medium)).foregroundStyle(accent); Spacer(); Button {store.focusAnnotation(annotation.id)} label:{controlIcon("scope")}.buttonStyle(.plain).help(T("定位原文")) }; Text(annotation.quote).font(.system(size:fontSize(12))).lineLimit(4).textSelection(.enabled) }.padding(13).frame(maxWidth:.infinity,alignment:.leading).background(Color(hex:"EDF4ED"),in:RoundedRectangle(cornerRadius:10)).contentShape(Rectangle()).onTapGesture {store.focusAnnotation(annotation.id)}.padding(.horizontal,16).padding(.bottom,12)
            if annotation.kind == .comment {
                VStack(alignment:.leading,spacing:12) { Text(T("你的评论")).font(.system(size:fontSize(11),weight:.medium)).foregroundStyle(muted); TextEditor(text:Binding(get:{store.selectedAnnotation?.comment ?? ""},set:{text in store.mutateAnnotation(annotation.id){$0.comment=text}})).font(.system(size:fontSize(13))).scrollContentBackground(.hidden).padding(9).frame(minHeight:150,maxHeight:270).background(.white,in:RoundedRectangle(cornerRadius:10)).overlay(RoundedRectangle(cornerRadius:10).stroke(Color(hex:"E1E9E2"))); Label(T("自动保存到本机"),systemImage:"checkmark.circle").font(.system(size:fontSize(10))).foregroundStyle(muted); Spacer(); Button(T("也向 AI 讨论这段文字")) {makeQuestion(from:annotation)}.buttonStyle(.bordered) }.padding(16)
            } else if annotation.kind == .highlight {
                VStack(spacing:16) { Image(systemName:"highlighter").font(.system(size:fontSize(30),weight:.light)).foregroundStyle(accent); Text(T("这段高亮已经保存")).font(.system(size:fontSize(13))); Text(T("下次打开这份 PDF，它还会在这里。")).font(.system(size:fontSize(11))).foregroundStyle(muted); Button(T("就这段文字向 AI 提问")) {makeQuestion(from:annotation)}.buttonStyle(.bordered); Spacer() }.padding(.top,35).frame(maxWidth:.infinity)
            } else { conversation(annotation) }
        }
    }
    private var allNotesButton: some View {
        Button {store.selectedAnnotationID=nil} label:{Label(T("全部笔记"),systemImage:"chevron.left").fixedSize().frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,3).contentShape(Rectangle())}.buttonStyle(.plain)
    }
    private func annotationTools(_ annotation: ReaderAnnotation) -> some View {
        HStack(spacing:8) {
            Text(T(annotation.kind.label)).foregroundStyle(accent).lineLimit(1)
            Button {trash(annotation)} label:{controlIcon("trash")}.buttonStyle(.plain).help(T("移到最近删除")).disabled(store.sending.contains(annotation.id))
            Menu {
                ForEach(HighlightColor.allCases) { color in
                    Button(T(color.label)) {store.mutateAnnotation(annotation.id){$0.color=color;$0.customColorHex=nil}}
                }
            } label:{controlIcon("paintpalette")}.menuStyle(.borderlessButton).frame(width:25).help(T("预设颜色"))
            AnnotationColorControl(hex:Binding(get:{annotation.effectiveColorHex},set:{value in store.mutateAnnotation(annotation.id){$0.customColorHex=value}}),title:T("标注颜色"),localize:T)
        }.fixedSize(horizontal:true,vertical:false)
    }
    private func conversation(_ annotation: ReaderAnnotation) -> some View {
        VStack(spacing:0) {
            Group {
                if annotation.messages.isEmpty {
                    Text(T("围绕这段原文讨论")).foregroundStyle(muted).frame(maxWidth:.infinity,alignment:.leading)
                } else {
                    Button {store.mutateAnnotation(annotation.id){$0.collapsed.toggle()}} label:{
                        HStack {Text(T("围绕这段原文讨论")).foregroundStyle(muted);Spacer();Text(annotation.collapsed ? T("展开对话") : T("折叠对话")).foregroundStyle(accent)}
                            .padding(.vertical,3).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }.font(.system(size:fontSize(10))).padding(.horizontal,18).padding(.bottom,8)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:14) {
                        if annotation.collapsed { Text(store.localized("已折叠 \(annotation.messages.count) 条发言","\(annotation.messages.count) messages collapsed")).font(.system(size:fontSize(12))).foregroundStyle(muted).padding(16) }
                        else {
                            ForEach(annotation.messages) { message in messageBubble(message) }
                            if store.sending.contains(annotation.id) {
                                VStack(alignment:.leading,spacing:8) { HStack(spacing:7) { ProgressView().controlSize(.mini); Text(T("正在思考与回复…")).font(.system(size:fontSize(10))).foregroundStyle(muted) }; if let text=store.partials[annotation.id],!text.isEmpty { Text(text).font(.system(size:fontSize(13))).textSelection(.enabled) } }.padding(13).frame(maxWidth:.infinity,alignment:.leading).background(Color(hex:store.library.aiBubble),in:RoundedRectangle(cornerRadius:12))
                            }
                            if annotation.messages.isEmpty { Text(T("有什么让你停下来思考？\n问概念、推导，或让 AI 举一个例子。")).font(.system(size:fontSize(12))).foregroundStyle(muted).lineSpacing(5).padding(.vertical,25).frame(maxWidth:.infinity) }
                        }
                        Color.clear.frame(height:1).id("bottom")
                    }.padding(.horizontal,16).padding(.vertical,8)
                }
                .onChange(of:annotation.messages.count) { _,_ in withAnimation {proxy.scrollTo("bottom",anchor:.bottom)} }
            }
            if let error=store.threadErrors[annotation.id] { Text(T(error)).font(.system(size:fontSize(10))).foregroundStyle(Color(hex:"AA6F53")).padding(.horizontal,16).padding(.vertical,6) }
            VStack(alignment:.leading,spacing:9) {
                TextEditor(text:Binding(get:{store.drafts[annotation.id] ?? ""},set:{store.drafts[annotation.id]=$0})).font(.system(size:fontSize(12))).scrollContentBackground(.hidden).frame(height:72).padding(8).background(.white,in:RoundedRectangle(cornerRadius:10)).overlay(alignment:.topLeading) { if (store.drafts[annotation.id] ?? "").isEmpty { Text(annotation.messages.isEmpty ? T("输入你的问题…") : T("继续追问…")).font(.system(size:fontSize(12))).foregroundStyle(muted.opacity(0.75)).padding(.horizontal,14).padding(.top,16).allowsHitTesting(false) } }.overlay(RoundedRectangle(cornerRadius:10).stroke(Color(hex:"DCE6DD")))
                HStack { ChatContextControl(store:store,annotation:annotation); Spacer(); if store.sending.contains(annotation.id) {Button(T("停止")) {Task {await service.cancel(threadID:annotation.id)}}.controlSize(.small)} else { Button {Task {await store.sendQuestion(service:service)}} label:{Label(T("发送"),systemImage:"arrow.up")}.buttonStyle(.borderedProminent).controlSize(.small).disabled(!service.authenticated || !service.planEnabled || (store.drafts[annotation.id] ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty) } }
            }.padding(15)
        }
    }
    private func messageBubble(_ message: ChatMessage) -> some View {
        let isUser = message.role == "user"
        let isLong = message.text.count > 1000
        let expanded = presentation.expandedMessages.contains(message.id)
        return VStack(alignment:.leading,spacing:8) {
            HStack { Text(isUser ? T("你") : "AI").font(.system(size:fontSize(10),weight:.semibold)); Spacer(); if !isUser { Text([message.model,message.effort].compactMap{$0}.joined(separator:" · ")).font(.system(size:fontSize(8))).lineLimit(1) } }.foregroundStyle(muted)
            if isUser {
                Text(.init(isLong && !expanded ? String(message.text.prefix(800))+"…" : message.text)).font(.system(size:fontSize(13))).lineSpacing(4).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
            } else {
                MathMessageView(text:message.text,fontSize:fontSize(13),textColor:NSColor(ink))
                    .frame(maxHeight:isLong && !expanded ? 260 : nil,alignment:.top).clipped()
            }
            if let reference = message.reference {
                Text(T("参考") + ": " + T(reference.scope.label) + (reference.pages.isEmpty ? "" : " · " + ChatReferenceSummary.compactPages(reference.pages)))
                    .font(.system(size:fontSize(9))).foregroundStyle(muted).lineLimit(2)
            }
            if isLong {Button {if expanded {presentation.expandedMessages.remove(message.id)} else {presentation.expandedMessages.insert(message.id)}} label:{Text(expanded ? T("收起长回复") : T("展开完整回复")).frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,4).contentShape(Rectangle())}.font(.system(size:fontSize(10))).buttonStyle(.plain).foregroundStyle(accent)}
            if message.failed {Label(T("这次发送未完成，可在下方重试"),systemImage:"exclamationmark.circle").font(.system(size:fontSize(10))).foregroundStyle(Color(hex:"AA6F53"))}
        }.padding(13).background(Color(hex:isUser ? store.library.userBubble : store.library.aiBubble),in:RoundedRectangle(cornerRadius:12)).padding(isUser ? .leading : .trailing,10)
    }
    private func trash(_ annotation: ReaderAnnotation) {
        guard let did = store.documentID, store.deleteAnnotation(annotation.id) else {return}
        presentation.showDeleted(annotation.id,documentID:did)
    }
    private func T(_ text: String) -> String { store.t(text) }
    private func controlIcon(_ name: String) -> some View { Image(systemName:name).frame(width:24,height:24).contentShape(Rectangle()) }
    private func fontSize(_ size: CGFloat) -> CGFloat { size * CGFloat(store.library.settings.textSize / 13) }
    private func makeQuestion(from annotation: ReaderAnnotation) { store.selection=SelectionSnapshot(text:annotation.quote,rects:annotation.rects,pageText:annotation.pageText);store.createAnnotation(.question) }
    private func post(_ name:Notification.Name) {if let id=store.documentID {NotificationCenter.default.post(name:name,object:id)}}
    private func effortLabel(_ value:String)->String { ["auto":T("自动"),"low":T("低"),"medium":T("中"),"high":T("高"),"xhigh":T("很高"),"max":T("最高")][value] ?? value }
}

/// Measure and place in one layout pass, including longer translations and large fonts.
private struct SelectionToolbarLayout: Layout {
    var anchor: SelectionActionAnchor
    var viewport: CGSize

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { viewport }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let toolbar = subviews.first else { return }
        let ideal = toolbar.sizeThatFits(.unspecified)
        let width = min(ideal.width, max(0,bounds.width - 16))
        let measured = toolbar.sizeThatFits(ProposedViewSize(width:width,height:nil))
        let size = CGSize(width:width,height:measured.height)
        let origin = anchor.toolbarOrigin(size:size,viewport:bounds.size)
        toolbar.place(at:CGPoint(x:bounds.minX + origin.x,y:bounds.minY + origin.y),anchor:.topLeading,
                      proposal:ProposedViewSize(width:size.width,height:size.height))
    }
}
