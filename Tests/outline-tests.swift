import Foundation

@main
struct OutlineTests {
    static func main() {
        let root = URL(fileURLWithPath:"/fixture")
        let paths = ["root.pdf", "Papers/A.pdf", "Papers/2025/A.pdf", "Papers/2025/B.PDF", "Slides/Week 10.pdf", "Slides/Week 2.pdf", "论文/增长.pdf"]
        let files = paths.map { LibraryFile(url:root.appendingPathComponent($0),relativePath:$0) }
        let tree = LibraryOutlineNode.make(files:files)
        precondition(tree.count == 4 && tree.last?.file?.relativePath == "root.pdf")
        precondition(tree.reduce(0){$0 + $1.pdfCount} == paths.count)
        let papers = tree.first { $0.name == "Papers" }!
        precondition(papers.children.map(\.name) == ["2025","A.pdf"])
        precondition(papers.children.first?.children.count == 2)
        precondition(LibraryOutlineNode.ancestors(of:files[2]) == ["Papers","Papers/2025"])
        precondition(LibraryOutlineNode.ancestors(of:files[0]).isEmpty)
        precondition(LibraryOutlineRow.visible(nodes:tree,expandedFolders:[]).count == 4)
        let expanded = LibraryOutlineRow.visible(nodes:tree,expandedFolders:["Papers","Papers/2025"])
        precondition(expanded.contains { $0.node.relativePath == "Papers/2025/A.pdf" && $0.depth == 2 })
        precondition(Set(expanded.map(\.id)).count == expanded.count, "Repeated filenames in separate folders need distinct row IDs")
        let search = LibraryOutlineNode.make(files:files,search:"A.pdf")
        precondition(search.count == 1 && search[0].name == "Papers")
        let searched = LibraryOutlineRow.visible(nodes:search,expandedFolders:[],searchActive:true)
        precondition(searched.filter { $0.node.file != nil }.count == 2)
        let collapsedSearch = LibraryOutlineRow.visible(nodes:search,expandedFolders:[],searchActive:true,collapsedSearchFolders:["Papers/2025"])
        precondition(collapsedSearch.filter { $0.node.file != nil }.count == 1)
        precondition(LibraryOutlineNode.make(files:files,search:"no match").isEmpty)
        precondition(tree.first { $0.name == "Slides" }!.children.map(\.name) == ["Week 2.pdf","Week 10.pdf"])
        print("OUTLINE_TESTS_PASSED: directory hierarchy, duplicates, Unicode, natural sorting, expansion, nested search and collapse")
    }
}
