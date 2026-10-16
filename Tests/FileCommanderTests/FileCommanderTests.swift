import Foundation
import Testing
@testable import FileCommander

// MARK: - Helpers

private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("oc-tests-\(UUID().uuidString)")
        .standardizedFileURL
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
}

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

@MainActor
private func run(_ center: JobCenter, _ kind: FileJob.Kind, _ sources: [URL], to dir: URL,
                 onConflict: ConflictChoice? = nil) async -> JobResult {
    await withCheckedContinuation { cont in
        center.start(kind, sources: sources, to: dir) { cont.resume(returning: $0) }
        if let onConflict {
            // Answer conflict prompts the way the sheet would.
            Task { @MainActor in
                while center.jobs.first?.isActive == true {
                    if let job = center.conflictJob { job.resolveConflict(onConflict, applyToAll: true) }
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
        }
    }
}

@MainActor
private func loaded(_ column: Column) async {
    await withCheckedContinuation { cont in column.whenLoaded { _ in cont.resume() } }
}

// MARK: - Copy engine

@MainActor
@Suite struct CopyEngineTests {
    @Test func copiesNestedTreeWithMetadata() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let src = root.appendingPathComponent("src/Project")
        try write("hello", to: src.appendingPathComponent("a.txt"))
        try write("deep", to: src.appendingPathComponent("sub/inner/b.txt"))
        // Finder-style extended attribute (tags live in xattrs) must survive the copy.
        _ = src.appendingPathComponent("a.txt").withUnsafeFileSystemRepresentation { path in
            setxattr(path, "com.example.test", "x", 1, 0, 0)
        }
        let dst = root.appendingPathComponent("dst")
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)

        let center = JobCenter()
        let result = await run(center, .copy, [src], to: dst)

        #expect(result.errors.isEmpty)
        #expect(result.created.map(\.lastPathComponent) == ["Project"])
        #expect(read(dst.appendingPathComponent("Project/a.txt")) == "hello")
        #expect(read(dst.appendingPathComponent("Project/sub/inner/b.txt")) == "deep")
        #expect(read(src.appendingPathComponent("a.txt")) == "hello")   // source untouched
        let size = dst.appendingPathComponent("Project/a.txt").withUnsafeFileSystemRepresentation {
            getxattr($0, "com.example.test", nil, 0, 0, 0)
        }
        #expect(size == 1)
        let job = try #require(center.jobs.first)
        #expect(job.state == .done)
        #expect(job.totalFiles == 2)
        #expect(job.totalBytes == 9)
        #expect(job.fraction == 1)
    }

    @Test func moveWithinVolumeRenames() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("one.txt"), b = root.appendingPathComponent("two.txt")
        try write("1", to: a)
        try write("2", to: b)
        let dst = root.appendingPathComponent("dst")
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)

        let result = await run(JobCenter(), .move, [a, b], to: dst)

        #expect(result.errors.isEmpty)
        #expect(result.moved.count == 2)
        #expect(!FileManager.default.fileExists(atPath: a.path))
        #expect(read(dst.appendingPathComponent("two.txt")) == "2")
    }

    @Test func duplicateInSameFolderKeepsBoth() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("note.txt")
        try write("n", to: a)

        let result = await run(JobCenter(), .copy, [a], to: root)
        #expect(result.created.map(\.lastPathComponent) == ["note copy.txt"])
        let again = await run(JobCenter(), .copy, [a], to: root)
        #expect(again.created.map(\.lastPathComponent) == ["note copy 2.txt"])
    }

    @Test func conflictSkipAndKeepBoth() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let src = root.appendingPathComponent("src/report.txt")
        try write("new", to: src)
        let existing = root.appendingPathComponent("dst/report.txt")
        try write("old", to: existing)
        let dst = existing.deletingLastPathComponent()

        let skipped = await run(JobCenter(), .copy, [src], to: dst, onConflict: .skip)
        #expect(skipped.created.isEmpty)
        #expect(read(existing) == "old")

        let both = await run(JobCenter(), .copy, [src], to: dst, onConflict: .keepBoth)
        #expect(both.created.map(\.lastPathComponent) == ["report copy.txt"])
        #expect(read(existing) == "old")
        #expect(read(dst.appendingPathComponent("report copy.txt")) == "new")
    }

    @Test func pauseThenCancelLeavesNoPartialCopy() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let src = root.appendingPathComponent("src/Big")
        for i in 0..<200 { try write(String(repeating: "x", count: 1000), to: src.appendingPathComponent("f\(i).txt")) }
        let dst = root.appendingPathComponent("dst")
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)

        let center = JobCenter()
        let result: JobResult = await withCheckedContinuation { cont in
            center.start(.copy, sources: [src], to: dst) { cont.resume(returning: $0) }
            let job = center.jobs[0]
            job.control.paused = true                 // worker parks at its first checkpoint
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                #expect(job.isActive)
                #expect((try? FileManager.default.contentsOfDirectory(atPath: dst.path))?.isEmpty == true)
                job.cancel()
            }
        }
        #expect(result.cancelled)
        #expect(result.created.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dst.appendingPathComponent("Big").path))
        #expect(center.jobs[0].state == .cancelled)
    }

    @Test func refusesNothingWhenMovingIntoSameFolder() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("x.txt")
        try write("x", to: a)
        let result = await run(JobCenter(), .move, [a], to: root)
        #expect(result.moved.isEmpty)
        #expect(read(a) == "x")
    }
}

// MARK: - Undo

@Suite struct UndoTests {
    @Test func moveUndoRedoRoundTrip() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.txt"), b = root.appendingPathComponent("b.txt")
        try write("data", to: a)

        let undo = try FileAction.move([MovePair(from: a, to: b)]).perform()
        #expect(read(b) == "data")
        let redo = try undo.perform()
        #expect(read(a) == "data")
        #expect(!FileManager.default.fileExists(atPath: b.path))
        _ = try redo.perform()
        #expect(read(b) == "data")
    }

    @Test func moveRefusesToOverwrite() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.txt"), b = root.appendingPathComponent("b.txt")
        try write("a", to: a)
        try write("b", to: b)
        #expect(throws: (any Error).self) { try FileAction.move([MovePair(from: a, to: b)]).perform() }
        #expect(read(b) == "b")
    }

    @Test func trashIsUndoable() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("trash-me-\(UUID().uuidString).txt")
        try write("keep", to: a)

        let restore = try FileAction.trash([a]).perform()
        #expect(!FileManager.default.fileExists(atPath: a.path))
        _ = try restore.perform()            // puts it back, leaving nothing in the Trash
        #expect(read(a) == "keep")
    }

    @Test func groupUndoesInReverseOrder() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b"), c = root.appendingPathComponent("c")
        try write("1", to: a)
        let undo = try FileAction.group([
            .move([MovePair(from: a, to: b)]),
            .move([MovePair(from: b, to: c)]),
        ]).perform()
        #expect(read(c) == "1")
        _ = try undo.perform()
        #expect(read(a) == "1")
        #expect(!FileManager.default.fileExists(atPath: b.path))
    }
}

// MARK: - Selection

@MainActor
@Suite struct SelectionTests {
    private func fixture() throws -> URL {
        let root = try makeTempDir()
        for name in ["a.pdf", "b.pdf", "c.txt", "d.txt", "e.jpg"] {
            try write(name, to: root.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        try write("inside", to: root.appendingPathComponent("Folder/inner.txt"))
        return root
    }

    @Test func clickShiftAndCommandSelection() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let pane = Pane(url: root, showHidden: false)
        await loaded(pane.columns[0])
        let items = pane.columns[0].items
        #expect(items.map(\.name) == ["Folder", "a.pdf", "b.pdf", "c.txt", "d.txt", "e.jpg"])

        pane.select(items[1], in: 0)
        pane.extend(to: items[3], in: 0)
        #expect(pane.selectedItems.map(\.name) == ["a.pdf", "b.pdf", "c.txt"])

        pane.toggle(items[2], in: 0)
        #expect(pane.selectedItems.map(\.name) == ["a.pdf", "c.txt"])

        pane.moveSelection(1, extending: true)  // anchor is b.pdf after the ⌘-click
        #expect(pane.selectedItems.map(\.name) == ["b.pdf", "c.txt"])
    }

    @Test func folderOpensColumnOnlyForSingleSelection() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let pane = Pane(url: root, showHidden: false)
        await loaded(pane.columns[0])
        let folder = pane.columns[0].items[0]

        pane.select(folder, in: 0)
        #expect(pane.columns.count == 2)
        await loaded(pane.columns[1])
        #expect(pane.columns[1].items.map(\.name) == ["inner.txt"])

        pane.toggle(pane.columns[0].items[1], in: 0)   // now two selected
        #expect(pane.columns.count == 1)
    }

    @Test func patternSelectionAndInvert() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let pane = Pane(url: root, showHidden: false)
        await loaded(pane.columns[0])

        pane.selectMatching("*.pdf; *.JPG", add: true)
        #expect(Set(pane.selectedItems.map(\.name)) == ["a.pdf", "b.pdf", "e.jpg"])
        pane.selectMatching("b*", add: false)
        #expect(Set(pane.selectedItems.map(\.name)) == ["a.pdf", "e.jpg"])
        pane.invertSelection()
        #expect(Set(pane.selectedItems.map(\.name)) == ["Folder", "b.pdf", "c.txt", "d.txt"])
        pane.selectAll()
        #expect(pane.selectedItems.count == 6)
    }

    @Test func goUpKeepsChildSelected() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Folder")
        let pane = Pane(url: folder, showHidden: false)
        await loaded(pane.columns[0])
        pane.goUp()
        await loaded(pane.columns[0])
        #expect(pane.rootURL.path == root.path)
        #expect(pane.columns[0].cursorItem?.name == "Folder")
        #expect(pane.columns.count == 2)
        #expect(pane.canGoBack)
    }

    @Test func tabsAddCloseAndCycle() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let side = PaneSide(tabs: [Pane(url: home, showHidden: false)])
        side.add(Pane(url: home, showHidden: false))
        side.add(Pane(url: home, showHidden: false))
        #expect(side.tabs.count == 3 && side.selected == 2)
        side.cycle(1)
        #expect(side.selected == 0)
        side.close(0)
        #expect(side.tabs.count == 2 && side.selected == 0)
        side.close(1)
        side.close(0)                     // never closes the last tab
        #expect(side.tabs.count == 1)
    }
}

// MARK: - Workspaces

@MainActor
@Suite struct WorkspaceTests {
    @Test func captureAndApplyRoundTrip() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("A"), b = root.appendingPathComponent("B"), c = root.appendingPathComponent("C")
        for d in [a, b, c] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }

        let model = AppModel()
        model.sides = [PaneSide(tabs: [model.makePane(a), model.makePane(b)], selected: 1),
                       PaneSide(tabs: [model.makePane(c)])]
        model.dualPane = false
        let ws = model.captureWorkspace(named: "Test")
        let decoded = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(ws))

        model.sides = [PaneSide(tabs: [model.makePane(c)]), PaneSide(tabs: [model.makePane(c)])]
        model.dualPane = true
        model.apply(decoded)

        #expect(model.sides[0].tabs.map(\.rootURL.path) == [a.path, b.path])
        #expect(model.sides[0].selected == 1)
        #expect(model.sides[1].tabs.map(\.rootURL.path) == [c.path])
        #expect(model.dualPane == false)
    }

    @Test func swapKeepsFocusOnTheSameFolder() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("A"), b = root.appendingPathComponent("B")
        for d in [a, b] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let model = AppModel()
        model.sides = [PaneSide(tabs: [model.makePane(a)]), PaneSide(tabs: [model.makePane(b)])]
        model.dualPane = true
        model.activePane = 0
        model.swapPanes()
        #expect(model.sides[1].current.rootURL.path == a.path)
        #expect(model.active.rootURL.path == a.path)      // still working in A, now on the right
    }

    @Test func applySkipsFoldersThatNoLongerExist() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel()
        let before = model.sides[0].tabs.map(\.rootURL.path)
        model.apply(Workspace(name: "gone", left: [root.appendingPathComponent("missing").path], right: [],
                              leftSelected: 0, rightSelected: 0, dualPane: true))
        #expect(model.sides[0].tabs.map(\.rootURL.path) == before)
    }
}

// MARK: - Matching

@Suite struct MatchingTests {
    @Test func glob() {
        #expect(globMatch("*.pdf", "Report.PDF"))
        #expect(globMatch("IMG_??.jpg", "img_01.jpg"))
        #expect(!globMatch("*.pdf", "notes.txt"))
    }

    @Test func fuzzy() {
        #expect(fuzzyScore("dl", "Downloads") != nil)
        #expect(fuzzyScore("xyz", "Downloads") == nil)
        // Word-start and consecutive matches beat scattered ones.
        let tight = fuzzyScore("ct", "CourtTracker")!
        let loose = fuzzyScore("ct", "documents-archive")!
        #expect(tight > loose)
        #expect(fuzzyScore("", "anything") == 0)
        #expect(fuzzyScore("swp", "Undo Copy") == nil)
        #expect(fuzzyScore("swp", "Swap Panes")! > fuzzyScore("swp", "Switch to Other Pane")!)
        #expect(fuzzyScore("ct", "CourtTracker")! > fuzzyScore("ct", "contract")!)   // camelCase hump
        #expect(fuzzyScore("aip", "AI-Projects") != nil)
    }
}

// MARK: - Batch rename

@Suite struct RenameTests {
    private func files(_ names: [String]) throws -> (URL, [URL]) {
        let root = try makeTempDir()
        let urls = try names.map { n -> URL in
            let u = root.appendingPathComponent(n)
            try write(n, to: u)
            return u
        }
        return (root, urls)
    }

    @Test func placeholdersAndCounter() throws {
        let (root, urls) = try files(["IMG_0042.JPG", "IMG_0043.JPG", "notes"])
        defer { try? FileManager.default.removeItem(at: root) }
        var o = RenameOptions()
        o.nameMask = "Trip_[C]_[N5-8]"
        o.counterStart = 7
        o.counterDigits = 3
        o.textCase = .lower
        let rows = RenamePlan.compute(urls, o)
        #expect(rows.map(\.newName) == ["trip_007_0042.jpg", "trip_008_0043.jpg", "trip_009_s"])
        #expect(rows.allSatisfy { $0.problem == nil })
    }

    @Test func substringsFromTheEndAndParent() throws {
        let (root, urls) = try files(["report-final.txt"])
        defer { try? FileManager.default.removeItem(at: root) }
        var o = RenameOptions()
        o.nameMask = "[N-5-]_[N1]_[P]"
        let name = RenamePlan.compute(urls, o)[0].newName
        #expect(name == "final_r_\(root.lastPathComponent).txt")
    }

    @Test func findReplacePlainAndRegex() throws {
        let (root, urls) = try files(["Draft v1 copy.txt", "Draft v2 copy.txt"])
        defer { try? FileManager.default.removeItem(at: root) }
        var o = RenameOptions()
        o.find = " copy"
        o.replace = ""
        #expect(RenamePlan.compute(urls, o).map(\.newName) == ["Draft v1.txt", "Draft v2.txt"])
        o.regex = true
        o.find = #"v(\d) copy"#
        o.replace = "rev$1"
        #expect(RenamePlan.compute(urls, o).map(\.newName) == ["Draft rev1.txt", "Draft rev2.txt"])
        o.find = "(["
        #expect(RenamePlan.compute(urls, o).allSatisfy { $0.problem == "Invalid regular expression" })
    }

    @Test func detectsClashes() throws {
        let (root, urls) = try files(["a.txt", "b.txt", "keep.txt"])
        defer { try? FileManager.default.removeItem(at: root) }
        var o = RenameOptions()
        o.nameMask = "same"
        let rows = RenamePlan.compute(Array(urls.prefix(2)), o)
        #expect(rows.allSatisfy { $0.problem?.hasPrefix("Same name") == true })
        o.nameMask = "KEEP"                       // clashes with an existing, unrenamed file
        #expect(RenamePlan.compute([urls[0]], o)[0].problem == "Already exists")
        o.nameMask = "x/y"
        #expect(RenamePlan.compute([urls[0]], o)[0].problem == "Contains / or :")
    }

    @Test func swapNamesAndUndo() throws {
        let (root, urls) = try files(["one.txt", "two.txt"])
        defer { try? FileManager.default.removeItem(at: root) }
        // one -> two and two -> one at the same time: needs the two-phase rename.
        let pairs = [MovePair(from: urls[0], to: urls[1]), MovePair(from: urls[1], to: urls[0])]
        let undo = try FileAction.renameBatch(pairs).perform()
        #expect(read(urls[0]) == "two.txt")
        #expect(read(urls[1]) == "one.txt")
        _ = try undo.perform()
        #expect(read(urls[0]) == "one.txt")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["one.txt", "two.txt"])
    }

    @Test func caseOnlyRename() throws {
        let (root, urls) = try files(["readme.md"])
        defer { try? FileManager.default.removeItem(at: root) }
        var o = RenameOptions()
        o.textCase = .upper
        let rows = RenamePlan.compute(urls, o)
        #expect(rows[0].newName == "README.MD" && rows[0].problem == nil)
        let pairs = [MovePair(from: urls[0], to: root.appendingPathComponent("README.MD"))]
        _ = try FileAction.renameBatch(pairs).perform()
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["README.MD"])
    }
}

// MARK: - Tags

@Suite struct TagTests {
    @Test func writeReadAndFinderSeesThem() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let f = root.appendingPathComponent("t.txt")
        try write("x", to: f)
        let tags = [FileTag(name: "Red", color: 6), FileTag(name: "Project X", color: 4)]
        try TagStore.write(tags, to: f)
        #expect(TagStore.read(f) == tags)
        // The system's own API reads the same attribute Finder uses.
        let system = try f.resourceValues(forKeys: [.tagNamesKey]).tagNames
        #expect(system == ["Red", "Project X"])
        #expect(FileLister.item(for: f).tags == tags)
        try TagStore.write([], to: f)
        #expect(TagStore.read(f).isEmpty)
        try TagStore.write([], to: f)             // removing twice is fine
    }

    @Test func parseHandlesMissingColour() {
        #expect(TagStore.parse("Work\n3") == FileTag(name: "Work", color: 3))
        #expect(TagStore.parse("Work")?.color == 0)
        #expect(TagStore.parse("") == nil)
    }

    @Test func tagChangesAreUndoable() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let f = root.appendingPathComponent("t.txt")
        try write("x", to: f)
        let undo = try FileAction.setTags([TagChange(url: f, old: [], new: [FileTag(name: "Green", color: 2)])]).perform()
        #expect(TagStore.read(f).map(\.name) == ["Green"])
        _ = try undo.perform()
        #expect(TagStore.read(f).isEmpty)
    }
}

// MARK: - Folder sizes

@Suite struct FolderSizeTests {
    @Test func sumsNestedAndHiddenFiles() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(String(repeating: "a", count: 100), to: root.appendingPathComponent("a.txt"))
        try write(String(repeating: "b", count: 50), to: root.appendingPathComponent("sub/deep/b.txt"))
        try write(String(repeating: "c", count: 7), to: root.appendingPathComponent(".hidden"))
        #expect(FolderSizes.compute(root) == 157)
    }

    @MainActor @Test func serviceCachesAndInvalidatesAncestors() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(String(repeating: "a", count: 10), to: root.appendingPathComponent("sub/a.txt"))
        let sub = root.appendingPathComponent("sub")
        let sizes = FolderSizes()
        sizes.request([sub, root])
        for _ in 0..<100 where sizes.size(sub.path) == nil || sizes.size(root.path) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(sizes.size(sub.path) == 10)
        #expect(sizes.size(root.path) == 10)
        sizes.invalidate(sub.path)
        #expect(sizes.size(sub.path) == nil && sizes.size(root.path) == nil)
    }
}

// MARK: - Compare & sync

@MainActor
@Suite struct CompareTests {
    private func setDate(_ url: URL, _ secondsAgo: TimeInterval) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-secondsAgo)],
                                              ofItemAtPath: url.path)
    }

    private func fixture() throws -> (URL, URL, URL) {
        let root = try makeTempDir()
        let l = root.appendingPathComponent("L"), r = root.appendingPathComponent("R")
        try write("same", to: l.appendingPathComponent("same.txt"))
        try write("same", to: r.appendingPathComponent("same.txt"))
        try setDate(l.appendingPathComponent("same.txt"), 1000)
        try setDate(r.appendingPathComponent("same.txt"), 1000)
        try write("new left", to: l.appendingPathComponent("doc.txt"))
        try write("old", to: r.appendingPathComponent("doc.txt"))
        try setDate(r.appendingPathComponent("doc.txt"), 5000)
        try write("only L", to: l.appendingPathComponent("sub/inner/onlyL.txt"))
        try write("only R", to: r.appendingPathComponent("onlyR.txt"))
        try FileManager.default.createDirectory(at: r.appendingPathComponent("sub"), withIntermediateDirectories: true)
        return (root, l, r)
    }

    @Test func classifiesDifferences() throws {
        let (root, l, r) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let entries = CompareEngine.compare(l, r, CompareOptions())
        let status = Dictionary(uniqueKeysWithValues: entries.map { ($0.relPath, $0.status) })
        #expect(status["same.txt"] == .equal)
        #expect(status["doc.txt"] == .leftNewer)
        #expect(status["sub/inner"] == .leftOnly)        // whole missing folder is one row
        #expect(status["onlyR.txt"] == .rightOnly)
        #expect(entries.count == 4)

        let flat = CompareEngine.compare(l, r, CompareOptions(recursive: false))
        #expect(!flat.contains { $0.relPath.hasPrefix("sub/") })
    }

    @Test func contentModeCatchesSameSizeDifferentBytes() throws {
        let (root, l, r) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("abcd", to: r.appendingPathComponent("same.txt"))       // same size, different bytes
        try setDate(r.appendingPathComponent("same.txt"), 1000)
        let byDate = CompareEngine.compare(l, r, CompareOptions())
        #expect(byDate.first { $0.relPath == "same.txt" }?.status == .equal)
        let byContent = CompareEngine.compare(l, r, CompareOptions(byContent: true))
        #expect(byContent.first { $0.relPath == "same.txt" }?.status == .differs)
    }

    @Test func syncMakesFoldersEqual() async throws {
        let (root, l, r) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        // Avoid the Trash in tests: drop the outdated right-hand doc.txt first, so nothing is replaced.
        try FileManager.default.removeItem(at: r.appendingPathComponent("doc.txt"))
        let entries = CompareEngine.compare(l, r, CompareOptions())
        let dirs = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, CompareEngine.defaultDirection($0.status)) })
        let items = CompareEngine.transfers(entries, dirs, left: l, right: r)
        #expect(items.count == 3)

        let result: JobResult = await withCheckedContinuation { cont in
            JobCenter().start(.copy, items: items, policy: .replace) { cont.resume(returning: $0) }
        }
        #expect(result.errors.isEmpty)
        #expect(read(r.appendingPathComponent("sub/inner/onlyL.txt")) == "only L")
        #expect(read(l.appendingPathComponent("onlyR.txt")) == "only R")
        // Copies keep modification dates, so a second compare finds nothing to do.
        let after = CompareEngine.compare(l, r, CompareOptions())
        #expect(after.allSatisfy { $0.status == .equal })
    }

    @Test func createsMissingDestinationFolders() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let src = root.appendingPathComponent("f.txt")
        try write("f", to: src)
        let dest = root.appendingPathComponent("new/deeper")
        let result: JobResult = await withCheckedContinuation { cont in
            JobCenter().start(.copy, items: [TransferItem(source: src, destinationDir: dest)]) { cont.resume(returning: $0) }
        }
        #expect(read(dest.appendingPathComponent("f.txt")) == "f")
        #expect(result.createdDirs.map(\.lastPathComponent) == ["new"])
    }
}

// MARK: - Sorting & filtering

@MainActor
@Suite struct SortFilterTests {
    private func item(_ name: String, folder: Bool = false, size: Int64? = nil, age: TimeInterval = 0) -> FileItem {
        FileItem(url: URL(fileURLWithPath: "/x/\(name)"), name: name, isFolder: folder, isHidden: false,
                 size: folder ? nil : size, modified: Date(timeIntervalSince1970: 1_000_000 - age))
    }

    @Test func foldersFirstThenKey() {
        let items = [item("b.txt", size: 5, age: 10), item("Zeta", folder: true), item("a.pdf", size: 50, age: 30),
                     item("Alpha", folder: true), item("c.txt", size: 1, age: 20)]
        #expect(SortSpec().sorted(items).map(\.name) == ["Alpha", "Zeta", "a.pdf", "b.txt", "c.txt"])
        #expect(SortSpec(key: .size, ascending: false).sorted(items).map(\.name) == ["Alpha", "Zeta", "a.pdf", "b.txt", "c.txt"])
        #expect(SortSpec(key: .size).sorted(items).map(\.name) == ["Alpha", "Zeta", "c.txt", "b.txt", "a.pdf"])
        #expect(SortSpec(key: .modified, ascending: false).sorted(items).map(\.name) == ["Alpha", "Zeta", "b.txt", "c.txt", "a.pdf"])
        #expect(SortSpec(key: .kind).sorted(items).map(\.name) == ["Alpha", "Zeta", "a.pdf", "b.txt", "c.txt"])
    }

    @Test func filterSyntax() {
        #expect(filterMatches("rep", "Annual Report.pdf"))
        #expect(filterMatches("*.PDF", "report.pdf"))
        #expect(!filterMatches("*.pdf", "report.txt"))
        #expect(filterMatches("  ", "anything"))
        #expect(filterMatches("resume", "Résumé.docx"))     // diacritics ignored
    }

    @Test func columnFiltersAndSortsAndPaneNavigationUsesVisibleItems() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        for (n, size) in [("a.pdf", 300), ("b.txt", 100), ("c.pdf", 200)] {
            try write(String(repeating: "x", count: size), to: root.appendingPathComponent(n))
        }
        let pane = Pane(url: root, showHidden: false)
        await loaded(pane.columns[0])
        let col = pane.columns[0]
        col.filter = "*.pdf"
        #expect(col.items.map(\.name) == ["a.pdf", "c.pdf"])
        #expect(col.allItems.count == 3)
        pane.sort = SortSpec(key: .size, ascending: true)
        #expect(col.items.map(\.name) == ["c.pdf", "a.pdf"])
        pane.selectAll()
        #expect(Set(pane.selectedItems.map(\.name)) == ["a.pdf", "c.pdf"])   // hidden-by-filter items excluded
        col.filter = ""
        #expect(col.items.count == 3)
    }
}

// MARK: - Zip

@MainActor
@Suite struct ZipTests {
    /// docs/readme.txt, docs/deep/notes.md (folders only implied), top.txt, Ünïcode.txt
    private func makeZip() throws -> (URL, URL) {
        let root = try makeTempDir()
        let src = root.appendingPathComponent("src")
        try write("readme", to: src.appendingPathComponent("docs/readme.txt"))
        try write("notes", to: src.appendingPathComponent("docs/deep/notes.md"))
        try write("top", to: src.appendingPathComponent("top.txt"))
        try write("u", to: src.appendingPathComponent("Ünïcode.txt"))
        let zip = root.appendingPathComponent("bundle.zip")
        // -D: no explicit directory entries, so folders must be synthesized from paths.
        try ZipArchive.run("/usr/bin/zip", ["-q", "-r", "-D", zip.path, "."], in: src)
        return (root, zip)
    }

    @Test func parsesCentralDirectory() throws {
        let (root, zip) = try makeZip()
        defer { try? FileManager.default.removeItem(at: root) }
        let entries = try ZipArchive.entries(zip)
        #expect(Set(entries.map(\.path)) == ["docs/readme.txt", "docs/deep/notes.md", "top.txt", "Ünïcode.txt"])
        #expect(entries.first { $0.path == "top.txt" }?.size == 3)
        #expect(entries.allSatisfy { $0.modified != nil })
    }

    @Test func listsLevelsWithImplicitFolders() throws {
        let (root, zip) = try makeZip()
        defer { try? FileManager.default.removeItem(at: root) }
        let top = try ZipArchive.list(zip, inner: "")
        #expect(Set(top.map(\.name)) == ["docs", "top.txt", "Ünïcode.txt"])
        #expect(top.first { $0.name == "docs" }?.isFolder == true)
        #expect(top.allSatisfy { $0.inArchive })
        let docs = try ZipArchive.list(zip, inner: "docs")
        #expect(Set(docs.map(\.name)) == ["deep", "readme.txt"])
        #expect(docs.first { $0.name == "readme.txt" }?.path == zip.appendingPathComponent("docs/readme.txt").path)
        #expect(ZipArchive.isDirectory(zip, inner: "docs/deep"))
        #expect(!ZipArchive.isDirectory(zip, inner: "top.txt"))
        #expect(ArchiveRef.resolve(zip.appendingPathComponent("docs/deep")) == ArchiveRef(zip: zip, inner: "docs/deep"))
        #expect(ArchiveRef.resolve(root) == nil)
    }

    @Test func rejectsGarbage() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let bad = root.appendingPathComponent("bad.zip")
        try write("this is not a zip", to: bad)
        #expect(throws: (any Error).self) { try ZipArchive.entries(bad) }
    }

    @Test func extractsFilesAndFolders() throws {
        let (root, zip) = try makeZip()
        defer { try? FileManager.default.removeItem(at: root) }
        let dest = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let created = try ZipArchive.extract(zip, inner: ["docs", "top.txt"], to: dest)
        #expect(Set(created.map(\.lastPathComponent)) == ["docs", "top.txt"])
        #expect(read(dest.appendingPathComponent("docs/deep/notes.md")) == "notes")
        #expect(read(dest.appendingPathComponent("top.txt")) == "top")
        // Extracting again keeps both rather than overwriting.
        let again = try ZipArchive.extract(zip, inner: ["top.txt"], to: dest)
        #expect(again.map(\.lastPathComponent) == ["top copy.txt"])
        let viewing = try ZipArchive.extractForViewing(zip, inner: "docs/readme.txt")
        #expect(read(viewing) == "readme")
    }

    @Test func compressOneAndMany() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("A"), b = root.appendingPathComponent("b.txt")
        try write("a", to: a.appendingPathComponent("inner.txt"))
        try write("b", to: b)
        let one = try ZipArchive.compress([a])
        #expect(one.lastPathComponent == "A.zip")
        #expect(try ZipArchive.entries(one).map(\.path).contains("A/inner.txt"))
        let single = try ZipArchive.compress([b])
        #expect(single.lastPathComponent == "b.txt.zip")
        #expect(try ZipArchive.entries(single).map(\.path) == ["b.txt"])     // no enclosing folder
        let many = try ZipArchive.compress([a, b])
        #expect(many.lastPathComponent == "Archive.zip")
        #expect(Set(try ZipArchive.entries(many).filter { !$0.isDir }.map(\.path)) == ["A/inner.txt", "b.txt"])
    }

    @Test func paneBrowsesIntoZip() async throws {
        let (root, _) = try makeZip()
        defer { try? FileManager.default.removeItem(at: root) }
        let pane = Pane(url: root, showHidden: false)
        await loaded(pane.columns[0])
        let zipItem = try #require(pane.columns[0].items.first { $0.name == "bundle.zip" })
        #expect(zipItem.isBrowsableArchive)
        pane.select(zipItem, in: 0)
        #expect(pane.columns.count == 2)
        let inside = pane.columns[1]
        #expect(inside.isVirtual)
        await loaded(inside)
        #expect(inside.items.first?.name == "docs")           // folders first
        pane.select(inside.items[0], in: 1)
        await loaded(pane.columns[2])
        #expect(Set(pane.columns[2].items.map(\.name)) == ["deep", "readme.txt"])
    }

    @Test func appModelExtractsOnCopyAndRefusesWrites() async throws {
        let (root, zip) = try makeZip()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel()
        let inside = zip.appendingPathComponent("docs/readme.txt")
        model.trash([inside])
        #expect(model.errorMessage?.contains("read-only") == true)
        model.errorMessage = nil
        model.transfer([inside], to: root, move: true)
        #expect(model.errorMessage != nil)                      // can't move out of a zip
        model.errorMessage = nil

        model.transfer([inside], to: root)                      // copy = extract
        for _ in 0..<100 where model.jobs.jobs.first?.isActive != false {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(read(root.appendingPathComponent("readme.txt")) == "readme")
        #expect(model.undoName == "Extract")
    }
}

// MARK: - Git

@MainActor
@Suite struct GitTests {
    @Test func parsesPorcelain() {
        let raw = "## main...origin/main [ahead 2, behind 1]\0 M src/a.swift\0?? new/\0R  b.txt\0old-b.txt\0A  c.txt\0UU d.txt\0"
        let s = RepoState.parse(Data(raw.utf8), root: "/r")
        #expect(s.branch == "main")
        #expect(s.ahead == 2 && s.behind == 1)
        #expect(s.files["/r/src/a.swift"] == .modified)
        #expect(s.files["/r/new"] == .untracked)
        #expect(s.files["/r/b.txt"] == .renamed)
        #expect(s.files["/r/old-b.txt"] == nil)                 // rename source isn't a row
        #expect(s.files["/r/c.txt"] == .added)
        #expect(s.files["/r/d.txt"] == .conflict)
        #expect(s.code(for: "/r/src") == .modified)               // folder contains changes
        #expect(s.code(for: "/r/elsewhere") == nil)
        #expect(RepoState.parse(Data("## No commits yet on dev\0".utf8), root: "/r").branch == "dev")
    }

    @Test func realRepository() async throws {
        guard GitService.available else { return }
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let git = { (args: [String]) in
            try ZipArchive.run("/usr/bin/git", ["-C", root.path, "-c", "user.name=T", "-c", "user.email=t@t"] + args)
        }
        _ = try git(["init", "-q", "-b", "main"])
        try write("v1", to: root.appendingPathComponent("lib/tracked.txt"))
        _ = try git(["add", "."])
        _ = try git(["commit", "-q", "-m", "init"])
        try write("v2", to: root.appendingPathComponent("lib/tracked.txt"))
        try write("new", to: root.appendingPathComponent("fresh.txt"))

        let service = GitService()
        service.refresh(root.appendingPathComponent("lib").path)
        for _ in 0..<150 where service.state(for: root.path) == nil { try await Task.sleep(for: .milliseconds(20)) }
        let state = try #require(service.state(for: root.appendingPathComponent("lib").path))
        #expect(state.branch == "main")
        #expect(state.code(for: root.appendingPathComponent("lib/tracked.txt").path) == .modified)
        #expect(state.code(for: root.appendingPathComponent("fresh.txt").path) == .untracked)
        #expect(state.code(for: root.appendingPathComponent("lib").path) == .modified)
        #expect(service.root(for: FileManager.default.temporaryDirectory.path) == nil)
    }

    /// A repo's own config must not get to run commands just because its folder was opened.
    @Test func repoConfigCannotRunCommands() throws {
        guard GitService.available else { return }
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let git = { (args: [String]) in
            try ZipArchive.run("/usr/bin/git", ["-C", root.path, "-c", "user.name=T", "-c", "user.email=t@t"] + args)
        }
        _ = try git(["init", "-q", "-b", "main"])
        try write("v1", to: root.appendingPathComponent("a.txt"))
        _ = try git(["add", "."])
        _ = try git(["commit", "-q", "-m", "init"])
        let marker = root.appendingPathComponent("ran")
        _ = try git(["config", "core.fsmonitor", "touch '\(marker.path)'; echo"])
        try write("v2", to: root.appendingPathComponent("a.txt"))

        #expect(GitService.status(root.path)?.code(for: root.appendingPathComponent("a.txt").path) == .modified)
        #expect(!FileManager.default.fileExists(atPath: marker.path))

        // Filter drivers defined by the repo itself: no status at all.
        #expect(!GitService.definesLocalFilters(root.path))
        _ = try git(["config", "filter.x.clean", "touch '\(marker.path)'; cat"])
        try write("*.txt filter=x", to: root.appendingPathComponent(".gitattributes"))
        #expect(GitService.definesLocalFilters(root.path))
        #expect(GitService.status(root.path) == nil)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
}

// MARK: - Search

@MainActor
@Suite struct SearchTests {
    // Each test folder gets its own small index instead of the whole disk.
    init() { SearchIndex.broadRoot = nil }

    /// A small tree, once the shared index has it: when an earlier test's index already covers
    /// the temp folder, new files reach it through FSEvents a moment after they are written.
    private func tree() async throws -> URL {
        let root = try makeTempDir()
        try write("alpha\nthe Needle is here\nomega", to: root.appendingPathComponent("docs/a.txt"))
        try write("nothing", to: root.appendingPathComponent("docs/b.md"))
        try write("needle in hidden", to: root.appendingPathComponent(".secret/c.txt"))
        try write("needle in git", to: root.appendingPathComponent(".git/config"))
        var bin = Data("needle".utf8); bin.append(0); bin.append(contentsOf: Data("needle".utf8))
        try bin.write(to: root.appendingPathComponent("data.bin"))
        let files: Set = ["a.txt", "b.md", "c.txt", "config", "data.bin"]
        for _ in 0..<200 {
            if files.isSubset(of: try await names(root, SearchOptions(name: "*", includeHidden: true))) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        return root
    }

    /// Runs a search the way the sheet does (through the shared Cardinal index).
    private func run(_ root: URL, _ o: SearchOptions) async throws -> SearchSession {
        let session = SearchSession(root: root)
        session.options = o
        session.start()
        for _ in 0..<600 where session.running { try await Task.sleep(for: .milliseconds(25)) }
        #expect(!session.running)
        return session
    }

    private func names(_ root: URL, _ o: SearchOptions) async throws -> [String] {
        try await run(root, o).hits.map(\.url.lastPathComponent).sorted()
    }

    @Test func contentSearchSkipsBinaryAndHidden() async throws {
        let root = try await tree()
        defer { try? FileManager.default.removeItem(at: root) }
        let hits = try await run(root, SearchOptions(text: "needle")).hits
        #expect(hits.map(\.url.lastPathComponent) == ["a.txt"])
        #expect(hits.first?.line == 2)
        #expect(hits.first?.snippet == "the Needle is here")
        #expect(try await names(root, SearchOptions(text: "needle", caseSensitive: true)).isEmpty)
        #expect(try await names(root, SearchOptions(text: "needle", includeHidden: true)) == ["a.txt", "c.txt", "config"])
        // Inside a subfolder, and with quotes and backslashes in the text.
        try write(#"say "hi" \o/"#, to: root.appendingPathComponent("docs/q.txt"))
        try write(#"say "hi" \o/"#, to: root.appendingPathComponent("docs/.cache/q.txt"))
        let docs = root.appendingPathComponent("docs")
        var found: [String] = []
        for _ in 0..<100 where found.isEmpty {
            found = try await names(docs, SearchOptions(text: #"SAY "hi" \o/"#))
            if found.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(found == ["q.txt"])
    }

    @Test func nameSearchWithWildcardsFoldersAndCardinalSyntax() async throws {
        let root = try await tree()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try await names(root, SearchOptions(name: "*.md")) == ["b.md"])
        #expect(try await names(root, SearchOptions(name: "DOC")) == ["docs"])
        #expect(try await names(root, SearchOptions(name: "*.txt", text: "alpha")) == ["a.txt"])
        #expect(try await names(root, SearchOptions(name: "ext:md;bin")) == ["b.md", "data.bin"])
        #expect(try await names(root, SearchOptions(name: "a.txt|b.md")) == ["a.txt", "b.md"])
        // Hits carry real paths and stay inside the searched folder.
        let hits = try await run(root.appendingPathComponent("docs"), SearchOptions(name: "*")).hits
        #expect(hits.map(\.url.lastPathComponent).sorted() == ["a.txt", "b.md"])
    }

    @Test func typingSearchesWithoutReturn() async throws {
        let root = try await tree()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = SearchSession(root: root)
        session.options.name = "b."
        session.scheduleSearch()
        session.options.name = "b.md" // a newer keystroke replaces the pending search
        session.scheduleSearch()
        for _ in 0..<200 where session.hits.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        #expect(session.hits.map(\.url.lastPathComponent) == ["b.md"])
        session.options.name = ""
        session.scheduleSearch()
        for _ in 0..<200 where !session.hits.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        #expect(session.hits.isEmpty)
    }

    @Test func badQueryShowsAnError() async throws {
        let root = try await tree()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try await run(root, SearchOptions(name: "\"unterminated"))
        #expect(session.hits.isEmpty)
        #expect(session.error != nil)
    }

    @Test func indexFollowsChanges() async throws {
        let root = try await tree()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try await names(root, SearchOptions(name: "later")).isEmpty)
        try write("x", to: root.appendingPathComponent("docs/later.txt"))
        var found: [String] = []
        for _ in 0..<100 where found.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
            found = try await names(root, SearchOptions(name: "later"))
        }
        #expect(found == ["later.txt"])
    }

    @Test func stopCancelsTheSearch() async throws {
        let root = try await tree()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = SearchSession(root: root)
        session.options = SearchOptions(name: "*")
        session.start()
        session.stop()
        #expect(!session.running)
        try await Task.sleep(for: .milliseconds(300))
        #expect(session.hits.isEmpty)
    }

    @Test func queryQuotesScopeAndLeavesTextOut() {
        let o = SearchOptions(name: "*.md", text: #"say "hi" \o/"#)
        #expect(CardinalIndex.query(o, scope: "/a/my \"dir\"", indexRoot: "/a") == #"in:"/a/my \"dir\"" *.md"#)
        #expect(CardinalIndex.query(SearchOptions(name: "x"), scope: "/a", indexRoot: "/a") == "x")
    }
}

@MainActor
@Suite struct SearchSessionTests {
    init() { SearchIndex.broadRoot = nil }

    @Test func broadSearchStopsAtTheCap() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<(SearchSession.maxHits + 100) {
            FileManager.default.createFile(atPath: root.appendingPathComponent("f\(i).txt").path, contents: nil)
        }
        let session = SearchSession(root: root)
        session.options.name = "*.txt"
        // The shared index may have been walking while the files were created (another test
        // started it); FSEvents bring it up to date within a moment.
        for _ in 0..<50 where !session.truncated {
            session.start()
            for _ in 0..<400 where session.running { try await Task.sleep(for: .milliseconds(25)) }
            if !session.truncated { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(!session.running)
        #expect(session.hits.count == SearchSession.maxHits)
        #expect(session.truncated)
    }
}

// MARK: - SFTP

@Suite struct SFTPParseTests {
    @Test func refusesUnsafeBatchInput() {
        SFTPClient.register(SFTPServer(host: "-oProxyCommand=x"))
        #expect(throws: SFTPClient.SFTPError.self) { try SFTPClient.batch("-oProxyCommand=x", ["pwd"]) }
        SFTPClient.register(SFTPServer(host: "example.invalid"))
        let ref = SFTPRef(target: "example.invalid", path: "/a\n!touch /tmp/x")
        #expect(throws: SFTPClient.SFTPError.self) { try SFTPClient.makeFolder(ref) }
    }

    @Test func parsesLongListing() {
        let now = DateComponents(calendar: .current, year: 2026, month: 10, day: 14).date!
        let text = """
        sftp> cd "/srv"
        sftp> ls -la
        drwxr-xr-x    ? kiao     wheel          64 Oct 14 19:51 .
        drwxr-xr-x    ? kiao     wheel         384 Oct 14 19:51 ..
        drwxr-xr-x    4 www      www           128 Mar  3  2025 site files
        -rw-r--r--    1 www      www          2048 Oct 13 09:05 index.html
        lrwxr-xr-x    1 www      www             9 Oct 12 10:00 current -> releases/7
        -rw-------    1 www      www            12 Dec 31 23:59 .env
        """
        let ref = SFTPRef(target: "me@host:2222", path: "/srv")
        let items = SFTPClient.parseListing(text, ref: ref, now: now)
        #expect(items.map(\.name) == ["site files", "index.html", "current", ".env"])
        let site = items[0]
        #expect(site.isFolder && site.isRemote && site.size == nil)
        #expect(Calendar.current.component(.year, from: site.modified!) == 2025)
        #expect(items[1].size == 2048)
        #expect(items[1].url.path == "/sftp:/me@host:2222/srv/index.html")
        #expect(items[3].isHidden)
        // "Dec 31" with no year, seen in October, must be last year — not in the future.
        #expect(Calendar.current.component(.year, from: items[3].modified!) == 2025)
    }

    @Test func pseudoPathsRoundTrip() {
        let url = SFTPRef.url("me@host:22", "/var/www/a b.txt")
        #expect(SFTPRef.resolve(url) == SFTPRef(target: "me@host:22", path: "/var/www/a b.txt"))
        #expect(SFTPRef.resolve(SFTPRef.url("host", "/")) == SFTPRef(target: "host", path: "/"))
        #expect(SFTPRef.resolve(URL(fileURLWithPath: "/Users/x")) == nil)
        #expect(SFTPServer(user: "me", host: "h", port: 2222).target == "me@h:2222")
        #expect(SFTPClient.q(#"a "b" \c"#) == #""a \"b\" \\c""#)
    }

    @Test func friendlyErrors() {
        #expect(SFTPClient.friendly("Host key verification failed.", target: "h").contains("ssh h"))
        #expect(SFTPClient.friendly("me@h: Permission denied (publickey).", target: "h").contains("SSH keys"))
        #expect(SFTPClient.friendly("ssh: Could not resolve hostname nope", target: "nope").contains("Can't find"))
    }

    @Test func mountURLs() {
        #expect(ServerMounter.makeURL(scheme: "smb", address: "nas.local/share")?.absoluteString == "smb://nas.local/share")
        #expect(ServerMounter.makeURL(scheme: "smb", address: " //nas/x ")?.absoluteString == "smb://nas/x")
        #expect(ServerMounter.makeURL(scheme: "smb", address: "afp://mac.local/Public")?.scheme == "afp")
        #expect(ServerMounter.makeURL(scheme: "nfs", address: "   ") == nil)
    }
}

/// Runs a private sshd as the current user on 127.0.0.1 with throwaway keys, so SFTP is tested
/// against a real server without touching system settings or ~/.ssh.
@MainActor
@Suite(.serialized) struct SFTPIntegrationTests {
    final class LocalServer {
        let dir: URL
        let port: Int
        let process: Process

        init?() {
            guard FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd"),
                  let dir = try? makeTempDir() else { return nil }
            self.dir = dir
            port = Int.random(in: 30000...45000)
            func sh(_ args: [String]) -> Bool { (try? ZipArchive.run(args[0], Array(args.dropFirst()))) != nil }
            guard sh(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", dir.appendingPathComponent("host_key").path]),
                  sh(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", dir.appendingPathComponent("client_key").path]),
                  (try? FileManager.default.copyItem(at: dir.appendingPathComponent("client_key.pub"),
                                                     to: dir.appendingPathComponent("authorized_keys"))) != nil
            else { return nil }
            let config = """
            Port \(port)
            ListenAddress 127.0.0.1
            HostKey \(dir.path)/host_key
            AuthorizedKeysFile \(dir.path)/authorized_keys
            PidFile \(dir.path)/sshd.pid
            UsePAM no
            StrictModes no
            PasswordAuthentication no
            KbdInteractiveAuthentication no
            Subsystem sftp internal-sftp
            """
            try? config.write(to: dir.appendingPathComponent("sshd_config"), atomically: true, encoding: .utf8)
            process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
            process.arguments = ["-D", "-e", "-f", dir.appendingPathComponent("sshd_config").path]
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            Thread.sleep(forTimeInterval: 1)
            guard process.isRunning else { return nil }
        }

        var server: SFTPServer {
            SFTPServer(user: NSUserName(), host: "127.0.0.1", port: port, path: "",
                       identityFile: dir.appendingPathComponent("client_key").path,
                       extraOptions: ["UserKnownHostsFile=\(dir.path)/known_hosts", "StrictHostKeyChecking=accept-new",
                                      "ControlMaster=no"])
        }

        func stop() {
            process.terminate()
            try? FileManager.default.removeItem(at: dir)
        }
    }

    @Test func browseUploadDownloadRenameDelete() async throws {
        guard let local = LocalServer() else { Issue.record("Couldn't start the test sshd"); return }
        defer { local.stop() }
        let s = local.server
        SFTPClient.register(s)
        let remote = local.dir.appendingPathComponent("remote")
        try write("hello", to: remote.appendingPathComponent("docs/readme.txt"))
        try write("x", to: remote.appendingPathComponent("top file.txt"))
        let base = SFTPRef(target: s.target, path: remote.path)

        // Browse.
        let items = try SFTPClient.list(base, showHidden: false)
        #expect(Set(items.map(\.name)) == ["docs", "top file.txt"])
        #expect(items.first { $0.name == "docs" }?.isFolder == true)

        // Upload a local folder.
        let localDir = local.dir.appendingPathComponent("local")
        try write("up", to: localDir.appendingPathComponent("payload/u.txt"))
        _ = try SFTPClient.upload([localDir.appendingPathComponent("payload")], to: base)
        #expect(read(remote.appendingPathComponent("payload/u.txt")) == "up")

        // Download a folder (keeps both on name clash).
        let dl = local.dir.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: dl, withIntermediateDirectories: true)
        let got = try SFTPClient.download([SFTPRef(target: s.target, path: remote.appendingPathComponent("docs").path)], to: dl)
        #expect(got.map(\.lastPathComponent) == ["docs"])
        #expect(read(dl.appendingPathComponent("docs/readme.txt")) == "hello")

        // Rename, new folder, delete.
        try SFTPClient.rename(SFTPRef(target: s.target, path: remote.appendingPathComponent("top file.txt").path),
                              to: remote.appendingPathComponent("renamed.txt").path)
        try SFTPClient.makeFolder(SFTPRef(target: s.target, path: remote.appendingPathComponent("empty").path))
        #expect(read(remote.appendingPathComponent("renamed.txt")) == "x")
        let doomed = [SFTPRef(target: s.target, path: remote.appendingPathComponent("renamed.txt").path),
                      SFTPRef(target: s.target, path: remote.appendingPathComponent("empty").path)]
        try SFTPClient.delete(doomed, folders: [remote.appendingPathComponent("empty").path])
        #expect(!FileManager.default.fileExists(atPath: remote.appendingPathComponent("renamed.txt").path))
        #expect(!FileManager.default.fileExists(atPath: remote.appendingPathComponent("empty").path))

        // Preview fetch.
        let viewed = try SFTPClient.fetchForViewing(SFTPRef(target: s.target, path: remote.appendingPathComponent("docs/readme.txt").path))
        #expect(read(viewed) == "hello")
    }

    @Test func paneBrowsesServer() async throws {
        guard let local = LocalServer() else { Issue.record("Couldn't start the test sshd"); return }
        defer { local.stop() }
        let s = local.server
        SFTPClient.register(s)
        let remote = local.dir.appendingPathComponent("remote")
        try write("a", to: remote.appendingPathComponent("sub/a.txt"))
        let pane = Pane(url: SFTPRef.url(s.target, remote.path), showHidden: false)
        #expect(pane.columns[0].remote != nil && pane.columns[0].isVirtual)
        await loaded(pane.columns[0])
        #expect(pane.columns[0].loadError == nil)
        let sub = try #require(pane.columns[0].items.first { $0.name == "sub" })
        pane.select(sub, in: 0)
        await loaded(pane.columns[1])
        #expect(pane.columns[1].items.map(\.name) == ["a.txt"])
        #expect(pane.canGoUp)
    }

    @Test func unknownHostIsRefusedNotTrusted() throws {
        guard let local = LocalServer() else { Issue.record("Couldn't start the test sshd"); return }
        defer { local.stop() }
        var s = local.server
        s.extraOptions = ["UserKnownHostsFile=\(local.dir.path)/empty_known_hosts", "ControlMaster=no"]   // default: ask → refused in batch mode
        SFTPClient.register(s)
        #expect(throws: SFTPClient.SFTPError.self) { try SFTPClient.home(s.target) }
        #expect(!FileManager.default.fileExists(atPath: local.dir.appendingPathComponent("empty_known_hosts").path))
    }
}

// MARK: - Info, Open With, themes

@Suite struct InfoAndThemeTests {
    @Test func permissionStrings() {
        #expect(InfoCardTestHook.permissions(0o755, dir: true) == "drwxr-xr-x")
        #expect(InfoCardTestHook.permissions(0o640, dir: false) == "-rw-r-----")
    }

    @MainActor @Test func openWithListsTextEditForText() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let f = root.appendingPathComponent("a.txt")
        try write("x", to: f)
        let apps = OpenWithMenu.apps(for: [f]).map(\.lastPathComponent)
        #expect(apps.contains("TextEdit.app"))
        #expect(Set(apps).count == apps.count)
    }

    @Test func themes() {
        #expect(Theme.named("nord").name == "Nord")
        #expect(Theme.named("nope").id == "system")
        #expect(Set(Theme.all.map(\.id)).count == Theme.all.count)
        #expect(Theme.named("paper").colorScheme == .light && Theme.named("dracula").colorScheme == .dark)
    }
}

// MARK: - Terminal

@MainActor
@Suite struct TerminalTests {
    @Test func controlCharactersAreNeverTyped() {
        #expect(TerminalController.isSafeToType("/Users/me/Projects/sub dir/ünï ✓"))
        #expect(!TerminalController.isSafeToType("/tmp/evil\u{03}touch x\r"))
        #expect(!TerminalController.isSafeToType("/tmp/a\nb"))
        #expect(!TerminalController.isSafeToType("/tmp/esc\u{1B}[A"))
        #expect(!TerminalController.isSafeToType("/tmp/c1\u{9B}x"))
    }

    @Test func shellReportsDirectoryAndFollowsCd() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appendingPathComponent("sub dir")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let t = TerminalController()
        var reported: [String] = []
        t.onDirectoryChange = { reported.append($0.path) }
        t.start(in: root)
        defer { kill(t.view.process.shellPid, SIGHUP) }
        // Wait for the login shell to reach its prompt (user rc files may take a moment).
        for _ in 0..<200 where !t.shellIsIdle { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(500))
        #expect(t.shellIsIdle)

        // A `cd` typed in the shell is reported back (this is what moves the pane).
        t.view.send(txt: "cd \(TerminalController.shellQuote(sub.path))\r")
        for _ in 0..<100 where !reported.contains(sub.path) { try await Task.sleep(for: .milliseconds(50)) }
        #expect(reported.contains(sub.path))

        // The pane moving sends a cd to the shell (no echo back, so no loop).
        reported.removeAll()
        t.cd(root)
        #expect(t.directory == root.path)
        try await Task.sleep(for: .milliseconds(800))
        #expect(reported.isEmpty)
    }
}

// MARK: - tar / 7z archives

@MainActor
@Suite struct TarArchiveTests {
    /// Builds "<name>" from a small tree with `tar` (any libarchive format).
    private func makeArchive(_ name: String, _ extraArgs: [String] = [], dotPrefix: Bool = false) throws -> (URL, URL) {
        let root = try makeTempDir()
        let src = root.appendingPathComponent("src")
        try write("hello", to: src.appendingPathComponent("Sub Dir/a b.txt"))
        try write("deep", to: src.appendingPathComponent("Sub Dir/inner/d.txt"))
        try write("top", to: src.appendingPathComponent("top.txt"))
        let archive = root.appendingPathComponent(name)
        try ZipArchive.run("/usr/bin/tar", extraArgs + ["-cf", archive.path] + (dotPrefix ? ["."] : ["Sub Dir", "top.txt"]), in: src)
        return (root, archive)
    }

    @Test func recognizesArchiveNames() {
        for n in ["a.zip", "a.tar", "a.tgz", "a.tar.gz", "A.TAR.BZ2", "a.txz", "a.7z", "a.rar", "a.iso"] {
            #expect(ZipArchive.isArchiveName(n), "\(n)")
        }
        #expect(!ZipArchive.isArchiveName("a.gz"))
        #expect(!ZipArchive.isArchiveName("notes.txt"))
        let tgz = URL(fileURLWithPath: "/tmp/x/photos.tar.gz/sub/file")
        #expect(ArchiveRef.resolve(tgz) == nil)        // not on disk → not an archive path
    }

    @Test func tgzWithDotPrefixedNames() throws {
        let (root, archive) = try makeArchive("pack.tgz", ["-z"], dotPrefix: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entries = try ZipArchive.entries(archive)
        #expect(Set(entries.filter { !$0.isDir }.map(\.path)) == ["Sub Dir/a b.txt", "Sub Dir/inner/d.txt", "top.txt"])
        #expect(entries.first { $0.path == "top.txt" }?.member == "./top.txt")
        let top = try ZipArchive.list(archive, inner: "")
        #expect(Set(top.map(\.name)) == ["Sub Dir", "top.txt"])
        #expect(top.first { $0.name == "top.txt" }?.size == 3)

        let dest = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let made = try ZipArchive.extract(archive, inner: ["Sub Dir", "top.txt"], to: dest)
        #expect(Set(made.map(\.lastPathComponent)) == ["Sub Dir", "top.txt"])
        #expect(read(dest.appendingPathComponent("Sub Dir/inner/d.txt")) == "deep")
        #expect(read(try ZipArchive.extractForViewing(archive, inner: "Sub Dir/a b.txt")) == "hello")
    }

    @Test func sevenZipAndBzip2() throws {
        for (name, args) in [("pack.7z", ["--format", "7zip"]), ("pack.tar.bz2", ["-j"])] {
            let (root, archive) = try makeArchive(name, args)
            defer { try? FileManager.default.removeItem(at: root) }
            let inner = try ZipArchive.list(archive, inner: "Sub Dir")
            #expect(Set(inner.map(\.name)) == ["a b.txt", "inner"], "\(name)")
            let dest = root.appendingPathComponent("all")
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            try ZipArchive.extractAll(archive, to: dest)
            #expect(read(dest.appendingPathComponent("Sub Dir/a b.txt")) == "hello", "\(name)")
        }
    }

    @Test func paneBrowsesTarball() async throws {
        let (root, _) = try makeArchive("pack.tar.gz", ["-z"])
        defer { try? FileManager.default.removeItem(at: root) }
        let pane = Pane(url: root, showHidden: false)
        await loaded(pane.columns[0])
        let tarball = try #require(pane.columns[0].items.first { $0.name == "pack.tar.gz" })
        #expect(tarball.isBrowsableArchive)
        pane.select(tarball, in: 0)
        await loaded(pane.columns[1])
        #expect(pane.columns[1].isVirtual)
        #expect(pane.columns[1].items.map(\.name) == ["Sub Dir", "top.txt"])
    }

    @Test func lsLineParsing() {
        let now = DateComponents(calendar: .current, year: 2026, month: 10, day: 14).date!
        let l = LsLine("-rw-r--r--  0 0      0           3 Oct 14 19:58 Sub Dir/a b.txt", now: now)
        #expect(l?.name == "Sub Dir/a b.txt" && l?.size == 3 && l?.perm == "-")
        #expect(LsLine("total 12") == nil)
        #expect(LsLine("garbage line with words but no sense at all") == nil)
        let entries = ZipArchive.parseTarListing("""
        drwxr-xr-x  0 kiao   wheel       0 Oct 14 19:58 ./
        lrwxr-xr-x  0 kiao   wheel       0 Oct 14 19:58 ./link -> target
        hrw-r--r--  0 kiao   wheel       0 Oct 14 19:58 ./hard link to ./top.txt
        -rw-r--r--  0 kiao   wheel       9 Oct 14 19:58 ../escape.txt
        """, now: now)
        #expect(entries.map(\.path) == ["link", "hard"])     // "." and path-escaping entries dropped
    }
}

@Suite struct CloudStateTests {
    @Test func mapping() {
        #expect(CloudState(isUbiquitous: nil, status: nil, downloading: nil, uploading: nil) == nil)
        #expect(CloudState(isUbiquitous: false, status: .notDownloaded, downloading: nil, uploading: nil) == nil)
        #expect(CloudState(isUbiquitous: true, status: .notDownloaded, downloading: false, uploading: false) == .notDownloaded)
        #expect(CloudState(isUbiquitous: true, status: .notDownloaded, downloading: true, uploading: false) == .downloading)
        #expect(CloudState(isUbiquitous: true, status: .current, downloading: false, uploading: true) == .uploading)
        #expect(CloudState(isUbiquitous: true, status: .current, downloading: false, uploading: false) == .downloaded)
        #expect(CloudState.downloaded.symbol == nil && CloudState.notDownloaded.symbol != nil)
    }
}

// MARK: - Rename migration

@MainActor
@Suite struct SettingsMigrationTests {
    @Test func copiesOldSettingsOnceWithoutOverwriting() throws {
        let suite = "fc-migration-test-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        d.set("nord", forKey: "theme")                                  // already set: must survive
        let old: [String: Any] = ["theme": "paper", "favorites": ["/a", "/b"], "fontSize": 14.0, "unrelated": 1]

        AppModel.migrateSettings(from: old, to: d)
        #expect(d.string(forKey: "theme") == "nord")
        #expect(d.stringArray(forKey: "favorites") == ["/a", "/b"])
        #expect(d.double(forKey: "fontSize") == 14)
        #expect(d.object(forKey: "unrelated") == nil)                   // only known keys

        d.removeObject(forKey: "favorites")
        AppModel.migrateSettings(from: old, to: d)                      // runs once only
        #expect(d.object(forKey: "favorites") == nil)
    }
}
