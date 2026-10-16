import AgentHUDSupport
import Foundation
import XCTest
@testable import AgentHUDCore

/// The server as a test drives it: a line in, the messages written back read as JSON, and the tool calls it handed
/// on. No application is behind it unless `answer` says so.
final class MCPServerProbe {
    private(set) var calls: [MCPToolRequest] = []
    var answer: MCPAppClient.Answer

    init(answer: MCPAppClient.Answer = .notRunning) {
        self.answer = answer
    }

    var server: MCPServer {
        MCPServer(version: "1.2.3") { [self] request in
            calls.append(request)
            return answer
        }
    }

    func messages(for line: String, file: StaticString = #filePath, line number: UInt = #line) throws -> [JSONValue] {
        try server.lines(for: line).map { text in
            XCTAssertFalse(text.contains("\n"), "a message is one line", file: file, line: number)
            return try JSONValue.parse(Data(text.utf8))
        }
    }

    /// The one response a request gets.
    func response(to line: String, file: StaticString = #filePath, line number: UInt = #line) throws -> JSONValue {
        let messages = try messages(for: line, file: file, line: number)
        XCTAssertEqual(messages.count, 1, "one request, one response", file: file, line: number)
        let response = try XCTUnwrap(messages.first, file: file, line: number)
        XCTAssertEqual(response["jsonrpc"], .string("2.0"), file: file, line: number)
        return response
    }

    /// The fields a request of the newest revision carries, as Claude Code 2.1.296 sends them.
    static let meta: String = #""_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","#
        + #""io.modelcontextprotocol/clientInfo":{"name":"claude-code","title":"Claude Code","version":"2.1.296","#
        + #""description":"Anthropic's agentic coding tool","websiteUrl":"https://claude.com/claude-code"},"#
        + #""io.modelcontextprotocol/clientCapabilities":{"roots":{"listChanged":true},"elicitation":{"form":{},"url":{}}}}"#
}

extension JSONValue {
    /// The text of the one block a tool call's result holds.
    var blockText: String? {
        guard let content = self["content"].arrayValue, content.count == 1 else { return nil }
        return content[0]["text"].stringValue
    }
}
