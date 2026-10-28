import SwiftUI

@MainActor
private final class ChatContextPresentation: ObservableObject {
    @Published var isOpen = false
}

struct ChatContextControl: View {
    @ObservedObject var store: ReaderStore
    var annotation: ReaderAnnotation
    @StateObject private var presentation = ChatContextPresentation()
    private var preference: ChatContextPreference { annotation.contextPreference ?? ChatContextPreference() }
    private func T(_ text: String) -> String { store.t(text) }
    private var theme: ReaderTheme { ReaderTheme(store.library.settings.themeHex) }
    private var tint: Color { Color(hex: theme.accent) }

    var body: some View {
        Button { presentation.isOpen.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "doc.text.magnifyingglass")
                Text(T(preference.scope.label)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8))
            }.padding(.vertical, 5).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(tint)
        .font(.system(size: max(10, store.library.settings.textSize - 2)))
        .help(T("AI 参考范围"))
        .accessibilityLabel(T("AI 参考范围") + ": " + T(preference.scope.label))
        .popover(isPresented: $presentation.isOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 14) {
                Text(T("AI 参考范围")).font(.headline)
                Picker(T("AI 参考范围"), selection: Binding(get: { preference.scope }, set: { scope in
                    store.mutateAnnotation(annotation.id) {
                        var p = $0.contextPreference ?? ChatContextPreference()
                        p.scope = scope
                        if scope == .custom && p.pageRange.isEmpty { p.pageRange = String(annotation.page + 1) }
                        $0.contextPreference = p
                    }
                })) {
                    ForEach(ChatContextScope.allCases) { scope in Text(T(scope.label)).tag(scope) }
                }.pickerStyle(.radioGroup).labelsHidden()
                if preference.scope == .custom {
                    TextField(T("例如 1-3, 5"), text: Binding(get: { preference.pageRange }, set: { value in
                        store.mutateAnnotation(annotation.id) {
                            var p = $0.contextPreference ?? ChatContextPreference()
                            p.pageRange = value; $0.contextPreference = p
                        }
                    })).textFieldStyle(.roundedBorder)
                    Text(T("使用 PDF 页序，与阅读区底部页码一致。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let pages = try? preference.pages(anchor: annotation.page + 1, total: store.pageCount), !pages.isEmpty {
                    Text(T("参考页码") + ": " + ChatReferenceSummary.compactPages(pages))
                        .font(.caption).foregroundStyle(tint).lineLimit(3)
                }
                Text(T("每次发送都会附加选中文字，并保留本条讨论历史。"))
                    .font(.caption).foregroundStyle(.secondary)
                HStack { Spacer(); Button(T("完成")) { presentation.isOpen = false }.buttonStyle(.borderedProminent) }
            }.padding(18).frame(width: 300).background(Color(hex:theme.card))
                .foregroundStyle(Color(hex:theme.ink)).tint(tint)
                .preferredColorScheme(theme.dark ? .dark : .light)
        }
        .disabled(store.sending.contains(annotation.id))
    }
}

extension ChatReferenceSummary {
    static func compactPages(_ pages: [Int]) -> String {
        guard let first = pages.first else { return "" }
        var start = first, end = first, pieces: [String] = []
        func label() -> String { start == end ? String(start) : "\(start)–\(end)" }
        for page in pages.dropFirst() {
            if page == end + 1 { end = page }
            else { pieces.append(label()); start = page; end = page }
        }
        pieces.append(label())
        return pieces.joined(separator: ", ")
    }
}
