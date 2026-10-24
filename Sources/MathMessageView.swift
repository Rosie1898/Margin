import SwiftUI
import AppKit
import WebKit

/// Locally rendered Markdown and LaTeX. Its height participates in the outer
/// discussion scroll view; only wide formula/code/table content scrolls inside.
struct MathMessageView: View {
    let text: String
    var fontSize: CGFloat = 13
    var textColor: NSColor = NSColor(red: 0.16, green: 0.25, blue: 0.22, alpha: 1)
    @StateObject private var layout = MathMessageLayout()

    var body: some View {
        MathWebContent(text: text, fontSize: fontSize, textColor: textColor, height: $layout.height)
            .frame(height: layout.height)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private final class MathMessageLayout: ObservableObject {
    @Published var height: CGFloat = 22
}

private struct MathWebContent: NSViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let textColor: NSColor
    @Binding var height: CGFloat

    func makeCoordinator() -> MathMessageCoordinator {
        MathMessageCoordinator { value in
            if abs(height - value) >= 1 { height = value }
        }
    }
    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.makeWebView()
    }
    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(text: text, fontSize: fontSize, textColor: textColor)
    }
    static func dismantleNSView(_ webView: WKWebView, coordinator: MathMessageCoordinator) {
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "marginHeight")
        webView.navigationDelegate = nil
    }
}

@MainActor
final class MathMessageCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private static let dataStore = WKWebsiteDataStore.nonPersistent()
    private var webView: WKWebView?
    private let onHeight: (CGFloat) -> Void
    private let resources: URL?
    private var loaded = false
    private var currentText = ""
    private var currentSize: CGFloat = 13
    private var currentColor = "#294039"
    private var hasContent = false

    init(resources: URL? = Bundle.main.resourceURL?.appendingPathComponent("MathRenderer", isDirectory: true), onHeight: @escaping (CGFloat) -> Void) {
        self.resources = resources
        self.onHeight = onHeight
    }

    func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = Self.dataStore
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(self, name: "marginHeight")
        let view = MathBubbleWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = self
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        webView = view
        if let resources {
            view.loadFileURL(resources.appendingPathComponent("index.html"), allowingReadAccessTo: resources)
        }
        return view
    }

    func update(text: String, fontSize: CGFloat, textColor: NSColor) {
        let rgb = textColor.usingColorSpace(.sRGB) ?? textColor
        let hex = String(format: "#%02X%02X%02X", Int(round(rgb.redComponent * 255)), Int(round(rgb.greenComponent * 255)), Int(round(rgb.blueComponent * 255)))
        guard !hasContent || currentText != text || currentSize != fontSize || currentColor != hex else { return }
        hasContent = true
        currentText = text
        currentSize = fontSize
        currentColor = hex
        render()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        render()
    }

    private func render() {
        guard loaded, hasContent, let webView else { return }
        // Structured arguments keep reply text out of executable JavaScript.
        webView.callAsyncJavaScript("return window.MarginMath.render(text, fontSize, color);",
                                   arguments: ["text": currentText, "fontSize": currentSize, "color": currentColor],
                                   in: nil, in: .page) { _ in }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "marginHeight", message.frameInfo.isMainFrame,
              let number = message.body as? NSNumber else { return }
        let value = CGFloat(number.doubleValue)
        guard value.isFinite, value >= 0, value < 2_000_000 else { return }
        // WebKit reports after layout; defer the SwiftUI state update so it
        // never occurs during representable update/layout.
        DispatchQueue.main.async { [weak self] in self?.onHeight(max(1, value)) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if navigationAction.navigationType == .linkActivated {
            if ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
            return
        }
        if url.isFileURL, let resources,
           url.standardizedFileURL == resources.appendingPathComponent("index.html").standardizedFileURL {
            decisionHandler(.allow)
        } else { decisionHandler(.cancel) }
    }
}

private final class MathBubbleWebView: WKWebView {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    override func scrollWheel(with event: NSEvent) {
        // The reply participates in the discussion's vertical scrolling. Keep
        // horizontal trackpad events available for long display formulas.
        if abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX), let outer = enclosingScrollView {
            outer.scrollWheel(with: event)
        } else { super.scrollWheel(with: event) }
    }
}
