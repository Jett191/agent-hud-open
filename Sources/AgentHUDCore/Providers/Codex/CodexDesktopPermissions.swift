import AgentHUDSupport
import Foundation

/// Native app and browser approvals and mid-turn questions belong to Desktop's original owner, independently of CLI
/// hooks. What is waiting is read from the threads a `CodexDesktopStream` follows, and an answer goes to the owner.
public struct CodexDesktopPermissions: Sendable {
    public struct Pending: Sendable {
        public let request: PermissionRequest
        public let threadID: String
        public let ownerClientID: String
        public let wireRequest: JSONValue
        public let requestID: JSONValue
        public var id: String { request.id }
    }

    public struct Snapshot: Sendable {
        public let pending: [Pending]
        /// Only threads whose state is known can establish that a previously visible request has disappeared.
        public let observedThreadIDs: Set<String>
        /// Threads whose owner says their turn waits on the user, for an approval or an answer, whether or not the HUD
        /// shows a card for what it asked.
        public var waitingThreadIDs: Set<String> = []
    }

    /// The flags Desktop sets on an active thread while it waits on the user.
    static let waitingFlags: Set<String> = ["waitingOnApproval", "waitingOnUserInput"]

    public enum Failure: Error, Equatable, Sendable {
        case noLongerWaiting, unsupportedDecision
    }

    private let dataDirectory: URL
    private let timeout: TimeInterval
    /// The followed threads, kept current by their owners' changes.
    public let stream: CodexDesktopStream
    var clock: @Sendable () -> Date = { Date() }

    /// - stream: the followed threads to read; by default a stream of this reader's own on `dataDirectory`.
    public init(dataDirectory: URL = CodexLocator.dataDirectory, timeout: TimeInterval = 3, stream: CodexDesktopStream? = nil) {
        self.dataDirectory = dataDirectory
        self.timeout = timeout
        self.stream = stream ?? CodexDesktopStream(dataDirectory: dataDirectory)
    }

    /// What the followed threads are waiting on at this moment. A thread whose state is not known, or cannot be read
    /// as this reader expects it, is left out of the observed ones rather than read as waiting on nothing.
    public func snapshot() -> Snapshot {
        var found: [Pending] = [], observed = Set<String>(), waiting = Set<String>()
        for (threadID, thread) in stream.threads {
            let status = thread.state["threadRuntimeStatus"]
            if status["type"].stringValue == "active",
               (status["activeFlags"].arrayValue ?? []).contains(where: { Self.waitingFlags.contains($0.stringValue ?? "") }) {
                waiting.insert(threadID)
            }
            guard let requests = try? Self.pending(thread.state, threadID: threadID, ownerClientID: thread.ownerClientID,
                                                   now: clock()) else { continue }
            found += requests
            observed.insert(threadID)
        }
        return Snapshot(pending: found.sorted { $0.id < $1.id }, observedThreadIDs: observed, waitingThreadIDs: waiting)
    }

    /// Confirms the exact owner and request in the thread as it now stands before sending only the option the user selected.
    public func resolve(_ decision: PermissionDecision, for pending: Pending) async throws {
        guard let response = try Self.response(decision, for: pending) else { return }
        guard timeout.isFinite, timeout > 0 else { throw CodexDesktopIPC.Failure.invalidInput }
        try Task.checkCancellation()
        try await detached { [self] in
            try Task.checkCancellation()
            // The stream's copy is the owner's own account of the thread, as of its last change.
            guard let thread = stream.thread(pending.threadID), thread.ownerClientID == pending.ownerClientID else {
                throw Failure.noLongerWaiting
            }
            let state = thread.state
            let current = try Self.pending(state, threadID: pending.threadID, ownerClientID: thread.ownerClientID, now: clock())
            guard current.contains(where: { $0.id == pending.id && $0.wireRequest == pending.wireRequest }) else {
                throw Failure.noLongerWaiting
            }
            let connection = try CodexDesktopIPC(path: socketPath, timeout: timeout)
            defer { connection.close() }
            let clientID = try Self.initialize(connection)
            // A thread can pass to another client between two of its changes: the answer goes to who owns it now, and
            // only when that is still who asked.
            let owner: String
            do { owner = try Self.owner(connection, source: clientID, threadID: pending.threadID) }
            catch CodexDesktopIPC.Failure.rejected("no-client-found") { throw Failure.noLongerWaiting }
            guard owner == pending.ownerClientID else { throw Failure.noLongerWaiting }
            try Task.checkCancellation()
            let method: String
            let params: [String: Any]
            switch pending.request.nativeApproval {
            case .computerUseApp, .browserAccess:
                method = Self.answerMethod
                params = ["conversationId": pending.threadID,
                          "requestId": try Self.foundation(pending.requestID),
                          "response": try Self.foundation(response)]
            case .asynchronousQuestion(let turnID):
                guard try CodexDesktopQuestions.currentTurnID(state) == turnID,
                      let text = response.stringValue else { throw Failure.noLongerWaiting }
                method = Self.questionAnswerMethod
                let messageID = UUID().uuidString.lowercased()
                var context: [String: Any] = ["prompt": text, "turnTrigger": "send_user_message_async_question",
                    "addedFiles": [], "fileAttachments": [], "ideContext": NSNull(), "imageAttachments": []]
                var restore: [String: Any] = ["id": messageID, "text": text, "context": context,
                                             "createdAt": clock().timeIntervalSince1970 * 1000]
                if let cwd = state["cwd"].stringValue {
                    context["workspaceRoots"] = [cwd]
                    restore["context"] = context
                    restore["cwd"] = cwd
                }
                params = ["conversationId": pending.threadID, "clientUserMessageId": messageID,
                          "input": [["type": "text", "text": text, "text_elements": []]],
                          "attachments": [], "restoreMessage": restore]
            case nil: throw Failure.unsupportedDecision
            }
            let reply: [String: Any]
            var wroteAnswer = false
            do {
                reply = try connection.request(method: method, version: 1, source: clientID,
                    target: owner, params: params, didWrite: { wroteAnswer = true })
            } catch let error as CodexDesktopIPC.Failure {
                if case .rejected(let reason) = error,
                   !["request-timeout", "server-closed", "client-disconnected"].contains(reason) { throw error }
                throw wroteAnswer ? CodexDesktopIPC.Failure.acceptanceUncertain : error
            } catch {
                if wroteAnswer { throw CodexDesktopIPC.Failure.acceptanceUncertain }
                throw error
            }
            let receipt = try Self.json(reply)
            guard receipt["handledByClientId"].stringValue == owner,
                  receipt["result"]["method"].stringValue == method else {
                throw CodexDesktopIPC.Failure.acceptanceUncertain
            }
            switch pending.request.nativeApproval {
            case .computerUseApp, .browserAccess:
                guard receipt["result"]["result"]["ok"] == .bool(true) else {
                    throw CodexDesktopIPC.Failure.acceptanceUncertain
                }
            case .asynchronousQuestion(let turnID):
                guard receipt["result"]["result"]["result"]["turnId"].stringValue == turnID else {
                    throw CodexDesktopIPC.Failure.acceptanceUncertain
                }
            case nil: throw Failure.unsupportedDecision
            }
        }
    }

    private static let answerMethod = "thread-follower-submit-mcp-server-elicitation-response"
    private static let questionAnswerMethod = "thread-follower-steer-turn"
    private var socketPath: String { dataDirectory.appendingPathComponent("ipc/ipc.sock").path }

    private static func initialize(_ connection: CodexDesktopIPC) throws -> String {
        let initialized = try connection.request(method: "initialize", version: 0,
            source: "initializing-client", params: ["clientType": "agent-hud"])
        guard let clientID = (initialized["result"] as? [String: Any])?["clientId"] as? String,
              !clientID.isEmpty else { throw CodexDesktopIPC.Failure.protocolError }
        return clientID
    }

    private static func owner(_ connection: CodexDesktopIPC, source: String, threadID: String) throws -> String {
        let discovered = try connection.request(method: "thread-owner-discovery", version: 1,
            source: source, params: ["hostId": "local", "conversationId": threadID])
        guard let owner = discovered["handledByClientId"] as? String, !owner.isEmpty else {
            throw CodexDesktopIPC.Failure.protocolError
        }
        return owner
    }

    static func pending(_ state: JSONValue, threadID: String, ownerClientID: String, now: Date) throws -> [Pending] {
        guard let requests = state["requests"].arrayValue else { throw CodexDesktopIPC.Failure.protocolError }
        let approvals = try requests.compactMap { wire -> Pending? in
            let params = wire["params"], metadata = params["_meta"]
            guard wire["method"].stringValue == "mcpServer/elicitation/request", wire["completed"].boolValue != true,
                  params["threadId"].stringValue == threadID, params["mode"].stringValue == "form",
                  metadata["codex_approval_kind"].stringValue == "mcp_tool_call" else { return nil }
            let requestID = wire["id"]
            switch requestID {
            case .string(let value) where !value.isEmpty: break
            case .integer: break
            default: return nil
            }
            let approval: Approval?
            switch metadata["connector_id"].stringValue {
            case "computer-use": approval = app(metadata)
            case "browser-use": approval = try browser(params, in: state)
            default: approval = nil
            }
            guard let approval else { return nil }
            let encodedID = String(decoding: try RecordCoding.encoder().encode(requestID), as: UTF8.self)
            let encodedWire = String(decoding: try RecordCoding.encoder().encode(wire), as: UTF8.self)
            let subtitle = metadata["subtitle"].stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let risk = metadata["riskLevel"].stringValue == "high" ? L10n.text("较高风险", "Elevated Risk") : nil
            let detail = [risk, subtitle.flatMap { $0.isEmpty ? nil : $0 }, approval.subject].compactMap { $0 }.joined(separator: "\n\n")
            let request = PermissionRequest(
                id: "codex-desktop-permission:\(RecordCoding.hash([threadID, ownerClientID, encodedID, encodedWire]))", source: .codex,
                vendor: "Codex", sessionID: threadID, toolName: approval.toolName, summary: approval.summary,
                detail: detail, cwd: state["cwd"].stringValue, nativeApproval: approval.native, at: now)
            return Pending(request: request, threadID: threadID, ownerClientID: ownerClientID,
                           wireRequest: wire, requestID: requestID)
        }
        return try approvals + CodexDesktopQuestions.pending(state, threadID: threadID,
                                                            ownerClientID: ownerClientID, now: now)
    }

    /// What a tool-call approval asks, in the card's terms: its one line, what it is about, and the scopes it offers.
    private struct Approval {
        let toolName: String
        let summary: String
        let subject: String?
        let native: PermissionRequest.NativeApproval
    }

    /// Computer Use asking to use an app, for this conversation and, when Desktop offers it, always.
    private static func app(_ metadata: JSONValue) -> Approval? {
        guard let app = metadata["tool_params"]["app"].stringValue,
              !app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let persist = scopes(metadata["persist"]), persist.contains("session") else { return nil }
        let displayName = metadata["tool_params_display"].arrayValue?.first(where: { $0["name"].stringValue == "app" })?["value"]
            .stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = displayName.flatMap { $0.isEmpty ? nil : $0 } ?? app
        return Approval(toolName: "computer_use_app", summary: L10n.text("允许 ChatGPT 使用 \(name)？", "Allow ChatGPT to use \(name)?"),
                        subject: app, native: .computerUseApp(persist: persist))
    }

    /// The browser asking for a website: to open it, to move files to or from it, to read its history or to drive it
    /// more deeply. Desktop answers these itself where nobody is asked: under automatic review, and for a site's pages
    /// in a turn that runs with full access and never asks. Only a turn the user reviews shows a card, as with the hook.
    private static func browser(_ params: JSONValue, in state: JSONValue) throws -> Approval? {
        let metadata = params["_meta"]
        guard let persist = scopes(metadata["persist"]) else { return nil }
        let turn = try params["turnId"].stringValue.flatMap { try CodexDesktopQuestions.turn($0, in: state) }
        let settings = turn?["params"] ?? state["currentPermissions"]
        guard settings["approvalsReviewer"].stringValue == "user" else { return nil }
        let tool = metadata["tool_name"].stringValue ?? ""
        let opensSite = tool == "access_browser_origin" || tool == "access_browser_origin_with_raw_cdp"
        if opensSite, settings["approvalPolicy"].stringValue == "never",
           settings["sandboxPolicy"]["type"].stringValue == "dangerFullAccess" { return nil }
        let origin = (metadata["origin"].stringValue ?? metadata["tool_params"]["origin"].stringValue)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = metadata["connector_name"].stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "ChatGPT"
        let summary: String
        if tool == "access_browser_origin", let origin, !origin.isEmpty {
            summary = L10n.text("允许 \(name) 访问 \(origin)？", "Allow \(name) to access \(origin)?")
        } else if let message = params["message"].stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            // Desktop's own sentence for the rarer requests, as its card reads.
            summary = message
        } else {
            return nil
        }
        return Approval(toolName: tool.isEmpty ? "browser" : tool, summary: summary, subject: origin.flatMap { $0.isEmpty ? nil : $0 },
                        native: .browserAccess(origin: origin.flatMap { $0.isEmpty ? nil : $0 }, persist: persist))
    }

    /// The scopes a request offers to keep its answer for, as Desktop writes them: none, one, or a list. Nil for a
    /// scope this reader does not know, whose request is then left to Desktop.
    private static func scopes(_ value: JSONValue) -> [String]? {
        let names: [String?]
        switch value {
        case .null: names = []
        case .string(let name): names = [name]
        case .array(let values): names = values.map(\.stringValue)
        default: return nil
        }
        guard names.allSatisfy({ $0 == "session" || $0 == "always" }) else { return nil }
        return names.compactMap { $0 }
    }

    static func response(_ decision: PermissionDecision, for pending: Pending) throws -> JSONValue? {
        if case .asynchronousQuestion = pending.request.nativeApproval {
            switch decision {
            case .leave: return nil
            case .answer(let answers):
                guard let question = pending.request.questions.first,
                      answers.keys.allSatisfy({ $0 == question.answerKey }) else { throw Failure.unsupportedDecision }
                guard let answer = answers[question.answerKey] else { return nil }
                guard answer.selected.allSatisfy({ choice in question.options.contains(where: { $0.label == choice }) }) else {
                    throw Failure.unsupportedDecision
                }
                let text = answer.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw Failure.unsupportedDecision }
                let value = JSONValue.array([.object(["questionItemId": pending.requestID,
                    "question": .string(question.question), "answer": .string(text)])])
                let encoded = String(decoding: try RecordCoding.encoder().encode(value), as: UTF8.self)
                return .string("<send_user_message_question_reply>\n\(encoded)\n</send_user_message_question_reply>")
            case .allow, .allowAlways, .deny: throw Failure.unsupportedDecision
            }
        }
        let persist: [String]
        switch pending.request.nativeApproval {
        case .computerUseApp(let scopes): persist = scopes
        case .browserAccess(_, let scopes): persist = scopes
        default: throw Failure.unsupportedDecision
        }
        switch decision {
        case .leave: return nil
        case .allow:
            // An app is allowed for the conversation. A website asked for with no scope is allowed as Desktop's own
            // "Allow once" allows it: accepted, and kept for as long as the browser's settings say.
            if persist.contains("session") {
                return .object(["action": .string("accept"), "content": .object([:]),
                                "_meta": .object(["persist": .string("session")])])
            }
            guard case .browserAccess = pending.request.nativeApproval else { throw Failure.unsupportedDecision }
            return .object(["action": .string("accept"), "content": .object([:]), "_meta": .null])
        case .allowAlways(let update):
            guard persist.contains("always"), update == .object(["persist": .string("always")]) else {
                throw Failure.unsupportedDecision
            }
            return .object(["action": .string("accept"), "content": .object([:]), "_meta": update])
        case .deny: return .object(["action": .string("decline"), "content": .null, "_meta": .null])
        case .answer: throw Failure.unsupportedDecision
        }
    }

    private static func json(_ object: [String: Any]) throws -> JSONValue {
        try JSONValue.parse(JSONSerialization.data(withJSONObject: object))
    }

    private static func foundation(_ value: JSONValue) throws -> Any {
        try JSONSerialization.jsonObject(with: RecordCoding.encoder().encode(value), options: [.fragmentsAllowed])
    }

    private func detached<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        let task = Task.detached(priority: .utility, operation: operation)
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
