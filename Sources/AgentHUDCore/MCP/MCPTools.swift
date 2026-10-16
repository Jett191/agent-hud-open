import AgentHUDSupport

/// The tools Agent HUD's MCP server offers: a fixed list, the same for every client and in the same order, so a
/// client may cache it. All four act on the hover panel's layouts, the shared one or a screen's own, and on one
/// screen's resting HUD style, and none of them saves: saving is the user's click in the panel. What a tool does with
/// its arguments is the running application's business; only the names and the shapes are known here.
public enum MCPTools {
    /// The tools' names, as a client calls them and as the application is handed them.
    public static let getPanel = "get_panel"
    public static let getPanelImage = "get_panel_image"
    public static let setPanelLayout = "set_panel_layout"
    public static let discardPanelDraft = "discard_panel_draft"
    static let names = [getPanel, getPanelImage, setPanelLayout, discardPanelDraft]

    /// What a client's model is told about the server before it has called anything.
    static let instructions = """
        Agent HUD shows AI coding agents' quota, usage and sessions at the Mac's notch. \
        These tools read what its hover panel shows and rearrange it, for every screen or for one, \
        and restyle one screen's resting HUD. A change is a draft until the user presses Save in the panel.
        """

    private static let getPanelDescription = """
        Read what the Agent HUD hover panel shows now: its blocks (one per agent or API account), each block's rows \
        with their latest readings, the layout in effect, the panel's width and height and whether it scrolls, and the \
        widgets and measures each block accepts; how many sessions it lists and its token chart's period and total; \
        and the attached screens, each with its resting HUD's style and the agents it can show. Call it before \
        changing the layout; block, row and screen keys come from here. Names are written as the panel shows them, in \
        the application's language.
        """

    private static let getPanelImageDescription = """
        Show a picture of the Agent HUD hover panel as the layout in effect draws it, an unsaved draft included, with \
        account names masked and session titles left out, or with show 'hud' a screen's resting HUD as it looks now. \
        Use it to check how a change looks; get_panel reads the same as data.
        """

    private static let setPanelLayoutDescription = """
        Propose a layout for the Agent HUD hover panel: its blocks, sections, session rows, token chart and style, its \
        width included, and the screen's resting HUD: which agents it shows and, for one screen, its mode, edge, sizes \
        and glow. Send the whole layout you want; anything left out uses the default, and a HUD style field left out \
        stays as saved. A call with only hud style fields leaves the layout as it is. What the layout from get_panel \
        holds for a block, a row or an agent not listed now can be sent back as it is. It shows at once as an unsaved \
        draft: the user keeps it with Save in the panel, and it is dropped when Agent HUD restarts. Pass from \
        'default' to propose the built-in layout instead, 'previous' for the last saved one, for a screen with the \
        resting HUD style that went with it, or 'shared' to have a screen use the shared layout again; hud.reset \
        proposes a screen's default HUD style.
        """

    private static let discardPanelDraftDescription = "Drop the unsaved draft so the Agent HUD panel returns to the saved "
        + "layout and, for a screen, its resting HUD to its saved style."

    /// What every tool takes to name the layout it acts on.
    private static let screenDescription = "A screen key from get_panel for that screen's own layout; 'all', the default, "
        + "for the shared layout the other screens use."

    /// The definitions `tools/list` returns.
    static let definitions: [JSONValue] = [
        tool(getPanel, getPanelDescription, input: object(["screen": described("string", screenDescription)]), changes: false),
        tool(getPanelImage, getPanelImageDescription, input: object([
            "screen": described("string", screenDescription),
            "show": text("What to draw: the hover panel, the default, or the screen's resting HUD, which needs a screen key.",
                         oneOf: ["panel", "hud"]),
        ]), changes: false),
        tool(setPanelLayout, setPanelLayoutDescription, input: layout, changes: true),
        tool(discardPanelDraft, discardPanelDraftDescription, input: object(["screen": described("string", screenDescription)]),
             changes: true),
    ]

    /// What `set_panel_layout` takes: every property optional, and no others.
    private static var layout: JSONValue {
        let key: JSONValue = .object(["type": .string("string")])
        let section = text("One of the panel's sections.", oneOf: ["blocks", "tokens", "sessions"])
        let measure: JSONValue = .object(["type": .string("string"), "enum": names(PanelMeasure.allCases.map(\.rawValue))])
        let block = object([
            "widget": text("How the block is drawn: bar rows, a ring, a number or a chart.",
                           oneOf: ["bar", "ring", "number", "chart"]),
            "measures": list("What its picker offers, in order, the first shown first: quota (an API account's balance), burn, "
                             + "tokens, cost. One means no picker; none means all its widget offers.", of: measure),
            "hidden": described("boolean", "True hides the block."),
            "hiddenRows": list("Keys of the block's rows to hide, from get_panel.", of: key),
            "countdown": described("boolean", "False hides a quota block's reset times."),
            "columns": described("integer", "Cells on a line for the ring and number widgets, 2 to 6; 4 if left out."),
            "ringSize": text("Ring size for the ring widget; medium if left out.", oneOf: ["small", "medium", "large"]),
            "span": text("The whole line, the default, or half of it beside the next block if that is half too. Not for bar "
                         + "rows.", oneOf: PanelSpan.allCases.map(\.rawValue)),
        ])
        let blocks: [String: JSONValue] = [
            "type": .string("object"),
            "additionalProperties": block,
            "description": .string("What differs from the default for each block, by block key from get_panel."),
        ]
        let style = object([
            "spacing": text("Room between sections, blocks and rows; regular if left out.", oneOf: ["compact", "regular", "roomy"]),
            "separators": described("boolean", "False drops the lines between blocks and sections."),
            "width": described("integer", "The whole panel's width, \(PanelStyle.widthRange.lowerBound) to "
                               + "\(PanelStyle.widthRange.upperBound) points; \(PanelStyle.defaultWidth) if left out."),
        ], description: "How the whole panel is set.")
        let limits = PanelLayout.Sessions.limitRange
        let sessions = object([
            "limit": described("integer", "Rows at most, \(limits.lowerBound) to \(limits.upperBound); "
                               + "\(PanelLayout.Sessions.defaultLimit) if left out."),
            "agents": list("Only these agents' sessions, names from get_panel's sessions.offeredAgents; none for every "
                           + "agent.", of: key),
            "states": list("Only sessions in these states; none for all.",
                           of: text("A session's state.", oneOf: PanelSessionState.allCases.map(\.rawValue))),
        ], description: "Which sessions the session rows list.")
        let tokens = object([
            "period": text("What the token chart shows when the panel opens: the last 24 hours, 7 days or 30 days; day if "
                           + "left out.", oneOf: PanelTokenPeriod.allCases.map(\.rawValue)),
            "agents": list("Only these agents' tokens, names from get_panel's tokens.offeredAgents; none for every "
                           + "agent.", of: key),
        ], description: "The token chart's period and agents.")
        let hud = object([
            "agents": list("Agents it shows, in order, by name from get_panel's screens; none shows every agent.", of: key),
            "mode": text("For one screen only, as is every field but agents. notch needs a screen with a notch.",
                         oneOf: HUDMode.allCases.map(\.agentName)),
            "edge": text("Dynamic or simple: the edge it is parked on.", oneOf: HUDEdge.allCases.map(\.rawValue)),
            "position": described("number", "Dynamic or simple: its centre along that edge, \(bounds(HUDStyle.Field.position.range)) "
                                  + "A notch HUD made a dock at the top centre starts at 0, clear of the notch."),
            "logoSize": number("Dynamic: logo size in points,", .logoSize),
            "logoGap": number("Dynamic: gap between logos, as a share of a logo,", .logoGap),
            "edgeDistance": number("Dynamic: logos' distance from the edge in points,", .edgeDistance),
            "showLogos": described("boolean", "Dynamic: false leaves the backdrop alone."),
            "simpleSize": number("Simple: ring diameter in points,", .simpleSize),
            "ringWidth": number("Simple: ring stroke in points,", .ringWidth),
            "showRings": described("boolean", "Simple: a ring round each mark."),
            "showNumbers": described("boolean", "Simple: the percentage beside each mark."),
            "bots": described("boolean", "Simple: marks turn into bots."),
            "separateAgents": described("boolean", "Dynamic or simple: hovering a mark opens that agent's own panel."),
            "glow": object([
                "style": text("Glow style.", oneOf: GlowStyle.allCases.map(\.rawValue)),
                "effect": text("What it plays.", oneOf: GlowEffect.allCases.map(\.rawValue)),
                "brightness": number("Its strength,", glow: .brightness),
                "range": number("Blur style: reach in points,", glow: .range),
                "blur": number("Blur style: feather in points,", glow: .blur),
                "speed": number("Seconds a cycle takes while an agent works,", glow: .speed),
                "amplitude": number("Breathe effect: how deep a breath dips,", glow: .amplitude),
                "outwardOnly": described("boolean", "Blur style: fade outward from the rim only."),
            ], description: "Notch or dynamic: the glow."),
            HUDStyle.resetName: described("boolean", "True proposes the screen's default style, the placement its "
                                          + "hardware is given and the default glow, with no other style field."),
        ], description: "The resting HUD: the marks of a Dynamic dock, the items of a Simple panel, the glow; a style "
            + "field left out stays as saved.")
        return object([
            "screen": described("string", screenDescription),
            "blocks": .object(blocks),
            "order": list("Block keys from get_panel, in the order the panel shows them.", of: key),
            "sections": list("The panel's sections, in the order it shows them.", of: section),
            "hiddenSections": list("The panel's sections to hide.", of: section),
            "style": style,
            "sessions": sessions,
            "tokens": tokens,
            "hud": hud,
            "from": text("Propose the built-in layout, the last saved one, or for a screen the shared layout, instead of "
                         + "the one described here. Only 'previous' brings a screen's HUD style with it.",
                         oneOf: ["default", "previous", "shared"]),
            "revision": described("integer", "The revision get_panel returned; when given and no longer current the call is refused."),
        ])
    }

    /// A tool's definition. Every hint is spelled out because a client assumes the worst of one left out: a tool
    /// that changes nothing says so, and one that changes the draft says it destroys nothing, may be repeated, and
    /// reaches nothing beyond this Mac.
    private static func tool(_ name: String, _ description: String, input: JSONValue, changes: Bool) -> JSONValue {
        var hints: [String: JSONValue] = ["readOnlyHint": .bool(!changes), "openWorldHint": .bool(false)]
        if changes {
            hints["destructiveHint"] = .bool(false)
            hints["idempotentHint"] = .bool(true)
        }
        return .object(["name": .string(name), "description": .string(description), "inputSchema": input,
                        "annotations": .object(hints)])
    }

    /// The schema of an object that has `properties`, all optional, and no others.
    private static func object(_ properties: [String: JSONValue], description: String? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": .string("object"), "additionalProperties": .bool(false)]
        if !properties.isEmpty { schema["properties"] = .object(properties) }
        if let description { schema["description"] = .string(description) }
        return .object(schema)
    }

    private static func described(_ type: String, _ description: String) -> JSONValue {
        .object(["type": .string(type), "description": .string(description)])
    }

    /// A number field of a screen's placement, described with the range it keeps within.
    private static func number(_ description: String, _ field: HUDStyle.Field) -> JSONValue {
        described("number", description + " " + bounds(field.range))
    }

    /// A number field of a screen's glow, described with the range it keeps within.
    private static func number(_ description: String, glow field: HUDStyle.GlowField) -> JSONValue {
        described("number", description + " " + bounds(field.range))
    }

    private static func bounds(_ range: ClosedRange<Double>?) -> String {
        guard let range else { return "" }
        return "\(HUDStyle.written(range.lowerBound)) to \(HUDStyle.written(range.upperBound))."
    }

    private static func text(_ description: String, oneOf values: [String]) -> JSONValue {
        .object(["type": .string("string"), "enum": names(values), "description": .string(description)])
    }

    private static func names(_ values: [String]) -> JSONValue { .array(values.map(JSONValue.string)) }

    private static func list(_ description: String, of items: JSONValue) -> JSONValue {
        .object(["type": .string("array"), "items": items, "description": .string(description)])
    }
}
