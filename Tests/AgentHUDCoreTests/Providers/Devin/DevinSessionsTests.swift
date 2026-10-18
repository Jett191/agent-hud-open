import Foundation
import SQLite3
import XCTest
@testable import AgentHUDCore

final class DevinSessionsTests: XCTestCase, @unchecked Sendable {
    private let now = Date(timeIntervalSince1970: 1788800000)
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("session_locks"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func database(_ url: URL, sessions: [String], nodes: [String]) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        let handle = try XCTUnwrap(db)
        defer { sqlite3_close(handle) }
        let schema = """
            CREATE TABLE sessions (id TEXT PRIMARY KEY, working_directory TEXT NOT NULL, backend_type TEXT NOT NULL,
                model TEXT NOT NULL, agent_mode TEXT NOT NULL, created_at INTEGER NOT NULL, last_activity_at INTEGER NOT NULL,
                title TEXT, main_chain_id INTEGER, shell_last_seen_index INTEGER DEFAULT 0, cogs_json TEXT,
                workspace_dirs TEXT, hidden INTEGER NOT NULL DEFAULT 0, metadata TEXT);
            CREATE TABLE message_nodes (row_id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL,
                node_id INTEGER NOT NULL, parent_node_id INTEGER, chat_message TEXT NOT NULL,
                created_at INTEGER NOT NULL, metadata TEXT);
            """
        let inserts = sessions.map { "INSERT INTO sessions (id, working_directory, backend_type, model, agent_mode, created_at, last_activity_at, title, hidden) VALUES (\($0));" }
            + nodes.map { "INSERT INTO message_nodes (session_id, node_id, chat_message, created_at) VALUES (\($0));" }
        XCTAssertEqual(sqlite3_exec(handle, schema + inserts.joined(), nil, nil, nil), SQLITE_OK)
    }
    private func sec(_ offset: Double) -> Int64 { Int64(now.timeIntervalSince1970 + offset) }
    private func iso(_ offset: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: now.addingTimeInterval(offset))
    }
    /// One assistant `chat_message` carrying `metadata.metrics` the way the CLI writes them.
    private func message(id: String, request: String?, model: String? = "swe-2-max", at offset: Double,
                         input: Int = 100, output: Int = 50, cacheRead: Int = 0, cacheWrite: Int = 0) -> String {
        """
        {"message_id":"\(id)","role":"assistant","content":"x","metadata":{"request_id":\(request.map { "\"\($0)\"" } ?? "null"),\
        "created_at":"\(iso(offset))"\(model.map { ",\"generation_model\":\"\($0)\"" } ?? ""),\
        "metrics":{"input_tokens":\(input),"output_tokens":\(output),"cache_read_tokens":\(cacheRead),"cache_creation_tokens":\(cacheWrite)}}}
        """
    }

    func testSessionsEventsDedupAndHidden() throws {
        let root = try directory()
        let url = root.appendingPathComponent("sessions.db")
        try database(url, sessions: [
            "'s1', '/Users/alice/work/demo', 'windsurf', 'swe-2-max', 'bypass', \(sec(-3600)), \(sec(-60)), 'Fix the login flow', 0",
            "'s2', '/Users/alice/work/other', 'windsurf', '', 'normal', \(sec(-7200)), \(sec(-30)), '', 0",
            "'s3', '/Users/alice/work/hidden', 'windsurf', 'swe-2-max', 'bypass', \(sec(-300)), \(sec(-60)), 'Hidden session', 1",
            "'old', '/Users/alice/work/old', 'windsurf', 'swe-2-max', 'bypass', \(sec(-90000)), \(sec(-86400 * 9)), 'Old session', 0"
        ], nodes: [
            "'s1', 1, '\(message(id: "m1", request: "r1", at: -300, cacheRead: 80, cacheWrite: 5))', \(sec(-60))",
            "'s1', 2, '\(message(id: "m1", request: "r1", at: -300, cacheRead: 80, cacheWrite: 5))', \(sec(-60))",
            "'s1', 3, '\(message(id: "m2", request: "r2", at: -200, input: 20, output: 30))', \(sec(-60))",
            "'s1', 4, '{\"message_id\":\"m3\",\"role\":\"tool\",\"content\":\"output\",\"metadata\":{\"metrics\":null}}', \(sec(-60))",
            "'s1', 5, '{\"message_id\":\"m4\",\"role\":\"assistant\",\"content\":\"failed\",\"metadata\":{\"request_id\":\"r3\",\"metrics\":{\"input_tokens\":null,\"output_tokens\":0}}}', \(sec(-60))",
            "'s1', 6, '{\"message_id\":\"m5\",\"role\":\"assistant\",\"metadata\":{\"request_id\":\"r4\",\"metrics\":{\"total_prompt_tokens\":300,\"total_completion_tokens\":60,\"total_cached_tokens\":120}}}', \(sec(-60))",
            "'s2', 1, '\(message(id: "n1", request: "q1", model: nil, at: -100))', \(sec(-60))"
        ])
        let result = try DevinSessions.read(url, since: now.addingTimeInterval(-86400))
        XCTAssertEqual(Set(result.sessions.map(\.id)), ["devin:s1", "devin:s2"], "hidden and stale sessions are not listed")
        let first = try XCTUnwrap(result.sessions.first { $0.id == "devin:s1" })
        XCTAssertEqual(first.title, "Fix the login flow")
        XCTAssertEqual(first.workspace, "/Users/alice/work/demo")
        XCTAssertEqual(first.client, "Devin CLI")
        XCTAssertEqual(first.events.map(\.id), ["r1", "r2", "r4"], "branch copies of one request count once")
        XCTAssertEqual(first.events.map(\.input), [105, 20, 180])
        XCTAssertEqual(first.events.map(\.cacheRead), [80, 0, 120])
        XCTAssertEqual(first.events.map(\.cacheWrite), [5, 0, 0])
        XCTAssertEqual(first.events.map(\.model), ["swe-2-max", "swe-2-max", "swe-2-max"], "no generation_model falls back to the session's model")
        let second = try XCTUnwrap(result.sessions.first { $0.id == "devin:s2" })
        XCTAssertEqual(second.title, "other", "no title falls back to the workspace folder")
        XCTAssertEqual(second.events.map(\.model), ["Unknown"], "no generation_model or session model is Unknown")
        XCTAssertTrue(second.turns.first?.state.isInFlight == true, "last activity thirty seconds back is still fresh")
    }

    func testLiveLockMarksRunning() throws {
        let root = try directory()
        let url = root.appendingPathComponent("sessions.db")
        try database(url, sessions: [
            "'live', '/w', 'windsurf', 'm', 'bypass', \(sec(-86400)), \(sec(-3600)), 'Live', 0",
            "'dead', '/w', 'windsurf', 'm', 'bypass', \(sec(-86400)), \(sec(-3600)), 'Dead', 0"
        ], nodes: [])
        try String(ProcessInfo.processInfo.processIdentifier).write(to: root.appendingPathComponent("session_locks/live.lock"), atomically: true, encoding: .utf8)
        try "2147483000".write(to: root.appendingPathComponent("session_locks/dead.lock"), atomically: true, encoding: .utf8)
        let result = try DevinSessions.read(url, since: now.addingTimeInterval(-86400))
        let live = try XCTUnwrap(result.sessions.first { $0.id == "devin:live" })
        XCTAssertEqual(live.turns.map(\.state), [.running])
        let dead = try XCTUnwrap(result.sessions.first { $0.id == "devin:dead" })
        XCTAssertTrue(dead.turns.isEmpty)
    }

    func testMissingMessageNodesTableStillListsSessions() throws {
        let root = try directory()
        let url = root.appendingPathComponent("sessions.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        let handle = try XCTUnwrap(db)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(sqlite3_exec(handle, """
            CREATE TABLE sessions (id TEXT PRIMARY KEY, working_directory TEXT NOT NULL, backend_type TEXT NOT NULL,
                model TEXT NOT NULL, agent_mode TEXT NOT NULL, created_at INTEGER NOT NULL, last_activity_at INTEGER NOT NULL,
                title TEXT, hidden INTEGER NOT NULL DEFAULT 0, metadata TEXT);
            INSERT INTO sessions VALUES ('s1', '/w', 'windsurf', 'm', 'bypass', \(sec(-100)), \(sec(-50)), 'T', 0, NULL);
            """, nil, nil, nil), SQLITE_OK)
        let result = try DevinSessions.read(url, since: now.addingTimeInterval(-86400))
        XCTAssertEqual(result.sessions.map(\.id), ["devin:s1"])
        XCTAssertNotNil(result.notice, "sessions without an event table get listed but say so")
    }
}
