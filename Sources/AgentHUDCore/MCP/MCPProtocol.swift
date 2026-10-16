import AgentHUDSupport
import Foundation

/// The Model Context Protocol as Agent HUD's server speaks it: the revisions it answers, the request fields the
/// newest ones carry, and JSON-RPC's messages, each written as one line.
///
/// Revisions come in two kinds. Up to 2025-11-25 a client opens with an `initialize` handshake. From 2026-07-28 there
/// is none: every request names its revision and the client's capabilities in `params._meta`, results say their
/// `resultType`, and a client learns about the server from `server/discover`.
enum MCPProtocol {
    /// The revisions that open with a handshake, newest first.
    static let handshakeRevisions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    /// The revisions whose requests each carry their own revision, newest first.
    static let statelessRevisions = ["2026-07-28"]
    /// Every revision the server answers, newest first.
    static var revisions: [String] { statelessRevisions + handshakeRevisions }
    /// The methods only the revisions without a handshake have.
    static let statelessMethods: Set<String> = ["server/discover", "subscriptions/listen"]

    /// The `_meta` keys the protocol reserves for itself.
    enum Meta {
        static let protocolVersion = "io.modelcontextprotocol/protocolVersion"
        static let clientCapabilities = "io.modelcontextprotocol/clientCapabilities"
        static let serverInfo = "io.modelcontextprotocol/serverInfo"
        static let subscriptionID = "io.modelcontextprotocol/subscriptionId"
    }

    /// JSON-RPC's error codes, and the one the protocol adds for a revision the server does not speak.
    enum Failure: Int64 {
        case parse = -32700
        case invalidRequest = -32600
        case methodNotFound = -32601
        case invalidParams = -32602
        case unsupportedProtocolVersion = -32022

        var message: String {
            switch self {
            case .parse: "Parse error"
            case .invalidRequest: "Invalid Request"
            case .methodNotFound: "Method not found"
            case .invalidParams: "Invalid params"
            case .unsupportedProtocolVersion: "Unsupported protocol version"
            }
        }
    }

    /// The response that carries `result` to the request `id` came with.
    static func response(_ result: [String: JSONValue], id: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": .object(result)])
    }

    /// The error response to the request `id` came with; a null `id` when the request's own could not be read.
    /// `message` replaces the code's standard one.
    static func response(_ failure: Failure, _ message: String? = nil, data: JSONValue? = nil, id: JSONValue) -> JSONValue {
        var error: [String: JSONValue] = ["code": .integer(failure.rawValue), "message": .string(message ?? failure.message)]
        if let data { error["data"] = data }
        return .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(error)])
    }

    static func notification(_ method: String, _ params: [String: JSONValue]) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "method": .string(method), "params": .object(params)])
    }

    /// Whether `message` is a response, to a request, rather than a notification.
    static func isResponse(_ message: JSONValue) -> Bool {
        message.objectValue?["method"] == nil
    }

    /// `value` as JSON on one line: the encoder writes no line breaks of its own and escapes those inside strings.
    static func line(_ value: JSONValue) -> String? {
        guard let data = try? RecordCoding.encoder().encode(value) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
