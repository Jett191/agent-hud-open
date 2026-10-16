import AgentHUDSupport
import XCTest
@testable import AgentHUDCore

@MainActor
final class CodexDesktopPermissionObserverTests: XCTestCase {
    private func pending(threadID: String = "desktop-thread") throws -> CodexDesktopPermissions.Pending {
        let wire = JSONValue.object([
            "id": .integer(7), "method": .string("mcpServer/elicitation/request"),
            "params": .object([
                "threadId": .string(threadID), "mode": .string("form"),
                "_meta": .object([
                    "codex_approval_kind": .string("mcp_tool_call"), "connector_id": .string("computer-use"),
                    "tool_name": .string("use_app"),
                    "tool_params": .object(["app": .string("app.agenthud")]),
                    "persist": .array([.string("session"), .string("always")]),
                ]),
            ]),
        ])
        return try XCTUnwrap(CodexDesktopPermissions.pending(.object(["requests": .array([wire])]),
            threadID: threadID, ownerClientID: "desktop-owner", now: Date()).first)
    }

    func testDismissalSurvivesFailedReadingAndEndsOnlyWithTheOwnersCompleteSnapshot() throws {
        let queue = PermissionRequests(), observer = CodexDesktopPermissionObserver(requests: queue, client: .init())
        let item = try pending()
        let waiting = CodexDesktopPermissions.Snapshot(pending: [item], observedThreadIDs: [item.threadID])
        observer.reconcile(waiting)
        XCTAssertEqual(queue.pending, [item.request])
        queue.resolve(item.id, .leave)
        observer.reconcile(.init(pending: [], observedThreadIDs: []))
        observer.reconcile(waiting)
        XCTAssertTrue(queue.pending.isEmpty, "a disconnect cannot undo the user's dismissal")
        observer.reconcile(.init(pending: [], observedThreadIDs: [item.threadID]))
        observer.reconcile(waiting)
        XCTAssertEqual(queue.pending, [item.request], "a subsequent native request can be displayed")
        observer.stop()
    }

    func testReadingOneThreadCannotSettleAnotherThreadsDismissal() throws {
        let queue = PermissionRequests(), observer = CodexDesktopPermissionObserver(requests: queue, client: .init())
        let first = try pending(threadID: "first"), second = try pending(threadID: "second")
        observer.reconcile(.init(pending: [first, second], observedThreadIDs: ["first", "second"]))
        queue.resolve(second.id, .leave)
        observer.reconcile(.init(pending: [], observedThreadIDs: ["first"]))
        observer.reconcile(.init(pending: [second], observedThreadIDs: ["second"]))
        XCTAssertTrue(queue.pending.isEmpty)
        observer.stop()
    }

    func testExternalAnswerWithdrawsTheCardAndStoppingResetsObservation() throws {
        let queue = PermissionRequests(), observer = CodexDesktopPermissionObserver(requests: queue, client: .init())
        let item = try pending()
        let waiting = CodexDesktopPermissions.Snapshot(pending: [item], observedThreadIDs: [item.threadID])
        observer.reconcile(waiting)
        observer.reconcile(.init(pending: [], observedThreadIDs: [item.threadID]))
        XCTAssertTrue(queue.pending.isEmpty)
        observer.reconcile(waiting)
        queue.resolve(item.id, .leave)
        observer.stop()
        observer.reconcile(waiting)
        XCTAssertEqual(queue.pending, [item.request])
        observer.stop()
    }

    func testAThreadIsFollowedWhileItsSessionIsInFlightOrACardOfItsWaits() throws {
        let client = CodexDesktopPermissions(dataDirectory: URL(fileURLWithPath: "/private/tmp/agenthud-missing-\(UUID().uuidString)"))
        let queue = PermissionRequests(), observer = CodexDesktopPermissionObserver(requests: queue, client: client)
        func session(_ id: String) -> LiveSession {
            .init(id: id, agentId: "codex", task: "Task", terminal: nil, startedAt: Date(), endedAt: nil, pctOfWindow: nil,
                  tokensIn: 0, tokensOut: 0, navigationTarget: .codexThread(id: id))
        }
        observer.updateSessions([session("running")], at: 100)
        XCTAssertEqual(client.stream.following, [], "an observer that is off follows nothing")
        observer.setEnabled(true)
        XCTAssertEqual(client.stream.following, ["running"])
        let item = try pending(threadID: "asked")
        observer.reconcile(.init(pending: [item], observedThreadIDs: ["asked"]))
        observer.updateSessions([], at: 102)
        XCTAssertEqual(client.stream.following, ["running", "asked"],
                       "a turn that ended is followed a while longer: the next one would have the whole state sent again")
        observer.updateSessions([], at: 100 + CodexDesktopPermissionObserver.linger)
        XCTAssertEqual(client.stream.following, ["asked"], "a card outlives the session that raised it")
        observer.reconcile(.init(pending: [], observedThreadIDs: ["asked"]))
        XCTAssertEqual(client.stream.following, [], "once Desktop settles the card there is nothing left to hear of")
        observer.stop()
    }

    func testAThreadWhoseStateIsUnknownHidesItsCardUntilItIsKnownAgain() throws {
        let queue = PermissionRequests(), observer = CodexDesktopPermissionObserver(requests: queue, client: .init())
        let item = try pending()
        let waiting = CodexDesktopPermissions.Snapshot(pending: [item], observedThreadIDs: [item.threadID])
        observer.reconcile(waiting)
        observer.reconcile(.init(pending: [], observedThreadIDs: []))
        XCTAssertTrue(queue.pending.isEmpty, "a connection that dropped says nothing, and a card nobody can answer is not shown")
        observer.reconcile(waiting)
        XCTAssertEqual(queue.pending, [item.request], "the request was never settled, so it returns with the state")
        observer.stop()
    }

    func testOnlyLiveDesktopDestinationsIncludingChildrenAreObserved() {
        func session(_ id: String, live: Bool = true, target: Bool = true, children: [LiveSession]? = nil) -> LiveSession {
            .init(id: id, agentId: "codex", task: "Task", terminal: nil, startedAt: Date(),
                  endedAt: live ? nil : Date(), pctOfWindow: nil, tokensIn: 0, tokensOut: 0,
                  subagentSessions: children, navigationTarget: target ? .codexThread(id: id) : nil)
        }
        let parent = session("parent", children: [session("child"), session("ended-child", live: false)])
        XCTAssertEqual(CodexDesktopPermissionObserver.threadIDs(in: [parent, session("ended", live: false), session("cli", target: false)]),
                       ["parent", "child"])
    }
}
