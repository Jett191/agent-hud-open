import AgentHUDSupport
import XCTest
@testable import AgentHUDCore

/// The layout document: its JSON, what reading it forgives, and when two layouts are the same layout.
final class PanelLayoutTests: XCTestCase {
    private func decode(_ json: String) throws -> PanelLayout {
        try JSONDecoder().decode(PanelLayout.self, from: Data(json.utf8))
    }

    private func encode(_ layout: PanelLayout) throws -> String {
        String(decoding: try RecordCoding.encoder().encode(layout), as: UTF8.self)
    }

    /// Every field set, in the shape an agent sends.
    private let full = PanelLayout(
        blocks: ["Claude": PanelLayout.Block(widget: .ring, measures: [.burnRate, .quota], hidden: true, hiddenRows: ["claude-weekly"],
                                             countdown: false, columns: 3, ringSize: .large),
                 "api:DeepSeek": PanelLayout.Block(widget: .number)],
        order: ["Codex", "Claude"], sections: [.blocks, .tokens, .sessions], hiddenSections: [.sessions],
        style: PanelStyle(spacing: .compact, separators: false))

    // MARK: Coding

    func testTheDocumentedShapeReadsIntoEveryField() throws {
        let json = """
            {"blocks": {"Claude": {"widget": "ring", "measures": ["burn", "quota"], "hidden": true, "hiddenRows": ["claude-weekly"],
                                   "countdown": false, "columns": 3, "ringSize": "large"},
                        "api:DeepSeek": {"widget": "number"}},
             "order": ["Codex", "Claude"], "sections": ["blocks", "tokens", "sessions"], "hiddenSections": ["sessions"],
             "style": {"spacing": "compact", "separators": false}}
            """
        XCTAssertEqual(try decode(json), full)
    }

    func testALayoutRoundTripsAndEqualLayoutsAreTheSameBytes() throws {
        let written = try encode(full)
        let expected = [
            #"{"blocks":{"Claude":{"columns":3,"countdown":false,"hidden":true,"hiddenRows":["claude-weekly"],"#,
            #""measures":["burn","quota"],"ringSize":"large","widget":"ring"},"#,
            #""api:DeepSeek":{"widget":"number"}},"hiddenSections":["sessions"],"order":["Codex","Claude"],"#,
            #""sections":["blocks","tokens","sessions"],"style":{"separators":false,"spacing":"compact"}}"#,
        ].joined()
        XCTAssertEqual(written, expected, "keys are sorted and nothing unset is written")
        XCTAssertEqual(try decode(written), full)
        XCTAssertEqual(try encode(try decode(written)), written)

        // Equal layouts whose blocks were put in by different routes.
        let keys = (0..<40).map { "vendor-\($0)" }
        var forwards = PanelLayout(), backwards = PanelLayout()
        for key in keys { forwards.blocks[key] = PanelLayout.Block(measures: [.tokens]) }
        for key in keys.reversed() { backwards.blocks[key] = PanelLayout.Block(measures: [.tokens]) }
        XCTAssertEqual(forwards, backwards)
        XCTAssertEqual(try RecordCoding.encoder().encode(forwards), try RecordCoding.encoder().encode(backwards))
    }

    /// A tool call's arguments arrive as a JSON value, and a layout goes back as one.
    func testALayoutReadsFromAJSONValueAsFromItsTextAndWritesToOne() throws {
        let arguments = try JSONValue.parse(Data(#"{"blocks": {"Claude": {"widget": "ring", "measures": ["pace"]}}, "order": ["Codex", 1]}"#.utf8))
        let layout = PanelLayout(blocks: ["Claude": PanelLayout.Block(widget: .ring)], order: ["Codex"])
        XCTAssertEqual(try arguments.decode(PanelLayout.self), layout)
        XCTAssertEqual(try JSONValue.from(layout),
                       .object(["blocks": .object(["Claude": .object(["widget": .string("ring")])]), "order": .array([.string("Codex")])]))
        XCTAssertEqual(try JSONValue.from(PanelLayout()), .object([:]))
        XCTAssertThrowsError(try JSONValue.array([]).decode(PanelLayout.self))
    }

    func testAnEmptyObjectIsTheDefaultLayoutAndTheDefaultLayoutIsAnEmptyObject() throws {
        XCTAssertEqual(try decode("{}"), PanelLayout())
        XCTAssertEqual(try encode(PanelLayout()), "{}")
        XCTAssertTrue(try decode("{}").isDefault)
    }

    func testWritingLeavesOutWhatIsUnsetOrEmpty() throws {
        XCTAssertEqual(try encode(PanelLayout(blocks: [:], order: [], sections: [], hiddenSections: [])), "{}")
        let blocks = ["a": PanelLayout.Block(widget: .chart), "b": PanelLayout.Block(hidden: false, hiddenRows: []),
                      "c": PanelLayout.Block(hidden: true), "d": PanelLayout.Block(hiddenRows: ["x"])]
        XCTAssertEqual(try encode(PanelLayout(blocks: blocks)),
                       #"{"blocks":{"a":{"widget":"chart"},"b":{},"c":{"hidden":true},"d":{"hiddenRows":["x"]}}}"#)
        XCTAssertEqual(try encode(PanelLayout(hiddenSections: [.tokens])), #"{"hiddenSections":["tokens"]}"#)
        XCTAssertEqual(try encode(PanelLayout(blocks: ["a": PanelLayout.Block(measures: [], countdown: true)])), #"{"blocks":{"a":{}}}"#,
                       "every measure, and the countdown as Settings has it, are what an absent field says")
        XCTAssertEqual(try encode(PanelLayout(style: PanelStyle(spacing: .regular, separators: true))), "{}",
                       "the default view's style is not written")
        XCTAssertEqual(try encode(PanelLayout(style: PanelStyle(spacing: .roomy))), #"{"style":{"spacing":"roomy"}}"#)
        XCTAssertEqual(try encode(PanelLayout(style: PanelStyle(separators: false))), #"{"style":{"separators":false}}"#)
    }

    // MARK: Forgiving what it reads

    func testAnUnknownNameLeavesOnlyThatFieldUnsetOrThatEntryOut() throws {
        let layout = try decode("""
            {"blocks": {"Claude": {"widget": "gauge", "measures": ["burn"], "hidden": true, "ringSize": "huge"},
                        "Codex": {"widget": "ring", "measures": ["velocity", "cost", "pace"], "hiddenRows": ["codex"]}},
             "style": {"spacing": "airy", "separators": false}}
            """)
        XCTAssertEqual(layout.blocks["Claude"], PanelLayout.Block(measures: [.burnRate], hidden: true))
        XCTAssertEqual(layout.blocks["Codex"], PanelLayout.Block(widget: .ring, measures: [.cost], hiddenRows: ["codex"]))
        XCTAssertEqual(layout.style, PanelStyle(separators: false), "a spacing this build does not know is regular")
        // A measure is written "burn", not by its case name, and the one measure a block once had is not read.
        XCTAssertEqual(try decode(#"{"blocks": {"Claude": {"measures": ["burnRate"]}}}"#).blocks["Claude"], PanelLayout.Block())
        XCTAssertEqual(try decode(#"{"blocks": {"Claude": {"measure": "burn"}}}"#).blocks["Claude"], PanelLayout.Block())
    }

    func testColumnsOutsideTwoToSixAreReadAsAbsent() throws {
        func columns(_ value: String) throws -> Int? { try decode(#"{"blocks": {"Claude": {"columns": \#(value)}}}"#).blocks["Claude"]?.columns }
        XCTAssertEqual(try columns("2"), 2)
        XCTAssertEqual(try columns("6"), 6)
        XCTAssertEqual(try columns("4.0"), 4, "a whole number written with a point is that number")
        for value in ["1", "7", "0", "-3", "4.5", "1e9", #""3""#, "true", "null", "[4]"] {
            XCTAssertNil(try columns(value), value)
        }
        XCTAssertEqual(PanelLayout(blocks: ["Claude": PanelLayout.Block(columns: 9)]).normalized(), PanelLayout(),
                       "made in code, columns out of range are dropped when normalized")
    }

    func testAnUnknownSectionIsLeftOut() throws {
        let layout = try decode(#"{"sections": ["sessions", "weather", "blocks"], "hiddenSections": ["weather", "tokens"]}"#)
        XCTAssertEqual(layout.sections, [.sessions, .blocks])
        XCTAssertEqual(layout.hiddenSections, [.tokens])
    }

    func testABlockThatIsNotAnObjectIsLeftOutAndTheOthersStay() throws {
        let layout = try decode(#"{"blocks": {"a": "ring", "b": 3, "c": ["ring"], "d": null, "e": true, "f": {"widget": "ring"}}}"#)
        XCTAssertEqual(layout.blocks, ["f": PanelLayout.Block(widget: .ring)])
        XCTAssertEqual(try decode(#"{"blocks": ["Claude"], "order": ["Claude"]}"#), PanelLayout(order: ["Claude"]),
                       "blocks that are not an object are none, and the rest of the layout stays")
    }

    func testUnknownKeysAreIgnored() throws {
        let layout = try decode("""
            {"version": 2, "theme": {"accent": "red"}, "order": ["Claude"], "style": {"font": "large"},
             "blocks": {"Claude": {"widget": "ring", "size": "large", "rows": 3}}}
            """)
        XCTAssertEqual(layout, PanelLayout(blocks: ["Claude": PanelLayout.Block(widget: .ring)], order: ["Claude"]))
    }

    func testAValueOfTheWrongTypeCountsAsNotGiven() throws {
        XCTAssertEqual(try decode(#"{"order": "Claude", "sections": {"blocks": 1}, "hiddenSections": 4}"#), PanelLayout())
        XCTAssertEqual(try decode(#"{"order": ["Claude", 7, null, ["Codex"], "Codex"], "sections": ["tokens", 2]}"#),
                       PanelLayout(order: ["Claude", "Codex"], sections: [.tokens]), "what is not a string is left out of a list")
        let block = try decode(#"{"blocks": {"Claude": {"widget": 1, "measures": "cost", "hidden": "yes", "hiddenRows": "all", "#
                               + #""countdown": "no", "columns": "3", "ringSize": 60}}}"#)
        XCTAssertEqual(block.blocks, ["Claude": PanelLayout.Block()])
        XCTAssertEqual(try decode(#"{"blocks": {"Claude": {"measures": ["cost", 2, null, "quota"]}}}"#).blocks["Claude"],
                       PanelLayout.Block(measures: [.cost, .quota]))
        XCTAssertEqual(try decode(#"{"style": "compact"}"#), PanelLayout(), "a style that is not an object is the default")
        XCTAssertEqual(try decode(#"{"style": {"spacing": 2, "separators": "no"}}"#), PanelLayout())
        XCTAssertEqual(try decode(#"{"blocks": {"Claude": {"hidden": 1, "hiddenRows": ["a", 2, "b"]}}}"#).blocks["Claude"],
                       PanelLayout.Block(hiddenRows: ["a", "b"]))
    }

    func testOnlyJSONThatIsNotAnObjectFails() {
        for json in ["[]", #"["blocks"]"#, #""ring""#, "3", "true", "null", "", "{", #"{"order": ["Claude"]"#] {
            XCTAssertThrowsError(try decode(json), json)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(PanelLayout.Block.self, from: Data(#""ring""#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(PanelStyle.self, from: Data(#""compact""#.utf8)))
        XCTAssertEqual(try JSONDecoder().decode(PanelStyle.self, from: Data(#"{"spacing": "roomy"}"#.utf8)), PanelStyle(spacing: .roomy))
        XCTAssertEqual(try JSONDecoder().decode(PanelLayout.Block.self, from: Data(#"{"widget": "bar"}"#.utf8)),
                       PanelLayout.Block(widget: .bar))
    }

    // MARK: The same layout

    func testNormalizingDropsBlocksThatChangeNothing() {
        let layout = PanelLayout(blocks: [
            "nothing": PanelLayout.Block(), "shown": PanelLayout.Block(hidden: false), "no-rows": PanelLayout.Block(hiddenRows: []),
            "empty-rows": PanelLayout.Block(hiddenRows: ["", ""]), "widget": PanelLayout.Block(widget: .bar),
            "measures": PanelLayout.Block(measures: [.quota]), "hidden": PanelLayout.Block(hidden: true),
            "rows": PanelLayout.Block(hiddenRows: ["a"]), "countdown-on": PanelLayout.Block(countdown: true),
            "countdown-off": PanelLayout.Block(countdown: false), "columns": PanelLayout.Block(columns: 4),
            "columns-out": PanelLayout.Block(columns: 7), "ring": PanelLayout.Block(ringSize: .medium),
        ])
        XCTAssertEqual(layout.normalized().blocks.keys.sorted(),
                       ["columns", "countdown-off", "hidden", "measures", "ring", "rows", "widget"],
                       "a widget, measures, columns or a ring size that is its block's default is still a recorded choice")
    }

    func testNormalizingNamesEachMeasureOnceInTheOrderFirstNamed() {
        let layout = PanelLayout(blocks: ["Claude": PanelLayout.Block(measures: [.cost, .quota, .cost, .tokens, .quota])])
        XCTAssertEqual(layout.normalized().blocks["Claude"]?.measures, [.cost, .quota, .tokens], "the order of measures is the picker's")
        XCTAssertNotEqual(PanelLayout(blocks: ["Claude": PanelLayout.Block(measures: [.cost, .quota])]).normalized(),
                          PanelLayout(blocks: ["Claude": PanelLayout.Block(measures: [.quota, .cost])]).normalized())
    }

    func testNormalizingKeepsTheFirstOfRepeatedKeysAndDropsEmptyOnes() {
        let layout = PanelLayout(blocks: ["Claude": PanelLayout.Block(widget: .ring, hiddenRows: ["b", "", "a", "b", "a"])],
                                 order: ["Codex", "", "Claude", "Codex", "Claude", "Cursor"],
                                 sections: [.sessions, .blocks, .sessions, .blocks],
                                 hiddenSections: [.sessions, .tokens, .sessions])
        XCTAssertEqual(layout.normalized(), PanelLayout(
            blocks: ["Claude": PanelLayout.Block(widget: .ring, hiddenRows: ["a", "b"])], order: ["Codex", "Claude", "Cursor"],
            sections: [.sessions, .blocks, .tokens], hiddenSections: [.tokens, .sessions]))
        XCTAssertEqual(layout.normalized().normalized(), layout.normalized())
    }

    func testListsThatSayTheSameInAnotherOrderAreTheSameLayout() {
        let one = PanelLayout(blocks: ["Claude": PanelLayout.Block(hiddenRows: ["weekly", "session"])],
                              sections: [.tokens], hiddenSections: [.sessions, .blocks])
        let other = PanelLayout(blocks: ["Claude": PanelLayout.Block(hiddenRows: ["session", "weekly"])],
                                sections: [.tokens, .blocks, .sessions], hiddenSections: [.blocks, .sessions])
        XCTAssertEqual(one.normalized(), other.normalized())
        XCTAssertNotEqual(PanelLayout(order: ["Claude", "Codex"]).normalized(), PanelLayout(order: ["Codex", "Claude"]).normalized(),
                          "the order of blocks is what `order` says")
    }

    func testAHiddenSectionKeepsItsPlaceInTheOrder() {
        let layout = PanelLayout(sections: [.sessions, .tokens], hiddenSections: [.sessions])
        XCTAssertEqual(layout.normalized(), PanelLayout(sections: [.sessions, .tokens, .blocks], hiddenSections: [.sessions]))
    }

    func testTwoLayoutsAreTheSameLayoutWhenTheirNormalizedValuesAreEqual() {
        let written = PanelLayout(blocks: ["Claude": PanelLayout.Block(widget: .ring), "Codex": PanelLayout.Block()],
                                  order: ["Claude", "Claude"], hiddenSections: [.tokens, .tokens])
        let same = PanelLayout(blocks: ["Claude": PanelLayout.Block(widget: .ring)], order: ["Claude"], hiddenSections: [.tokens])
        XCTAssertNotEqual(written, same)
        XCTAssertEqual(written.normalized(), same.normalized())
        XCTAssertNotEqual(same.normalized(), PanelLayout(blocks: ["Claude": PanelLayout.Block(widget: .number)], order: ["Claude"],
                                                         hiddenSections: [.tokens]).normalized())
    }

    func testALayoutIsTheDefaultWhenNothingIsLeftOfItNormalized() {
        XCTAssertTrue(PanelLayout().isDefault)
        XCTAssertTrue(PanelLayout(blocks: ["Claude": PanelLayout.Block(), "Codex": PanelLayout.Block(hiddenRows: [""])], order: [""]).isDefault)
        XCTAssertTrue(PanelLayout(sections: [.blocks, .tokens, .sessions]).isDefault, "the default order, written out")
        XCTAssertTrue(PanelLayout(sections: [.blocks]).isDefault)
        XCTAssertTrue(PanelLayout(blocks: ["Claude": PanelLayout.Block(countdown: true)], style: PanelStyle(spacing: .regular)).isDefault,
                      "the countdown as Settings has it, and regular spacing with separators, are the default view")
        let changes = [
            PanelLayout(blocks: ["Claude": PanelLayout.Block(hidden: true)]), PanelLayout(order: ["Claude"]),
            PanelLayout(sections: [.tokens]), PanelLayout(hiddenSections: [.tokens]),
            PanelLayout(blocks: ["Claude": PanelLayout.Block(countdown: false)]), PanelLayout(style: PanelStyle(spacing: .compact)),
            PanelLayout(style: PanelStyle(separators: false)),
        ]
        for layout in changes { XCTAssertFalse(layout.isDefault, "\(layout)") }
    }
}
