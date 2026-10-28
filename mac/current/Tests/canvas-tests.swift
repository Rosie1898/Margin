import AppKit
import PDFKit
import SwiftUI

/// Simulates a PDF tracking owner that tries to install its text cursor on every
/// move. Events must be routed to the action panel before this window sees them.
private final class CompetingCursorWindow: NSWindow {
    var competingMoves = 0
    override func sendEvent(_ event: NSEvent) {
        super.sendEvent(event)
        if event.type == .mouseMoved {
            competingMoves += 1
            NSCursor.iBeam.set()
        }
    }
}

@main
struct CanvasTests {
    @MainActor static func main() throws {
        precondition((3...4).contains(CommandLine.arguments.count), "Usage: canvas-tests PROJECT_ROOT SCRATCH_DIRECTORY [--navigation]")
        let verifiesNavigation = CommandLine.arguments.contains("--navigation")
        let project = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let scratch = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let cursorSurface = SelectionActionController(content: VStack(spacing: 7) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 2) { Text("Highlight").frame(width: 80, height: 30); Text("Comment").frame(width: 80, height: 30); Text("Ask AI").frame(width: 80, height: 30) }
                VStack(spacing: 2) { Text("Highlight").frame(width: 80, height: 30); Text("Comment").frame(width: 80, height: 30); Text("Ask AI").frame(width: 80, height: 30) }
            }
            Divider()
            Circle().frame(width: 18, height: 18)
        }.padding(9))
        let idealSurface = cursorSurface.measuredSize(.unspecified)
        let narrowSurface = cursorSurface.measuredSize(ProposedViewSize(width: 140, height: nil))
        precondition(idealSurface.width.isFinite && idealSurface.width < 400 && idealSurface.height > 0,
                     "The native cursor surface must have the toolbar's ideal size, not the full PDF viewport")
        precondition(narrowSurface.width == 140 && narrowSurface.height > idealSurface.height,
                     "Narrow toolbars must preserve stacked actions instead of clipping them")
        _ = NSApplication.shared
        let hitContainer = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 500))
        let documentHitView = NSView(frame: hitContainer.bounds)
        hitContainer.addSubview(documentHitView)
        let readingWindow = CompetingCursorWindow(contentRect: hitContainer.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        readingWindow.isReleasedWhenClosed = false
        readingWindow.contentView = hitContainer
        let anchorView = cursorSurface.view as! SelectionActionAnchorView
        anchorView.frame = CGRect(x: 100, y: 100, width: idealSurface.width, height: idealSurface.height)
        hitContainer.addSubview(anchorView)
        cursorSurface.updatePresentation()
        let panel = cursorSurface.actionPanel!
        let cursorView = cursorSurface.actionContentView!
        precondition(cursorSurface.hosting.view.window === panel && panel !== readingWindow,
                     "The floating actions must receive events in their own native window, outside PDFKit's competing tracking areas")
        precondition(panel.frame == readingWindow.convertToScreen(anchorView.convert(anchorView.bounds, to: nil)),
                     "The child panel must cover exactly the toolbar anchor after screen-coordinate conversion")
        precondition(!panel.canBecomeKey && !panel.canBecomeMain,
                     "Clicking floating actions must not take keyboard focus and clear the original PDF selection")
        precondition(!panel.isVisible, "An inactive or hidden reader must not display a detached floating panel")
        precondition(hitContainer.hitTest(CGPoint(x: 30, y: 30)) === documentHitView &&
                     hitContainer.hitTest(CGPoint(x: 102, y: 102)) === documentHitView,
                     "The layout anchor must not intercept PDF gestures; only the actual child panel owns its pointer region")
        let expectedSize = anchorView.frame.size
        anchorView.frame.origin = CGPoint(x: 180, y: 220)
        cursorSurface.updatePresentation()
        precondition(panel.frame == readingWindow.convertToScreen(anchorView.convert(anchorView.bounds, to: nil)) && panel.frame.size == expectedSize,
                     "Moving the toolbar anchor must move its separate window without expanding the hit region")
        cursorView.updateTrackingAreas()
        cursorView.updateTrackingAreas()
        precondition(cursorView.trackingAreas.filter { $0.owner as? SelectionActionCursorView === cursorView }.count == 1,
                     "Resizing a toolbar must replace its cursor tracker instead of accumulating trackers")
        let priorCursor = NSCursor.current
        for x in stride(from: 8.0, through: Double(idealSurface.width - 8), by: 8.0) {
            let move = NSEvent.mouseEvent(with: .mouseMoved, location: CGPoint(x: x, y: 20), modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
            // Hidden test windows have no WindowServer number, so this checks
            // the native receiver boundary. Physical routing is verified in UI QA.
            panel.sendEvent(move)
        }
        precondition(readingWindow.competingMoves == 0,
                     "Movement events delivered to the actions panel must never reach the underlying window's competing cursor handler")
        let returnToPDF = NSEvent.mouseEvent(with: .mouseMoved, location: CGPoint(x: 30, y: 30), modifierFlags: [], timestamp: 0, windowNumber: readingWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        readingWindow.sendEvent(returnToPDF)
        precondition(readingWindow.competingMoves == 1 && NSCursor.current == .iBeam,
                     "Returning an event to the PDF window must immediately restore its normal text-cursor handling: moves=\(readingWindow.competingMoves), cursor=\(NSCursor.current)")
        priorCursor.set()
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApplication.shared)
        precondition(panel.parent == nil && !panel.isVisible, "Deactivation must detach and hide the action panel")
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: readingWindow)
        cursorSurface.updatePresentation()
        precondition(panel.parent == nil && !panel.isVisible, "Queued layout callbacks must not resurrect actions while the parent closes")
        cursorSurface.dispose()
        cursorSurface.dispose()
        precondition(cursorSurface.actionPanel == nil && panel.contentView == nil,
                     "Dismantling actions must release their child window and content exactly once")
        anchorView.removeFromSuperview()
        readingWindow.close()
        let actionSize = CGSize(width: 280, height: 74)
        let actionViewport = CGSize(width: 600, height: 500)
        let actionBounds = CGRect(origin: .zero, size: actionViewport).insetBy(dx: 8, dy: 8)
        let actionAnchors = [
            SelectionActionAnchor(point: CGPoint(x: 300, y: 200), line: CGRect(x: 200, y: 190, width: 180, height: 20)),
            SelectionActionAnchor(point: CGPoint(x: 2, y: 200), line: CGRect(x: 0, y: 190, width: 180, height: 20)),
            SelectionActionAnchor(point: CGPoint(x: 598, y: 200), line: CGRect(x: 420, y: 190, width: 180, height: 20)),
            SelectionActionAnchor(point: CGPoint(x: 300, y: 490), line: CGRect(x: 200, y: 480, width: 180, height: 20))
        ]
        for (index, anchor) in actionAnchors.enumerated() {
            let toolbar = CGRect(origin: anchor.toolbarOrigin(size: actionSize, viewport: actionViewport), size: actionSize)
            precondition(actionBounds.contains(toolbar), "Floating actions must remain inside the reading viewport at its edges")
            precondition(!toolbar.intersects(anchor.line), "Floating actions must not cover the selected line")
            if index == actionAnchors.count - 1 {
                precondition(toolbar.maxY < anchor.line.minY, "Near the bottom, actions must move above the selection")
            } else {
                precondition(toolbar.minY > anchor.line.maxY, "With space below, actions must appear beneath the selection")
            }
        }
        let source = project.appendingPathComponent("Tests/Fixtures/selection.pdf")
        let before = try Data(contentsOf: source)
        let doc = PDFDocument(url: source)!
        let p0 = doc.page(at: 0)!
        let p1 = doc.page(at: 1)!
        let original = PDFAnnotation(bounds: CGRect(x: 30, y: 30, width: 30, height: 30), forType: .square, withProperties: nil)
        original.userName = "Original author"
        p0.addAnnotation(original)
        let selection = PDFSelection(document: doc)
        let firstText = "An anchored PDF selection stays with its page.\ng(t) = 7t^3 - 5t + 2"
        let range0 = (p0.string! as NSString).range(of: firstText)
        precondition(range0.location != NSNotFound)
        selection.add(p0.selection(for: range0)!)
        selection.add(p1.selection(for: (p1.string! as NSString).range(of: "g(t) = 7t^3 - 5t + 2"))!)
        let snapshot = PDFCanvas.snapshot(from: selection, document: doc)!
        precondition(snapshot.rects.count == 3)
        precondition(snapshot.rects.map(\.page) == [0, 0, 1])
        precondition(snapshot.pageText == p0.string)
        precondition(snapshot.imageDataURL == nil)
        let note = ReaderAnnotation(kind: .highlight, quote: snapshot.text, rects: snapshot.rects, color: .mint)
        var received: SelectionSnapshot?
        var currentPage: Int?
        var receivedScales: [CGFloat] = []
        var actionEvents: [(SelectionSnapshot?, SelectionActionAnchor?)] = []
        let search = PDFSearchState()
        var parent = PDFCanvas(document: doc, documentID: "fixture", annotations: [note], selectedAnnotationID: note.id, initialPage: 0, navigationToken: 1, navigationRect: verifiesNavigation ? note.rects[0] : nil, searchState: search, onScale: { receivedScales.append($0) }, onSelection: { received = $0 }, onPage: { currentPage = $0 }, onAnnotationClick: { _ in })
        parent.onSelectionActions = { actionEvents.append(($0, $1)) }
        let view = ReaderPDFView(frame: CGRect(x: 0, y: 0, width: 700, height: verifiesNavigation ? 420 : 850))
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = verifiesNavigation
        let coordinator = parent.makeCoordinator()
        coordinator.attach(view)
        coordinator.update(parent)
        precondition(receivedScales.isEmpty, "Scale updates must be deferred outside SwiftUI updates")
        precondition(p0.annotations.count == 3)
        precondition(p1.annotations.count == 1)
        precondition(p0.annotations.contains { $0 === original })
        precondition(view.managedAnnotationIDs.count == 3)
        let ours = p0.annotations.filter { $0 !== original }
        precondition(ours.map(\.bounds) == snapshot.rects.filter { $0.page == 0 }.map(\.cgRect))
        view.setCurrentSelection(selection, animate: false)
        NotificationCenter.default.post(name: .PDFViewSelectionChanged, object: view)
        RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        precondition(received?.rects == snapshot.rects)
        precondition(currentPage != nil)
        precondition(receivedScales.last?.isFinite == true && receivedScales.last! > 0)
        precondition(abs(receivedScales.last! - view.scaleFactor) < 0.001)
        let scaleCallbackCount = receivedScales.count
        coordinator.update(parent)
        NotificationCenter.default.post(name: .PDFViewScaleChanged, object: view)
        view.clearSelection()
        NotificationCenter.default.post(name: .PDFViewSelectionChanged, object: view)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        precondition(receivedScales.count == scaleCallbackCount, "Repeated scale notifications must be deduplicated")
        precondition(received?.rects == snapshot.rects, "Focus clearing currentSelection must not discard cached selection")
        view.setCurrentSelection(selection, animate: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        let releaseLine = view.convert(snapshot.rects[0].cgRect, from: p0)
        let releasePoint = CGPoint(x: releaseLine.maxX, y: releaseLine.midY)
        let actionCountBeforeRelease = actionEvents.count
        view.onUserMouseUp?(releasePoint, false)
        precondition(actionEvents.count == actionCountBeforeRelease, "Selection actions must be deferred outside PDFKit callbacks")
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        precondition(actionEvents.last?.0 == snapshot, "Mouse release must publish the exact cross-page selection with its actions")
        let releaseAnchor = actionEvents.last!.1!
        let expectedReleaseY = view.isFlipped ? releasePoint.y - view.bounds.minY : view.bounds.maxY - releasePoint.y
        precondition(abs(releaseAnchor.point.x - (releasePoint.x - view.bounds.minX)) < 0.001 && abs(releaseAnchor.point.y - expectedReleaseY) < 0.001, "Action anchor must use PDF viewport coordinates with a top-left origin")
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: view.documentView!.enclosingScrollView!.contentView)
        // PDFKit can emit multiple viewport notifications before the deferred hide runs.
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: view.documentView!.enclosingScrollView!.contentView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        precondition(actionEvents.last?.0 == nil && actionEvents.last?.1 == nil, "Repeated synchronous scroll notifications must preserve the queued dismissal of floating actions")
        precondition(received?.rects == snapshot.rects, "Hiding floating actions must preserve the captured selection")
        let actionCountBeforeReselection = actionEvents.count
        view.onUserMouseUp?(CGPoint(x: releasePoint.x - 12, y: releasePoint.y), false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        precondition(actionEvents.count > actionCountBeforeReselection && actionEvents.last?.0 == snapshot && actionEvents.last?.1 != nil, "Releasing the same selection again must reopen floating actions despite selection deduplication")
        precondition(abs(actionEvents.last!.1!.point.x - (releaseAnchor.point.x - 12)) < 0.001, "Repeated selection must use the new release position")
        if verifiesNavigation {
            // Sidebar navigation uses page coordinates, including cross-page selection anchors.
            func assertVisible(_ target: PageRect, expectedPage: Int, message: String) {
                RunLoop.main.run(until: Date().addingTimeInterval(0.12))
                let page = doc.page(at: target.page)!
                let documentView = view.documentView!
                let clip = documentView.enclosingScrollView!.contentView
                let rect = documentView.convert(view.convert(target.cgRect, from: page), from: view)
                let visible = clip.documentVisibleRect
                precondition(visible.contains(rect), "\(message): target \(rect) outside \(visible)")
                var centered = clip.bounds
                centered.origin = CGPoint(x: rect.midX - centered.width / 2, y: rect.midY - centered.height / 2)
                let expected = clip.constrainBoundsRect(centered).origin
                precondition(abs(clip.bounds.minY - expected.y) < 2, "\(message): not centered")
                precondition(currentPage == expectedPage, "\(message): page callback is stale: \(String(describing: currentPage))")
            }
            parent.navigationRect = note.rects[2]
            parent.navigationToken += 1
            coordinator.update(parent)
            assertVisible(note.rects[2], expectedPage: 1, message: "Cross-page comment click")
            view.go(to: p0)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            parent.navigationToken += 1
            coordinator.update(parent)
            assertVisible(note.rects[2], expectedPage: 1, message: "Repeated click after manual page change")
            parent.navigationRect = note.rects[0]
            parent.navigationToken += 1
            coordinator.update(parent)
            parent.navigationRect = note.rects[2]
            parent.navigationToken += 1
            coordinator.update(parent)
            assertVisible(note.rects[2], expectedPage: 1, message: "Latest click wins queued navigation")
        }
        parent.canvasBackground = NSColor.systemPink.withAlphaComponent(0.3)
        coordinator.update(parent)
        precondition(view.backgroundColor == parent.canvasBackground)
        precondition(view.documentView?.enclosingScrollView?.drawsBackground == false)
        precondition(view.documentView?.enclosingScrollView?.contentView.drawsBackground == false)
        let thumb = p0.thumbnail(of: CGSize(width: 612, height: 792), for: .cropBox)
        let bitmap = NSBitmapImageRep(data: thumb.tiffRepresentation!)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: scratch.appendingPathComponent("canvas-highlights.png"))
        // The internal native scroll view may receive a pinch before PDFView does.
        // Its start notification must leave automatic fit mode and restore our bounds.
        let nativeScroll = view.documentView!.enclosingScrollView!
        NotificationCenter.default.post(name: NSScrollView.willStartLiveMagnifyNotification, object: nativeScroll)
        precondition(!view.autoScales && view.minScaleFactor == 0.2 && view.maxScaleFactor == 6)
        view.scaleFactor = 1.65
        precondition(abs(view.scaleFactor - 1.65) < 0.001, "Manual zoom must exceed 100%")
        var comment = ReaderAnnotation(kind: .comment, quote: note.quote, rects: [note.rects[0]], color: .blue)
        comment.customColorHex = "CB8C62"
        parent.annotations = [comment]
        coordinator.update(parent)
        precondition(p0.annotations.count == 2 && p1.annotations.isEmpty)
        precondition(p0.annotations.contains { $0 === original })
        precondition(p0.annotations.first { $0 !== original }?.type == "Highlight", "Ordinary comments use a filled highlight")
        precondition(abs(view.scaleFactor - 1.65) < 0.001 && !view.autoScales, "Sidebar updates must preserve manual zoom")
        let oldSize = view.frame.size
        view.setFrameSize(NSSize(width: 640, height: oldSize.height))
        precondition(abs(view.scaleFactor - 1.65) < 0.001, "Manual zoom must survive a viewport resize")
        view.setFrameSize(oldSize)
        let markedColor = p0.annotations.first { $0 !== original }!.color.usingColorSpace(.deviceRGB)!
        let expectedColor = comment.effectiveNSColor.usingColorSpace(.deviceRGB)!
        precondition(abs(markedColor.redComponent - expectedColor.redComponent) < 0.001)
        precondition(abs(markedColor.greenComponent - expectedColor.greenComponent) < 0.001)
        precondition(abs(markedColor.blueComponent - expectedColor.blueComponent) < 0.001)
        comment.customColorHex = "B483CE"
        parent.annotations = [comment]
        coordinator.update(parent)
        let changedColor = p0.annotations.first { $0 !== original }!.color.usingColorSpace(.deviceRGB)!
        precondition(abs(changedColor.redComponent - markedColor.redComponent) > 0.01, "Changing a custom color must refresh an existing annotation")
        parent.annotations = [ReaderAnnotation(kind: .question, quote: note.quote, rects: [note.rects[0]], color: .pink)]
        coordinator.update(parent)
        precondition(p0.annotations.first { $0 !== original }?.type == "Underline", "Questions keep the separate underline style")
        view.scaleFactor = 9
        precondition(abs(view.scaleFactor - 6) < 0.001)
        view.scaleFactor = 0.05
        precondition(abs(view.scaleFactor - 0.2) < 0.001)
        NotificationCenter.default.post(name: .leafPDFFit, object: "fixture")
        precondition(view.autoScales)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveMagnifyNotification, object: nativeScroll)
        view.scaleFactor = 2
        coordinator.update(parent)
        precondition(!view.autoScales && abs(view.scaleFactor - 2) < 0.001, "Pinch after Fit must again allow a stable zoom over 100%")
        precondition(view.minScaleFactor == 0.2 && view.maxScaleFactor == 6)
        // Every clip notification must keep the horizontal origin. Checking only
        // the final value would miss an intermediate PDFKit go(to:) sideways jump.
        view.layoutSubtreeIfNeeded()
        view.layoutDocumentView()
        let navigationClip = nativeScroll.contentView
        var panned = navigationClip.bounds
        panned.origin.x = 170
        navigationClip.scroll(to: navigationClip.constrainBoundsRect(panned).origin)
        nativeScroll.reflectScrolledClipView(navigationClip)
        let retainedX = navigationClip.bounds.minX
        precondition(retainedX > 10, "The navigation regression must start horizontally panned beyond fit")
        var horizontalPositions: [CGFloat] = []
        let navigationObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: navigationClip, queue: nil) { _ in
            horizontalPositions.append(navigationClip.bounds.minX)
        }
        for target in [note.rects[2], note.rects[0], note.rects[2], note.rects[2]] {
            parent.navigationRect = target
            parent.navigationToken += 1
            coordinator.update(parent)
            RunLoop.main.run(until: Date().addingTimeInterval(0.09))
            let targetPage = doc.page(at: target.page)!
            let documentView = view.documentView!
            let located = documentView.convert(view.convert(target.cgRect, from: targetPage), from: view)
            let visible = navigationClip.documentVisibleRect
            precondition(visible.maxY >= located.minY && visible.minY <= located.maxY,
                         "A zoomed note jump must reveal its vertical location")
            precondition(abs(navigationClip.bounds.minX - retainedX) < 0.5 && abs(view.scaleFactor - 2) < 0.001 && !view.autoScales,
                         "Repeated note jumps must preserve the user's horizontal offset and manual zoom")
        }
        NotificationCenter.default.removeObserver(navigationObserver)
        precondition(!horizontalPositions.isEmpty && horizontalPositions.allSatisfy { abs($0 - retainedX) < 0.5 },
                     "No intermediate scroll notification may shift the page sideways: \(horizontalPositions)")
        // Find overlays stay separate from existing annotations and mouse selection.
        let selectionBeforeSearch = view.currentSelection?.string
        let annotationCountBeforeSearch = p0.annotations.count + p1.annotations.count
        func finishSearch() {
            let deadline = Date().addingTimeInterval(3)
            while search.isSearching && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            precondition(!search.isSearching, "A small PDF search should finish promptly")
        }
        search.query = "G(T)"
        finishSearch()
        let expectedSearchCount = doc.findString("G(T)", withOptions: .caseInsensitive).count
        precondition(expectedSearchCount > 1 && search.matchCount == expectedSearchCount && search.currentMatch == 1,
                     "Search must find all case-insensitive matches in document order")
        precondition(view.highlightedSelections?.count == expectedSearchCount,
                     "Find results must have transient highlights")
        precondition(view.currentSelection?.string == selectionBeforeSearch && p0.annotations.count + p1.annotations.count == annotationCountBeforeSearch,
                     "Finding text must preserve the current mouse selection and saved annotations")
        search.previous()
        precondition(search.currentMatch == expectedSearchCount, "Previous from the first result must wrap to the last")
        search.next()
        precondition(search.currentMatch == 1, "Next from the last result must wrap to the first")
        search.query = "no-match-that-must-not-leak"
        search.query = "G(T)"
        finishSearch()
        precondition(search.matchCount == expectedSearchCount, "A replacement query must discard canceled search results")
        search.query = "no-match-that-must-not-leak"
        finishSearch()
        precondition(search.matchCount == 0 && search.currentMatch == 0 && view.highlightedSelections?.isEmpty != false,
                     "No-match searches must clear old overlays and result counters")
        search.clear()
        precondition(search.query.isEmpty && search.matchCount == 0 && view.currentSelection?.string == selectionBeforeSearch,
                     "Closing Find must remove its results without clearing the user's selection")
        parent.annotations = []
        coordinator.update(parent)
        precondition(p0.annotations.count == 1 && p0.annotations[0] === original)
        precondition(p1.annotations.isEmpty)
        // Installing OCR on another page keeps the reader's zoom, live native
        // selection and original embedded annotations on the current page.
        view.go(to: p0)
        let keptSelection = p0.selection(for: NSRange(location: 0, length: 10))!
        view.setCurrentSelection(keptSelection, animate: false)
        search.query = "G(T)"
        finishSearch()
        let originBeforeOCR = view.documentView!.enclosingScrollView!.contentView.bounds.origin
        NotificationCenter.default.post(name: .leafPDFWillReplacePage, object: "fixture")
        let replacementPage = PDFDocument(url: source)!.page(at: 1)!
        doc.removePage(at: 1); doc.insert(replacementPage, at: 1)
        parent.documentRevision += 1
        coordinator.update(parent)
        precondition(!view.autoScales && abs(view.scaleFactor - 2) < 0.001,
                     "Installing an OCR page must preserve manual zoom")
        precondition(view.currentSelection?.string == keptSelection.string,
                     "OCR on a different page must preserve the current text selection")
        let originAfterOCR = view.documentView!.enclosingScrollView!.contentView.bounds.origin
        precondition(abs(originAfterOCR.y - originBeforeOCR.y) < 1 && abs(originAfterOCR.x - originBeforeOCR.x) < 1,
                     "Installing an OCR page must preserve the exact scroll position")
        precondition(p0.annotations.contains { $0 === original },
                     "OCR refresh must preserve embedded source annotations")
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        finishSearch()
        precondition(search.query == "G(T)" && search.matchCount == doc.findString("G(T)", withOptions: .caseInsensitive).count,
                     "Installing OCR text must refresh active search matches without losing the query")
        precondition(abs(view.documentView!.enclosingScrollView!.contentView.bounds.minX - originBeforeOCR.x) < 1 &&
                     abs(view.documentView!.enclosingScrollView!.contentView.bounds.minY - originBeforeOCR.y) < 1,
                     "An OCR search refresh must not navigate away from the current reading position")
        view.setCurrentSelection(selection, animate: false)
        let actionCountBeforeDocumentChange = actionEvents.count
        view.onUserMouseUp?(releasePoint, false)
        parent.document = PDFDocument(url: source)!
        parent.documentID = "replacement-fixture"
        parent.navigationRect = nil
        parent.selectedAnnotationID = nil
        coordinator.update(parent)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(actionEvents.dropFirst(actionCountBeforeDocumentChange).allSatisfy { $0.0 == nil && $0.1 == nil }, "A queued selection action from the previous document must not appear after switching documents")
        precondition(search.query.isEmpty && search.matchCount == 0 && view.highlightedSelections?.isEmpty != false,
                     "Switching PDFs must clear the old search query and highlights")
        coordinator.detach()
        let after = try Data(contentsOf: source)
        precondition(after == before)
        if verifiesNavigation { print("NAVIGATION_TESTS_PASSED: cross-page centered navigation, repeat and superseded navigation, page callbacks") }
        print("CANVAS_TESTS_PASSED: separate toolbar window geometry and native receiver boundary, focus-safe panel lifecycle and exact bounds, narrow toolbar measurement, cross-page line anchors, exact rectangles, preserved original annotation, owned markup lifecycle, selection cache survives focus loss, floating action edge placement and release snapshot, scroll dismissal, repeated selection reopens actions, stale action invalidation on document change, page callback, transparent canvas, filled comments/custom colors, manual zoom 20-600%, zoom survives sidebar update and resize, deferred deduplicated scale callback, source bytes unchanged, vertical-only zoomed note jumps including transient offsets, cancellable cross-page search and result wraparound, separate find overlays, OCR search refresh and document reset")
    }
}
