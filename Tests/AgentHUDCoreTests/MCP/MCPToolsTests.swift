import AgentHUDSupport
import Foundation
import XCTest
@testable import AgentHUDCore

/// The tools a client is offered, and what comes back from calling one.
final class MCPToolsTests: XCTestCase {
    private let probe = MCPServerProbe()

    private func call(_ params: String, id: String = "5") throws -> JSONValue {
        try probe.response(to: #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":\#(params)}"#)
    }

    /// The one block of text a call's result holds.
    private func text(of response: JSONValue, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let content = try XCTUnwrap(response["result"]["content"].arrayValue, file: file, line: line)
        XCTAssertEqual(content.count, 1, file: file, line: line)
        XCTAssertEqual(content.first?["type"], .string("text"), file: file, line: line)
        return try XCTUnwrap(content.first?["text"].stringValue, file: file, line: line)
    }

    /// Checks that `schema` is a JSON Schema the clients take: a typed node whose parts are typed nodes, described on
    /// one line where the task of describing falls to it.
    private func assertSchema(_ schema: JSONValue, at path: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let node = try XCTUnwrap(schema.objectValue, "\(path) is an object", file: file, line: line)
        let known: Set<String> = ["type", "description", "properties", "additionalProperties", "items", "enum"]
        XCTAssertTrue(Set(node.keys).isSubset(of: known), "\(path): \(node.keys.sorted())", file: file, line: line)
        let type = try XCTUnwrap(node["type"]?.stringValue, "\(path) has a type", file: file, line: line)
        XCTAssertTrue(["object", "array", "string", "boolean", "integer", "number"].contains(type), "\(path): \(type)", file: file, line: line)
        if let description = node["description"] {
            let sentence = try XCTUnwrap(description.stringValue, file: file, line: line)
            XCTAssertFalse(sentence.isEmpty || sentence.contains("\n"), "\(path) is described on one line", file: file, line: line)
        }
        if let choices = node["enum"] {
            XCTAssertEqual(type, "string", file: file, line: line)
            XCTAssertFalse(try XCTUnwrap(choices.arrayValue).isEmpty, file: file, line: line)
            XCTAssertTrue(choices.arrayValue?.allSatisfy { $0.stringValue != nil } == true, path, file: file, line: line)
        }
        for (name, property) in node["properties"]?.objectValue ?? [:] {
            XCTAssertNotNil(property["description"].stringValue, "\(path).\(name) says what it is", file: file, line: line)
            try assertSchema(property, at: "\(path).\(name)", file: file, line: line)
        }
        if type == "array" { try assertSchema(try XCTUnwrap(node["items"]), at: path + "[]", file: file, line: line) }
        if type == "object", let rest = node["additionalProperties"], rest != .bool(false) {
            try assertSchema(rest, at: path + ".*", file: file, line: line)
        }
    }

    func testTheListHoldsTheFourToolsWithTheirSchemas() throws {
        // Codex 0.162.1 asks with a progress token and nothing else.
        let response = try probe.response(to: #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"progressToken":0}}}"#)
        XCTAssertEqual(response["result"].objectValue?.keys.sorted(), ["tools"], "a handshake client gets the list and nothing else")
        let tools = try XCTUnwrap(response["result"]["tools"].arrayValue)
        XCTAssertEqual(tools.map { $0["name"].stringValue }, ["get_panel", "get_panel_image", "set_panel_layout", "discard_panel_draft"])
        XCTAssertEqual(try probe.response(to: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)["result"], response["result"],
                       "the same list in the same order every time, so a client may cache it")

        for tool in tools {
            let name = try XCTUnwrap(tool["name"].stringValue)
            XCTAssertEqual(tool.objectValue?.keys.sorted(), ["annotations", "description", "inputSchema", "name"], "no output schema is declared")
            XCTAssertNotNil(name.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression), name)
            XCTAssertLessThanOrEqual(tool["description"].stringValue?.count ?? .max, 2048, "\(name) is described within what a client shows whole")
            XCTAssertEqual(tool["inputSchema"]["type"], .string("object"), name)
            XCTAssertEqual(tool["inputSchema"]["additionalProperties"], .bool(false), "\(name) takes no property it does not name")
            try assertSchema(tool["inputSchema"], at: name)
        }
        XCTAssertEqual([MCPTools.getPanel, MCPTools.getPanelImage, MCPTools.setPanelLayout, MCPTools.discardPanelDraft],
                       tools.map { $0["name"].stringValue })
        for index in [0, 1, 3] {
            XCTAssertEqual(tools[index]["inputSchema"]["properties"].objectValue?.keys.sorted(), index == 1 ? ["screen", "show"] : ["screen"],
                           "\(tools[index]["name"]) takes the screen it acts on and, for a picture, what to draw")
            XCTAssertEqual(tools[index]["inputSchema"]["properties"]["screen"], tools[2]["inputSchema"]["properties"]["screen"],
                           "every tool names a screen the same way")
        }
        XCTAssertEqual(tools[1]["inputSchema"]["properties"]["show"]["enum"], .array([.string("panel"), .string("hud")]))
        XCTAssertFalse(tools.contains { $0["name"].stringValue?.contains("save") == true }, "saving is the user's click in the panel")
    }

    func testTheLayoutToolTakesTheLayoutAndNothingElse() throws {
        let schema = try XCTUnwrap(MCPTools.definitions.first { $0["name"] == .string("set_panel_layout") })["inputSchema"]
        let properties = try XCTUnwrap(schema["properties"].objectValue)
        XCTAssertEqual(properties.keys.sorted(),
                       ["blocks", "from", "hiddenSections", "hud", "order", "revision", "screen", "sections", "sessions", "style",
                        "tokens"])
        XCTAssertNil(schema.objectValue?["required"], "every property is optional")
        func choices(_ node: JSONValue) -> [String] { node["enum"].arrayValue?.compactMap(\.stringValue) ?? [] }

        let block = schema["properties"]["blocks"]["additionalProperties"]
        XCTAssertEqual(schema["properties"]["blocks"]["type"], .string("object"))
        XCTAssertEqual(block["additionalProperties"], .bool(false))
        XCTAssertEqual(block["properties"].objectValue?.keys.sorted(),
                       ["columns", "countdown", "hidden", "hiddenRows", "measures", "ringSize", "span", "widget"])
        XCTAssertEqual(choices(block["properties"]["widget"]), ["bar", "ring", "number", "chart"])
        XCTAssertEqual(block["properties"]["measures"]["type"], .string("array"))
        XCTAssertEqual(choices(block["properties"]["measures"]["items"]), ["quota", "burn", "tokens", "cost"])
        XCTAssertEqual(block["properties"]["hidden"]["type"], .string("boolean"))
        XCTAssertEqual(block["properties"]["hiddenRows"]["items"], .object(["type": .string("string")]))
        XCTAssertEqual(block["properties"]["countdown"]["type"], .string("boolean"))
        XCTAssertEqual(block["properties"]["columns"]["type"], .string("integer"))
        XCTAssertEqual(choices(block["properties"]["ringSize"]), ["small", "medium", "large"])
        XCTAssertEqual(choices(block["properties"]["span"]), ["full", "half"])

        let style = schema["properties"]["style"]
        XCTAssertEqual(style["type"], .string("object"))
        XCTAssertEqual(style["additionalProperties"], .bool(false))
        XCTAssertEqual(style["properties"].objectValue?.keys.sorted(), ["separators", "spacing", "width"])
        XCTAssertEqual(choices(style["properties"]["spacing"]), ["compact", "regular", "roomy"])
        XCTAssertEqual(style["properties"]["separators"]["type"], .string("boolean"))
        XCTAssertEqual(style["properties"]["width"]["type"], .string("integer"))
        XCTAssertEqual(style["properties"]["width"]["description"].stringValue,
                       "The whole panel's width, 480 to 720 points; 540 if left out.")

        let sessions = schema["properties"]["sessions"]
        XCTAssertEqual(sessions["additionalProperties"], .bool(false))
        XCTAssertEqual(sessions["properties"].objectValue?.keys.sorted(), ["agents", "limit", "states"])
        XCTAssertEqual(sessions["properties"]["limit"]["type"], .string("integer"))
        XCTAssertEqual(sessions["properties"]["limit"]["description"].stringValue, "Rows at most, 1 to 10; 5 if left out.")
        XCTAssertEqual(sessions["properties"]["agents"]["items"], .object(["type": .string("string")]))
        XCTAssertEqual(choices(sessions["properties"]["states"]["items"]), ["waiting", "running", "ended"])
        let tokens = schema["properties"]["tokens"]
        XCTAssertEqual(tokens["additionalProperties"], .bool(false))
        XCTAssertEqual(tokens["properties"].objectValue?.keys.sorted(), ["agents", "period"])
        XCTAssertEqual(choices(tokens["properties"]["period"]), ["day", "week", "month"])
        XCTAssertEqual(tokens["properties"]["agents"]["items"], .object(["type": .string("string")]))

        XCTAssertEqual(schema["properties"]["order"]["items"], .object(["type": .string("string")]))
        for name in ["sections", "hiddenSections"] {
            XCTAssertEqual(schema["properties"][name]["type"], .string("array"))
            XCTAssertEqual(choices(schema["properties"][name]["items"]), ["blocks", "tokens", "sessions"], name)
        }
        XCTAssertEqual(choices(schema["properties"]["from"]), ["default", "previous", "shared"])
        XCTAssertEqual(schema["properties"]["revision"]["type"], .string("integer"))
        XCTAssertEqual(schema["properties"]["screen"]["type"], .string("string"))
        XCTAssertEqual(schema["properties"]["screen"]["description"].stringValue,
                       "A screen key from get_panel for that screen's own layout; 'all', the default, for the shared layout the other screens use.")

        let hud = schema["properties"]["hud"]
        XCTAssertEqual(hud["type"], .string("object"))
        XCTAssertEqual(hud["additionalProperties"], .bool(false))
        XCTAssertEqual(hud["properties"].objectValue?.keys.sorted(),
                       ["agents", "bots", "edge", "edgeDistance", "glow", "logoGap", "logoSize", "mode", "position", "reset",
                        "ringWidth", "separateAgents", "showLogos", "showNumbers", "showRings", "simpleSize"])
        XCTAssertEqual(hud["properties"]["reset"]["type"], .string("boolean"))
        XCTAssertEqual(hud["properties"]["reset"]["description"].stringValue,
                       "True proposes the screen's default style, the placement its hardware is given and the default glow, with no other style field.")
        XCTAssertEqual(schema["properties"]["from"]["description"].stringValue,
                       "Propose the built-in layout, the last saved one, or for a screen the shared layout, instead of the one described here. Only 'previous' brings a screen's HUD style with it.")
        XCTAssertEqual(hud["properties"]["agents"]["type"], .string("array"))
        XCTAssertEqual(hud["properties"]["agents"]["items"], .object(["type": .string("string")]))
        XCTAssertEqual(choices(hud["properties"]["mode"]), ["notch", "dynamic", "simple"])
        XCTAssertEqual(choices(hud["properties"]["edge"]), ["top", "right", "bottom", "left"])
        for name in ["position", "logoSize", "logoGap", "edgeDistance", "simpleSize", "ringWidth"] {
            XCTAssertEqual(hud["properties"][name]["type"], .string("number"), name)
        }
        for name in ["showLogos", "showRings", "showNumbers", "bots", "separateAgents"] {
            XCTAssertEqual(hud["properties"][name]["type"], .string("boolean"), name)
        }
        XCTAssertEqual(hud["properties"]["logoSize"]["description"].stringValue, "Dynamic: logo size in points, 12 to 36.")
        XCTAssertEqual(hud["properties"]["logoGap"]["description"].stringValue,
                       "Dynamic: gap between logos, as a share of a logo, 0.1 to 0.6.")
        let glow = hud["properties"]["glow"]
        XCTAssertEqual(glow["additionalProperties"], .bool(false))
        XCTAssertEqual(glow["properties"].objectValue?.keys.sorted(),
                       ["amplitude", "blur", "brightness", "effect", "outwardOnly", "range", "speed", "style"])
        XCTAssertEqual(choices(glow["properties"]["style"]), ["blur", "dots", "ascii", "blocks", "braille", "binary"])
        XCTAssertEqual(choices(glow["properties"]["effect"]), ["breathe", "flow", "scan", "ripple", "shimmer", "boot"])
        XCTAssertEqual(glow["properties"]["speed"]["description"].stringValue,
                       "Seconds a cycle takes while an agent works, 1 to 12.")
        XCTAssertEqual(glow["properties"]["brightness"]["description"].stringValue, "Its strength, 0.2 to 1.")
    }

    /// The names the schema offers are the names the layout reads, so an agent is never offered one that is refused.
    func testTheSchemaOffersTheNamesTheLayoutReads() throws {
        let schema = try XCTUnwrap(MCPTools.definitions.first { $0["name"] == .string("set_panel_layout") })["inputSchema"]
        func choices(_ node: JSONValue) -> [String] { node["enum"].arrayValue?.compactMap(\.stringValue) ?? [] }
        let block = schema["properties"]["blocks"]["additionalProperties"]["properties"]
        XCTAssertEqual(choices(block["widget"]), PanelWidget.allCases.map(\.rawValue))
        XCTAssertEqual(choices(block["measures"]["items"]), PanelMeasure.allCases.map(\.rawValue))
        XCTAssertEqual(choices(block["ringSize"]), PanelRingSize.allCases.map(\.rawValue))
        XCTAssertEqual(choices(block["span"]), PanelSpan.allCases.map(\.rawValue))
        XCTAssertEqual(choices(schema["properties"]["style"]["properties"]["spacing"]), PanelSpacing.allCases.map(\.rawValue))
        XCTAssertEqual(choices(schema["properties"]["sections"]["items"]), PanelSection.allCases.map(\.rawValue))
        XCTAssertEqual(choices(schema["properties"]["sessions"]["properties"]["states"]["items"]),
                       PanelSessionState.allCases.map(\.rawValue))
        XCTAssertEqual(choices(schema["properties"]["tokens"]["properties"]["period"]), PanelTokenPeriod.allCases.map(\.rawValue))
        let hud = schema["properties"]["hud"]["properties"]
        XCTAssertEqual(choices(hud["mode"]), HUDMode.allCases.map(\.agentName))
        XCTAssertEqual(choices(hud["edge"]), HUDEdge.allCases.map(\.rawValue))
        XCTAssertEqual(choices(hud["glow"]["properties"]["style"]), GlowStyle.allCases.map(\.rawValue))
        XCTAssertEqual(choices(hud["glow"]["properties"]["effect"]), GlowEffect.allCases.map(\.rawValue))
        XCTAssertEqual(Set(hud.objectValue?.keys.map { $0 } ?? []), Set(["agents"] + HUDStyle.names + [HUDStyle.resetName]),
                       "the hud's fields are the ones the strict reading knows")
    }

    func testEachToolSaysWhatItDoesAndWhatItMayChange() throws {
        let tools = Dictionary(uniqueKeysWithValues: MCPTools.definitions.map { ($0["name"].stringValue ?? "", $0) })
        XCTAssertEqual(tools["get_panel"]?["description"].stringValue,
                       "Read what the Agent HUD hover panel shows now: its blocks (one per agent or API account), each block's rows with their latest readings, the layout in effect, the panel's width and height and whether it scrolls, and the widgets and measures each block accepts; how many sessions it lists and its token chart's period and total; and the attached screens, each with its resting HUD's style and the agents it can show. Call it before changing the layout; block, row and screen keys come from here. Names are written as the panel shows them, in the application's language.")
        XCTAssertEqual(tools["get_panel_image"]?["description"].stringValue,
                       "Show a picture of the Agent HUD hover panel as the layout in effect draws it, an unsaved draft included, with account names masked and session titles left out, or with show 'hud' a screen's resting HUD as it looks now. Use it to check how a change looks; get_panel reads the same as data.")
        XCTAssertLessThanOrEqual(tools["get_panel_image"]?["description"].stringValue?.count ?? .max, 300)
        XCTAssertEqual(tools["set_panel_layout"]?["description"].stringValue,
                       "Propose a layout for the Agent HUD hover panel: its blocks, sections, session rows, token chart and style, its width included, and the screen's resting HUD: which agents it shows and, for one screen, its mode, edge, sizes and glow. Send the whole layout you want; anything left out uses the default, and a HUD style field left out stays as saved. A call with only hud style fields leaves the layout as it is. What the layout from get_panel holds for a block, a row or an agent not listed now can be sent back as it is. It shows at once as an unsaved draft: the user keeps it with Save in the panel, and it is dropped when Agent HUD restarts. Pass from 'default' to propose the built-in layout instead, 'previous' for the last saved one, for a screen with the resting HUD style that went with it, or 'shared' to have a screen use the shared layout again; hud.reset proposes a screen's default HUD style.")
        XCTAssertEqual(tools["discard_panel_draft"]?["description"].stringValue,
                       "Drop the unsaved draft so the Agent HUD panel returns to the saved layout and, for a screen, its resting HUD to its saved style.")

        XCTAssertEqual(tools["get_panel"]?["annotations"], .object(["readOnlyHint": .bool(true), "openWorldHint": .bool(false)]))
        XCTAssertEqual(tools["get_panel_image"]?["annotations"], .object(["readOnlyHint": .bool(true), "openWorldHint": .bool(false)]))
        let draft: JSONValue = .object(["readOnlyHint": .bool(false), "destructiveHint": .bool(false),
                                        "idempotentHint": .bool(true), "openWorldHint": .bool(false)])
        XCTAssertEqual(tools["set_panel_layout"]?["annotations"], draft)
        XCTAssertEqual(tools["discard_panel_draft"]?["annotations"], draft)
    }

    func testAToolTheServerDoesNotHaveIsTheProtocolsError() throws {
        let response = try call(#"{"name":"save_panel_layout","arguments":{}}"#, id: "3")
        XCTAssertEqual(response["id"], .integer(3))
        XCTAssertEqual(response["error"], .object(["code": .integer(-32602), "message": .string("Unknown tool: save_panel_layout")]))
        XCTAssertEqual(try call(#"{"arguments":{}}"#)["error"]["code"], .integer(-32602), "a call names its tool")
        XCTAssertEqual(try call(#"{"name":7}"#)["error"]["code"], .integer(-32602))
        XCTAssertEqual(try call(#"{"name":"get_panel","arguments":[1]}"#)["error"]["code"], .integer(-32602), "arguments are an object")
        XCTAssertEqual(try call(#"{"name":"get_panel","arguments":"{}"}"#)["error"]["code"], .integer(-32602))
        XCTAssertTrue(probe.calls.isEmpty, "none of these reaches the application")
    }

    func testACallWithNoApplicationRunningSaysSo() throws {
        probe.answer = .notRunning
        // Claude Code 2.1.296 on a handshake connection.
        let line = #"{"method":"tools/call","params":{"name":"get_panel","arguments":{},"_meta":{"claudecode/toolUseId":"toolu_1","progressToken":2}},"jsonrpc":"2.0","id":2}"#
        let response = try probe.response(to: line)
        XCTAssertEqual(response["id"], .integer(2))
        XCTAssertEqual(try text(of: response), "Agent HUD is not running. Open Agent HUD and try again.")
        XCTAssertEqual(response["result"]["isError"], .bool(true))
        XCTAssertEqual(response["result"].objectValue?.keys.sorted(), ["content", "isError"],
                       "a client's own _meta does not make the request one of the newest revision")
        XCTAssertEqual(probe.calls, [MCPToolRequest(tool: "get_panel")])

        // Codex 0.162.1 puts the turn it runs in beside the call.
        let codex = #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"_meta":{"callId":"exec-1","x-codex-turn-metadata":{"session_id":"thread-1","sandbox":"seatbelt","codex_version":"0.162.1"},"threadId":"thread-1","progressToken":1},"name":"get_panel","arguments":{}}}"#
        XCTAssertEqual(try probe.response(to: codex)["result"], response["result"])
    }

    func testWhatTheApplicationReturnsComesBackAsOneBlockOfJSON() throws {
        let result: [String: JSONValue] = ["revision": .integer(12), "saved": .bool(false), "share": .number(0.25),
                                           "blocks": .array([.object(["key": .string("claude"), "title": .string("Claude\nMax \"20x\"")])])]
        probe.answer = .reply(.result(result))
        let response = try call(#"{"name":"get_panel"}"#)
        XCTAssertEqual(response["result"]["isError"], .bool(false))
        XCTAssertNil(response["result"].objectValue?["structuredContent"])
        let text = try text(of: response)
        XCTAssertFalse(text.contains("\n") || text.contains(": "), "compact, on one line")
        XCTAssertEqual(try JSONValue.parse(Data(text.utf8)), .object(result))
        XCTAssertEqual(probe.calls, [MCPToolRequest(tool: "get_panel")], "arguments left out are none")
    }

    /// A picture comes after the text that says what it shows, as the image block every revision the server answers
    /// defines: the PNG in base64 with its media type.
    func testAPictureTheApplicationDrewComesBackAsAnImageBlockAfterTheText() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xFF, 0x00, 0x3E])
        let result: [String: JSONValue] = ["width": .integer(540), "height": .integer(741), "scrolls": .bool(false)]
        probe.answer = .reply(.result(result, images: [MCPImage(mimeType: "image/png", data: png)]))
        let image: JSONValue = .object(["type": .string("image"), "data": .string(png.base64EncodedString()),
                                        "mimeType": .string("image/png")])
        for meta in ["", "," + MCPServerProbe.meta] {
            let response = try call(#"{"name":"get_panel_image","arguments":{}\#(meta)}"#)
            let content = try XCTUnwrap(response["result"]["content"].arrayValue)
            XCTAssertEqual(content.count, 2, meta)
            XCTAssertEqual(content[0]["type"], .string("text"))
            XCTAssertEqual(try JSONValue.parse(Data(try XCTUnwrap(content[0]["text"].stringValue).utf8)), .object(result))
            XCTAssertEqual(content[1], image, "the block has its type, its data and its media type, and nothing else")
            XCTAssertEqual(Data(base64Encoded: content[1]["data"].stringValue ?? ""), png)
            XCTAssertEqual(response["result"]["isError"], .bool(false))
            XCTAssertEqual(response["result"]["resultType"], meta.isEmpty ? .null : .string("complete"),
                           "the newest revision says the result is complete; a handshake client gets the content alone")
        }
        XCTAssertEqual(probe.calls, [MCPToolRequest(tool: "get_panel_image"), MCPToolRequest(tool: "get_panel_image")])

        probe.answer = .reply(.failure("This copy of Agent HUD cannot draw the panel."))
        let refused = try call(#"{"name":"get_panel_image"}"#)
        XCTAssertEqual(try text(of: refused), "This copy of Agent HUD cannot draw the panel.", "a refusal is its sentence and no picture")
        XCTAssertEqual(refused["result"]["isError"], .bool(true))
    }

    func testArgumentsReachTheApplicationAsTheyCame() throws {
        probe.answer = .reply(.result(["revision": .integer(13)]))
        let arguments = #"{"blocks":{"claude":{"widget":"ring","hiddenRows":["weekly"]}},"order":["codex","claude"],"revision":12,"unknown":null}"#
        _ = try call(#"{"name":"set_panel_layout","arguments":\#(arguments)}"#)
        _ = try call(#"{"name":"discard_panel_draft","arguments":{}}"#)
        let layout = MCPToolRequest(tool: "set_panel_layout",
                                    arguments: try XCTUnwrap(try JSONValue.parse(Data(arguments.utf8)).objectValue))
        XCTAssertEqual(probe.calls, [layout, MCPToolRequest(tool: "discard_panel_draft")], "checking them is the application's job")
    }

    func testARefusalOrSilenceFromTheApplicationIsAnErrorResult() throws {
        probe.answer = .reply(.failure("The layout changed since revision 12. Call get_panel and send the layout again."))
        let refused = try call(#"{"name":"set_panel_layout","arguments":{"revision":12}}"#)
        XCTAssertEqual(try text(of: refused), "The layout changed since revision 12. Call get_panel and send the layout again.")
        XCTAssertEqual(refused["result"]["isError"], .bool(true))
        XCTAssertNil(refused.objectValue?["error"], "the model reads a refusal and tries again; it is not a protocol error")

        probe.answer = .unanswered
        let silent = try call(#"{"name":"discard_panel_draft"}"#)
        XCTAssertEqual(try text(of: silent), "Agent HUD did not answer. Try again.")
        XCTAssertEqual(silent["result"]["isError"], .bool(true))
    }
}
