import AppKit
import WebKit
import Foundation

private struct MathFailure: Error, CustomStringConvertible { let description: String }
private func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw MathFailure(description: message) }
}

@main
struct MathRenderingTests {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // Independent of the main actor and JavaScript completion callbacks.
        // A stalled WebKit process must still produce a bounded test result.
        let resultURL = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("result.txt")
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 60) {
            let message = "FAIL offline math: WebKit test exceeded 60 seconds; see progress.txt"
            try? message.write(to: resultURL, atomically: true, encoding: .utf8)
            exit(1)
        }
        Task { @MainActor in
            do {
                try await run()
                finish("PASS offline math: all delimiters, malformed display brackets, Markdown, code/currency preservation, untrusted HTML/links/LaTeX, local fonts, automatic height and horizontal formula overflow", status: 0)
            } catch { finish("FAIL offline math: \(error)", status: 1) }
        }
        app.run()
    }

    @MainActor static func finish(_ message: String, status: Int32) -> Never {
        let result = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("result.txt")
        try? message.write(to: result, atomically: true, encoding: .utf8)
        print(message)
        exit(status)
    }

    @MainActor static func stage(_ message: String) {
        let url = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("progress.txt")
        let line = "\(Date()): \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(line.utf8)); try? handle.close()
        } else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }

    @MainActor static func run() async throws {
        stage("creating WebKit view")
        var measuredHeight: CGFloat = 0
        let coordinator = MathMessageCoordinator { measuredHeight = $0 }
        let web = coordinator.makeWebView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = web
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        for _ in 0..<150 {
            if (try? await web.evaluateJavaScript("typeof window.MarginMath")) as? String == "object" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try check((try? await web.evaluateJavaScript("typeof window.MarginMath")) as? String == "object", "Offline renderer did not load")

        func render(_ text: String) async throws {
            _ = try await web.callAsyncJavaScript("return window.MarginMath.render(text, 13, '#294039');", arguments: ["text": text], in: nil, contentWorld: .page)
            try await Task.sleep(for: .milliseconds(100))
        }
        func count(_ selector: String) async throws -> Int {
            (try await web.callAsyncJavaScript("return document.querySelectorAll(selector).length;", arguments:["selector":selector], in:nil, contentWorld:.page)) as? Int ?? -1
        }
        func bodyText() async throws -> String {
            try await web.evaluateJavaScript("document.getElementById('message').textContent") as? String ?? ""
        }

        stage("renderer loaded; checking delimiters")
        let theta = #"\theta^v_{fjt}=\frac{\partial Q_{fjt}}{\partial V^v_{fjt}}\frac{V^v_{fjt}}{Q_{fjt}}=\frac{\partial\ln Q_{fjt}}{\partial\ln V^v_{fjt}},"#
        for formula in ["\\[\n\(theta)\n\\]", "$$\n\(theta)\n$$", "[\n\(theta)\n]"] {
            try await render(formula)
            try check(try await count(".katex") == 1, "Expected one rendered formula: \(formula)")
            try check(try await count(".katex-error") == 0, "Economics derivative formula failed to compile")
            try check(try await count("math") == 1, "Accessible MathML missing")
        }
        stage("checking full replies and Markdown container boundaries")
        let multilineTheta = #"\theta^v_{fjt}"# + "\n=\n" +
            #"\frac{\partial Q_{fjt}}{\partial V^v_{fjt}}"# + "\n" +
            #"\frac{V^v_{fjt}}{Q_{fjt}}"# + "\n=\n" +
            #"\frac{\partial \ln Q_{fjt}}{\partial \ln V^v_{fjt}},"#
        for delimiters in [("[", "]"), ("\\[", "\\]"), ("$$", "$$")] {
            let equation = delimiters.0 + "\n" + multilineTheta + "\n" + delimiters.1
            let following = "它表示投入增加 1% 时，产出变化的百分比。行内形式为 $d\\ln Q/d\\ln V$。"
            let completeReply = "这里的生产弹性可以写为：\n" + equation + "\n" + following
            let examples = [
                completeReply,
                "- A list item:\n" + equation + "\n" + following,
                "- A list item:\n" + equation.split(separator: "\n", omittingEmptySubsequences: false).map { "  " + $0 }.joined(separator: "\n") + "\n  " + following,
                completeReply.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
            ]
            for reply in examples {
                try await render(reply)
                try check(try await count(".katex") == 2, "A complete reply must render display and inline math without surrounding blank lines: \(reply)")
                try check(try await count(".katex-error") == 0, "Formula in prose/list/quote failed")
                try check(try await count("h1, h2") == 0, "Formula equals signs must not become Markdown headings")
                try check(try await bodyText().contains("它表示投入增加 1%"), "Following prose must remain visible")
            }
        }
        try await render("Ordinary heading\n===\n\nA paragraph.\n\nSecond heading\n---")
        try check(try await count("h1, h2") == 2, "Real Setext headings must still render normally")

        try await render(#"Inline \(x_i^2\), $\alpha+\beta$, and **important** text."#)
        try check(try await count(".katex") == 2, "Inline math delimiters failed")
        try check(try await count("strong") == 1, "Markdown emphasis failed")

        stage("checking code and currency")
        try await render("`$x$`\n\n```tex\n\\[x^2\\]\n```\n\n[\nordinary text\n]\n\nThe prices are $5 and $10.")
        try check(try await count(".katex") == 0, "Code/currency/plain brackets must remain literal text")
        try check(try await bodyText().contains("$5 and $10"), "Currency text changed")
        try check(try await count("code") == 2, "Code spans and blocks must be preserved")

        stage("checking untrusted markup and links")
        try await render(#"<script>window.pwned=true</script><img src='https://example.invalid/track' onerror='window.pwned=true'> [unsafe](javascript:alert(1)) ![sample](https://example.invalid/image.png) $\href{javascript:alert(1)}{x}$ $\includegraphics{https://example.invalid/track}$"#)
        try check(try await count("#message script, #message img, #message iframe") == 0, "Untrusted active elements entered message DOM")
        try check((try await web.evaluateJavaScript("typeof window.pwned")) as? String == "undefined", "Message script executed")
        try check(try await count("#message a") == 0, "Unsafe links entered message DOM")
        let external = try await web.evaluateJavaScript("performance.getEntriesByType('resource').filter(e => /^https?:/.test(e.name)).length") as? Int
        try check(external == 0, "Renderer attempted an external resource request")
        try await render("[Source](https://example.com/paper)\n\n- first\n- second\n\n| A | B |\n| - | - |\n| 1 | 2 |")
        let markdownCounts = try await [count("a"), count("li"), count("table")]
        try check(markdownCounts == [1, 2, 1], "Markdown links/lists/tables failed")

        stage("checking invalid and wide formulas")
        try await render("$$\\frac{1}{$$")
        try check(try await count(".katex-error") == 1, "Invalid LaTeX should remain visible as source")
        try await render("$$" + Array(repeating: "x_i+y_i", count: 40).joined(separator: "+") + "$$")
        let wide = try await web.evaluateJavaScript("(() => {let x=document.querySelector('.math-display'); return x.scrollWidth > x.clientWidth && getComputedStyle(x).overflowX === 'auto';})()") as? Bool
        try check(wide == true, "Wide formulas must scroll horizontally within the bubble")
        let fonts = try await web.evaluateJavaScript("Array.from(document.fonts).some(f => f.family.includes('KaTeX') && f.status === 'loaded')") as? Bool
        try check(fonts == true, "Bundled KaTeX fonts did not load")
        stage("checking height expansion and shrinkage")
        try await render(String(repeating: "A long reply wraps naturally inside its discussion bubble. ", count: 40))
        let longHeight = measuredHeight
        try check(longHeight > 200, "Reply height must expand beyond the WebView viewport")
        try await render("Short reply.")
        try check(measuredHeight < longHeight && measuredHeight > 10, "Reply height must shrink when content collapses")
        let overflow = try await web.evaluateJavaScript("getComputedStyle(document.documentElement).overflowY") as? String
        try check(overflow == "hidden", "Web document must not create a second vertical scrollbar")
        stage("all checks passed")
        withExtendedLifetime(coordinator) {}
    }
}
