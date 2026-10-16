import AgentHUDSupport
import Foundation

/// What `get_panel_image` tells an agent: a picture of a screen's hover panel, or of its resting HUD.
extension PanelTools {
    // MARK: The panel

    /// The picture with what it shows: which screen and layout and its revision, the panel's size in points, whether it
    /// scrolls on its display, and the pixels a point it is drawn at, with a note that says the same in words.
    func image(_ scope: PanelLayoutScope, among attached: [PanelScreen]) -> MCPToolReply {
        guard let picture else {
            return .failure("This copy of Agent HUD cannot draw the panel, so there is no picture of it here. "
                            + "get_panel reads the same panel as data.")
        }
        guard let drawn = picture(scope) else {
            return .failure("The panel's picture could not be drawn. Try again, or read the panel with get_panel.")
        }
        let fit = drawn.fit
        var note: String
        var display = "The main display"
        switch scope {
        case .shared:
            note = "The hover panel as \(layout.hasDraft ? "the unsaved draft" : "the saved layout") draws it"
        case .screen(let key):
            note = "The hover panel on \(name(of: key, among: attached)) as \(drawing(key)) draws it"
            // The bar above the footer says what waits unsaved, the screen's style too, and counts in the height.
            if layout.hasStyleDraft(key) {
                note += layout.draftScope(on: key) == nil
                    ? ", with the bar above its footer that says its resting HUD's style is unsaved"
                    : ", with the bar above its footer for the unsaved layout and its resting HUD's unsaved style"
            }
            if attached.contains(where: { $0.key == key }) { display = "That display" }
        }
        note += ", \(Self.points(drawn.width)) by \(Self.points(fit.height)) points, with account names masked, session titles "
            + "left out and any reading's reason or client's notice drawn as grey bars."
        if fit.scrolls {
            note += " \(display) opens it at most \(Self.points(fit.maximumHeight)) points tall, so a person scrolls to see "
                + "the rest; the picture shows all of it."
        }
        if drawn.isScaledDown {
            note += " It is drawn at \(Self.hundredths(drawn.scale)) pixels a point instead of \(Self.points(PanelPicture.pointScale)) "
                + "to stay within \(PanelPicture.pixelLimit) pixels tall."
        }
        let result: [String: JSONValue] = [
            "screen": .string(Self.name(of: scope)), "revision": .integer(revision), "unsaved": .bool(unsaved(scope)),
            "width": .integer(Int64(drawn.width.rounded())), "height": .integer(Int64(fit.height.rounded())),
            "scrolls": .bool(fit.scrolls), "pixelsPerPoint": .number(Self.hundredths(drawn.scale)), "note": .string(note),
        ]
        return .result(result, images: [MCPImage(mimeType: "image/png", data: drawn.png)])
    }

    /// Which layout a screen's panel draws, in words.
    private func drawing(_ key: String) -> String {
        switch layout.draft(of: key) {
        case .own?: return "its own unsaved draft"
        case .shared?: return "the shared layout, in an unsaved draft that has it use the shared layout"
        case nil: break
        }
        if layout.ownLayout(of: key) != nil { return "its own saved layout" }
        return layout.hasDraft ? "the shared layout's unsaved draft" : "the saved shared layout"
    }

    // MARK: The resting HUD

    /// A picture of one attached screen's resting HUD as it looks now, its style draft included, drawn off screen without
    /// opening anything: which screen, its mode and edge, whether a style draft waits, whether the glow is in the
    /// picture, its size in points and the pixels a point it is drawn at, with a note that says the same in words.
    func hudImage(_ scope: PanelLayoutScope, among attached: [PanelScreen]) -> MCPToolReply {
        guard case .screen(let key) = scope else {
            return .failure("show \"hud\" draws one screen's resting HUD, so it needs that screen's key. "
                            + Self.attachedList(attached))
        }
        guard let screen = attached.first(where: { $0.key == key }) else {
            return .failure("\(name(of: key, among: attached, starting: true)) has no resting HUD to draw. "
                            + Self.attachedList(attached))
        }
        guard let hud else {
            return .failure("This copy of Agent HUD cannot draw a resting HUD, so there is no picture of it here. "
                            + "get_panel reads its style as data.")
        }
        guard let drawn = hud(key) else {
            return .failure("The resting HUD's picture could not be drawn. Try again, or read its style with get_panel.")
        }
        let placement = store.settings.effectivePlacement(on: key, hasNotch: screen.hasNotch)
        let draft = layout.hasStyleDraft(key)
        var note = "The resting HUD of \"\(screen.name)\" as it looks now, " + (draft ? "with its unsaved style draft" : "as saved")
        switch placement.mode {
        case .notch:
            note += screen.hasNotch ? ": the island at its notch" : ": the bar that stands in for a notch at its top centre"
        case .logos, .simple:
            note += ": a \"\(placement.mode.agentName)\" HUD on its \(placement.edge.rawValue) edge"
            if placement.edge != .top { note += ", drawn here along a top edge as Settings previews it" }
        }
        note += ", on a dark backdrop, \(Self.points(drawn.width)) by \(Self.points(drawn.height)) points"
        if placement.mode == .simple {
            note += "; a simple HUD draws no glow."
        } else {
            note += drawn.drawsGlow ? ", with its glow." : ", without its glow, which only its window on the display draws."
        }
        note += " It shows marks and figures, and no account or session."
        let result: [String: JSONValue] = [
            "screen": .string(key), "show": .string("hud"), "revision": .integer(revision), "unsaved": .bool(draft),
            "mode": .string(placement.mode.agentName), "edge": .string(placement.mode.isDocked ? placement.edge.rawValue : "top"),
            "glow": .bool(drawn.drawsGlow), "width": .integer(Int64(drawn.width.rounded())),
            "height": .integer(Int64(drawn.height.rounded())), "pixelsPerPoint": .number(Self.hundredths(drawn.scale)),
            "note": .string(note),
        ]
        return .result(result, images: [MCPImage(mimeType: "image/png", data: drawn.png)])
    }
}
