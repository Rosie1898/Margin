import AppKit
import PDFKit
import SwiftUI

extension Notification.Name {
    static let leafPDFZoomIn = Notification.Name("leafPDFZoomIn")
    static let leafPDFZoomOut = Notification.Name("leafPDFZoomOut")
    static let leafPDFFit = Notification.Name("leafPDFFit")
    static let leafPDFFind = Notification.Name("leafPDFFind")
}

/// View coordinates, with the same top-left origin as the SwiftUI overlay.
struct SelectionActionAnchor: Equatable {
    var point: CGPoint
    var line: CGRect

    func toolbarOrigin(size: CGSize, viewport: CGSize) -> CGPoint {
        let margin: CGFloat = 8
        let below = max(point.y + 12, line.maxY + 8)
        let above = min(point.y - 12, line.minY - 8) - size.height
        let y = below + size.height <= viewport.height - margin ? below : above
        return CGPoint(x: max(margin, min(point.x - size.width / 2, viewport.width - size.width - margin)),
                       y: max(margin, min(y, viewport.height - size.height - margin)))
    }
}

/// PDFKit owns text hit testing and rendering; the app stores annotations separately.
struct PDFCanvas: NSViewRepresentable {
    var document: PDFDocument
    var documentID: String
    var annotations: [ReaderAnnotation]
    var selectedAnnotationID: UUID?
    var initialPage: Int
    var navigationToken: Int
    var navigationRect: PageRect?
    var documentRevision: Int = 0
    var canvasBackground: NSColor = NSColor(hex: "E9EEEB")
    var onScale: (CGFloat) -> Void = { _ in }
    var onSelection: (SelectionSnapshot?) -> Void
    var onPage: (Int) -> Void
    var onAnnotationClick: (UUID) -> Void
    var hasStoredSelection = true
    var onSelectionActions: (SelectionSnapshot?, SelectionActionAnchor?) -> Void = { _, _ in }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> ReaderPDFView {
        let view = ReaderPDFView()
        view.setCanvasBackground(canvasBackground)
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 16, left: 14, bottom: 16, right: 14)
        view.autoScales = true
        view.minScaleFactor = 0.2
        view.maxScaleFactor = 6
        context.coordinator.attach(view)
        context.coordinator.update(self)
        return view
    }

    func updateNSView(_ view: ReaderPDFView, context: Context) {
        context.coordinator.update(self)
    }

    static func dismantleNSView(_ view: ReaderPDFView, coordinator: Coordinator) {
        coordinator.detach()
    }

    /// Captures page coordinates immediately, before focus moves into the sidebar.
    static func snapshot(from selection: PDFSelection, document: PDFDocument) -> SelectionSnapshot? {
        guard let copied = selection.copy() as? PDFSelection,
              let text = copied.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var rects: [PageRect] = []
        var seen: Set<PageRect> = []
        let lines = copied.selectionsByLine()
        for line in lines.isEmpty ? [copied] : lines {
            for page in line.pages {
                let index = document.index(for: page)
                let rect = line.bounds(for: page)
                guard index != NSNotFound, index >= 0, index < document.pageCount,
                      !rect.isNull, !rect.isInfinite, rect.width > 0, rect.height > 0,
                      [rect.minX, rect.minY, rect.width, rect.height].allSatisfy({ $0.isFinite }) else { continue }
                let value = PageRect(page: index, rect: rect)
                if seen.insert(value).inserted { rects.append(value) }
            }
        }
        guard let first = rects.first else { return nil }
        let pageText = String((document.page(at: first.page)?.string ?? "").prefix(12_000))
        return SelectionSnapshot(text: text, rects: rects, pageText: pageText)
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: PDFCanvas
        weak var view: ReaderPDFView?
        private var attachedDocument: PDFDocument?
        private var attachedDocumentID: String?
        private var attachedRevision = 0
        private var managed: [(PDFPage, PDFAnnotation)] = []
        private var appearance: [Appearance] = []
        private var lastNavigationToken: Int?
        private var lastSelection: SelectionSnapshot?
        private var lastPage: Int?
        private var lastScale: CGFloat?
        private var isUpdating = false
        private var generation = 0
        private var lastFindText = ""
        private var lastFindSelection: PDFSelection?
        private var actionRevision = 0
        private var actionAnchor: SelectionActionAnchor?
        private struct OCRViewport {
            var origin: CGPoint?
            var scale: CGFloat
            var fitted: Bool
            var selection: PDFSelection?
        }
        private var ocrViewport: OCRViewport?

        private struct Appearance: Equatable {
            let id: UUID
            let kind: AnnotationKind
            let colorHex: String
            let rects: [PageRect]
            let selected: Bool
        }

        init(parent: PDFCanvas) { self.parent = parent }

        func attach(_ view: ReaderPDFView) {
            self.view = view
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(selectionChanged), name: .PDFViewSelectionChanged, object: view)
            center.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: view)
            center.addObserver(self, selector: #selector(scaleChanged), name: .PDFViewScaleChanged, object: view)
            center.addObserver(self, selector: #selector(annotationHit(_:)), name: .PDFViewAnnotationHit, object: view)
            // PDFKit's internal scroll view can handle a trackpad event before it reaches
            // the PDFView responder. Observe that native gesture entry as well.
            center.addObserver(self, selector: #selector(liveMagnifyBegan(_:)), name: NSScrollView.willStartLiveMagnifyNotification, object: nil)
            center.addObserver(self, selector: #selector(viewportChanged(_:)), name: NSView.boundsDidChangeNotification, object: nil)
            center.addObserver(self, selector: #selector(willReplacePage(_:)), name: .leafPDFWillReplacePage, object: nil)
            for name in [Notification.Name.leafPDFZoomIn, .leafPDFZoomOut, .leafPDFFit, .leafPDFFind] {
                center.addObserver(self, selector: #selector(command(_:)), name: name, object: nil)
            }
            view.onUserMouseUp = { [weak self] point, isClick in self?.userMouseUp(point: point, isClick: isClick) }
            view.onDismissSelectionActions = { [weak self] in self?.dismissSelectionActions() }
        }

        func detach() {
            generation += 1
            NotificationCenter.default.removeObserver(self)
            removeManagedAnnotations()
            view?.onUserMouseUp = nil
            view?.onDismissSelectionActions = nil
            view?.managedAnnotationIDs = [:]
            view = nil
            attachedDocument = nil
        }

        func update(_ newParent: PDFCanvas) {
            let consumedSelection = parent.hasStoredSelection && !newParent.hasStoredSelection
            parent = newParent
            guard let view else { return }
            isUpdating = true
            defer { isUpdating = false }
            let changedDocument = attachedDocument !== parent.document || attachedDocumentID != parent.documentID
            let changedPages = !changedDocument && attachedRevision != parent.documentRevision
            if changedDocument {
                generation += 1
                dismissSelectionActions()
                removeManagedAnnotations()
                appearance = []
                lastSelection = nil
                lastPage = nil
                lastScale = nil
                lastFindText = ""
                lastFindSelection = nil
                ocrViewport = nil
                attachedDocument = parent.document
                attachedDocumentID = parent.documentID
                view.document = parent.document
                view.autoScales = true
                lastNavigationToken = nil
                if let page = parent.document.page(at: max(0, min(parent.initialPage, parent.document.pageCount - 1))) {
                    view.go(to: page)
                }
            }
            if changedPages {
                // Installing an OCR page changes the in-memory document, not its
                // identity. Keep the same page coordinates and manual zoom.
                let saved = ocrViewport
                ocrViewport = nil
                let scale = saved?.scale ?? view.scaleFactor
                let fitted = saved?.fitted ?? view.autoScales
                let selection = saved?.selection ?? (view.currentSelection?.copy() as? PDFSelection)
                let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
                let visible = view.page(for: center, nearest: true) ?? view.currentPage
                let index = visible.map { parent.document.index(for: $0) } ?? NSNotFound
                let pageIndex = index == NSNotFound ? (lastPage ?? parent.initialPage) : index
                let point = visible.map { view.convert(center, to: $0) }
                generation += 1
                dismissSelectionActions()
                removeManagedAnnotations()
                view.document = nil
                view.document = parent.document
                view.autoScales = fitted
                if !fitted { view.scaleFactor = scale }
                view.layoutSubtreeIfNeeded()
                view.layoutDocumentView()
                if let origin = saved?.origin, let scroll = view.documentView?.enclosingScrollView {
                    var bounds = scroll.contentView.bounds
                    bounds.origin = origin
                    scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(bounds).origin)
                    scroll.reflectScrolledClipView(scroll.contentView)
                } else if let page = parent.document.page(at: pageIndex) {
                    if let point { _ = view.centerAnchor(CGRect(x: point.x - 0.5, y: point.y - 0.5, width: 1, height: 1), on: page) }
                    else { view.go(to: page) }
                }
                if let selection, selection.pages.allSatisfy({ parent.document.index(for: $0) != NSNotFound }) {
                    view.setCurrentSelection(selection, animate: false)
                }
                lastFindSelection = nil
            }
            attachedRevision = parent.documentRevision
            if !parent.hasStoredSelection { dismissSelectionActions() }
            if consumedSelection { view.clearSelection() }
            view.setCanvasBackground(parent.canvasBackground)
            let newAppearance = parent.annotations.map {
                Appearance(id: $0.id, kind: $0.kind, colorHex: $0.effectiveColorHex, rects: $0.rects, selected: $0.id == parent.selectedAnnotationID)
            }
            if newAppearance != appearance || changedDocument || changedPages {
                removeManagedAnnotations()
                appearance = newAppearance
                addManagedAnnotations()
            }
            if lastNavigationToken != parent.navigationToken {
                dismissSelectionActions()
                lastNavigationToken = parent.navigationToken
                if let target = parent.navigationRect, validAnchor(target) {
                    // SwiftUI can deliver this update before PDFKit has laid out its document.
                    // Keep navigation separate from annotation/selection updates and discard an
                    // older request if a different document or annotation is selected meanwhile.
                    scheduleNavigation(to: target, generation: generation, token: parent.navigationToken)
                }
            }
            publishPage()
            publishScale()
        }

        private func validAnchor(_ target: PageRect) -> Bool {
            let rect = target.cgRect
            return target.page >= 0 && target.page < parent.document.pageCount &&
                !rect.isEmpty && !rect.isNull && !rect.isInfinite &&
                [rect.minX, rect.minY, rect.width, rect.height].allSatisfy { $0.isFinite }
        }

        private func scheduleNavigation(to target: PageRect, generation expectedGeneration: Int, token: Int, attempt: Int = 0) {
            DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0 : 0.06)) { [weak self] in
                guard let self, self.generation == expectedGeneration,
                      self.lastNavigationToken == token, self.parent.navigationRect == target,
                      let view = self.view, let page = self.parent.document.page(at: target.page) else { return }
                self.isUpdating = true
                let centered = view.centerAnchor(target.cgRect, on: page)
                self.isUpdating = false
                self.publishPage()
                // A newly inserted PDFView may not have a usable viewport yet. Retry only
                // while layout is incomplete, with a small fixed bound on deferred work.
                if !centered && attempt < 5 {
                    self.scheduleNavigation(to: target, generation: expectedGeneration, token: token, attempt: attempt + 1)
                }
            }
        }

        private func removeManagedAnnotations() {
            for (page, annotation) in managed { page.removeAnnotation(annotation) }
            managed.removeAll()
            view?.managedAnnotationIDs = [:]
        }

        private func addManagedAnnotations() {
            guard let view else { return }
            for item in appearance {
                for (lineIndex, anchor) in item.rects.enumerated() {
                    guard let page = parent.document.page(at: anchor.page) else { continue }
                    let rect = anchor.cgRect
                    guard !rect.isEmpty, !rect.isNull, !rect.isInfinite,
                          [rect.minX, rect.minY, rect.width, rect.height].allSatisfy({ $0.isFinite }) else { continue }
                    let isFilled = item.kind != .question
                    let type: PDFAnnotationSubtype = isFilled ? .highlight : .underline
                    let annotation = PDFAnnotation(bounds: rect, forType: type, withProperties: nil)
                    let color = NSColor(hex: item.colorHex)
                    if isFilled {
                        annotation.color = color.withAlphaComponent(item.selected ? 0.55 : 0.38)
                    } else {
                        annotation.color = color.blended(withFraction: item.selected ? 0.38 : 0.24, of: NSColor(hex: "45685D")) ?? color
                        let border = PDFBorder()
                        border.lineWidth = item.selected ? 2 : 1.5
                        annotation.border = border
                    }
                    annotation.userName = "Margin"
                    annotation.setValue("leaf-reader:\(item.id.uuidString):\(lineIndex)", forAnnotationKey: .name)
                    page.addAnnotation(annotation)
                    managed.append((page, annotation))
                    view.managedAnnotationIDs[ObjectIdentifier(annotation)] = item.id
                }
            }
            view.needsDisplay = true
        }

        @objc private func selectionChanged() {
            guard !isUpdating, let view, let selection = view.currentSelection,
                  let snapshot = PDFCanvas.snapshot(from: selection, document: parent.document) else { return }
            publishSelection(snapshot)
        }

        private func publishSelection(_ snapshot: SelectionSnapshot?) {
            guard snapshot != lastSelection else { return }
            lastSelection = snapshot
            let expectedGeneration = generation
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == expectedGeneration, self.lastSelection == snapshot else { return }
                self.parent.onSelection(snapshot)
            }
        }

        private func dismissSelectionActions() {
            guard actionAnchor != nil else { return }
            actionRevision += 1
            actionAnchor = nil
            let revision = actionRevision
            DispatchQueue.main.async { [weak self] in
                guard let self, self.actionRevision == revision else { return }
                self.parent.onSelectionActions(nil, nil)
            }
        }

        private func showSelectionActions(at point: CGPoint) {
            guard let view, let selection = view.currentSelection,
                  let snapshot = PDFCanvas.snapshot(from: selection, document: parent.document) else { return }
            // Use the line nearest the release point, including reverse and cross-page drags.
            let lines = snapshot.rects.compactMap { rect -> CGRect? in
                guard let page = parent.document.page(at: rect.page) else { return nil }
                return view.convert(rect.cgRect, from: page)
            }
            guard let line = lines.min(by: {
                hypot($0.midX - point.x, $0.midY - point.y) < hypot($1.midX - point.x, $1.midY - point.y)
            }) else { return }
            let topPoint = CGPoint(x: point.x - view.bounds.minX,
                                   y: view.isFlipped ? point.y - view.bounds.minY : view.bounds.maxY - point.y)
            let topLine = CGRect(x: line.minX - view.bounds.minX,
                                 y: view.isFlipped ? line.minY - view.bounds.minY : view.bounds.maxY - line.maxY,
                                 width: line.width, height: line.height)
            let anchor = SelectionActionAnchor(point: topPoint, line: topLine)
            actionRevision += 1
            actionAnchor = anchor
            let revision = actionRevision
            let expectedGeneration = generation
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == expectedGeneration, self.actionRevision == revision else { return }
                // Publish together so an immediately clicked action uses this exact selection.
                self.lastSelection = snapshot
                self.parent.onSelectionActions(snapshot, anchor)
            }
        }

        @objc private func viewportChanged(_ notification: Notification) {
            guard let clip = view?.documentView?.enclosingScrollView?.contentView,
                  notification.object as? NSClipView === clip else { return }
            dismissSelectionActions()
        }

        @objc private func willReplacePage(_ notification: Notification) {
            guard notification.object as? String == attachedDocumentID, let view else { return }
            // Removing the currently visible PDFPage can make PDFKit scroll
            // immediately. Capture before that mutation, not after SwiftUI updates.
            ocrViewport = OCRViewport(origin: view.documentView?.enclosingScrollView?.contentView.bounds.origin,
                                      scale: view.scaleFactor, fitted: view.autoScales,
                                      selection: view.currentSelection?.copy() as? PDFSelection)
        }

        @objc private func scaleChanged() {
            dismissSelectionActions()
            if !isUpdating { publishScale() }
        }

        private func publishScale() {
            guard let scale = view?.scaleFactor, scale.isFinite, scale > 0 else { return }
            if let lastScale, abs(lastScale - scale) < 0.00001 { return }
            lastScale = scale
            let expectedGeneration = generation
            // Coalesce rapid pinch notifications and never mutate SwiftUI state from
            // inside PDFKit's synchronous layout/scale notifications.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == expectedGeneration,
                      self.view != nil, self.lastScale == scale else { return }
                self.parent.onScale(scale)
            }
        }

        @objc private func pageChanged() { if !isUpdating { publishPage() } }

        private func publishPage() {
            guard let view else { return }
            // Continuous PDFKit views can retain currentPage until their next layout
            // notification after a programmatic clip scroll. Resolve the visible center
            // directly so the page counter and saved position follow the navigation.
            let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            guard let page = view.page(for: center, nearest: true) ?? view.currentPage else { return }
            let index = parent.document.index(for: page)
            guard index != NSNotFound, index >= 0, index < parent.document.pageCount, index != lastPage else { return }
            lastPage = index
            let expectedGeneration = generation
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == expectedGeneration, self.lastPage == index else { return }
                self.parent.onPage(index)
            }
        }

        @objc private func annotationHit(_ notification: Notification) {
            guard let view else { return }
            // PDFKit supplies the clicked annotation in userInfo. Its key is not a public constant.
            for value in notification.userInfo?.values ?? [:].values {
                if let annotation = value as? PDFAnnotation,
                   let id = view.managedAnnotationIDs[ObjectIdentifier(annotation)] {
                    parent.onAnnotationClick(id)
                    return
                }
            }
        }

        private func userMouseUp(point: CGPoint, isClick: Bool) {
            guard let view else { return }
            if isClick {
                if let page = view.page(for: point, nearest: false) {
                    let pagePoint = view.convert(point, to: page)
                    if let annotation = page.annotation(at: pagePoint),
                       let id = view.managedAnnotationIDs[ObjectIdentifier(annotation)] {
                        parent.onAnnotationClick(id)
                        return
                    }
                    // Do not clear the saved selection merely because the sidebar takes focus.
                    // Only a direct click on blank PDF space intentionally clears it.
                    if page.selectionForWord(at: pagePoint) == nil,
                       view.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                        publishSelection(nil)
                    }
                } else {
                    publishSelection(nil)
                }
            }
            selectionChanged()
            if view.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                showSelectionActions(at: point)
            } else {
                dismissSelectionActions()
            }
        }

        @objc private func liveMagnifyBegan(_ notification: Notification) {
            guard let view, let scrollView = notification.object as? NSScrollView,
                  scrollView === view.documentView?.enclosingScrollView else { return }
            view.prepareForManualZoom()
            dismissSelectionActions()
        }

        @objc private func command(_ notification: Notification) {
            guard let view else { return }
            let target = (notification.userInfo?["documentID"] as? String) ?? (notification.object as? String)
            if let target, target != parent.documentID { return }
            switch notification.name {
            case .leafPDFZoomIn:
                view.prepareForManualZoom()
                view.zoomIn(nil)
            case .leafPDFZoomOut:
                view.prepareForManualZoom()
                view.zoomOut(nil)
            case .leafPDFFit:
                view.autoScales = true
            case .leafPDFFind:
                let text = (notification.userInfo?["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                if text != lastFindText { lastFindText = text; lastFindSelection = nil }
                let found = parent.document.findString(text, fromSelection: lastFindSelection, withOptions: .caseInsensitive)
                    ?? parent.document.findString(text, fromSelection: nil, withOptions: .caseInsensitive)
                guard let found else { NSSound.beep(); return }
                lastFindSelection = found
                view.setCurrentSelection(found, animate: true)
                view.go(to: found)
            default: break
            }
        }
    }
}

final class ReaderPDFView: PDFView {
    var managedAnnotationIDs: [ObjectIdentifier: UUID] = [:]
    var onUserMouseUp: ((CGPoint, Bool) -> Void)?
    var onDismissSelectionActions: (() -> Void)?
    private var mouseDownPoint: CGPoint?

    override var isOpaque: Bool { backgroundColor.alphaComponent >= 1 }

    /// Tint the canvas around the pages. PDF page pixels remain opaque white.
    func setCanvasBackground(_ color: NSColor) {
        // SwiftUI can update the sidebar while a pinch is active. Do not ask PDFKit
        // to redraw its canvas on every such update when the actual color is unchanged.
        if backgroundColor != color { backgroundColor = color }
        if let scrollView = documentView?.enclosingScrollView {
            if scrollView.drawsBackground { scrollView.drawsBackground = false }
            if scrollView.contentView.drawsBackground { scrollView.contentView.drawsBackground = false }
        }
    }

    /// Enabling autoScales or replacing a document lets PDFKit reset its zoom limits.
    /// Set the manual range at the gesture boundary, not during every SwiftUI update.
    func prepareForManualZoom() {
        if autoScales { autoScales = false }
        if minScaleFactor != 0.2 { minScaleFactor = 0.2 }
        if maxScaleFactor != 6 { maxScaleFactor = 6 }
    }

    override func magnify(with event: NSEvent) {
        prepareForManualZoom()
        // PDFKit/NSScrollView retains the point under the gesture and performs native
        // continuous magnification. Manual scale assignments here cause anchor jumps.
        super.magnify(with: event)
    }

    /// PDFKit's go(to:rect:on:) only makes a rectangle visible; a card click must also
    /// bring an already-visible line to the same predictable place in the viewport.
    @discardableResult
    func centerAnchor(_ anchor: CGRect, on page: PDFPage) -> Bool {
        guard bounds.width > 1, bounds.height > 1 else { return false }
        layoutSubtreeIfNeeded()
        layoutDocumentView()
        // Let PDFKit update its page navigation bookkeeping before centering the clip.
        go(to: anchor, on: page)
        layoutSubtreeIfNeeded()
        guard let documentView, let scrollView = documentView.enclosingScrollView else { return false }
        let clip = scrollView.contentView
        guard clip.bounds.width > 1, clip.bounds.height > 1,
              documentView.bounds.width > 1, documentView.bounds.height > 1 else { return false }
        let target = documentView.convert(convert(anchor, from: page), from: self)
        guard !target.isEmpty, !target.isNull, !target.isInfinite else { return false }
        var proposed = clip.bounds
        proposed.origin = CGPoint(x: target.midX - proposed.width / 2, y: target.midY - proposed.height / 2)
        // Clip-view constraints handle the first/last page and documents narrower than
        // the viewport, including flipped document coordinates and zoomed pages.
        let constrained = clip.constrainBoundsRect(proposed)
        clip.scroll(to: constrained.origin)
        scrollView.reflectScrolledClipView(clip)
        setCanvasBackground(backgroundColor)
        return clip.documentVisibleRect.intersects(target)
    }

    override func mouseDown(with event: NSEvent) {
        onDismissSelectionActions?()
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        super.mouseDown(with: event)
    }

    override func setFrameSize(_ newSize: NSSize) {
        if newSize != frame.size { onDismissSelectionActions?() }
        super.setFrameSize(newSize)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onDismissSelectionActions?(); return }
        super.keyDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let start = mouseDownPoint ?? point
        let isClick = hypot(point.x - start.x, point.y - start.y) < 4
        onUserMouseUp?(point, isClick)
        mouseDownPoint = nil
    }
}
