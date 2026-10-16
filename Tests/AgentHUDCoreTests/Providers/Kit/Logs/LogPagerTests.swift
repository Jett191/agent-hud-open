import XCTest
@testable import AgentHUDCore

/// Reading a log back from its end: line by line, to the newest turn's start, and a page at a time.
final class LogPagerTests: XCTestCase {
    /// `T` lines start a turn; one line is longer than several chunks and than the prefix a line is judged by.
    private let lines = ["a1", "T2", "b3", String(repeating: "x", count: 5000), "", "T5", "c6"]

    private func log(_ lines: [String]) throws -> (url: URL, data: Data) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        let data = Data(lines.map { $0 + "\n" }.joined().utf8)
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return (url, data)
    }

    private func offset(of line: String, in data: Data) -> Int {
        data.range(of: Data(("\n" + line + "\n").utf8)).map { $0.lowerBound + 1 } ?? (data.starts(with: Data((line + "\n").utf8)) ? 0 : -1)
    }

    private final class Count: @unchecked Sendable { var value = 0 }

    private func pager(_ url: URL, wholeLines: Count = Count()) throws -> LogPager {
        let handle = try FileHandle(forReadingFrom: url)
        addTeardownBlock { try? handle.close() }
        return LogPager(handle: handle, chunkSize: 16) { prefix, line in
            guard prefix.first == UInt8(ascii: "T") else { return false }
            wholeLines.value += 1
            return try line().allSatisfy { $0 != 0x0A }
        }
    }

    func testLinesComeBackNewestFirstAcrossChunksWithoutTheirNewlines() throws {
        let (url, data) = try log(lines)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var back = LinesBack(handle: handle, end: data.count, chunkSize: 16), read: [String] = []
        while let range = try back.next() { read.append(String(decoding: data[range], as: UTF8.self)) }
        XCTAssertEqual(read, lines.filter { !$0.isEmpty }.reversed())
    }

    func testTheNewestTurnStartsAtTheLastMarkedLine() throws {
        let (url, data) = try log(lines)
        let whole = Count()
        XCTAssertEqual(try pager(url, wholeLines: whole).lastTurnStart(before: data.count), offset(of: "T5", in: data))
        XCTAssertEqual(whole.value, 1, "only a line whose first bytes mark it is read whole")
    }

    func testALogWithoutATurnStartIsReadFromItsStart() throws {
        let (url, data) = try log(["a1", "b2"])
        XCTAssertEqual(try pager(url).lastTurnStart(before: data.count), 0)
        let (empty, _) = try log([])
        XCTAssertEqual(try pager(empty).lastTurnStart(before: 0), 0)
    }

    func testAPageReachesBackPastItsLinesToATurnStart() throws {
        let (url, data) = try log(lines)
        let pager = try pager(url), end = offset(of: "T5", in: data)
        XCTAssertEqual(try pager.pageStart(before: end, minimumLines: 1), offset(of: "T2", in: data))
        XCTAssertEqual(try pager.pageStart(before: end, minimumLines: 3), offset(of: "T2", in: data))
        XCTAssertEqual(try pager.pageStart(before: end, minimumLines: 4), 0, "past the last turn start, the page runs to the log's start")
        XCTAssertEqual(try pager.pageStart(before: offset(of: "T2", in: data), minimumLines: 1), 0)
    }
}
