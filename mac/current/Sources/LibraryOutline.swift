import Foundation

/// Reconstruct the original directory hierarchy from paths relative to the chosen root.
/// Only branches containing PDFs are shown; filesystem names are never rewritten.
struct LibraryOutlineNode: Identifiable {
    let relativePath: String
    let name: String
    let file: LibraryFile?
    let children: [LibraryOutlineNode]
    var id: String { relativePath }
    var isFolder: Bool { file == nil }
    var pdfCount: Int { file == nil ? children.reduce(0) { $0 + $1.pdfCount } : 1 }

    static func make(files: [LibraryFile], search: String = "") -> [LibraryOutlineNode] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = files.filter { query.isEmpty || $0.relativePath.localizedCaseInsensitiveContains(query) }
        return branches(matching, prefix: "")
    }

    private static func branches(_ files: [LibraryFile], prefix: String) -> [LibraryOutlineNode] {
        let groups = Dictionary(grouping: files) { file in
            String(file.relativePath.dropFirst(prefix.count).split(separator: "/", maxSplits: 1)[0])
        }
        return groups.map { name, descendants in
            let path = prefix + name
            if let file = descendants.first(where: { $0.relativePath == path }) {
                return LibraryOutlineNode(relativePath: path, name: name, file: file, children: [])
            }
            return LibraryOutlineNode(relativePath: path, name: name, file: nil,
                                      children: branches(descendants, prefix: path + "/"))
        }.sorted {
            if $0.isFolder != $1.isFolder { return $0.isFolder }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func ancestors(of file: LibraryFile) -> Set<String> {
        let parts = file.relativePath.split(separator: "/").dropLast()
        guard !parts.isEmpty else { return [] }
        return Set((1...parts.count).map { parts.prefix($0).joined(separator: "/") })
    }
}

struct LibraryOutlineRow: Identifiable {
    let node: LibraryOutlineNode
    let depth: Int
    let expanded: Bool
    var id: String { node.id }

    static func visible(nodes: [LibraryOutlineNode], expandedFolders: Set<String>,
                        searchActive: Bool = false, collapsedSearchFolders: Set<String> = [], depth: Int = 0) -> [LibraryOutlineRow] {
        nodes.flatMap { node -> [LibraryOutlineRow] in
            let expanded = node.isFolder && (searchActive ? !collapsedSearchFolders.contains(node.id) : expandedFolders.contains(node.id))
            let row = LibraryOutlineRow(node:node,depth:depth,expanded:expanded)
            return [row] + (expanded ? visible(nodes:node.children,expandedFolders:expandedFolders,
                                              searchActive:searchActive,collapsedSearchFolders:collapsedSearchFolders,depth:depth + 1) : [])
        }
    }
}
