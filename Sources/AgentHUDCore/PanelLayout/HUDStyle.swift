import AgentHUDSupport
import Foundation

/// A change an agent proposed to one screen's resting HUD: the fields of that screen's placement and glow it sets, each
/// nil where it leaves Settings as they are. Settings stay the saved truth. A style waits as that screen's draft, drawn
/// over its settings (`applied(to:)`) until a person saves it into them or drops it (`PanelLayoutStore`), and a person's
/// own edit of that screen drops it first. Its values are within the ranges Settings keep them in.
///
/// It is written in an agent's words, as `set_panel_layout`'s `hud` takes it beside `agents`: `mode` is `notch`,
/// `dynamic` or `simple`; `position` is the placement's `offset`, `logoGap` its `gapScale`, `edgeDistance` its
/// `logoEdgeDistance`, `showLogos`, `showRings` and `showNumbers` its `showsLogos`, `showsRings` and `showsNumbers`,
/// `bots` its `simpleBots` and `separateAgents` its `separatesAgents`; under `glow`, `speed` is the glow's working
/// period, `breathSeconds`, and `amplitude` its `breathAmplitude`.
public struct HUDStyle: Hashable, Sendable {
    public var mode: HUDMode?
    public var edge: HUDEdge?
    /// The HUD's centre along its edge, 0 to 1.
    public var position: Double?
    public var logoSize: Double?
    /// The gap between two logos, as a share of a logo.
    public var logoGap: Double?
    /// From a logo, its outline included, to its edge, in points.
    public var edgeDistance: Double?
    public var showLogos: Bool?
    public var simpleSize: Double?
    public var ringWidth: Double?
    public var showRings: Bool?
    public var showNumbers: Bool?
    /// Whether the Simple panel's marks turn into bots.
    public var bots: Bool?
    /// Whether a dock answers for one agent at a time.
    public var separateAgents: Bool?
    public var glow: Glow

    /// The glow's part of a style.
    public struct Glow: Hashable, Sendable {
        public var style: GlowStyle?
        public var effect: GlowEffect?
        public var brightness: Double?
        public var range: Double?
        public var blur: Double?
        /// The period every effect plays at while an agent works, in seconds.
        public var speed: Double?
        /// How deep a breath dips.
        public var amplitude: Double?
        public var outwardOnly: Bool?

        public init(style: GlowStyle? = nil, effect: GlowEffect? = nil, brightness: Double? = nil, range: Double? = nil,
                    blur: Double? = nil, speed: Double? = nil, amplitude: Double? = nil, outwardOnly: Bool? = nil) {
            self.style = style
            self.effect = effect
            self.brightness = brightness
            self.range = range
            self.blur = blur
            self.speed = speed
            self.amplitude = amplitude
            self.outwardOnly = outwardOnly
        }
    }

    public init(mode: HUDMode? = nil, edge: HUDEdge? = nil, position: Double? = nil, logoSize: Double? = nil,
                logoGap: Double? = nil, edgeDistance: Double? = nil, showLogos: Bool? = nil, simpleSize: Double? = nil,
                ringWidth: Double? = nil, showRings: Bool? = nil, showNumbers: Bool? = nil, bots: Bool? = nil,
                separateAgents: Bool? = nil, glow: Glow = Glow()) {
        self.mode = mode
        self.edge = edge
        self.position = position
        self.logoSize = logoSize
        self.logoGap = logoGap
        self.edgeDistance = edgeDistance
        self.showLogos = showLogos
        self.simpleSize = simpleSize
        self.ringWidth = ringWidth
        self.showRings = showRings
        self.showNumbers = showNumbers
        self.bots = bots
        self.separateAgents = separateAgents
        self.glow = glow
    }

    /// Whether the style changes nothing.
    var isEmpty: Bool { self == HUDStyle() }

    /// `placement` with the fields this style sets in place of its own.
    func applied(to placement: ScreenPlacement) -> ScreenPlacement {
        var next = placement
        if let mode { next.mode = mode }
        if let edge { next.edge = edge }
        if let position { next.offset = position }
        if let logoSize { next.logoSize = logoSize }
        if let logoGap { next.gapScale = logoGap }
        if let edgeDistance { next.logoEdgeDistance = edgeDistance }
        if let showLogos { next.showsLogos = showLogos }
        if let simpleSize { next.simpleSize = simpleSize }
        if let ringWidth { next.ringWidth = ringWidth }
        if let showRings { next.showsRings = showRings }
        if let showNumbers { next.showsNumbers = showNumbers }
        if let bots { next.simpleBots = bots }
        if let separateAgents { next.separatesAgents = separateAgents }
        return next
    }

    /// `glow` with the fields this style sets in place of its own.
    func applied(to glow: GlowSettings) -> GlowSettings {
        var next = glow
        if let style = self.glow.style { next.style = style }
        if let effect = self.glow.effect { next.effect = effect }
        if let brightness = self.glow.brightness { next.brightness = brightness }
        if let range = self.glow.range { next.range = range }
        if let blur = self.glow.blur { next.blur = blur }
        if let speed = self.glow.speed { next.breathSeconds = speed }
        if let amplitude = self.glow.amplitude { next.breathAmplitude = amplitude }
        if let outwardOnly = self.glow.outwardOnly { next.outwardOnly = outwardOnly }
        return next
    }

    /// Every field an agent can set, as `placement` and `glow` have it: a screen's style in effect, as `get_panel` lists it.
    init(every placement: ScreenPlacement, glow: GlowSettings) {
        self.init(mode: placement.mode, edge: placement.edge, position: placement.offset, logoSize: placement.logoSize,
                  logoGap: placement.gapScale, edgeDistance: placement.logoEdgeDistance, showLogos: placement.showsLogos,
                  simpleSize: placement.simpleSize, ringWidth: placement.ringWidth, showRings: placement.showsRings,
                  showNumbers: placement.showsNumbers, bots: placement.simpleBots, separateAgents: placement.separatesAgents,
                  glow: Glow(style: glow.style, effect: glow.effect, brightness: glow.brightness, range: glow.range,
                             blur: glow.blur, speed: glow.breathSeconds, amplitude: glow.breathAmplitude,
                             outwardOnly: glow.outwardOnly))
    }

    /// The style reduced to what it changes about a screen saved with `placement` and `glow`: a field set to the value
    /// the screen has saved is left out, so a style that spells out what is saved is empty.
    func reduced(placement: ScreenPlacement, glow: GlowSettings) -> HUDStyle {
        let saved = HUDStyle(every: placement, glow: glow)
        var kept = self
        for field in Field.allCases where kept.value(field) == saved.value(field) { kept.set(field, .null) }
        for field in GlowField.allCases where kept.glow.value(field) == saved.glow.value(field) { kept.glow.set(field, .null) }
        return kept
    }
}

/// A screen's style draft: the style, as an agent reads it, and whether the screen has a notch, which decides the
/// placement it is drawn over where the screen has none of its own saved. A draft that brings a version of the screen
/// back, its previous one or the default, also holds that version's look as it was kept (`restoring`): the screen draws
/// that look whole, and Save writes it back as it was, a placement or a glow the screen had none of included.
struct PanelStyleDraft: Equatable, Sendable {
    let style: HUDStyle
    let hasNotch: Bool
    var restoring: ScreenLook? = nil

    /// The placement the screen draws with the draft over the `saved` one; `hasNotch` is the screen's.
    func placement(over saved: ScreenPlacement, hasNotch: Bool) -> ScreenPlacement {
        guard let restoring else { return style.applied(to: saved) }
        return restoring.placement ?? .default(hasNotch: hasNotch)
    }

    /// The glow the screen draws with the draft over the `saved` one; `defaultGlow` is `Settings.glow`.
    func glow(over saved: GlowSettings, defaultGlow: GlowSettings) -> GlowSettings {
        guard let restoring else { return style.applied(to: saved) }
        return restoring.glow ?? defaultGlow
    }

    /// The screen's own placement and glow once the draft is written over `look`: the version it restores, else the
    /// style over `look`, where a part the style changes nothing of stays as it was, none included, so a screen that
    /// draws a default keeps drawing it.
    /// - defaultGlow: the glow a screen without one of its own draws (`Settings.glow`).
    func applied(to look: ScreenLook, defaultGlow: GlowSettings) -> ScreenLook {
        if let restoring { return restoring }
        let placement = look.placement ?? .default(hasNotch: hasNotch), glow = look.glow ?? defaultGlow
        let drawnPlacement = style.applied(to: placement), drawnGlow = style.applied(to: glow)
        return ScreenLook(placement: drawnPlacement == placement ? look.placement : drawnPlacement,
                          glow: drawnGlow == glow ? look.glow : drawnGlow)
    }
}

extension HUDMode {
    /// The mode as Agent HUD names it to a person and to an agent: notch, dynamic or simple.
    var agentName: String {
        switch self {
        case .notch: "notch"
        case .logos: "dynamic"
        case .simple: "simple"
        }
    }

    /// The mode an agent names; nil for a name that is none.
    init?(agentName: String) {
        guard let mode = HUDMode.allCases.first(where: { $0.agentName == agentName }) else { return nil }
        self = mode
    }
}

// MARK: Fields

extension HUDStyle {
    /// A field of a screen's placement an agent can set, by the name it uses for it.
    enum Field: String, CaseIterable, Sendable {
        case mode, edge, position, logoSize, logoGap, edgeDistance, showLogos, simpleSize, ringWidth, showRings,
             showNumbers, bots, separateAgents

        /// The range a number keeps within, Settings' own; nil for a field that is no number.
        var range: ClosedRange<Double>? {
            switch self {
            case .position: 0...1
            case .logoSize: ScreenPlacement.logoSizeRange
            case .logoGap: ScreenPlacement.gapScaleRange
            case .edgeDistance: ScreenPlacement.logoEdgeDistanceRange
            case .simpleSize: ScreenPlacement.simpleSizeRange
            case .ringWidth: ScreenPlacement.ringWidthRange
            case .mode, .edge, .showLogos, .showRings, .showNumbers, .bots, .separateAgents: nil
            }
        }

        /// The modes whose HUD the field changes, as Settings shows it for them.
        var modes: [HUDMode] {
            switch self {
            case .mode: HUDMode.allCases
            case .edge, .position, .separateAgents: [.logos, .simple]
            case .logoSize, .logoGap, .edgeDistance, .showLogos: [.logos]
            case .simpleSize, .ringWidth, .showRings, .showNumbers, .bots: [.simple]
            }
        }
    }

    /// A field of a screen's glow an agent can set, by the name it uses for it.
    enum GlowField: String, CaseIterable, Sendable {
        case style, effect, brightness, range, blur, speed, amplitude, outwardOnly

        /// The range a number keeps within, Settings' own; nil for a field that is no number.
        var range: ClosedRange<Double>? {
            switch self {
            case .brightness: GlowSettings.brightnessRange
            case .range, .blur: GlowSettings.sizeRange
            case .speed: GlowSettings.workingPeriodRange
            case .amplitude: GlowSettings.amplitudeRange
            case .style, .effect, .outwardOnly: nil
            }
        }
    }

    /// A field's value as an agent writes it; nil while the style leaves it.
    func value(_ field: Field) -> JSONValue? {
        switch field {
        case .mode: mode.map { .string($0.agentName) }
        case .edge: edge.map { .string($0.rawValue) }
        case .position: position.map(JSONValue.number)
        case .logoSize: logoSize.map(JSONValue.number)
        case .logoGap: logoGap.map(JSONValue.number)
        case .edgeDistance: edgeDistance.map(JSONValue.number)
        case .showLogos: showLogos.map(JSONValue.bool)
        case .simpleSize: simpleSize.map(JSONValue.number)
        case .ringWidth: ringWidth.map(JSONValue.number)
        case .showRings: showRings.map(JSONValue.bool)
        case .showNumbers: showNumbers.map(JSONValue.bool)
        case .bots: bots.map(JSONValue.bool)
        case .separateAgents: separateAgents.map(JSONValue.bool)
        }
    }

    /// Sets a field from what an agent wrote: a value the field takes, within its range, or nothing for any other.
    mutating func set(_ field: Field, _ json: JSONValue) {
        let number = json.numberValue.flatMap { value in field.range.map { $0.contains(value) } == true ? value : nil }
        switch field {
        case .mode: mode = json.stringValue.flatMap(HUDMode.init(agentName:))
        case .edge: edge = json.stringValue.flatMap(HUDEdge.init(rawValue:))
        case .position: position = number
        case .logoSize: logoSize = number
        case .logoGap: logoGap = number
        case .edgeDistance: edgeDistance = number
        case .showLogos: showLogos = json.boolValue
        case .simpleSize: simpleSize = number
        case .ringWidth: ringWidth = number
        case .showRings: showRings = json.boolValue
        case .showNumbers: showNumbers = json.boolValue
        case .bots: bots = json.boolValue
        case .separateAgents: separateAgents = json.boolValue
        }
    }

    /// The style as an agent writes it: the fields it sets, the glow's under `glow`, and none it leaves.
    var json: [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        for field in Field.allCases { fields[field.rawValue] = value(field) }
        var glowFields: [String: JSONValue] = [:]
        for field in GlowField.allCases { glowFields[field.rawValue] = glow.value(field) }
        if !glowFields.isEmpty { fields["glow"] = .object(glowFields) }
        return fields
    }

    /// The style fields of a hud as an agent wrote them, each one a value it takes; `agents` and keys that name no
    /// field are passed over. A proposal is checked first (`misreadings(of:)`), so nothing it asks for is lost here.
    init(json fields: [String: JSONValue]) {
        self.init()
        for field in Field.allCases { if let value = fields[field.rawValue] { set(field, value) } }
        for field in GlowField.allCases { if let value = fields["glow"]?.objectValue?[field.rawValue] { glow.set(field, value) } }
    }

    /// The names of the style's fields, as a hud takes them beside `agents`.
    static var names: [String] { Field.allCases.map(\.rawValue) + ["glow"] }

    /// The hud's switch that asks for a screen's default style whole, in place of the style's fields: the placement its
    /// hardware is given and the default glow, as the HUD style's Reset to Default gives them.
    static let resetName = "reset"
}

extension HUDStyle.Glow {
    func value(_ field: HUDStyle.GlowField) -> JSONValue? {
        switch field {
        case .style: style.map { .string($0.rawValue) }
        case .effect: effect.map { .string($0.rawValue) }
        case .brightness: brightness.map(JSONValue.number)
        case .range: range.map(JSONValue.number)
        case .blur: blur.map(JSONValue.number)
        case .speed: speed.map(JSONValue.number)
        case .amplitude: amplitude.map(JSONValue.number)
        case .outwardOnly: outwardOnly.map(JSONValue.bool)
        }
    }

    mutating func set(_ field: HUDStyle.GlowField, _ json: JSONValue) {
        let number = json.numberValue.flatMap { value in field.range.map { $0.contains(value) } == true ? value : nil }
        switch field {
        case .style: style = json.stringValue.flatMap(GlowStyle.init(rawValue:))
        case .effect: effect = json.stringValue.flatMap(GlowEffect.init(rawValue:))
        case .brightness: brightness = number
        case .range: range = number
        case .blur: blur = number
        case .speed: speed = number
        case .amplitude: amplitude = number
        case .outwardOnly: outwardOnly = json.boolValue
        }
    }
}
