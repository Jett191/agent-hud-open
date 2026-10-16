import AgentHUDSupport
import Darwin
import Foundation
import XCTest
@testable import AgentHUDCore

final class CodexDesktopPermissionsTests: XCTestCase, @unchecked Sendable {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let threadID = "native-thread"

    private func wire(id: JSONValue = .string("native-request"), threadID: String = "native-thread",
                      persist: JSONValue = .array([.string("session"), .string("always")]),
                      completed: Bool = false) -> JSONValue {
        .object([
            "id": id, "method": .string("mcpServer/elicitation/request"), "completed": .bool(completed),
            "params": .object([
                "threadId": .string(threadID), "turnId": .string("native-turn"), "mode": .string("form"),
                "serverName": .string("cua_repl"), "message": .string("Allow Computer Use to use \"Agent HUD\"?"),
                "requestedSchema": .object(["type": .string("object"), "properties": .object([:])]),
                "_meta": .object([
                    "codex_approval_kind": .string("mcp_tool_call"), "connector_id": .string("computer-use"),
                    "connector_name": .string("Computer Use"), "persist": persist,
                    "tool_name": .string("get_app_state"), "tool_params": .object(["app": .string("com.agenthud.app")]),
                    "tool_params_display": .array([.object([
                        "name": .string("app"), "display_name": .string("App"), "value": .string("Agent HUD"),
                    ])]),
                ]),
            ]),
        ])
    }

    private func state(_ requests: [JSONValue]) -> JSONValue {
        .object(["id": .string(threadID), "cwd": .string("/Users/me/project"), "requests": .array(requests)])
    }

    private func pending(_ wire: JSONValue? = nil) throws -> CodexDesktopPermissions.Pending {
        try XCTUnwrap(CodexDesktopPermissions.pending(state([wire ?? self.wire()]), threadID: threadID,
            ownerClientID: "desktop-owner", now: now).first)
    }

    /// A client that follows the fixture's thread, once the fixture's current state has reached it.
    private func following(_ server: CodexDesktopTestServer) async throws -> CodexDesktopPermissions {
        let client = CodexDesktopPermissions(dataDirectory: server.directory, timeout: 1)
        client.stream.follow([threadID])
        addTeardownBlock { client.stream.stop() }
        try await arrived(server, at: client)
        return client
    }

    /// Waits for the fixture's newest revision to be the one the client holds.
    private func arrived(_ server: CodexDesktopTestServer, at client: CodexDesktopPermissions,
                         file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<1000 {
            if client.stream.thread(threadID)?.revision == server.revision { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("the fixture's state never reached the stream", file: file, line: line)
    }

    private func replacing(_ value: JSONValue, at path: [String], with replacement: JSONValue) -> JSONValue {
        guard let key = path.first, var object = value.objectValue else { return value }
        object[key] = path.count == 1 ? replacement : replacing(object[key] ?? .null, at: Array(path.dropFirst()), with: replacement)
        return .object(object)
    }

    private func question(_ title: String = "What should I check next?", options: JSONValue = .null) -> JSONValue {
        .object(["title": .string(title), "options": options])
    }

    private func questionState(_ questions: [JSONValue], extraItems: [JSONValue] = [], status: String = "inProgress",
                               turnID: String = "native-turn", canonical: Bool = false,
                               requests: [JSONValue] = []) -> JSONValue {
        let turn = JSONValue.object([
            "turnId": .string(turnID), "status": .string(status),
            "items": .array([.object([
                "id": .string("message"), "type": .string("agentMessage"), "text": .string("Please provide your input."),
                "questions": .array(questions),
            ])] + extraItems),
        ])
        var result: [String: JSONValue] = ["id": .string(threadID), "cwd": .string("/Users/me/project"), "requests": .array(requests)]
        if canonical {
            result["turns"] = .array([])
            result["turnHistory"] = .object(["kind": .string("canonical"), "history": .object([
                "generation": .integer(1), "isComplete": .bool(true),
                "entitiesByKey": .object(["turn:\(turnID)": turn]),
                "islands": .array([.object([
                    "id": .string("live-history"),
                    "entries": .array([.object(["key": .string("turn:\(turnID)"), "value": .string("turn:\(turnID)")])]),
                    "olderBoundary": .object(["status": .string("exhausted")]),
                    "newerBoundary": .object(["status": .string("exhausted")]),
                ])]),
            ])])
        } else { result["turns"] = .array([turn]) }
        return .object(result)
    }

    private func pendingQuestion(_ state: JSONValue? = nil) throws -> CodexDesktopPermissions.Pending {
        try XCTUnwrap(CodexDesktopPermissions.pending(state ?? questionState([question()]), threadID: threadID,
            ownerClientID: "desktop-owner", now: now).first(where: { $0.request.isQuestion }))
    }

    private func questionReply(answer: String = "ready", index: Int64 = 0,
                               title: String = "What should I check next?", asArray: Bool = true) throws -> String {
        let questionID = String(decoding: try RecordCoding.encoder().encode(JSONValue.array([
            .string("request_user_input_async"), .string("message"), .integer(index),
        ])), as: UTF8.self)
        let payload = JSONValue.object(["questionItemId": .string(questionID), "question": .string(title), "answer": .string(answer)])
        let encoded = try RecordCoding.encoder().encode(asArray ? JSONValue.array([payload]) : payload)
        return "<send_user_message_question_reply>\n\(String(decoding: encoded, as: UTF8.self))\n</send_user_message_question_reply>"
    }

    private func replyItem(_ text: String, type: String = "steeringUserMessage", status: String? = "accepted") -> JSONValue {
        var item: [String: JSONValue] = ["type": .string(type), "id": .string("external-answer")]
        if let status { item["status"] = .string(status) }
        item[type == "userMessage" ? "content" : "input"] = .array([.object(["type": .string("text"), "text": .string(text)])])
        return .object(item)
    }

    func testActualAgentMessageQuestionsKeepFreeformAndNativeChoicesSeparately() throws {
        let raw = [question(), question("Which checks?", options: .array([.string("Smoke"), .string("Full suite")]))]
        let found = try CodexDesktopPermissions.pending(questionState(raw), threadID: threadID,
            ownerClientID: "desktop-owner", now: now)
        XCTAssertEqual(found.count, 2)
        let freeform = try XCTUnwrap(found.first)
        XCTAssertEqual(freeform.request.questions.count, 1)
        XCTAssertTrue(freeform.request.questions[0].options.isEmpty)
        XCTAssertEqual(freeform.request.questions[0].question, "What should I check next?")
        XCTAssertEqual(freeform.requestID, .string("[\"request_user_input_async\",\"message\",0]"))
        XCTAssertEqual(freeform.request.questions[0].answerKey, "[\"request_user_input_async\",\"message\",0]")
        XCTAssertEqual(freeform.request.nativeApproval, .asynchronousQuestion(turnID: "native-turn"))
        XCTAssertEqual(freeform.wireRequest, .object([
            "turnId": .string("native-turn"), "sourceItemId": .string("message"), "questionIndex": .integer(0), "question": raw[0],
        ]))
        XCTAssertEqual(found[1].request.questions[0].options.map(\.label), ["Smoke", "Full suite"])
        XCTAssertFalse(found[1].request.questions[0].multiSelect)
        XCTAssertNotEqual(found[0].id, found[1].id)
        XCTAssertNil(freeform.request.alwaysAllow)
        XCTAssertEqual(freeform.request.cwd, "/Users/me/project")
    }

    func testCanonicalQuestionHistoryMatchesLegacyStateAndCoexistsWithAppApprovals() throws {
        let legacy = try CodexDesktopPermissions.pending(questionState([question()], requests: [wire()]),
            threadID: threadID, ownerClientID: "desktop-owner", now: now)
        let canonical = try CodexDesktopPermissions.pending(questionState([question()], canonical: true, requests: [wire()]),
            threadID: threadID, ownerClientID: "desktop-owner", now: now)
        XCTAssertEqual(legacy.count, 2)
        XCTAssertEqual(Set(legacy.map(\.id)), Set(canonical.map(\.id)))
        XCTAssertEqual(canonical.filter { $0.request.isQuestion }.count, 1)
        XCTAssertEqual(canonical.filter { $0.request.nativeApproval == .computerUseApp(persist: ["session", "always"]) }.count, 1)
    }

    func testOnlyAcceptedExternalQuestionRepliesHideTheCorrespondingQuestion() throws {
        let questions = [question(), question("Which checks?", options: .array([.string("Smoke")]))]
        for status in [nil, "pending", "rejected", "failed"] as [String?] {
            let snapshot = questionState(questions, extraItems: [replyItem(try questionReply(), status: status)])
            XCTAssertEqual(try CodexDesktopPermissions.pending(snapshot, threadID: threadID,
                ownerClientID: "desktop-owner", now: now).count, 2, "An unaccepted steer is not an answer")
        }
        for item in [replyItem(try questionReply()), replyItem(try questionReply(asArray: false), type: "userMessage", status: nil)] {
            let snapshot = questionState(questions, extraItems: [item])
            let found = try CodexDesktopPermissions.pending(snapshot, threadID: threadID, ownerClientID: "desktop-owner", now: now)
            XCTAssertEqual(found.count, 1)
            XCTAssertEqual(found.first?.request.questions[0].question, "Which checks?")
        }
        let malformed = "<send_user_message_question_reply>\n{\"questionItemId\":\"[\\\"request_user_input_async\\\",\\\"message\\\",0]\",\"answer\":\"ready\"}\n</send_user_message_question_reply>"
        XCTAssertEqual(try CodexDesktopPermissions.pending(questionState(questions, extraItems: [replyItem(malformed)]),
            threadID: threadID, ownerClientID: "desktop-owner", now: now).count, 2)
    }

    func testQuestionAnswerUsesNativeEnvelopeAndSkipLeavesTheQuestionInDesktop() throws {
        let item = try pendingQuestion()
        let key = item.request.questions[0].answerKey
        XCTAssertEqual(try CodexDesktopPermissions.response(.answer([key: .init(custom: "ready")]), for: item),
                       .string(try questionReply()))
        XCTAssertNil(try CodexDesktopPermissions.response(.answer([:]), for: item))
        XCTAssertNil(try CodexDesktopPermissions.response(.leave, for: item))
        XCTAssertThrowsError(try CodexDesktopPermissions.response(.allow, for: item))
        XCTAssertThrowsError(try CodexDesktopPermissions.response(.deny, for: item))
        XCTAssertThrowsError(try CodexDesktopPermissions.response(.allowAlways(.object(["persist": .string("always")])), for: item))
        let choice = try pendingQuestion(questionState([question(options: .array([.string("Smoke"), .string("Full suite")]))]))
        XCTAssertEqual(try CodexDesktopPermissions.response(.answer([choice.request.questions[0].answerKey: .init(selected: ["Smoke"])]), for: choice),
                       .string(try questionReply(answer: "Smoke")))
    }

    func testQuestionAnswerSteersOnlyTheExistingOwnerAndPreservesTheCompleteEnvelope() async throws {
        let server = try CodexDesktopTestServer(state: questionState([question()], canonical: true))
        defer { server.stop() }
        let client = try await following(server)
        let item = try XCTUnwrap(client.snapshot().pending.first)
        let answer = PermissionDecision.answer([item.request.questions[0].answerKey: .init(custom: "ready")])
        try await client.resolve(answer, for: item)
        let sent = try XCTUnwrap(server.answers.first)
        XCTAssertEqual(sent["method"].stringValue, "thread-follower-steer-turn")
        XCTAssertEqual(sent["version"], .integer(1))
        XCTAssertEqual(sent["targetClientId"].stringValue, "desktop-owner")
        XCTAssertEqual(sent["params"]["conversationId"].stringValue, threadID)
        let input = try XCTUnwrap(sent["params"]["input"].arrayValue)
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input[0]["type"].stringValue, "text")
        XCTAssertEqual(input[0]["text"].stringValue, try questionReply())
        XCTAssertEqual(input[0]["text_elements"], .array([]))
        XCTAssertEqual(sent["params"]["restoreMessage"]["text"].stringValue, try questionReply())
        XCTAssertTrue(server.methods.allSatisfy { $0 != "thread-follower-start-turn" })
        let before = server.methods
        try await client.resolve(.answer([:]), for: item)
        XCTAssertEqual(server.methods, before, "Skip is a local HUD dismissal, not a steering input")
    }

    func testWithdrawnChangedCompletedOrReplacedTurnQuestionCannotBeAnswered() async throws {
        let original = questionState([question()])
        let server = try CodexDesktopTestServer(state: original)
        defer { server.stop() }
        let client = try await following(server)
        let item = try pendingQuestion(original)
        let decision = PermissionDecision.answer([item.request.questions[0].answerKey: .init(custom: "ready")])
        let superseded = replacing(original, at: ["turns"], with: .array((original["turns"].arrayValue ?? []) + [
            .object(["turnId": .string("later-turn"), "status": .string("completed"), "items": .array([])]),
        ]))
        XCTAssertEqual(try pendingQuestion(superseded).id, item.id,
                       "The old question can remain displayed while Desktop's current steerable turn has changed")
        for changed in [
            questionState([question("Different question")]),
            questionState([question()], status: "completed"),
            questionState([question()], turnID: "replacement-turn"),
            questionState([question()], extraItems: [replyItem(try questionReply())]),
            questionState([]),
            superseded,
        ] {
            server.state = changed
            try await arrived(server, at: client)
            do { try await client.resolve(decision, for: item); XCTFail("Stale question cannot steer a turn") }
            catch let error as CodexDesktopPermissions.Failure { XCTAssertEqual(error, .noLongerWaiting) }
        }
        server.state = original
        try await arrived(server, at: client)
        server.owner = "replacement-owner"
        do { try await client.resolve(decision, for: item); XCTFail("Question's original owner must still match") }
        catch let error as CodexDesktopPermissions.Failure { XCTAssertEqual(error, .noLongerWaiting) }
        XCTAssertTrue(server.answers.isEmpty)
    }

    func testBadQuestionTurnReceiptIsUncertainAndNeverAutomaticallyRetried() async throws {
        let server = try CodexDesktopTestServer(state: questionState([question()]), acknowledges: false)
        defer { server.stop() }
        let item = try pendingQuestion()
        let answer = PermissionDecision.answer([item.request.questions[0].answerKey: .init(custom: "ready")])
        do {
            try await following(server).resolve(answer, for: item)
            XCTFail("A different acknowledged turn is not the user's question turn")
        } catch let error as CodexDesktopIPC.Failure { XCTAssertEqual(error, .acceptanceUncertain) }
        XCTAssertEqual(server.answers.count, 1)
    }

    func testScreenshotRequestCarriesAppContextAndExactlyTheAdvertisedScopes() throws {
        let item = try pending()
        XCTAssertEqual(item.request.source, .codex)
        XCTAssertEqual(item.request.vendor, "Codex")
        XCTAssertEqual(item.request.sessionID, threadID)
        XCTAssertEqual(item.request.toolName, "computer_use_app")
        XCTAssertTrue(item.request.summary.contains("Agent HUD"))
        XCTAssertEqual(item.request.detail, "com.agenthud.app")
        XCTAssertEqual(item.request.cwd, "/Users/me/project")
        XCTAssertEqual(item.request.at, now)
        XCTAssertEqual(item.request.nativeApproval, .computerUseApp(persist: ["session", "always"]))
        XCTAssertEqual(item.request.alwaysAllow, .object(["persist": .string("always")]))
        XCTAssertEqual(item.wireRequest, wire())
        XCTAssertEqual(item.requestID, .string("native-request"))
        XCTAssertEqual(PermissionDecision.allow.response(for: item.request), PermissionDecision.noDecision)
    }

    func testCompletedUnrelatedAndMalformedRequestsAreExcluded() throws {
        let unrelated: [JSONValue] = [
            wire(completed: true), wire(threadID: "other-thread"),
            wire(persist: .array([.string("always")])), wire(persist: .array([.string("session"), .string("unknown")])),
            wire(persist: .array([.string("session"), .integer(2)])), wire(persist: .null),
            wire(id: .bool(true)), wire(id: .number(1.5)), wire(id: .null), wire(id: .string("")),
            replacing(wire(), at: ["method"], with: .string("item/permissions/requestApproval")),
            replacing(wire(), at: ["params", "mode"], with: .string("url")),
            replacing(wire(), at: ["params", "_meta", "connector_id"], with: .string("browser-use")),
            replacing(wire(), at: ["params", "_meta", "codex_approval_kind"], with: .string("tool_suggestion")),
            replacing(wire(), at: ["params", "_meta", "tool_params", "app"], with: .string("  ")),
        ]
        let found = try CodexDesktopPermissions.pending(state(unrelated + [wire()]), threadID: threadID,
            ownerClientID: "desktop-owner", now: now)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.wireRequest, wire())
        XCTAssertThrowsError(try CodexDesktopPermissions.pending(.object([:]), threadID: threadID,
            ownerClientID: "desktop-owner", now: now))
    }

    func testIdentityNamespacingAndRPCIDTypesPreserveIntegerPrecision() throws {
        let numeric = try pending(wire(id: .integer(Int64.max)))
        let string = try pending(wire(id: .string(String(Int64.max))))
        XCTAssertEqual(numeric.requestID, .integer(Int64.max))
        XCTAssertNotEqual(numeric.id, string.id)
        let other = try XCTUnwrap(CodexDesktopPermissions.pending(
            state([wire(id: .integer(Int64.max), threadID: "other-thread")]), threadID: "other-thread",
            ownerClientID: "desktop-owner", now: now).first)
        XCTAssertNotEqual(numeric.id, other.id)
        XCTAssertEqual(numeric.id, try pending(wire(id: .integer(Int64.max))).id)
        let newOwner = try XCTUnwrap(CodexDesktopPermissions.pending(state([wire(id: .integer(Int64.max))]),
            threadID: threadID, ownerClientID: "replacement-owner", now: now).first)
        XCTAssertNotEqual(numeric.id, newOwner.id)
        let changedTerms = try pending(replacing(wire(id: .integer(Int64.max)),
            at: ["params", "_meta", "tool_params", "app"], with: .string("other.app")))
        XCTAssertEqual(numeric.requestID, changedTerms.requestID)
        XCTAssertNotEqual(numeric.id, changedTerms.id, "Changed native terms must replace the displayed card and its answer closure")
    }

    func testHighRiskNativeWarningIsPreservedWithTheBundleID() throws {
        let risky = replacing(replacing(wire(), at: ["params", "_meta", "riskLevel"], with: .string("high")),
            at: ["params", "_meta", "subtitle"], with: .string("This app can access sensitive information."))
        let item = try pending(risky)
        XCTAssertTrue(item.request.detail?.contains("This app can access sensitive information.") == true)
        XCTAssertTrue(item.request.detail?.contains("com.agenthud.app") == true)
        XCTAssertNotEqual(item.request.detail, "com.agenthud.app")
    }

    func testResponsesMatchNativeConversationAlwaysAndDenyChoices() throws {
        let item = try pending()
        XCTAssertEqual(try CodexDesktopPermissions.response(.allow, for: item), .object([
            "action": .string("accept"), "content": .object([:]), "_meta": .object(["persist": .string("session")]),
        ]))
        XCTAssertEqual(try CodexDesktopPermissions.response(.allowAlways(.object(["persist": .string("always")])), for: item), .object([
            "action": .string("accept"), "content": .object([:]), "_meta": .object(["persist": .string("always")]),
        ]))
        XCTAssertEqual(try CodexDesktopPermissions.response(.deny, for: item), .object([
            "action": .string("decline"), "content": .null, "_meta": .null,
        ]))
        XCTAssertNil(try CodexDesktopPermissions.response(.leave, for: item))
        XCTAssertThrowsError(try CodexDesktopPermissions.response(.answer([:]), for: item))
        XCTAssertThrowsError(try CodexDesktopPermissions.response(.allowAlways(.object([
            "persist": .string("always"), "extra": .bool(true),
        ])), for: item))
    }

    func testSessionOnlyRequestDoesNotOfferOrAcceptAlwaysAllow() throws {
        let item = try pending(wire(persist: .array([.string("session")])))
        XCTAssertNil(item.request.alwaysAllow)
        XCTAssertEqual(item.request.nativeApproval, .computerUseApp(persist: ["session"]))
        XCTAssertThrowsError(try CodexDesktopPermissions.response(.allowAlways(.object(["persist": .string("always")])), for: item))
    }

    /// A browser request as the bundled plugin writes one, in a turn started with the given settings.
    private func browserState(tool: String? = "access_browser_origin", persist: JSONValue = .string("always"),
                              message: String = "Allow ChatGPT to access https://www.reddit.com?",
                              reviewer: String? = "user", policy: String = "on-request", sandbox: String = "workspaceWrite",
                              extra: [String: JSONValue] = [:]) -> JSONValue {
        var metadata: [String: JSONValue] = [
            "codex_approval_kind": .string("mcp_tool_call"), "codex_sensitive_action": .bool(true),
            "connector_id": .string("browser-use"), "connector_name": .string("ChatGPT"), "persist": persist,
            "tool_title": .string("Access browser origin"), "tool_params": .object(["origin": .string("https://www.reddit.com")]),
            "tool_params_display": .array([]), "origin": .string("https://www.reddit.com"),
        ]
        if let tool { metadata["tool_name"] = .string(tool) }
        metadata.merge(extra) { _, new in new }
        var settings: [String: JSONValue] = ["approvalPolicy": .string(policy), "sandboxPolicy": .object(["type": .string(sandbox)])]
        if let reviewer { settings["approvalsReviewer"] = .string(reviewer) }
        return .object([
            "id": .string(threadID), "cwd": .string("/Users/me/project"),
            "turns": .array([.object(["turnId": .string("native-turn"), "status": .string("inProgress"),
                                      "params": .object(settings), "items": .array([])])]),
            "requests": .array([.object([
                "id": .integer(41), "method": .string("mcpServer/elicitation/request"),
                "params": .object([
                    "threadId": .string(threadID), "turnId": .string("native-turn"), "mode": .string("form"),
                    "serverName": .string("cua_repl"), "message": .string(message),
                    "requestedSchema": .object(["type": .string("object"), "properties": .object([:])]),
                    "_meta": .object(metadata),
                ]),
            ])]),
        ])
    }

    private func browser(_ state: JSONValue) throws -> CodexDesktopPermissions.Pending? {
        try CodexDesktopPermissions.pending(state, threadID: threadID, ownerClientID: "desktop-owner", now: now).first
    }

    func testAWebsiteRequestOffersOnceAndAlwaysWithTheSiteItIsAbout() throws {
        let item = try XCTUnwrap(browser(browserState()))
        XCTAssertEqual(item.request.badge, "WEB")
        XCTAssertEqual(item.request.toolName, "access_browser_origin")
        XCTAssertTrue(item.request.summary.contains("ChatGPT") && item.request.summary.contains("https://www.reddit.com"))
        XCTAssertEqual(item.request.detail, "https://www.reddit.com")
        XCTAssertEqual(item.request.nativeApproval, .browserAccess(origin: "https://www.reddit.com", persist: ["always"]))
        XCTAssertEqual(item.request.allowLabel, PermissionRequest(id: "", source: .codex, sessionID: "", toolName: nil, summary: "",
                                                                  detail: nil, cwd: nil, at: now).allowLabel,
                       "with no conversation scope on offer, allowing reads as it does for any one call")
        XCTAssertEqual(item.request.alwaysAllowRule, "https://www.reddit.com", "always allowing adds the site")
        // The answers are the ones Desktop's own card sends: accepted with nothing more, or with the site kept.
        XCTAssertEqual(try CodexDesktopPermissions.response(.allow, for: item),
                       .object(["action": .string("accept"), "content": .object([:]), "_meta": .null]))
        XCTAssertEqual(try CodexDesktopPermissions.response(.allowAlways(.object(["persist": .string("always")])), for: item),
                       .object(["action": .string("accept"), "content": .object([:]), "_meta": .object(["persist": .string("always")])]))
        XCTAssertEqual(try CodexDesktopPermissions.response(.deny, for: item),
                       .object(["action": .string("decline"), "content": .null, "_meta": .null]))
        XCTAssertNil(try CodexDesktopPermissions.response(.leave, for: item))

        let once = try XCTUnwrap(browser(browserState(persist: .null)))
        XCTAssertEqual(once.request.nativeApproval, .browserAccess(origin: "https://www.reddit.com", persist: []))
        XCTAssertNil(once.request.alwaysAllow, "a site that policy keeps from being saved offers no always")
        XCTAssertNil(once.request.alwaysAllowRule)
        XCTAssertThrowsError(try CodexDesktopPermissions.response(.allowAlways(.object(["persist": .string("always")])), for: once))
    }

    func testOtherBrowserRequestsReadAsDesktopWritesThemWithTheScopesTheyOffer() throws {
        let upload = try XCTUnwrap(browser(browserState(tool: "upload_browser_files", persist: .array([.string("session"), .string("always")]),
                                                        message: "Allow upload to reddit.com?")))
        XCTAssertEqual(upload.request.summary, "Allow upload to reddit.com?")
        XCTAssertEqual(try CodexDesktopPermissions.response(.allow, for: upload),
                       .object(["action": .string("accept"), "content": .object([:]), "_meta": .object(["persist": .string("session")])]),
                       "a request that offers the conversation is allowed for it")
        XCTAssertNotEqual(upload.request.allowLabel, try XCTUnwrap(browser(browserState())).request.allowLabel)
        let cdp = try XCTUnwrap(browser(browserState(tool: "access_browser_origin_with_raw_cdp",
            message: "Allow ChatGPT to use full Chrome Developer Tools access on https://www.reddit.com",
            extra: ["riskLevel": .string("high")])))
        XCTAssertTrue(cdp.request.summary.contains("Developer Tools"))
        XCTAssertEqual(cdp.request.detail?.components(separatedBy: "\n\n").count, 2, "the warning Desktop gives stands above the site")
        let history = try XCTUnwrap(browser(browserState(tool: nil, message: "Allow ChatGPT to use your browsing history for this task?",
            extra: ["subtitle": .string("ChatGPT can use records of pages visited."), "origin": .null, "tool_params": .object([:])])))
        XCTAssertEqual(history.request.toolName, "browser")
        XCTAssertEqual(history.request.detail, "ChatGPT can use records of pages visited.")
        XCTAssertNil(try browser(browserState(tool: "download_browser_files", message: " ")), "nothing to read is nothing to ask")
        XCTAssertNil(try browser(browserState(persist: .string("forever"))), "a scope this reader does not know stays with Desktop")
        XCTAssertNil(try browser(browserState(persist: .integer(1))))
    }

    func testABrowserRequestIsShownOnlyInATurnTheUserReviews() throws {
        XCTAssertNil(try browser(browserState(reviewer: "auto_review")), "automatic review answers it without the user")
        XCTAssertNil(try browser(browserState(reviewer: nil)), "an unknown reviewer leaves the request with Desktop")
        XCTAssertNil(try browser(browserState(policy: "never", sandbox: "dangerFullAccess")),
                     "Desktop itself answers a site's pages in a turn that never asks and has full access")
        XCTAssertNotNil(try browser(browserState(tool: "upload_browser_files", persist: .string("session"), message: "Allow upload to reddit.com?",
                                                 policy: "never", sandbox: "dangerFullAccess")), "moving files is still asked there")
        XCTAssertNotNil(try browser(browserState(policy: "never")))
        // A request for a turn the state no longer holds is judged by the thread's current settings.
        var orphan = try XCTUnwrap(browserState().objectValue)
        orphan["turns"] = .array([])
        XCTAssertNil(try browser(.object(orphan)))
        orphan["currentPermissions"] = .object(["approvalsReviewer": .string("user"), "approvalPolicy": .string("on-request")])
        XCTAssertNotNil(try browser(.object(orphan)))
    }

    func testAnAnswerUsesTheStateTheStreamHoldsAndPreservesARawIntegerID() async throws {
        let raw = wire(id: .integer(Int64.max))
        let server = try CodexDesktopTestServer(state: state([raw]))
        defer { server.stop() }
        let client = try await following(server)
        let snapshot = client.snapshot()
        XCTAssertEqual(snapshot.observedThreadIDs, [threadID])
        let item = try XCTUnwrap(snapshot.pending.first)
        try await client.resolve(.allow, for: item)
        let answer = try XCTUnwrap(server.answers.first)
        XCTAssertEqual(answer["targetClientId"].stringValue, "desktop-owner")
        XCTAssertEqual(answer["version"], .integer(1))
        XCTAssertEqual(answer["params"]["requestId"], .integer(Int64.max))
        XCTAssertEqual(answer["params"]["response"]["_meta"]["persist"].stringValue, "session")
        XCTAssertEqual(server.methods.filter { $0 == "thread-owner-discovery" }.count, 2, "the stream's, and the answer's own")
        XCTAssertEqual(server.methods.filter { $0 == "thread-stream-following-changed" }.count, 1,
                       "the answer is checked against the state the stream already holds: the thread is not asked for again")
    }

    func testLongThreadStateIsReadWithItsRequestAndWithoutItsLongStrings() async throws {
        // Desktop sends a thread's whole history with its requests: 108 MB for one thread measured on 2026-10-14, of
        // which 102 MB were its tool results' screenshots and page dumps. This one is past the 64 MiB a reading stopped at.
        var long = try XCTUnwrap(state([wire()]).objectValue)
        long["turns"] = .array([.object(["turnId": .string("earlier-turn"), "status": .string("completed"), "items": .array([
            .object(["id": .string("output"), "type": .string("mcpToolCall"), "result": .object(["content": .array([
                .object(["type": .string("image"), "data": .string(String(repeating: "x", count: 70 * 1024 * 1024))]),
            ])])]),
        ])])])
        let server = try CodexDesktopTestServer(state: .object(long))
        defer { server.stop() }
        let client = try await following(server)
        let snapshot = client.snapshot()
        XCTAssertEqual(snapshot.observedThreadIDs, [threadID])
        XCTAssertEqual(snapshot.pending.map(\.request.toolName), ["computer_use_app"])
        let item = try XCTUnwrap(client.stream.thread(threadID)?.state["turns"].arrayValue?.first?["items"].arrayValue?.first)
        XCTAssertEqual(item["type"].stringValue, "mcpToolCall")
        XCTAssertEqual(item["result"]["content"].arrayValue?.first, .object(["type": .string("image"), "data": .null]),
                       "the picture is passed over as it is read; what surrounds it is kept")
    }

    func testChangedRequestOrOwnerNeverReceivesAnAnswer() async throws {
        let server = try CodexDesktopTestServer(state: state([wire()]))
        defer { server.stop() }
        let client = try await following(server)
        let item = try XCTUnwrap(client.snapshot().pending.first)
        server.state = state([replacing(wire(), at: ["params", "_meta", "tool_params", "app"], with: .string("other.app"))])
        try await arrived(server, at: client)
        do { try await client.resolve(.allow, for: item); XCTFail("Changed permission cannot be approved") }
        catch let error as CodexDesktopPermissions.Failure { XCTAssertEqual(error, .noLongerWaiting) }
        server.state = state([wire()])
        try await arrived(server, at: client)
        server.owner = "new-owner"
        do { try await client.resolve(.deny, for: item); XCTFail("A new owner cannot answer the original permission") }
        catch let error as CodexDesktopPermissions.Failure { XCTAssertEqual(error, .noLongerWaiting) }
        XCTAssertTrue(server.answers.isEmpty)
    }

    func testAlwaysAndDenyDeliverTheNativeResponsesAndRequireOwnerAcknowledgement() async throws {
        for decision in [PermissionDecision.allowAlways(.object(["persist": .string("always")])), .deny] {
            let server = try CodexDesktopTestServer(state: state([wire()]))
            defer { server.stop() }
            let client = try await following(server)
            let item = try pending()
            try await client.resolve(decision, for: item)
            let answer = try XCTUnwrap(server.answers.first)
            XCTAssertEqual(answer["params"]["response"], try CodexDesktopPermissions.response(decision, for: item))
        }
        let server = try CodexDesktopTestServer(state: state([wire()]), acknowledges: false)
        defer { server.stop() }
        do {
            try await following(server).resolve(.allow, for: pending())
            XCTFail("A false owner receipt does not establish acceptance")
        } catch let error as CodexDesktopIPC.Failure { XCTAssertEqual(error, .acceptanceUncertain) }
        XCTAssertEqual(server.answers.count, 1, "An uncertain answer must never be automatically retried")
    }

    func testNoOwnerOrMalformedStateIsUnknownAndLeaveDoesNotConnect() async throws {
        let server = try CodexDesktopTestServer(state: .object([:]))
        defer { server.stop() }
        let client = try await following(server)
        let malformed = client.snapshot()
        XCTAssertTrue(malformed.pending.isEmpty)
        XCTAssertTrue(malformed.observedThreadIDs.isEmpty, "a state that does not read as expected says nothing about what waits")
        let before = server.methods
        try await client.resolve(.leave, for: pending())
        XCTAssertEqual(server.methods, before)

        let ownerless = try CodexDesktopTestServer(state: state([wire()]))
        defer { ownerless.stop() }
        ownerless.owner = nil
        let absent = CodexDesktopPermissions(dataDirectory: ownerless.directory, timeout: 1)
        absent.stream.follow([threadID])
        addTeardownBlock { absent.stream.stop() }
        for _ in 0..<200 where !ownerless.methods.contains("thread-owner-discovery") { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(absent.snapshot().observedThreadIDs.isEmpty)
        XCTAssertFalse(ownerless.methods.contains("thread-stream-following-changed"), "a thread nobody owns is not followed")
        do { try await absent.resolve(.allow, for: pending()); XCTFail("An unknown thread cannot be answered") }
        catch let error as CodexDesktopPermissions.Failure { XCTAssertEqual(error, .noLongerWaiting) }
    }

    func testUnavailableSocketIsUnknownAndCancelledPreflightNeverAnswers() async throws {
        let missing = CodexDesktopPermissions(dataDirectory: URL(fileURLWithPath: "/private/tmp/agenthud-missing-\(UUID().uuidString)"))
        missing.stream.follow([threadID])
        addTeardownBlock { missing.stream.stop() }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(missing.snapshot().observedThreadIDs.isEmpty, "A missing native service is not an empty thread")
        let server = try CodexDesktopTestServer(state: state([wire()]))
        defer { server.stop() }
        let client = try await following(server)
        let item = try pending()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await client.resolve(.allow, for: item)
        }
        do { try await task.value; XCTFail("Cancelled preflight must stop") }
        catch is CancellationError { }
        XCTAssertTrue(server.answers.isEmpty)
    }
}
