import Foundation
import PDFKit

private final class ContextPage: PDFPage {
    let content: String
    init(_ content: String) { self.content = content; super.init() }
    override var string: String? { content }
}
private final class ContextDocument: PDFDocument {
    let samples: [ContextPage]
    init(_ texts: [String]) { samples = texts.map(ContextPage.init); super.init() }
    override var pageCount: Int { samples.count }
    override func page(at index: Int) -> PDFPage? { samples.indices.contains(index) ? samples[index] : nil }
}

@main
struct ContextTests {
    @MainActor static func main() throws {
        var annotation = ReaderAnnotation(kind: .question, quote: "selected passage", rects: [PageRect(page: 1, rect: CGRect(x: 0,y: 0,width: 20,height: 10))], color: .mint, pageText: "legacy clipped text")
        let pdf = ContextDocument(["Page one.", "Complete page two.", "Page three.", "Page four."])
        let current = try ChatReference.build(preference: ChatContextPreference(), annotation: annotation, document: pdf)
        precondition(current.summary.pages == [2] && current.texts == ["Complete page two."])
        let selection = try ChatReference.build(preference: ChatContextPreference(scope: .selection), annotation: annotation, document: pdf)
        precondition(selection.texts.isEmpty && selection.summary.pages.isEmpty)
        let serialized = String(data: try JSONSerialization.data(withJSONObject: selection.payload), encoding: .utf8)!
        precondition(!serialized.contains("legacy") && !serialized.contains("Complete"))
        let firstPageNeighbors = try ChatContextPreference(scope: .nearby).pages(anchor: 1, total: 4)
        let lastPageNeighbors = try ChatContextPreference(scope: .nearby).pages(anchor: 4, total: 4)
        precondition(firstPageNeighbors == [1,2])
        precondition(lastPageNeighbors == [3,4])
        let custom = ChatContextPreference(scope: .custom, pageRange: "3–4, 1, 3")
        let selected = try ChatReference.build(preference: custom, annotation: annotation, document: pdf)
        precondition(selected.summary.pages == [1,3,4] && selected.texts == ["Page one.", "Page three.", "Page four."])
        let full = try ChatReference.build(preference: ChatContextPreference(scope: .document), annotation: annotation, document: pdf)
        precondition(full.summary.pages == [1,2,3,4])
        for invalid in ["", "0", "2-1", "1-5", "1,,2", "one", "1-2-3"] {
            do { _ = try ChatContextPreference(scope: .custom,pageRange: invalid).pages(anchor: 2,total: 4); preconditionFailure(invalid) }
            catch is ChatContextError {}
        }
        do { _ = try ChatContextPreference(scope: .document).pages(anchor: 1,total: 201); preconditionFailure("too many pages") }
        catch is ChatContextError {}
        for texts in [["one", ""], ["one", String(repeating:"😀",count:50_001)]] {
            do { _ = try ChatReference.build(preference:ChatContextPreference(),annotation:annotation,document:ContextDocument(texts)); preconditionFailure("invalid text") }
            catch is ChatContextError {}
        }
        annotation.contextPreference = custom
        annotation.messages = [ChatMessage(role:"user",text:"Question",reference:selected.summary)]
        let restored = try JSONDecoder().decode(ReaderAnnotation.self,from:JSONEncoder().encode(annotation))
        precondition(restored.contextPreference == custom && restored.messages[0].reference == selected.summary)
        var old = try JSONSerialization.jsonObject(with:JSONEncoder().encode(annotation)) as! [String:Any]
        old.removeValue(forKey:"contextPreference")
        var oldMessages = old["messages"] as! [[String:Any]]
        oldMessages[0].removeValue(forKey:"reference"); old["messages"] = oldMessages
        let legacy = try JSONDecoder().decode(ReaderAnnotation.self,from:JSONSerialization.data(withJSONObject:old))
        precondition(legacy.contextPreference == nil && legacy.messages.count == 1 && legacy.messages[0].reference == nil)
        print("CONTEXT_TESTS_PASSED: scope extraction, page ranges, no selection leakage, bounded UTF-16 text, missing OCR, saved settings and legacy annotations")
    }
}
