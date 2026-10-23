import AppKit
import SwiftUI

/// The actions occupy their own nonactivating child window. PDFKit installs
/// tracking areas below the overlay, so competing cursors in one window cannot
/// be fixed reliably by setting the arrow again on every mouse movement.
struct SelectionActionSurface<Content: View>: NSViewControllerRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    func makeNSViewController(context: Context) -> SelectionActionController<AnyView> {
        SelectionActionController(content: AnyView(content.environment(\.self, context.environment)))
    }

    func updateNSViewController(_ controller: SelectionActionController<AnyView>, context: Context) {
        controller.hosting.rootView = AnyView(content.environment(\.self, context.environment))
        controller.schedulePresentationUpdate()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController controller: SelectionActionController<AnyView>, context: Context) -> CGSize? {
        controller.measuredSize(proposal)
    }

    static func dismantleNSViewController(_ controller: SelectionActionController<AnyView>, coordinator: ()) {
        controller.dispose()
    }
}

final class SelectionActionController<Content: View>: NSViewController {
    let hosting: NSHostingController<Content>
    private(set) var actionPanel: SelectionActionPanel?
    private(set) var actionContentView: SelectionActionCursorView?
    private weak var attachedWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var updateQueued = false
    private var disposed = false
    private var parentIsClosing = false

    init(content: Content) {
        hosting = NSHostingController(rootView: content)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let anchor = SelectionActionAnchorView()
        anchor.onGeometryChange = { [weak self] in self?.schedulePresentationUpdate() }
        view = anchor

        let surface = SelectionActionCursorView()
        actionContentView = surface
        addChild(hosting)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: surface.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: surface.bottomAnchor)
        ])
        let panel = SelectionActionPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = true
        panel.isFloatingPanel = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.acceptsMouseMovedEvents = true
        panel.contentView = surface
        actionPanel = panel
    }

    func measuredSize(_ proposal: ProposedViewSize) -> CGSize {
        // An infinite width makes the toolbar's divider expand indefinitely. Its
        // intrinsic width preserves the ideal proposal used by the custom layout;
        // a finite width still allows ViewThatFits to switch to stacked actions.
        let ideal = hosting.view.intrinsicContentSize
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? max(0, ideal.width)
        return hosting.sizeThatFits(in: CGSize(width: width, height: proposal.height ?? .infinity))
    }

    /// Coalesce layout callbacks, rather than changing windows in SwiftUI layout.
    func schedulePresentationUpdate() {
        guard !disposed, !updateQueued else { return }
        updateQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateQueued = false
            self.updatePresentation()
        }
    }

    func updatePresentation() {
        guard !disposed, let anchor = view as? SelectionActionAnchorView, let panel = actionPanel else { return }
        let parent = anchor.window
        if attachedWindow !== parent {
            detachFromParent()
            attachedWindow = parent
            parentIsClosing = false
            if let parent { observe(parent) }
        }
        guard let parent, !parentIsClosing, !anchor.isHiddenOrHasHiddenAncestor,
              anchor.bounds.width > 0, anchor.bounds.height > 0 else {
            hidePanel()
            return
        }
        // The anchor is only the measured toolbar rectangle, not the PDF viewport.
        let frame = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        guard !frame.isEmpty, !frame.isInfinite, !frame.isNull else { hidePanel(); return }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        panel.level = parent.level
        let belongsToActiveReadingWindow = parent.isMainWindow || parent.isKeyWindow || NSApp.mainWindow === parent
        guard NSApp.isActive, parent.isVisible, !parent.isMiniaturized, parent.attachedSheet == nil,
              belongsToActiveReadingWindow else { hidePanel(); return }
        if panel.parent !== parent { parent.addChildWindow(panel, ordered: .above) }
        if !panel.isVisible { panel.orderFront(nil) }
    }

    private func observe(_ parent: NSWindow) {
        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification] {
            observers.append(center.addObserver(forName: name, object: parent, queue: .main) { [weak self] _ in
                self?.schedulePresentationUpdate()
            })
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification,
                     NSApplication.didBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.schedulePresentationUpdate()
            })
        }
        for name in [NSWindow.willMiniaturizeNotification, NSWindow.willCloseNotification] {
            observers.append(center.addObserver(forName: name, object: parent, queue: .main) { [weak self] note in
                if note.name == NSWindow.willCloseNotification { self?.parentIsClosing = true }
                self?.hidePanel()
            })
        }
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.hidePanel()
        })
    }

    private func hidePanel() {
        guard let panel = actionPanel else { return }
        panel.orderOut(nil)
        panel.parent?.removeChildWindow(panel)
    }

    private func detachFromParent() {
        hidePanel()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        attachedWindow = nil
    }

    func dispose() {
        guard !disposed else { return }
        disposed = true
        (view as? SelectionActionAnchorView)?.onGeometryChange = nil
        detachFromParent()
        actionPanel?.close()
        actionPanel?.contentView = nil
        actionPanel = nil
        actionContentView = nil
    }
}

/// This invisible layout anchor does not receive events. The small child panel
/// above it owns pointer input; everywhere else remains part of the PDF window.
final class SelectionActionAnchorView: NSView {
    var onGeometryChange: (() -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); onGeometryChange?() }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); onGeometryChange?() }
    override func layout() { super.layout(); onGeometryChange?() }
    override func setFrameOrigin(_ newOrigin: NSPoint) { super.setFrameOrigin(newOrigin); onGeometryChange?() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); onGeometryChange?() }
    override func viewDidHide() { super.viewDidHide(); onGeometryChange?() }
    override func viewDidUnhide() { super.viewDidUnhide(); onGeometryChange?() }
}

final class SelectionActionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class SelectionActionCursorView: NSView {
    private var cursorTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        if let cursorTrackingArea { removeTrackingArea(cursorTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
            options: [.inVisibleRect, .activeInActiveApp, .cursorUpdate],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        cursorTrackingArea = area
        super.updateTrackingAreas()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Keep native controls interactive and protect the toolbar's padding too.
        // Returning nil outside this small view leaves all PDF gestures untouched.
        guard !isHidden, frame.contains(point) else { return nil }
        return super.hitTest(point) ?? self
    }
}
