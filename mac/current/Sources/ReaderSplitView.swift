import AppKit
import SwiftUI

/// A new window restores the last manual layout, defaulting to 20 / 60 / 20.
/// Native dividers remain draggable, and
/// each pane keeps its hosting view (and its PDFView) as SwiftUI values change.
struct ReaderSplitView<Left: View, Center: View, Right: View>: NSViewRepresentable {
    private let left: Left
    private let center: Center
    private let right: Right
    private let initialProportions: [Double]?
    private let onProportionsChange: (([Double]) -> Void)?

    init(initialProportions: [Double]? = nil, onProportionsChange: (([Double]) -> Void)? = nil,
         @ViewBuilder left: () -> Left, @ViewBuilder center: () -> Center, @ViewBuilder right: () -> Right) {
        self.left = left(); self.center = center(); self.right = right()
        self.initialProportions = initialProportions
        self.onProportionsChange = onProportionsChange
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ReaderNativeSplitView {
        let split = ReaderNativeSplitView(frame: .zero)
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = context.coordinator
        split.restoreProportions(initialProportions)
        for host in context.coordinator.hosts {
            // NSSplitView owns pane frames. Intrinsic SwiftUI content widths must
            // not compete with the explicit initial proportions or user drags.
            host.sizingOptions = []
            host.autoresizingMask = [.height]
            split.addSubview(host)
        }
        updateNSView(split, context: context)
        return split
    }

    func updateNSView(_ view: ReaderNativeSplitView, context: Context) {
        view.onProportionsChange = onProportionsChange
        // A hosting root does not inherit its surrounding representable's
        // environment. Forward the complete environment, including locale,
        // tint, foreground styles, accessibility and custom environment keys.
        context.coordinator.hosts[0].rootView = AnyView(left.environment(\.self, context.environment))
        context.coordinator.hosts[1].rootView = AnyView(center.environment(\.self, context.environment))
        context.coordinator.hosts[2].rootView = AnyView(right.environment(\.self, context.environment))
        view.needsLayout = true
    }

    static func dismantleNSView(_ view: ReaderNativeSplitView, coordinator: Coordinator) {
        view.delegate = nil
        view.onProportionsChange = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSSplitViewDelegate {
        let hosts = (0..<3).map { _ in NSHostingView(rootView: AnyView(EmptyView())) }

        func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
            (splitView as? ReaderNativeSplitView)?.layoutPanes()
        }

        func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }

        func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
            guard let split = splitView as? ReaderNativeSplitView, split.subviews.count == 3 else { return proposedMinimumPosition }
            let minimum = split.effectiveMinimums
            if dividerIndex == 0 { return split.bounds.minX + minimum[0] }
            return split.subviews[0].frame.maxX + split.dividerThickness + minimum[1]
        }

        func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
            guard let split = splitView as? ReaderNativeSplitView, split.subviews.count == 3 else { return proposedMaximumPosition }
            let minimum = split.effectiveMinimums
            if dividerIndex == 0 { return split.subviews[1].frame.maxX - minimum[1] }
            return split.bounds.maxX - split.dividerThickness - minimum[2]
        }

        func splitViewDidResizeSubviews(_ notification: Notification) {
            guard let split = notification.object as? ReaderNativeSplitView, split.isTrackingDivider else { return }
            split.rememberUserProportions()
        }
    }
}

@MainActor
final class ReaderNativeSplitView: NSSplitView {
    private static let initialProportions: [CGFloat] = [0.2, 0.6, 0.2]
    private static let minimumWidths: [CGFloat] = [180, 420, 200]
    private var userProportions: [CGFloat]?
    private var isApplyingLayout = false
    private(set) var isTrackingDivider = false
    var onProportionsChange: (([Double]) -> Void)?

    func restoreProportions(_ values: [Double]?) {
        userProportions = ReaderSettings.normalizedPaneProportions(values)?.map { CGFloat($0) }
    }

    var effectiveMinimums: [CGFloat] {
        let available = max(0, bounds.width - dividerThickness * 2)
        let scale = min(1, available / Self.minimumWidths.reduce(0, +))
        return Self.minimumWidths.map { $0 * scale }
    }

    override func layout() {
        super.layout()
        layoutPanes()
    }

    override func mouseDown(with event: NSEvent) {
        let before = subviews.map { $0.frame.width }
        isTrackingDivider = true
        super.mouseDown(with: event)
        isTrackingDivider = false
        if subviews.map({ $0.frame.width }) != before {
            rememberUserProportions()
            // Persist once at mouse-up, not while SwiftUI/AppKit is laying out
            // the window. Automatic resizing never overwrites this preference.
            if let userProportions { onProportionsChange?(userProportions.map { Double($0) }) }
        }
    }

    func layoutPanes() {
        guard subviews.count == 3, bounds.width > 0, bounds.height > 0,
              !isApplyingLayout, !isTrackingDivider else { return }
        isApplyingLayout = true
        defer { isApplyingLayout = false }
        let available = max(0, bounds.width - dividerThickness * 2)
        let widths = Self.allocate(available: available,
                                   proportions: userProportions ?? Self.initialProportions,
                                   minimums: effectiveMinimums)
        var x = bounds.minX
        for (index, pane) in subviews.enumerated() {
            let frame = NSRect(x: x, y: bounds.minY, width: widths[index], height: bounds.height)
            if pane.frame != frame { pane.frame = frame }
            x += widths[index] + dividerThickness
        }
    }

    /// Only divider tracking calls this in the app. Automatic layout and window
    /// resizing therefore never turn a transient startup frame into saved ratios.
    func rememberUserProportions() {
        guard !isApplyingLayout, subviews.count == 3 else { return }
        let widths = subviews.map { max(0, $0.frame.width) }
        let total = widths.reduce(0, +)
        guard total > 0 else { return }
        userProportions = widths.map { $0 / total }
    }

    private static func allocate(available: CGFloat, proportions: [CGFloat], minimums: [CGFloat]) -> [CGFloat] {
        var widths = Array(repeating: CGFloat.zero, count: 3)
        var remaining = Set(0..<3)
        var free = available
        while !remaining.isEmpty {
            let weight = remaining.reduce(CGFloat.zero) { $0 + proportions[$1] }
            let constrained = remaining.filter { index in
                let proposed = weight > 0 ? free * proportions[index] / weight : free / CGFloat(remaining.count)
                return proposed < minimums[index]
            }
            if constrained.isEmpty {
                for index in remaining {
                    widths[index] = weight > 0 ? free * proportions[index] / weight : free / CGFloat(remaining.count)
                }
                break
            }
            for index in constrained {
                widths[index] = minimums[index]
                free = max(0, free - minimums[index])
                remaining.remove(index)
            }
        }
        return widths
    }
}
