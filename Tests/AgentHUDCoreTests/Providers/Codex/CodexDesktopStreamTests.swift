import AgentHUDSupport
import Foundation
import XCTest
@testable import AgentHUDCore

private actor Count {
    var value = 0
    func add() { value += 1 }
}

final class CodexDesktopStreamTests: XCTestCase, @unchecked Sendable {
    private let threadID = "native-thread"

    private func request(_ id: Int64, completed: Bool = false) -> JSONValue {
        .object([
            "id": .integer(id), "method": .string("mcpServer/elicitation/request"), "completed": .bool(completed),
            "params": .object([
                "threadId": .string(threadID), "mode": .string("form"),
                "_meta": .object([
                    "codex_approval_kind": .string("mcp_tool_call"), "connector_id": .string("computer-use"),
                    "tool_params": .object(["app": .string("app.agenthud")]), "persist": .array([.string("session")]),
                ]),
            ]),
        ])
    }

    private func state(_ requests: [JSONValue] = []) -> JSONValue {
        .object(["id": .string(threadID), "cwd": .string("/Users/me/project"), "requests": .array(requests)])
    }

    private func patch(_ op: String, _ path: [JSONValue], _ value: JSONValue? = nil) -> JSONValue {
        var patch: [String: JSONValue] = ["op": .string(op), "path": .array(path)]
        patch["value"] = value
        return .object(patch)
    }

    private func following(_ server: CodexDesktopTestServer) async throws -> CodexDesktopPermissions {
        let client = CodexDesktopPermissions(dataDirectory: server.directory, timeout: 1)
        client.stream.retry = 0.3
        client.stream.follow([threadID])
        addTeardownBlock { client.stream.stop() }
        try await arrived(server, at: client)
        return client
    }

    private func arrived(_ server: CodexDesktopTestServer, at client: CodexDesktopPermissions,
                         file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<1000 {
            if client.stream.thread(threadID)?.revision == server.revision { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("the fixture's state never reached the stream", file: file, line: line)
    }

    func testAFollowedThreadIsKeptCurrentByWhatItsOwnerSaysChangedAndIsAskedForOnce() async throws {
        let server = try CodexDesktopTestServer(state: state())
        defer { server.stop() }
        let client = try await following(server)
        XCTAssertEqual(client.snapshot().observedThreadIDs, [threadID])
        XCTAssertTrue(client.snapshot().pending.isEmpty)

        let heard = Count()
        let listening = Task { for await _ in client.stream.changes { await heard.add() } }
        server.change([patch("add", [.string("requests"), .integer(0)], request(7))])
        try await arrived(server, at: client)
        XCTAssertEqual(client.snapshot().pending.map(\.requestID), [.integer(7)], "a request appears with the change that brings it")
        server.change([patch("add", [.string("requests"), .integer(1)], request(8)),
                       patch("replace", [.string("requests"), .integer(0), .string("completed")], .bool(true))])
        try await arrived(server, at: client)
        XCTAssertEqual(client.snapshot().pending.map(\.requestID), [.integer(8)], "and goes with the change that settles it")
        server.change([patch("remove", [.string("requests"), .integer(1)]), patch("remove", [.string("requests"), .integer(0)])])
        try await arrived(server, at: client)
        XCTAssertTrue(client.snapshot().pending.isEmpty)
        XCTAssertEqual(client.snapshot().observedThreadIDs, [threadID])
        XCTAssertEqual(server.follows, 1, "the thread's whole state was sent once; everything after it was a change")
        try await Task.sleep(for: .milliseconds(300))
        listening.cancel()
        let announced = await heard.value
        XCTAssertGreaterThanOrEqual(announced, 3, "each change is announced to whoever listens")
    }

    func testAThreadWhoseOwnerSaysItWaitsOnTheUserIsWaitingWhateverItAsked() async throws {
        let server = try CodexDesktopTestServer(state: state())
        defer { server.stop() }
        let client = try await following(server)
        XCTAssertTrue(client.snapshot().waitingThreadIDs.isEmpty)
        for (flags, waits) in [(["waitingOnApproval"], true), (["waitingOnUserInput"], true), ([], false), (["somethingElse"], false)] {
            server.change([patch("add", [.string("threadRuntimeStatus")],
                                 .object(["type": .string("active"), "activeFlags": .array(flags.map(JSONValue.string))]))])
            try await arrived(server, at: client)
            XCTAssertEqual(client.snapshot().waitingThreadIDs.contains(threadID), waits, "\(flags)")
            XCTAssertTrue(client.snapshot().pending.isEmpty, "no card is made of a flag: the HUD shows only what it can answer")
        }
        server.change([patch("replace", [.string("threadRuntimeStatus")],
                             .object(["type": .string("idle"), "activeFlags": .array([.string("waitingOnApproval")])]))])
        try await arrived(server, at: client)
        XCTAssertFalse(client.snapshot().waitingThreadIDs.contains(threadID), "an idle thread waits on nobody")
    }

    func testAMissedRevisionOrAPatchThatNamesNoPlaceAsksForTheWholeStateAgain() async throws {
        let server = try CodexDesktopTestServer(state: state([request(7)]))
        defer { server.stop() }
        let client = try await following(server)
        // A change the state already includes, late on its way, changes nothing and asks for nothing.
        server.change([patch("remove", [.string("requests"), .integer(0)])], base: 0, late: 1)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(client.snapshot().pending.map(\.requestID), [.integer(7)])
        XCTAssertEqual(server.follows, 1)
        // A change that follows a revision the stream never held: applying it would describe a thread that never was.
        server.change([patch("remove", [.string("requests"), .integer(0)])], base: 40)
        for _ in 0..<200 where client.stream.thread(threadID) != nil && server.follows == 1 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(client.stream.thread(threadID) == nil || server.follows == 2, "until the owner sends it again the thread is unknown")
        try await arrived(server, at: client)
        XCTAssertEqual(server.follows, 2)
        XCTAssertEqual(client.snapshot().pending.map(\.requestID), [.integer(7)], "the state is the owner's own again")
        server.change([patch("replace", [.string("turns"), .integer(3), .string("status")], .string("completed"))])
        try await arrived(server, at: client)
        XCTAssertEqual(server.follows, 3)
        XCTAssertEqual(client.snapshot().pending.map(\.requestID), [.integer(7)])
    }

    func testAThreadAskedAboutOnceIsFollowedForTheAskingAndAWhileAfter() async throws {
        let server = try CodexDesktopTestServer(state: state([request(7)]))
        defer { server.stop() }
        let stream = CodexDesktopStream(dataDirectory: server.directory)
        addTeardownBlock { stream.stop() }
        XCTAssertNil(stream.thread(threadID), "nothing is followed until something is wanted")
        let known = await stream.thread(threadID, within: 5, linger: 0.3)
        XCTAssertEqual(known?.ownerClientID, "desktop-owner")
        XCTAssertEqual(known?.state["cwd"].stringValue, "/Users/me/project")
        // Another user of the stream keeps its own threads through the first one's comings and goings.
        stream.follow(["another-thread"], for: "approvals")
        XCTAssertEqual(stream.following, [threadID, "another-thread"])
        _ = await stream.thread(threadID, within: 1, linger: 0.3)
        XCTAssertEqual(server.follows, 1, "asked about again while followed, the thread is not sent again")
        for _ in 0..<500 where stream.following != ["another-thread"] { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(stream.following, ["another-thread"], "the asking's own following ends after its while")
        stream.follow([], for: "approvals")
        for _ in 0..<500 where server.unfollows == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(stream.thread(threadID))
        let unowned = await CodexDesktopStream(dataDirectory: URL(fileURLWithPath: "/private/tmp/agenthud-missing-\(UUID().uuidString)"))
            .thread(threadID, within: 0.3, linger: 0.1)
        XCTAssertNil(unowned, "a thread nobody describes in time is unknown")
    }

    func testAThreadNoLongerAskedForIsLeftAndAnOwnerThatLeavesTakesItsThreads() async throws {
        let server = try CodexDesktopTestServer(state: state([request(7)]))
        defer { server.stop() }
        let client = try await following(server)
        server.announce("client-status-changed", ["clientId": .string("another-client"), "status": .string("disconnected")])
        server.announce("client-status-changed", ["clientId": .string("desktop-owner"), "status": .string("connected")])
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNotNil(client.stream.thread(threadID), "only its own owner leaving ends a following")
        server.announce("client-status-changed", ["clientId": .string("desktop-owner"), "status": .string("disconnected")])
        for _ in 0..<500 where client.stream.thread(threadID) != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(client.stream.thread(threadID), "what a departed owner last said is not kept as the thread's state")
        XCTAssertTrue(client.snapshot().observedThreadIDs.isEmpty)

        let other = try CodexDesktopTestServer(state: state([request(7)]))
        defer { other.stop() }
        let second = try await following(other)
        second.stream.follow([])
        for _ in 0..<500 where other.unfollows == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(other.unfollows, 1, "the owner is told, and stops sending the thread's changes")
        XCTAssertNil(second.stream.thread(threadID))
    }
}
