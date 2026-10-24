import SwiftUI
import AppKit

extension Notification.Name {
    static let marginFind = Notification.Name("marginFind")
    static let marginFindNext = Notification.Name("marginFindNext")
    static let marginFindPrevious = Notification.Name("marginFindPrevious")
}

struct PDFSearchBar: View {
    @ObservedObject var search: PDFSearchState
    var focusToken: Int
    var localize: (String) -> String
    var close: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            PDFSearchField(text: $search.query, focusToken:focusToken, placeholder:localize("在文档中查找…"), next:search.next, previous:search.previous, close:close)
                .frame(minWidth:100, maxWidth:.infinity).frame(height:26)
            if search.isSearching {
                ProgressView().controlSize(.mini).help(localize("正在搜索…"))
            } else if !search.query.isEmpty {
                Text(search.matchCount == 0 ? localize("未找到匹配") : "\(search.currentMatch) / \(search.matchCount)")
                    .font(.system(size:11,design:.monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
            Button(action:search.previous) { Image(systemName:"chevron.up").frame(width:22,height:24).contentShape(Rectangle()) }
                .help(localize("上一处")).accessibilityLabel(localize("上一处")).disabled(search.matchCount == 0)
            Button(action:search.next) { Image(systemName:"chevron.down").frame(width:22,height:24).contentShape(Rectangle()) }
                .help(localize("下一处")).accessibilityLabel(localize("下一处")).disabled(search.matchCount == 0)
            Button(action:close) { Image(systemName:"xmark").frame(width:22,height:24).contentShape(Rectangle()) }
                .help(localize("关闭搜索")).accessibilityLabel(localize("关闭搜索"))
        }.buttonStyle(.plain).padding(.horizontal,18).padding(.vertical,9)
            .background(Color(hex:"F1F6F2"))
            .help(localize("搜索仅包含已有文字及已完成 OCR 的页面。"))
    }
}

private struct PDFSearchField: NSViewRepresentable {
    @Binding var text: String
    var focusToken: Int
    var placeholder: String
    var next: () -> Void
    var previous: () -> Void
    var close: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context:Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.setContentHuggingPriority(.defaultLow,for:.horizontal)
        return field
    }
    func updateNSView(_ field:NSSearchField,context:Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        if context.coordinator.lastFocus != focusToken {
            context.coordinator.lastFocus = focusToken
            DispatchQueue.main.async { [weak field] in
                guard let field, let window = field.window else { return }
                window.makeFirstResponder(field)
                field.selectText(nil)
            }
        }
    }
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent:PDFSearchField
        var lastFocus:Int?
        init(_ parent:PDFSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification:Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }
        func control(_ control:NSControl,textView:NSTextView,doCommandBy commandSelector:Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { parent.previous() } else { parent.next() }
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) { parent.close(); return true }
            return false
        }
    }
}
