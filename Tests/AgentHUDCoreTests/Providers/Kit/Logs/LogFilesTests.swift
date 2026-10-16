import XCTest
@testable import AgentHUDCore

final class LogFilesTests: XCTestCase {
    /// The entries a listing asked about, to show which part of the tree a refresh visited.
    private final class Visits {
        var paths: [String] = []
    }

    private func directory() throws -> URL {
        // Under the temporary directory's symlinked path, so events naming the resolved path exercise the mapping.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// The path a listing names the files under `url` by.
    private func real(_ url: URL) -> URL {
        URL(fileURLWithPath: url.path.withCString { pointer in
            guard let real = realpath(pointer, nil) else { return url.path }
            defer { free(real) }
            return String(cString: real)
        })
    }

    private func write(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "a 1\n".write(to: url, atomically: false, encoding: .utf8)
    }

    private func listing(_ roots: [URL], limit: Int = .max, visits: Visits) -> LogFiles {
        LogFiles(roots: roots, watchesChanges: false, limit: limit, skips: { $0.lastPathComponent == "tool-results" }) {
            visits.paths.append($0.path)
            return $0.pathExtension == "jsonl"
        }
    }

    private func names(_ files: LogFiles) -> Set<String> {
        Set(files.files.keys.map { URL(fileURLWithPath: $0).lastPathComponent })
    }

    func testANewDirectoryIsListedWithoutItsSiblingsOrOtherRoots() throws {
        let root = try directory(), other = try directory(), visits = Visits()
        for session in 0..<20 { try write(root.appendingPathComponent("project/s\(session).jsonl")) }
        try write(other.appendingPathComponent("o.jsonl"))
        let files = listing([root, other], visits: visits)
        files.refresh(now: Date())
        XCTAssertEqual(files.files.count, 21)

        let added = root.appendingPathComponent("project/s3/subagents")
        try write(added.appendingPathComponent("agent-1.jsonl"))
        try write(added.appendingPathComponent("agent-2.jsonl"))
        visits.paths = []
        // The watch names the new folders, the parent by its real path and the child by the root's own, and a path elsewhere.
        let listed = real(root)
        XCTAssertNotEqual(listed.path, root.path, "the fixture sits behind a symlink")
        files.noteChanges([listed.appendingPathComponent("project/s3").path,
                           root.appendingPathComponent("project/s3/subagents").path, "/elsewhere/project"])
        XCTAssertEqual(files.refresh(now: Date()).unreadable, 0)

        let keyed = listed.appendingPathComponent("project/s3/subagents")
        XCTAssertNotNil(files.files[keyed.appendingPathComponent("agent-1.jsonl").path], "keyed as the full listing keys them")
        XCTAssertNotNil(files.files[keyed.appendingPathComponent("agent-2.jsonl").path])
        XCTAssertEqual(files.files.count, 23)
        XCTAssertEqual(visits.paths.count, 3, "the subfolder and its two files, each once: \(visits.paths)")
        XCTAssertTrue(visits.paths.allSatisfy { $0.hasPrefix(listed.appendingPathComponent("project/s3").path + "/") })
    }

    func testARemovedDirectoryDropsItsFiles() throws {
        let root = try directory(), visits = Visits()
        for name in ["a/1.jsonl", "a/b/2.jsonl", "c/3.jsonl", "c/4.jsonl"] { try write(root.appendingPathComponent(name)) }
        let files = listing([root], visits: visits)
        files.refresh(now: Date())
        XCTAssertEqual(names(files), ["1.jsonl", "2.jsonl", "3.jsonl", "4.jsonl"])

        try FileManager.default.removeItem(at: root.appendingPathComponent("a"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("c/4.jsonl"))
        visits.paths = []
        // Removing a folder is reported for the folder alone; one that is still there loses the files it no longer holds.
        files.noteChanges([root.appendingPathComponent("a").path, root.appendingPathComponent("c").path])
        files.refresh(now: Date())
        XCTAssertEqual(names(files), ["3.jsonl"])
        XCTAssertEqual(Set(visits.paths), [real(root).appendingPathComponent("c/3.jsonl").path])
    }

    func testARootEventListsThatRootOnly() throws {
        let root = try directory(), other = try directory(), visits = Visits()
        try write(root.appendingPathComponent("p/1.jsonl"))
        try write(other.appendingPathComponent("p/2.jsonl"))
        let files = listing([root, other], visits: visits)
        files.refresh(now: Date())

        try write(root.appendingPathComponent("q/3.jsonl"))
        try write(other.appendingPathComponent("q/4.jsonl"))
        visits.paths = []
        files.noteChanges([root.path])
        files.refresh(now: Date())
        XCTAssertEqual(names(files), ["1.jsonl", "2.jsonl", "3.jsonl"], "the other root waits for its own event")
        XCTAssertTrue(visits.paths.allSatisfy { $0.hasPrefix(real(root).path + "/") })
    }

    func testDroppedEventsStillListEverything() throws {
        let root = try directory(), other = try directory(), visits = Visits()
        try write(root.appendingPathComponent("p/1.jsonl"))
        let files = listing([root, other], visits: visits)
        files.refresh(now: Date())

        try write(root.appendingPathComponent("q/2.jsonl"))
        try write(other.appendingPathComponent("3.jsonl"))
        files.noteChanges([root.appendingPathComponent("q").path])
        files.noteChanges(nil)
        files.refresh(now: Date())
        XCTAssertEqual(names(files), ["1.jsonl", "2.jsonl", "3.jsonl"])
    }

    func testADirectoryTheFullListingSkipsAddsNothing() throws {
        let root = try directory(), visits = Visits()
        try write(root.appendingPathComponent("s/1.jsonl"))
        let files = listing([root], visits: visits)
        files.refresh(now: Date())

        try write(root.appendingPathComponent("s/tool-results/x/2.jsonl"))
        try write(root.appendingPathComponent("s/.hidden/3.jsonl"))
        files.noteChanges([root.appendingPathComponent("s/tool-results/x").path, root.appendingPathComponent("s/.hidden").path])
        files.refresh(now: Date())
        XCTAssertEqual(names(files), ["1.jsonl"])
    }

    func testAListingStoppedByItsLimitSaysSoUntilTheNextFullListing() throws {
        let root = try directory(), visits = Visits()
        for name in ["a/1.jsonl", "a/2.jsonl", "b/3.jsonl"] { try write(root.appendingPathComponent(name)) }
        let files = listing([root], limit: 3, visits: visits)
        XCTAssertTrue(files.refresh(now: Date()).truncated)

        try write(root.appendingPathComponent("c/4.jsonl"))
        files.noteChanges([root.appendingPathComponent("c").path])
        XCTAssertTrue(files.refresh(now: Date()).truncated, "files the full listing did not reach are still missing")
        XCTAssertTrue(names(files).contains("4.jsonl"))
    }

    func testASymlinkedRootListsTheSameFilesHoweverItIsReached() throws {
        let base = try directory(), visits = Visits()
        let target = base.appendingPathComponent("real"), link = base.appendingPathComponent("link")
        try write(target.appendingPathComponent("p/1.jsonl"))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let files = listing([link], visits: visits)
        files.refresh(now: Date())
        let full = Set(files.files.keys)
        XCTAssertEqual(full, [real(target).appendingPathComponent("p/1.jsonl").path])

        files.noteChanges([real(target).appendingPathComponent("p").path])
        files.refresh(now: Date())
        XCTAssertEqual(Set(files.files.keys), full, "a subfolder event")
        files.noteChanges([link.path])
        files.refresh(now: Date())
        XCTAssertEqual(Set(files.files.keys), full, "a root event")
        files.noteChanges([real(target).path])
        files.refresh(now: Date())
        XCTAssertEqual(Set(files.files.keys), full, "a root event by the real path")
    }

    func testARootCreatedAfterTheFirstListingTakesEventsByItsRealPath() throws {
        let base = try directory(), visits = Visits()
        let root = base.appendingPathComponent("home/projects")
        let files = listing([root], visits: visits)
        files.refresh(now: Date())
        XCTAssertTrue(files.files.isEmpty)

        let log = root.appendingPathComponent("p/a.jsonl")
        try write(log)
        let named = real(root)
        XCTAssertNotEqual(named.path, root.path, "the fixture sits behind a symlink")
        files.noteChanges([named.path, named.appendingPathComponent("p").path])
        files.refresh(now: Date())
        XCTAssertEqual(Set(files.files.keys), [named.appendingPathComponent("p/a.jsonl").path])
    }

    func testAFileEventInASkippedOrHiddenFolderAddsNothing() throws {
        let root = try directory(), visits = Visits()
        try write(root.appendingPathComponent("s/1.jsonl"))
        let files = listing([root], visits: visits)
        files.refresh(now: Date())

        let skipped = root.appendingPathComponent("s/tool-results/2.jsonl"), hidden = root.appendingPathComponent("s/.hidden/3.jsonl")
        let hiddenFile = root.appendingPathComponent("s/.4.jsonl")
        for url in [skipped, hidden, hiddenFile] { try write(url) }
        files.noteChanges(Set([skipped, hidden, hiddenFile].map { real($0).path }))
        files.refresh(now: Date())
        XCTAssertEqual(names(files), ["1.jsonl"])
    }

    func testAGoneFileThatWasNeverListedWalksNothing() throws {
        let root = try directory(), visits = Visits()
        try write(root.appendingPathComponent("s/1.jsonl"))
        let files = listing([root], visits: visits)
        files.refresh(now: Date())

        // An atomic write reports its temporary file, gone by the time the poll looks.
        visits.paths = []
        files.noteChanges([real(root).appendingPathComponent("s/1.meta.json.sb-1234").path])
        files.refresh(now: Date())
        XCTAssertEqual(names(files), ["1.jsonl"])
        XCTAssertEqual(visits.paths, [real(root).appendingPathComponent("s/1.meta.json.sb-1234").path], "asked about once, as a file")
    }
}
