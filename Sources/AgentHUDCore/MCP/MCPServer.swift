import AgentHUDSupport
import Foundation

/// Agent HUD's MCP server, as a function of one line read: the lines to write back for it.
///
/// It keeps nothing between lines. A request is answered once, with the id it came with; a notification is never
/// answered; a method the server does not have is refused at once, which is how a client that probes with
/// `server/discover` finds an older server without waiting. The handshake, `ping`, `server/discover` and `tools/list`
/// are answered here; only `tools/call` goes to the running application, through `call`.
///
/// A request is answered as the revision it names in `params._meta` says, and one that names none as the handshake
/// revisions do, so both kinds of client work against one process.
struct MCPServer {
    /// The application's version, given as the server's.
    let version: String
    /// Hands a tool call to the running application and waits for what comes back.
    let call: (MCPToolRequest) -> MCPAppClient.Answer

    /// How long a client may keep `server/discover` and `tools/list` results, which change only with the application.
    static let cacheLifetime: Int64 = 300_000

    private typealias Meta = MCPProtocol.Meta

    /// The revisions a request is answered by, or the refusal it gets instead.
    private enum Era {
        case handshake, stateless
        case refused(JSONValue)
    }

    func lines(for line: String) -> [String] { lines(for: Data(line.utf8)) }

    /// None for a notification or a blank line, one for a request, and two for a subscription, which is acknowledged
    /// and then closed.
    func lines(for line: Data) -> [String] {
        guard line.contains(where: { $0 != 0x20 && $0 != 0x09 && $0 != 0x0D }) else { return [] }
        guard let message = try? JSONValue.parse(line) else {
            return [MCPProtocol.response(.parse, id: .null)].compactMap(MCPProtocol.line)
        }
        guard case .array(let batch) = message else { return answers(to: message).compactMap(MCPProtocol.line) }
        // Revision 2025-03-26 lets a client send several messages as one array and takes their responses as one.
        guard !batch.isEmpty else { return [MCPProtocol.response(.invalidRequest, id: .null)].compactMap(MCPProtocol.line) }
        // A notification written for one of them is no response, and goes ahead of the array on a line of its own.
        let messages = batch.flatMap { answers(to: $0) }
        let responses = messages.filter(MCPProtocol.isResponse)
        var written = messages.filter { !MCPProtocol.isResponse($0) }
        if !responses.isEmpty { written.append(.array(responses)) }
        return written.compactMap(MCPProtocol.line)
    }

    private func answers(to message: JSONValue) -> [JSONValue] {
        guard let object = message.objectValue else { return [MCPProtocol.response(.invalidRequest, id: .null)] }
        let id: JSONValue?
        switch object["id"] {
        case nil: id = nil
        case .string?, .integer?: id = object["id"]
        default: return [MCPProtocol.response(.invalidRequest, "Invalid Request: id must be a string or an integer", id: .null)]
        }
        guard object["jsonrpc"] == .string("2.0"), let method = object["method"]?.stringValue else {
            // A response is nobody's request; the server sends no requests, so none is expected and none is answered.
            let stray = object["method"] == nil && (object["result"] != nil || object["error"] != nil)
            return stray ? [] : [MCPProtocol.response(.invalidRequest, id: id ?? .null)]
        }
        guard let id else { return [] }
        switch object["params"] {
        case nil, .null?: return answers(to: method, params: [:], id: id)
        case .object(let params)?: return answers(to: method, params: params, id: id)
        default: return [MCPProtocol.response(.invalidParams, "Invalid params: params must be an object", id: id)]
        }
    }

    private func answers(to method: String, params: [String: JSONValue], id: JSONValue) -> [JSONValue] {
        if method == "initialize" { return [MCPProtocol.response(handshake(params), id: id)] }
        let stateless: Bool
        switch era(of: method, meta: params["_meta"]?.objectValue ?? [:], id: id) {
        case .handshake: stateless = false
        case .stateless: stateless = true
        case .refused(let refusal): return [refusal]
        }

        switch (method, stateless) {
        case ("ping", _):
            // The newest revisions have no ping; a client that sends one anyway is still told the server is there.
            return [response([:], id: id, stateless: stateless)]
        case ("server/discover", true):
            var result = cacheable(["supportedVersions": .array(MCPProtocol.revisions.map(JSONValue.string))])
            result["capabilities"] = capabilities
            result["instructions"] = .string(MCPTools.instructions)
            return [response(result, id: id, stateless: true)]
        case ("tools/list", _):
            // The list is one page, so no cursor was ever given out.
            if let cursor = params["cursor"], cursor != .null {
                return [MCPProtocol.response(.invalidParams, "Invalid params: unknown cursor", id: id)]
            }
            let tools: [String: JSONValue] = ["tools": .array(MCPTools.definitions)]
            return [response(stateless ? cacheable(tools) : tools, id: id, stateless: stateless)]
        case ("tools/call", _):
            return [toolCall(params, id: id, stateless: stateless)]
        case ("subscriptions/listen", true):
            // No list here changes while the process runs: the subscription is acknowledged as holding nothing and
            // ended in the same breath, which tells the client it closed cleanly and need not be reopened.
            let tag: [String: JSONValue] = [Meta.subscriptionID: id]
            let acknowledged = MCPProtocol.notification("notifications/subscriptions/acknowledged",
                                                        ["_meta": .object(tag), "notifications": .object([:])])
            return [acknowledged, response(["_meta": .object(tag)], id: id, stateless: true)]
        default:
            return [MCPProtocol.response(.methodNotFound, "Method not found: \(method)", id: id)]
        }
    }

    // MARK: Revisions

    /// The handshake's answer: the revision asked for when the server speaks it, else the newest it does.
    private func handshake(_ params: [String: JSONValue]) -> [String: JSONValue] {
        let requested = params["protocolVersion"]?.stringValue ?? ""
        let revision = MCPProtocol.handshakeRevisions.contains(requested) ? requested : MCPProtocol.handshakeRevisions[0]
        return ["protocolVersion": .string(revision), "capabilities": capabilities, "serverInfo": serverInfo,
                "instructions": .string(MCPTools.instructions)]
    }

    /// Which revisions answer a request. One that names no revision, declares no capabilities and asks for nothing
    /// only the newest revisions have comes from a client that opened with a handshake. Any other has to be whole: it
    /// names a revision the server speaks and, for one without a handshake, its client's capabilities. A handshake
    /// revision named this way is answered as that revision defines.
    private func era(of method: String, meta: [String: JSONValue], id: JSONValue) -> Era {
        let named = meta[Meta.protocolVersion]
        let carriesItsOwn = named != nil || meta[Meta.clientCapabilities] != nil
        guard carriesItsOwn || MCPProtocol.statelessMethods.contains(method) else { return .handshake }
        guard let requested = named?.stringValue else {
            return .refused(MCPProtocol.response(.invalidParams, "Invalid params: _meta needs \(Meta.protocolVersion)", id: id))
        }
        if MCPProtocol.handshakeRevisions.contains(requested) { return .handshake }
        guard MCPProtocol.statelessRevisions.contains(requested) else {
            let data: [String: JSONValue] = ["supported": .array(MCPProtocol.revisions.map(JSONValue.string)),
                                            "requested": .string(requested)]
            return .refused(MCPProtocol.response(.unsupportedProtocolVersion, data: .object(data), id: id))
        }
        guard meta[Meta.clientCapabilities]?.objectValue != nil else {
            return .refused(MCPProtocol.response(.invalidParams, "Invalid params: _meta needs \(Meta.clientCapabilities)", id: id))
        }
        return .stateless
    }

    private var capabilities: JSONValue { .object(["tools": .object(["listChanged": .bool(false)])]) }

    private var serverInfo: JSONValue {
        .object(["name": .string("agent-hud"), "title": .string("Agent HUD"), "version": .string(version)])
    }

    /// A result with the hints the newest revisions want on what a client may cache: the same for every user.
    private func cacheable(_ result: [String: JSONValue]) -> [String: JSONValue] {
        var result = result
        result["ttlMs"] = .integer(Self.cacheLifetime)
        result["cacheScope"] = .string("public")
        return result
    }

    /// The response for `result`. The newest revisions' results say that they are complete and which server sent
    /// them; a handshake client gets the result as its revision defines it, with nothing added.
    private func response(_ result: [String: JSONValue], id: JSONValue, stateless: Bool) -> JSONValue {
        guard stateless else { return MCPProtocol.response(result, id: id) }
        var result = result
        var meta = result["_meta"]?.objectValue ?? [:]
        meta[Meta.serverInfo] = serverInfo
        result["_meta"] = .object(meta)
        result["resultType"] = .string("complete")
        return MCPProtocol.response(result, id: id)
    }

    // MARK: Tools

    /// A call's result is one block of text, what the tool returned as JSON, followed by an image block for each
    /// picture it drew; or, marked as an error, one block with the sentence that says why it did not run. An image
    /// block has the same shape in every revision the server answers. A tool the server does not have is the
    /// protocol's error instead.
    private func toolCall(_ params: [String: JSONValue], id: JSONValue, stateless: Bool) -> JSONValue {
        guard let name = params["name"]?.stringValue else {
            return MCPProtocol.response(.invalidParams, "Invalid params: tools/call needs the tool's name", id: id)
        }
        guard MCPTools.names.contains(name) else {
            return MCPProtocol.response(.invalidParams, "Unknown tool: \(name)", id: id)
        }
        let arguments: [String: JSONValue]
        switch params["arguments"] {
        case nil, .null?: arguments = [:]
        case .object(let object)?: arguments = object
        default: return MCPProtocol.response(.invalidParams, "Invalid params: arguments must be an object", id: id)
        }
        let text: String
        var failed = true
        var pictures: [MCPImage] = []
        switch call(MCPToolRequest(tool: name, arguments: arguments)) {
        case .reply(.result(let result, let images)):
            if let json = MCPProtocol.line(.object(result)) {
                text = json
                failed = false
                pictures = images
            } else {
                text = "Agent HUD's answer could not be read. Try again."
            }
        case .reply(.failure(let sentence)): text = sentence
        case .notRunning: text = "Agent HUD is not running. Open Agent HUD and try again."
        case .off: text = "Agent HUD's agent tools are off. Turn them on in Settings › Experimental."
        case .unanswered: text = "Agent HUD did not answer. Try again."
        }
        let block: JSONValue = .object(["type": .string("text"), "text": .string(text)])
        let content = [block] + pictures.map { picture -> JSONValue in
            .object(["type": .string("image"), "data": .string(picture.data.base64EncodedString()),
                     "mimeType": .string(picture.mimeType)])
        }
        return response(["content": .array(content), "isError": .bool(failed)], id: id, stateless: stateless)
    }
}
