import XCTest
@testable import AgentHUDCore

/// A log that tells where its turns start is read from its newest turn first, then back through its history a page at
/// a time, on a budget of its own, and ends up counted exactly as a read from its start would count it.
final class TailLogHistoryTests: XCTestCase, @unchecked Sendable {
    private static let base = Date(timeIntervalSince1970: 1_800_000_000)

    /// One `<mark> <tokens>` line per request; a `T` line starts a turn. Each line is keyed by its place in the log, and
    /// the summary lists those places in the log's order.
    private enum Turns: TailLog {
        static let source = "fixture"
        static let summaryKey = "places"
        static let version = 1
        static func summary(for url: URL) -> [Int] { [] }
        static func ingest(_ lines: Data, at offset: Int, into places: inout [Int]) -> [UsageLedger.Event] {
            var events: [UsageLedger.Event] = [], position = offset
            for line in lines.split(separator: 0x0A, omittingEmptySubsequences: false) {
                defer { position += line.count + 1 }
                guard let tokens = line.split(separator: 0x20).last.flatMap({ Int(String(decoding: $0, as: UTF8.self)) }) else { continue }
                places.append(position)
                events.append(.init(key: "o:\(position)", timestamp: TailLogHistoryTests.base, agentId: "fixture-model:m",
                                    tokensIn: tokens, tokensOut: 0))
            }
            return events
        }
        static let startsTurn: LogPager.StartsTurn? = { prefix, _ in prefix.first == UInt8(ascii: "T") }
        static func merge(older: [Int], into places: inout [Int]) { places = older + places }
    }

    /// Three turns of 300 one-token requests: each page of at least 200 lines reaches back to a whole turn.
    private let turns = (0..<3).flatMap { _ in ["T 1"] + Array(repeating: "- 1", count: 299) }

    private func log(_ lines: [String]) throws -> (root: URL, url: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("session.log")
        try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: url)
        return (root, url)
    }

    private func tokens(_ ledger: UsageLedger) async throws -> Int {
        try await ledger.buckets(since: .distantPast, source: Turns.source).reduce(0) { $0 + $1.tokensIn }
    }

    /// Where each line begins.
    private func places(_ lines: [String]) -> [Int] {
        lines.reduce(into: [Int]()) { places, line in places.append((places.last ?? 0) + (places.isEmpty ? 0 : 4)) }
    }

    func testTheNewestTurnIsReadFirstAndTheHistoryAfterIt() async throws {
        let (root, _) = try log(turns), ledger = UsageLedger.inMemory()
        let store = TailLogStore<Turns>(roots: [root], ledger: ledger, watchesChanges: false) { _ in true }
        store.historyBudget = 0
        var pass = await store.index(since: .distantPast, timeBudget: 5)
        let path = try XCTUnwrap(pass.logs.first?.path, "the store keys a log by the path its listing gives")
        var total = try await tokens(ledger)
        XCTAssertEqual(total, 300, "the first read takes the newest turn")
        XCTAssertEqual(pass.pending, 1, "its history is still to read")
        XCTAssertEqual(store.entry(path)?.summary, Array(places(turns).suffix(300)))

        store.historyBudget = 5
        pass = await store.index(since: .distantPast, timeBudget: 5)
        total = try await tokens(ledger)
        XCTAssertEqual(total, 900)
        XCTAssertEqual(pass.pending, 0)
        XCTAssertEqual(store.entry(path)?.summary, places(turns), "the pages join in the log's order")
        XCTAssertNil(store.entry(path)?.back)
    }

    func testLinesAddedWhileTheHistoryWaitsAreReadAtOnce() async throws {
        let (root, url) = try log(turns), ledger = UsageLedger.inMemory()
        let store = TailLogStore<Turns>(roots: [root], ledger: ledger, watchesChanges: false) { _ in true }
        store.historyBudget = 0
        _ = await store.index(since: .distantPast, timeBudget: 5)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("T 5\n- 5\n".utf8))
        try handle.close()
        _ = await store.index(since: .distantPast, timeBudget: 5)
        var total = try await tokens(ledger)
        XCTAssertEqual(total, 310)

        store.historyBudget = 5
        _ = await store.index(since: .distantPast, timeBudget: 5)
        total = try await tokens(ledger)
        XCTAssertEqual(total, 910)
    }

    func testARewrittenLogIsReadAgainFromItsNewestTurn() async throws {
        let (root, url) = try log(turns), ledger = UsageLedger.inMemory()
        let store = TailLogStore<Turns>(roots: [root], ledger: ledger, watchesChanges: false) { _ in true }
        _ = await store.index(since: .distantPast, timeBudget: 5)
        try Data((["T 2"] + Array(repeating: "- 2", count: 9)).map { $0 + "\n" }.joined().utf8).write(to: url)
        store.historyBudget = 0
        let pass = await store.index(since: .distantPast, timeBudget: 5)
        let total = try await tokens(ledger)
        XCTAssertEqual(total, 20, "what the old log recorded leaves with it")
        let entry = try XCTUnwrap(pass.logs.first.flatMap { store.entry($0.path) })
        XCTAssertNil(entry.back, "a log of one turn has no history")
    }

    func testALogWithoutTurnsIsReadFromItsStart() async throws {
        let (root, _) = try log(Array(repeating: "- 1", count: 50)), ledger = UsageLedger.inMemory()
        let store = TailLogStore<Turns>(roots: [root], ledger: ledger, watchesChanges: false) { _ in true }
        store.historyBudget = 0
        let pass = await store.index(since: .distantPast, timeBudget: 5)
        let total = try await tokens(ledger)
        XCTAssertEqual(total, 50)
        let entry = try XCTUnwrap(pass.logs.first.flatMap { store.entry($0.path) })
        XCTAssertNil(entry.back)
    }
}
