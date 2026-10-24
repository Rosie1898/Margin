import AppKit
import Combine
import PDFKit

/// Searches the document's native text, including installed OCR pages. Search
/// highlights are transient PDFSelections and never become saved annotations.
@MainActor
final class PDFSearchState: ObservableObject {
    @Published var query = "" {
        didSet { if query != oldValue { scheduleSearch() } }
    }
    @Published private(set) var matchCount = 0
    @Published private(set) var currentMatch = 0
    @Published private(set) var isSearching = false

    private(set) var matches: [PDFSelection] = []
    var activeSelection: PDFSelection? {
        guard currentMatch > 0, currentMatch <= matches.count else { return nil }
        return matches[currentMatch - 1]
    }
    var onResultsChanged: ((_ navigate: Bool) -> Void)?
    private weak var document: PDFDocument?
    private var documentID: String?
    private var revision = 0
    private var task: Task<Void, Never>?
    private var generation = 0

    func next() { move(by: 1) }
    func previous() { move(by: -1) }

    func clear() {
        if query.isEmpty { resetResults() }
        else { query = "" }
    }

    /// Called from the canvas update. Published values change on the next run-loop
    /// turn, after SwiftUI finishes its view update.
    func attach(document: PDFDocument, id: String, revision: Int) {
        let changed = self.document !== document || documentID != id
        guard changed || self.revision != revision else { return }
        task?.cancel()
        generation += 1
        let expected = generation
        self.document = document
        documentID = id
        self.revision = revision
        task = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.generation == expected, !Task.isCancelled else { return }
            if changed { self.clear() }
            else { self.scheduleSearch(debounce: false, navigate: false) }
        }
    }

    func detach() {
        task?.cancel()
        generation += 1
        document = nil
        documentID = nil
        onResultsChanged = nil
    }

    private func move(by amount: Int) {
        guard !matches.isEmpty else { return }
        currentMatch = ((currentMatch - 1 + amount + matches.count) % matches.count) + 1
        onResultsChanged?(true)
    }

    private func resetResults() {
        task?.cancel()
        generation += 1
        matches = []
        matchCount = 0
        currentMatch = 0
        isSearching = false
        onResultsChanged?(false)
    }

    private func scheduleSearch(debounce: Bool = true, navigate: Bool = true) {
        resetResults()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let document else { return }
        isSearching = true
        let expected = generation
        task = Task { @MainActor [weak self, weak document] in
            if debounce { try? await Task.sleep(for: .milliseconds(180)) }
            guard let self, let document, !Task.isCancelled, self.generation == expected else { return }
            var found: [PDFSelection] = []
            // Yield between pages (and batches on dense pages) so a new query,
            // document switch, or OCR replacement can cancel stale work promptly.
            for index in 0..<document.pageCount {
                guard !Task.isCancelled, self.generation == expected else { return }
                guard let page = document.page(at: index), let pageText = page.string else { continue }
                let content = pageText as NSString
                var remaining = NSRange(location: 0, length: content.length)
                while remaining.length > 0 {
                    let range = content.range(of: text, options: [.caseInsensitive], range: remaining)
                    guard range.location != NSNotFound, range.length > 0 else { break }
                    if let selection = page.selection(for: range), !selection.bounds(for: page).isEmpty {
                        found.append(selection)
                    }
                    let next = NSMaxRange(range)
                    remaining = NSRange(location: next, length: content.length - next)
                    if found.count.isMultiple(of: 64) {
                        await Task.yield()
                        guard !Task.isCancelled, self.generation == expected else { return }
                    }
                }
                await Task.yield()
            }
            guard !Task.isCancelled, self.generation == expected else { return }
            self.matches = found
            self.matchCount = found.count
            self.currentMatch = found.isEmpty ? 0 : 1
            self.isSearching = false
            self.onResultsChanged?(navigate)
        }
    }
}
