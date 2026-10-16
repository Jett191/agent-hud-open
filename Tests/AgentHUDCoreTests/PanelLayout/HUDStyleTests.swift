import AgentHUDSupport
import XCTest
@testable import AgentHUDCore

/// A screen's resting HUD style as an agent writes it (`HUDStyle`), and the panel's width a layout sets: what each field
/// changes in the settings, the ranges a proposal is held to, and what is refused with which sentence.
final class HUDStyleTests: XCTestCase {
    /// Every field set, in an agent's words.
    private let every: [String: JSONValue] = [
        "mode": .string("dynamic"), "edge": .string("left"), "position": .number(0.25), "logoSize": .integer(30),
        "logoGap": .number(0.5), "edgeDistance": .integer(6), "showLogos": .bool(false), "simpleSize": .integer(32),
        "ringWidth": .number(2.5), "showRings": .bool(false), "showNumbers": .bool(false), "bots": .bool(true),
        "separateAgents": .bool(true),
        "glow": .object(["style": .string("dots"), "effect": .string("ripple"), "brightness": .number(0.5),
                         "range": .integer(20), "blur": .integer(4), "speed": .integer(6), "amplitude": .number(0.3),
                         "outwardOnly": .bool(false)]),
    ]

    // MARK: What a style changes

    /// Each field lands on the settings' own field, and a field left out leaves it as it was.
    func testEachFieldSetsItsSettingsField() {
        let style = HUDStyle(json: every)
        let placement = style.applied(to: .default(hasNotch: true))
        XCTAssertEqual(placement, ScreenPlacement(mode: .logos, edge: .left, offset: 0.25, logoSize: 30, logoEdgeDistance: 6,
                                                  gapScale: 0.5, showsLogos: false, simpleSize: 32, ringWidth: 2.5,
                                                  showsRings: false, showsNumbers: false, simpleBots: true, separatesAgents: true))
        var glow = GlowSettings()
        glow.style = .dots
        glow.effect = .ripple
        glow.brightness = 0.5
        glow.range = 20
        glow.blur = 4
        glow.breathSeconds = 6
        glow.breathAmplitude = 0.3
        glow.outwardOnly = false
        XCTAssertEqual(style.applied(to: GlowSettings()), glow, "speed is the working period and amplitude the breath's depth")
        XCTAssertEqual(style.applied(to: GlowSettings()).idleBreathSeconds, GlowSettings().idleBreathSeconds,
                       "what no field names is left as it was")

        let one = HUDStyle(logoSize: 24)
        XCTAssertEqual(one.applied(to: .default(hasNotch: false)), ScreenPlacement(logoSize: 24))
        XCTAssertEqual(one.applied(to: GlowSettings()), GlowSettings())
        XCTAssertTrue(HUDStyle().isEmpty)
        XCTAssertFalse(one.isEmpty)
    }

    /// A style is written back in an agent's words, the glow's under glow, and reads back as itself.
    func testAStyleIsWrittenInAnAgentsWordsAndReadsBack() {
        let style = HUDStyle(json: every)
        XCTAssertEqual(HUDStyle(json: style.json), style)
        XCTAssertEqual(style.json["mode"], .string("dynamic"), "a Dynamic dock is dynamic to an agent")
        XCTAssertEqual(HUDStyle(mode: .simple).json, ["mode": .string("simple")], "only what is set is written")
        XCTAssertEqual(HUDStyle().json, [:])
        XCTAssertEqual(HUDMode.allCases.map(\.agentName), ["notch", "dynamic", "simple"])
        XCTAssertEqual(HUDMode(agentName: "dynamic"), .logos)
        XCTAssertNil(HUDMode(agentName: "logos"), "the settings' own name is not an agent's")
        XCTAssertEqual(HUDStyle.names, ["mode", "edge", "position", "logoSize", "logoGap", "edgeDistance", "showLogos", "simpleSize",
                                        "ringWidth", "showRings", "showNumbers", "bots", "separateAgents", "glow"])
    }

    /// Reduced against what a screen has saved, a style keeps only what it changes: the style a screen has in effect,
    /// sent back whole, changes nothing.
    func testAStyleIsReducedToWhatItChanges() {
        let saved = ScreenPlacement(mode: .logos, logoSize: 24), glow = GlowSettings()
        let whole = HUDStyle(every: saved, glow: glow)
        XCTAssertTrue(whole.reduced(placement: saved, glow: glow).isEmpty)
        var asked = whole
        asked.logoSize = 30
        asked.glow.range = 20
        XCTAssertEqual(asked.reduced(placement: saved, glow: glow), HUDStyle(logoSize: 30, glow: HUDStyle.Glow(range: 20)))
    }

    /// A dock that leaves the notch for the top edge, never moved from the centre and with no position given, starts at
    /// the top left, as Settings' own change of mode places it, clear of the hardware.
    func testADockLeavingTheNotchStartsClearOfIt() {
        let notch = ScreenPlacement.default(hasNotch: true)
        XCTAssertEqual(HUDStyle(mode: .simple).placedClearOfTheNotch(from: notch, hasNotch: true), HUDStyle(mode: .simple, position: 0))
        XCTAssertEqual(HUDStyle(mode: .simple, position: 0.7).placedClearOfTheNotch(from: notch, hasNotch: true),
                       HUDStyle(mode: .simple, position: 0.7), "a position given is kept")
        XCTAssertEqual(HUDStyle(mode: .logos, edge: .left).placedClearOfTheNotch(from: notch, hasNotch: true),
                       HUDStyle(mode: .logos, edge: .left), "another edge is clear of it")
        XCTAssertEqual(HUDStyle(mode: .logos).placedClearOfTheNotch(from: ScreenPlacement(mode: .notch), hasNotch: false),
                       HUDStyle(mode: .logos), "a screen without a notch has nothing to clear")
    }

    // MARK: What is refused

    /// Every number is held to the range Settings keeps it in, written in the sentence; a bound itself is taken.
    func testEveryNumberIsHeldToItsSettingsRange() {
        let ranges: [(String, ClosedRange<Double>)] = [
            ("position", 0...1), ("logoSize", ScreenPlacement.logoSizeRange), ("logoGap", ScreenPlacement.gapScaleRange),
            ("edgeDistance", ScreenPlacement.logoEdgeDistanceRange), ("simpleSize", ScreenPlacement.simpleSizeRange),
            ("ringWidth", ScreenPlacement.ringWidthRange),
        ]
        for (name, range) in ranges {
            XCTAssertEqual(HUDStyle.misreadings(ofField: name, .number(range.lowerBound)), [], name)
            XCTAssertEqual(HUDStyle.misreadings(ofField: name, .number(range.upperBound)), [], name)
            let sentence = "hud.\(name) is a number from \(HUDStyle.written(range.lowerBound)) to \(HUDStyle.written(range.upperBound))."
            XCTAssertEqual(HUDStyle.misreadings(ofField: name, .number(range.upperBound + 0.5)), [sentence])
            XCTAssertEqual(HUDStyle.misreadings(ofField: name, .number(range.lowerBound - 0.05)), [sentence])
            XCTAssertEqual(HUDStyle.misreadings(ofField: name, .string("12")), [sentence], "a number written as text")
            XCTAssertEqual(HUDStyle(json: [name: .number(range.upperBound + 1)]), HUDStyle(), "nothing out of range is read")
        }
        XCTAssertEqual(HUDStyle.misreadings(ofField: "logoSize", .number(37)), ["hud.logoSize is a number from 12 to 36."])
        XCTAssertEqual(HUDStyle.misreadings(ofField: "logoGap", .number(0.05)), ["hud.logoGap is a number from 0.1 to 0.6."])

        let glow: [(String, ClosedRange<Double>)] = [
            ("brightness", GlowSettings.brightnessRange), ("range", GlowSettings.sizeRange), ("blur", GlowSettings.sizeRange),
            ("speed", GlowSettings.workingPeriodRange), ("amplitude", GlowSettings.amplitudeRange),
        ]
        for (name, range) in glow {
            XCTAssertEqual(HUDStyle.misreadings(ofField: "glow", .object([name: .number(range.upperBound)])), [], name)
            XCTAssertEqual(HUDStyle.misreadings(ofField: "glow", .object([name: .number(range.upperBound + 1)])),
                           ["hud.glow.\(name) is a number from \(HUDStyle.written(range.lowerBound)) to "
                            + "\(HUDStyle.written(range.upperBound))."])
        }
        XCTAssertEqual(HUDStyle.misreadings(ofField: "glow", .object(["speed": .integer(20)])),
                       ["hud.glow.speed is a number from 1 to 12."], "the working period Settings offers")
        XCTAssertEqual(HUDStyle.misreadings(ofField: "glow", .object(["brightness": .number(0.1)])),
                       ["hud.glow.brightness is a number from 0.2 to 1."])
    }

    /// A name this build does not know, a value of the wrong type and a property the glow does not have are each told.
    func testNamesTypesAndPropertiesAreTold() {
        XCTAssertEqual(HUDStyle.misreadings(ofField: "mode", .string("logos")),
                       ["hud.mode is one of \"notch\", \"dynamic\", \"simple\"."])
        XCTAssertEqual(HUDStyle.misreadings(ofField: "edge", .string("centre")),
                       ["hud.edge is one of \"top\", \"right\", \"bottom\", \"left\"."])
        for name in ["showLogos", "showRings", "showNumbers", "bots", "separateAgents"] {
            XCTAssertEqual(HUDStyle.misreadings(ofField: name, .string("yes")), ["hud.\(name) is true or false."])
            XCTAssertEqual(HUDStyle.misreadings(ofField: name, .bool(true)), [])
        }
        XCTAssertEqual(HUDStyle.misreadings(ofField: "glow", .string("dots")), ["hud.glow is an object."])
        XCTAssertEqual(HUDStyle.misreadings(ofField: "glow", .object(["style": .string("neon"), "effect": .string("spin"),
                                                                      "outwardOnly": .integer(1), "colour": .string("red")])), [
            "hud.glow has no property \"colour\"; the glow takes style, effect, brightness, range, blur, speed, amplitude "
                + "and outwardOnly.",
            "hud.glow.effect is one of \"breathe\", \"flow\", \"scan\", \"ripple\", \"shimmer\", \"boot\".",
            "hud.glow.outwardOnly is true or false.",
            "hud.glow.style is one of \"blur\", \"dots\", \"ascii\", \"blocks\", \"braille\", \"binary\".",
        ])
        XCTAssertEqual(HUDStyle.misreadings(ofField: "mode", .null), [], "a value given as null is not given")
        XCTAssertNil(HUDStyle.misreadings(ofField: "background", .string("blue")), "a key that names no field is the caller's")
        XCTAssertEqual(PanelLayout.misreadings(of: .object(["hud": .object(["background": .string("blue")])])),
                       ["hud has no property \"background\"; the hud takes agents, mode, edge, position, logoSize, logoGap, "
                        + "edgeDistance, showLogos, simpleSize, ringWidth, showRings, showNumbers, bots, separateAgents, glow "
                        + "and reset."])
        XCTAssertEqual(HUDStyle.misreadings(ofField: "reset", .string("yes")), ["hud.reset is true or false."])
        XCTAssertEqual(HUDStyle.misreadings(ofField: "reset", .bool(false)), [])
        XCTAssertEqual(HUDStyle.misreadings(ofField: "reset", .null), [])
        XCTAssertEqual(HUDStyle(json: ["reset": .bool(true)]), HUDStyle(), "reset is no field of a style")
    }

    /// What the screen's HUD would not draw as asked is refused: the notch on a screen without one, and a field the mode
    /// it would have does not draw, as Settings shows each only for its modes.
    func testWhatTheHUDWouldNotDrawIsAnIssue() {
        let notch = ScreenPlacement.default(hasNotch: true), dock = ScreenPlacement.default(hasNotch: false), glow = GlowSettings()
        func issues(_ style: HUDStyle, _ placement: ScreenPlacement, hasNotch: Bool = true) -> [String] {
            style.issues(placement: placement, glow: glow, hasNotch: hasNotch, screen: "\"Display 2\"").map { "\($0.path): \($0.message)" }
        }
        XCTAssertEqual(issues(HUDStyle(mode: .notch), dock, hasNotch: false),
                       ["hud.mode: \"Display 2\" has no notch, so its HUD cannot be \"notch\". It can be \"dynamic\" or \"simple\"."])
        XCTAssertEqual(issues(HUDStyle(mode: .notch), dock), [])
        XCTAssertEqual(issues(HUDStyle(logoSize: 30), notch),
                       ["hud.logoSize: logoSize sets a \"dynamic\" HUD, and the HUD of \"Display 2\" would be \"notch\". "
                        + "Leave it out, or set mode to \"dynamic\"."])
        XCTAssertEqual(issues(HUDStyle(mode: .logos, logoSize: 30), notch), [], "with the mode that draws it")
        XCTAssertEqual(issues(HUDStyle(edge: .left), notch).count, 1, "beside the notch there is no edge to choose")
        XCTAssertEqual(issues(HUDStyle(mode: .simple, logoSize: 30), dock).first?.hasPrefix("hud.logoSize: "), true)
        XCTAssertEqual(issues(HUDStyle(simpleSize: 30, separateAgents: true), dock).count, 1, "a dock separates; it has no rings")
        XCTAssertEqual(issues(HUDStyle(mode: .simple, glow: HUDStyle.Glow(style: .dots)), dock),
                       ["hud.glow.style: A \"simple\" HUD draws no glow, and the HUD of \"Display 2\" would be \"simple\"."])
        XCTAssertEqual(issues(HUDStyle(glow: HUDStyle.Glow(style: .dots, range: 20)), notch),
                       ["hud.glow.range: range sets the \"blur\" glow style, and the glow of \"Display 2\" would be \"dots\"."])
        XCTAssertEqual(issues(HUDStyle(glow: HUDStyle.Glow(effect: .scan, amplitude: 0.2)), notch),
                       ["hud.glow.amplitude: amplitude sets the \"breathe\" effect, and the glow of \"Display 2\" would play \"scan\"."])
        XCTAssertEqual(issues(HUDStyle(glow: HUDStyle.Glow(style: .dots, effect: .ripple, brightness: 0.4, speed: 5)), notch), [])
    }

    // MARK: The panel's width

    /// A layout's width is a whole number from 480 to 720; left out, or at 540, it is today's panel, which is not
    /// written. An agent's own panel on a separated dock is 100 points narrower and never below 440.
    func testThePanelsWidthIsReadNormalizedAndNarrowedForOneAgent() throws {
        XCTAssertEqual(PanelStyle().panelWidth, 540)
        XCTAssertEqual(PanelStyle().agentPanelWidth, 440, "as before layouts had a width")
        for (width, agent) in [(480, 440), (540, 440), (541, 441), (600, 500), (720, 620)] {
            let style = PanelStyle(width: width)
            XCTAssertEqual(style.panelWidth, width)
            XCTAssertEqual(style.agentPanelWidth, agent, "\(width)")
        }
        XCTAssertEqual(PanelStyle(width: 479).panelWidth, 540, "a width out of range is none")
        XCTAssertEqual(PanelStyle(width: 721).panelWidth, 540)
        XCTAssertEqual(PanelStyle(width: 540).normalized(), PanelStyle())
        XCTAssertEqual(PanelLayout(style: PanelStyle(width: 540)).normalized(), PanelLayout())
        XCTAssertTrue(PanelLayout(style: PanelStyle(width: 540)).isDefault)

        func read(_ json: String) throws -> PanelLayout { try JSONDecoder().decode(PanelLayout.self, from: Data(json.utf8)) }
        XCTAssertEqual(try read(#"{"style":{"width":720}}"#).style.width, 720)
        XCTAssertNil(try read(#"{"style":{"width":900}}"#).style.width, "a stored width out of range is forgiven as none")
        XCTAssertNil(try read(#"{"style":{"width":"wide"}}"#).style.width)
        let written = String(decoding: try RecordCoding.encoder().encode(PanelLayout(style: PanelStyle(width: 600))), as: UTF8.self)
        XCTAssertEqual(written, #"{"style":{"width":600}}"#)
        XCTAssertEqual(String(decoding: try RecordCoding.encoder().encode(PanelLayout(style: PanelStyle(width: 540))), as: UTF8.self),
                       "{}", "the default width is not written")

        let sentence = "style.width is a whole number from 480 to 720."
        for wrong in [JSONValue.integer(479), .integer(721), .number(600.5), .string("600"), .bool(true)] {
            XCTAssertEqual(PanelLayout.misreadings(of: .object(["style": .object(["width": wrong])])), [sentence], "\(wrong)")
        }
        XCTAssertEqual(PanelLayout.misreadings(of: .object(["style": .object(["width": .integer(480)])])), [])
        XCTAssertEqual(PanelLayout.misreadings(of: .object(["style": .object(["width": .number(720)])])), [])
    }
}
