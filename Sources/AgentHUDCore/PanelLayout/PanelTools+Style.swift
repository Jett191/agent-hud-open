import AgentHUDSupport
import Foundation

extension PanelTools {
    /// The style part of a proposal: the style fields of its `hud`, checked against the one screen they are for. A
    /// screen's style belongs to that screen alone, so the shared layout takes none, and only an attached screen has a
    /// resting HUD to draw one on. A proposal is whole: a field it leaves out is what the screen has saved. A field set
    /// to what the screen has saved changes nothing and is no issue, so the style `get_panel` lists can be sent back,
    /// and the style a waiting draft lists asks nothing new, so a draft's style read back can be sent back too, a
    /// version of the screen it brings back included. `reset` true asks for the screen's default style whole, as the
    /// HUD style's Reset to Default gives it, in place of every other style field.
    @MainActor
    struct StyleProposal {
        /// The attached screen the proposal is for; nil for the shared layout or a screen that is away.
        let target: PanelScreen?
        /// What the proposal asks, reduced to what it changes about what the screen has saved, with a dock leaving the
        /// notch placed clear of it as Settings places one.
        let reduced: HUDStyle
        /// Whether the proposal asks for the screen's default style (`hud.reset`).
        let resets: Bool
        /// The mode the screen's resting HUD would have under the proposal; nil without a screen to have one.
        let mode: HUDMode?
        /// Why the style cannot be done as asked, as sentences; what the reading would forgive is said by
        /// `PanelLayout.misreadings(of:)`.
        let reasons: [String]
        /// Whether a dock leaving the notch was placed clear of it at the top left, which the agent did not ask.
        let placedClear: Bool

        init(hud fields: [String: JSONValue], scope: PanelLayoutScope, among attached: [PanelScreen], tools: PanelTools) {
            let fieldsGiven = HUDStyle.names.filter { Self.sets($0, fields[$0]) }.map { "hud.\($0)" }
            resets = fields[HUDStyle.resetName] == .bool(true)
            let given = fieldsGiven + (resets ? ["hud.\(HUDStyle.resetName)"] : [])
            let style = HUDStyle(json: fields)
            let paths = HUDStyle.listed(given)
            let sets = given.count == 1 ? "sets" : "set"
            guard case .screen(let key) = scope else {
                target = nil
                reduced = HUDStyle()
                mode = nil
                placedClear = false
                reasons = given.isEmpty ? [] : ["\(paths) \(sets) the resting HUD of one screen, so the proposal needs "
                    + "that screen's key; with screen \"all\" the hud takes agents alone. \(PanelTools.attachedList(attached))"]
                return
            }
            guard let screen = attached.first(where: { $0.key == key }) else {
                target = nil
                reduced = HUDStyle()
                mode = nil
                placedClear = false
                reasons = given.isEmpty ? [] : ["\(paths) \(sets) the resting HUD of an attached screen, and "
                    + "\(tools.name(of: key, among: attached)) has none to draw it on."]
                return
            }
            let settings = tools.store.settings.settings
            let placement = settings.placement(on: key, hasNotch: screen.hasNotch), glow = settings.glow(on: key)
            target = screen
            let asked = style.reduced(placement: placement, glow: glow)
            if resets {
                // The default style, as the store proposes it: what it changes, which the default always draws.
                reduced = HUDStyle(every: .default(hasNotch: screen.hasNotch), glow: settings.glow)
                    .reduced(placement: placement, glow: glow)
                placedClear = false
                reasons = fieldsGiven.isEmpty ? [] : ["hud.reset proposes the default style of the resting HUD of "
                    + "\(tools.name(of: key, among: attached)) whole, so the hud takes no other style field with it: "
                    + "leave out \(HUDStyle.listed(fieldsGiven)), or leave out hud.\(HUDStyle.resetName)."]
            } else if let waiting = tools.layout.styleDraft(of: key), asked == waiting {
                reduced = asked
                placedClear = false
                reasons = []
            } else {
                let placed = style.placedClearOfTheNotch(from: placement, hasNotch: screen.hasNotch)
                let changes = placed.reduced(placement: placement, glow: glow)
                reduced = changes
                placedClear = placed.position != style.position
                reasons = changes.issues(placement: placement, glow: glow, hasNotch: screen.hasNotch,
                                         screen: tools.name(of: key, among: attached)).map { "\($0.path): \($0.message)" }
            }
            mode = reduced.applied(to: placement).mode
        }

        /// Whether a hud field as sent sets anything: a value given as null is not given, and neither is a glow that has
        /// no property or only null ones.
        private static func sets(_ name: String, _ value: JSONValue?) -> Bool {
            guard let value, value != .null else { return false }
            guard name == "glow", let glow = value.objectValue else { return true }
            return glow.values.contains { $0 != .null }
        }
    }

    /// Shows a proposal's style as `key`'s style draft: the screen's default style for `hud.reset`, else what the
    /// proposal changes. A proposal's style is whole, so one that changes nothing, or a screen that is away, drops the
    /// style draft. The screen's layout, saved or as a draft, is left as it is.
    func proposeStyle(_ style: StyleProposal, for key: String) {
        guard let target = style.target else { return layout.discardStyle(key) }
        if style.resets {
            layout.proposeDefaultLook(for: key, hasNotch: target.hasNotch)
        } else {
            layout.proposeStyle(style.reduced, for: key, hasNotch: target.hasNotch)
        }
    }

    /// The layout in effect for a scope as an agent reads it, which it can send back as it is: for a screen, with the
    /// fields of its style draft in `hud` beside its agents.
    func layoutJSON(_ scope: PanelLayoutScope) -> JSONValue {
        var json = (try? JSONValue.from(effective(scope)))?.objectValue ?? [:]
        guard case .screen(let key) = scope, let style = layout.styleDraft(of: key) else { return .object(json) }
        json["hud"] = .object((json["hud"]?.objectValue ?? [:]).merging(style.json) { $1 })
        return .object(json)
    }

    /// One attached screen's resting HUD as it draws it now, its style draft included: every style field in an agent's
    /// words, each one as a proposal sets it.
    func styleInEffect(of screen: PanelScreen) -> JSONValue {
        let settings = store.settings
        let style = HUDStyle(every: settings.effectivePlacement(on: screen.key, hasNotch: screen.hasNotch),
                             glow: settings.effectiveGlow(on: screen.key))
        return .object(style.json)
    }
}
