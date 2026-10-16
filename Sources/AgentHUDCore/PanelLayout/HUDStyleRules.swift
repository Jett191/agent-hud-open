import AgentHUDSupport
import Foundation

extension HUDStyle {
    /// What is wrong with one style field of a hud as an agent sent it, or its `reset`, as sentences: a value of the
    /// wrong type or out of its range, a mode, edge, glow style or effect this build does not know, or a property the
    /// glow does not have. Nil for a key that names no style field, which the caller words. A value given as null is not
    /// given.
    static func misreadings(ofField name: String, _ value: JSONValue) -> [String]? {
        if name == "glow" { return glowMisreadings(value) }
        if name == resetName { return value == .null || value.boolValue != nil ? [] : ["hud.\(name) is true or false."] }
        guard let field = Field(rawValue: name) else { return nil }
        if value == .null { return [] }
        let path = "hud.\(name)"
        switch field {
        case .mode:
            return HUDMode(agentName: value.stringValue ?? "") == nil
                ? ["\(path) is one of \(PanelLayout.quoted(HUDMode.allCases.map(\.agentName)))."] : []
        case .edge:
            return HUDEdge(rawValue: value.stringValue ?? "") == nil
                ? ["\(path) is one of \(PanelLayout.quoted(HUDEdge.allCases.map(\.rawValue)))."] : []
        case .showLogos, .showRings, .showNumbers, .bots, .separateAgents:
            return value.boolValue == nil ? ["\(path) is true or false."] : []
        case .position, .logoSize, .logoGap, .edgeDistance, .simpleSize, .ringWidth:
            return number(value, at: path, within: field.range)
        }
    }

    private static func glowMisreadings(_ value: JSONValue) -> [String] {
        if value == .null { return [] }
        guard let glow = value.objectValue else { return ["hud.glow is an object."] }
        var found: [String] = []
        for property in glow.keys.sorted() {
            let value = glow[property] ?? .null
            let path = "hud.glow.\(property)"
            guard let field = GlowField(rawValue: property) else {
                found.append("hud.glow has no property \"\(property)\"; the glow takes "
                             + "\(listed(GlowField.allCases.map(\.rawValue))).")
                continue
            }
            if value == .null { continue }
            switch field {
            case .style:
                if GlowStyle(rawValue: value.stringValue ?? "") == nil {
                    found.append("\(path) is one of \(PanelLayout.quoted(GlowStyle.allCases.map(\.rawValue))).")
                }
            case .effect:
                if GlowEffect(rawValue: value.stringValue ?? "") == nil {
                    found.append("\(path) is one of \(PanelLayout.quoted(GlowEffect.allCases.map(\.rawValue))).")
                }
            case .outwardOnly:
                if value.boolValue == nil { found.append("\(path) is true or false.") }
            case .brightness, .range, .blur, .speed, .amplitude:
                found += number(value, at: path, within: field.range)
            }
        }
        return found
    }

    private static func number(_ value: JSONValue, at path: String, within range: ClosedRange<Double>?) -> [String] {
        guard let range else { return [] }
        if let number = value.numberValue, range.contains(number) { return [] }
        return ["\(path) is a number from \(written(range.lowerBound)) to \(written(range.upperBound))."]
    }

    /// A bound as a sentence writes it: a whole number without a point, such as 12, else as it is, such as 0.1.
    static func written(_ value: Double) -> String {
        value.rounded() == value ? "\(Int(value))" : "\(value)"
    }

    /// Names joined as a sentence lists them: "a, b and c".
    static func listed(_ names: [String]) -> String {
        guard let last = names.last, names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }

    // MARK: What a screen can draw

    /// Every field the style sets that the screen's resting HUD would not draw as asked, by path, worded for the agent:
    /// mode `notch` on a screen without a notch, and a field that the mode the HUD would have does not draw, as Settings
    /// shows each only for the modes it changes: an edge or a position beside the notch, a logo's size on a Simple panel,
    /// a glow on a Simple panel, which draws none, a range, feather or outward fade on a grid glow, and a breath's depth
    /// under another effect. It is asked of a style reduced to what it changes (`reduced(placement:glow:)`), so a field
    /// that only repeats what is saved is never one.
    ///
    /// - placement, glow: what the screen has saved, which the style is drawn over.
    /// - screen: the screen as a sentence names it, such as "\"Display 2\"".
    func issues(placement: ScreenPlacement, glow saved: GlowSettings, hasNotch: Bool, screen: String) -> [PanelLayoutIssue] {
        let mode = applied(to: placement).mode, drawn = applied(to: saved)
        var issues: [PanelLayoutIssue] = []
        if self.mode == .notch, !hasNotch {
            let others = HUDMode.allCases.filter { $0 != .notch }.map { "\"\($0.agentName)\"" }.joined(separator: " or ")
            issues.append(PanelLayoutIssue(path: "hud.mode", message: "\(screen) has no notch, so its HUD cannot be "
                                           + "\"notch\". It can be \(others)."))
        }
        let modeNamed = "the HUD of \(screen) would be \"\(mode.agentName)\""
        for field in Field.allCases where field != .mode && value(field) != nil && !field.modes.contains(mode) {
            let modes = field.modes.map { "\"\($0.agentName)\"" }.joined(separator: " or ")
            issues.append(PanelLayoutIssue(path: "hud.\(field.rawValue)", message: "\(field.rawValue) sets a \(modes) HUD, and "
                                           + "\(modeNamed). Leave it out, or set mode to \(modes)."))
        }
        for field in GlowField.allCases where self.glow.value(field) != nil {
            let path = "hud.glow.\(field.rawValue)"
            if mode == .simple {
                issues.append(PanelLayoutIssue(path: path, message: "A \"simple\" HUD draws no glow, and \(modeNamed)."))
            } else if [.range, .blur, .outwardOnly].contains(field), drawn.style != .blur {
                issues.append(PanelLayoutIssue(path: path, message: "\(field.rawValue) sets the \"blur\" glow style, and the "
                                               + "glow of \(screen) would be \"\(drawn.style.rawValue)\"."))
            } else if field == .amplitude, drawn.effect != .breathe {
                issues.append(PanelLayoutIssue(path: path, message: "amplitude sets the \"breathe\" effect, and the glow of "
                                               + "\(screen) would play \"\(drawn.effect.rawValue)\"."))
            }
        }
        return issues
    }

    /// The style as a screen saved with `placement` on a display with a notch would take it, as Settings' own change of
    /// mode does: a dock that leaves the notch for the top edge, where it has never been moved from the centre, starts
    /// at the top left, clear of the hardware. A position given as the saved centre is no position, so the style
    /// `get_panel` lists, sent back with a new mode, is placed as Settings places it.
    func placedClearOfTheNotch(from placement: ScreenPlacement, hasNotch: Bool) -> HUDStyle {
        guard hasNotch, mode?.isDocked == true, placement.mode == .notch, (position ?? placement.offset) == placement.offset,
              (edge ?? placement.edge) == .top, placement.offset == 0.5 else { return self }
        var style = self
        style.position = 0
        return style
    }
}
