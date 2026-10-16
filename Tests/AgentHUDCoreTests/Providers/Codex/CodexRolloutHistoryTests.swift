import XCTest
@testable import AgentHUDCore

/// A Codex rollout read from its newest turn first, and its history after that, counts what a read from its start counts.
final class CodexRolloutHistoryTests: XCTestCase, @unchecked Sendable {
    private func line(_ type: String, _ payload: [String: Any], at second: Int) -> String {
        let object: [String: Any] = ["type": type, "timestamp": Date().addingTimeInterval(Double(second - 600)).ISO8601Format(), "payload": payload]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object, options: .sortedKeys), as: UTF8.self)
    }

    /// Codex's running totals, and the call's own share.
    private func tokens(total: Int, last: Int, at second: Int) -> String {
        line("event_msg", ["type": "token_count", "info": ["total_token_usage": ["input_tokens": total, "output_tokens": 0],
                                                           "last_token_usage": ["input_tokens": last, "output_tokens": 0]]], at: second)
    }

    private func turn(_ id: String, at second: Int) -> [String] {
        [line("event_msg", ["type": "task_started", "turn_id": id], at: second),
         line("turn_context", ["turn_id": id, "model": "gpt-5"], at: second + 1)]
    }

    /// Two turns of one call each. Codex repeats its totals in a record of their own after a call, and again at the start
    /// of the next turn, where a page read on its own begins.
    private var rollout: [String] {
        [line("session_meta", ["id": "thread", "cwd": "/project", "source": "cli", "timestamp": Date().addingTimeInterval(-600).ISO8601Format()], at: 0),
         line("event_msg", ["type": "user_message", "message": "First prompt"], at: 1)]
            + turn("t1", at: 2) + [tokens(total: 100, last: 100, at: 4), tokens(total: 100, last: 100, at: 5),
                                   line("event_msg", ["type": "task_complete", "turn_id": "t1"], at: 6)]
            + turn("t2", at: 10) + [tokens(total: 100, last: 100, at: 12), tokens(total: 150, last: 50, at: 13),
                                    line("event_msg", ["type": "task_complete", "turn_id": "t2"], at: 14)]
    }

    func testAPageStartsFromTheTotalsBeforeIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try Data(rollout.map { $0 + "\n" }.joined().utf8).write(to: root.appendingPathComponent("rollout-thread.jsonl"))
        let ledger = UsageLedger.inMemory()
        let store = TailLogStore<CodexRollouts>(roots: [root], ledger: ledger, watchesChanges: false) { $0.pathExtension == "jsonl" }
        func input() async throws -> Int { try await ledger.buckets(since: .distantPast, source: CodexRollouts.source).reduce(0) { $0 + $1.tokensIn } }

        store.historyBudget = 0
        let pass = await store.index(since: .distantPast, timeBudget: 5)
        var counted = try await input()
        XCTAssertEqual(counted, 50, "the newest turn's repeated totals count nothing")
        let path = try XCTUnwrap(pass.logs.first?.path)
        XCTAssertEqual(store.entry(path)?.summary.task, "First prompt", "the head names the session")
        XCTAssertEqual(store.entry(path)?.summary.id, "thread")

        store.historyBudget = 5
        _ = await store.index(since: .distantPast, timeBudget: 5)
        counted = try await input()
        XCTAssertEqual(counted, 150)
        XCTAssertEqual(store.entry(path)?.summary.sessionTurns.map(\.turnID), ["t1", "t2"])
        XCTAssertEqual(store.entry(path)?.summary.inputTokens, 150)
    }
}
