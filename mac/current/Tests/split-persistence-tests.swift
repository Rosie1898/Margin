import AppKit
import Foundation
import SwiftUI

@main
struct SplitPersistenceTests {
    static func close(_ actual: [Double], _ expected: [Double], tolerance: Double = 0.000_001) -> Bool {
        actual.count == expected.count && zip(actual, expected).allSatisfy { abs($0 - $1) <= tolerance }
    }

    @MainActor static func makeSplit(_ proportions: [Double]?, width: CGFloat = 1600) -> (ReaderNativeSplitView, ReaderSplitView<Text, Text, Text>.Coordinator) {
        let split = ReaderNativeSplitView(frame: NSRect(x: 0, y: 0, width: width, height: 900))
        split.isVertical = true
        split.dividerStyle = .thin
        let coordinator = ReaderSplitView<Text, Text, Text>.Coordinator()
        split.delegate = coordinator
        for _ in 0..<3 { split.addSubview(NSView()) }
        split.restoreProportions(proportions)
        split.layoutPanes()
        return (split, coordinator)
    }

    @MainActor static func assertProportions(_ split: ReaderNativeSplitView, _ expected: [Double]) {
        let available = split.bounds.width - 2 * split.dividerThickness
        precondition(close(split.subviews.map { Double($0.frame.width / available) }, expected), "Unexpected pane proportions")
        precondition(abs(split.subviews.last!.frame.maxX - split.bounds.maxX) < 0.001, "Panes and dividers must fill the window exactly")
    }

    @MainActor static func main() throws {
        precondition((2...3).contains(CommandLine.arguments.count), "Usage: split-persistence-tests [PROJECT_ROOT] SCRATCH_DIRECTORY")
        let scratch = URL(fileURLWithPath: CommandLine.arguments.last!, isDirectory: true)
        let run = scratch.appendingPathComponent("split-persistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        let decoder = JSONDecoder()

        let legacy = try decoder.decode(ReaderSettings.self, from: Data("{}".utf8))
        precondition(legacy.paneProportions == nil, "An existing library without pane settings must use the default")
        precondition(close(ReaderSettings.normalizedPaneProportions([1, 3, 1])!, [0.2, 0.6, 0.2]))
        let invalid: [[Double]?] = [nil, [], [1, 2], [1, 2, 3, 4], [0, 1, 1], [-1, 2, 3], [.nan, 1, 1], [.infinity, 1, 1], [.greatestFiniteMagnitude, .greatestFiniteMagnitude, 1]]
        for value in invalid {
            precondition(ReaderSettings.normalizedPaneProportions(value) == nil, "Invalid proportions must fall back safely")
        }
        for malformed in ["null", "\"wrong type\"", "[1,\"bad\",1]", "[1,2]", "[0,1,1]", "[-1,3,1]"] {
            let json = Data("{\"language\":\"ja\",\"textSize\":17,\"paneProportions\":\(malformed)}".utf8)
            let settings = try decoder.decode(ReaderSettings.self, from: json)
            precondition(settings.paneProportions == nil)
            precondition(settings.language == .ja && settings.textSize == 17, "Bad layout data must not discard other preferences")
        }
        var settings = ReaderSettings()
        settings.paneProportions = [3, 5, 2]
        settings.normalize()
        let roundTrip = try decoder.decode(ReaderSettings.self, from: JSONEncoder().encode(settings))
        precondition(roundTrip == settings && close(roundTrip.paneProportions!, [0.3, 0.5, 0.2]))

        let (fresh, freshDelegate) = makeSplit(nil)
        let (restored, restoredDelegate) = makeSplit(roundTrip.paneProportions)
        // NSSplitView.delegate is weak; retain delegates for all native layout operations.
        try withExtendedLifetime([freshDelegate, restoredDelegate]) {
            assertProportions(fresh, [0.2, 0.6, 0.2])
            assertProportions(restored, [0.3, 0.5, 0.2])
            var persistenceCalls = 0
            restored.onProportionsChange = { _ in persistenceCalls += 1 }
            for _ in 0..<3 { restored.layoutPanes() }
            restored.setFrameSize(NSSize(width: 1000, height: 700))
            restored.layoutPanes()
            precondition(zip(restored.subviews.map(\.frame.width), [180.0, 420.0, 200.0]).allSatisfy { $0 >= $1 }, "Resizing must respect minimum widths")
            precondition(abs(restored.subviews.last!.frame.maxX - restored.bounds.maxX) < 0.001)
            restored.setFrameSize(NSSize(width: 1600, height: 900))
            restored.layoutPanes()
            assertProportions(restored, [0.3, 0.5, 0.2])
            precondition(persistenceCalls == 0, "Automatic and constrained layout must not save a new preference")

            // A drag's intermediate in-memory updates must remain local. The
            // completed native mouse drag is covered in the actual app UI check.
            restored.setPosition(360, ofDividerAt: 0)
            restored.rememberUserProportions()
            let dragged = restored.subviews.map { Double($0.frame.width / (restored.bounds.width - 2 * restored.dividerThickness)) }
            restored.layoutPanes()
            assertProportions(restored, dragged)
            precondition(persistenceCalls == 0, "Intermediate divider updates must not write to disk")

            let store = ReaderStore(dataDirectory: run)
            store.library.documents["fixture"] = DocumentRecord(id: "fixture", path: "/fixture/unchanged.pdf", title: "Unchanged", page: 5)
            store.library.selectedPath = "/fixture/unchanged.pdf"
            store.updateSettings { $0.language = .ja; $0.textSize = 17; $0.paneProportions = dragged }
            precondition(store.error == nil, store.error ?? "")
            let savedBytes = try Data(contentsOf: run.appendingPathComponent("library.json"))
            let reopened = ReaderStore(dataDirectory: run)
            precondition(reopened.error == nil, reopened.error ?? "")
            precondition(close(reopened.library.settings.paneProportions!, dragged))
            precondition(reopened.library.settings.language == .ja && reopened.library.settings.textSize == 17)
            precondition(reopened.library.documents["fixture"]?.page == 5 && reopened.library.selectedPath == "/fixture/unchanged.pdf")
            let (relaunched, relaunchDelegate) = makeSplit(reopened.library.settings.paneProportions)
            withExtendedLifetime(relaunchDelegate) { assertProportions(relaunched, dragged) }
            let afterReopen = try Data(contentsOf: run.appendingPathComponent("library.json"))
            precondition(afterReopen == savedBytes, "Reading and restoring the layout must not overwrite library data")
        }
        print("SPLIT_PERSISTENCE_TESTS_PASSED: legacy default; validated normalization; tolerant decoding; settings round trip; native restored widths; clamp then expand; no automatic writes; intermediate drag local; store and split relaunch; other preferences and reading position retained")
    }
}
