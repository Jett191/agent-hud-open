import AgentHUDSupport
import XCTest
@testable import AgentHUDCore

/// A block's span: how the document writes and reads it, what a proposal may ask, and how the plan sets blocks in lines,
/// two half blocks side by side where both ask for half and the panel has room, every other block across the line.
final class PanelLayoutSpanTests: XCTestCase {
    /// Two quota blocks, a third with one row, and a balance, in default order.
    private let blocks = [
        PanelBlockInfo(key: "Claude", kind: .quota, rowKeys: ["claude-session", "claude-weekly"]),
        PanelBlockInfo(key: "Codex", kind: .quota, rowKeys: ["codex"]),
        PanelBlockInfo(key: "Cursor", kind: .quota, rowKeys: ["cursor"]),
        PanelBlockInfo(key: "api:DeepSeek", kind: .billing),
    ]

    private func half(_ widget: PanelWidget? = .ring, columns: Int? = nil) -> PanelLayout.Block {
        PanelLayout.Block(widget: widget, columns: columns, span: .half)
    }

    /// The plan at `width`, the whole panel's, beside the notch.
    private func plan(_ layout: PanelLayout, width: Int? = nil, pairs: Bool = true) -> PanelLayoutPlan {
        PanelLayoutPlan(layout: layout, blocks: blocks, contentWidth: width.map { Double($0) - PanelLines.sideInsets }, pairs: pairs)
    }

    private func lines(_ layout: PanelLayout, width: Int? = nil, pairs: Bool = true) -> [[String]] {
        plan(layout, width: width, pairs: pairs).lines.map { $0.map(\.key) }
    }

    // MARK: The document

    func testASpanIsWrittenAsGivenAndReadForgivingly() throws {
        let layout = PanelLayout(blocks: ["Claude": PanelLayout.Block(widget: .ring, span: .half),
                                          "Codex": PanelLayout.Block(span: .full)])
        let written = String(decoding: try RecordCoding.encoder().encode(layout), as: UTF8.self)
        XCTAssertEqual(written, #"{"blocks":{"Claude":{"span":"half","widget":"ring"},"Codex":{"span":"full"}}}"#)
        XCTAssertEqual(try JSONDecoder().decode(PanelLayout.self, from: Data(written.utf8)), layout)
        func span(_ value: String) throws -> PanelSpan? {
            try JSONDecoder().decode(PanelLayout.self, from: Data(#"{"blocks": {"Claude": {"span": \#(value)}}}"#.utf8))
                .blocks["Claude"]?.span
        }
        XCTAssertEqual(try span(#""half""#), .half)
        XCTAssertEqual(try span(#""full""#), .full)
        for value in [#""wide""#, #""Half""#, "1", "true", "null", #"["half"]"#] {
            XCTAssertNil(try span(value), "a span this build does not know is not given: \(value)")
        }
    }

    /// A span written out is a recorded choice, as a widget is, until a proposal is reduced against the panel.
    func testASpanIsAChangeAndTheWholeLineIsKeptWhenNormalized() {
        XCTAssertFalse(PanelLayout(blocks: ["Claude": PanelLayout.Block(span: .half)]).isDefault)
        XCTAssertEqual(PanelLayout(blocks: ["Claude": PanelLayout.Block(span: .full)]).normalized().blocks["Claude"]?.span, .full)
        XCTAssertTrue(PanelLayout(blocks: ["Claude": PanelLayout.Block(span: nil)]).isDefault)
    }

    // MARK: What a proposal may ask

    func testHalfALineForBarRowsIsAnIssueAndForEveryOtherWidgetIsNot() {
        let bars = PanelLayout(blocks: ["Claude": PanelLayout.Block(span: .half), "Codex": PanelLayout.Block(widget: .bar, span: .half)])
        let issues = bars.issues(against: blocks)
        XCTAssertEqual(issues.map(\.path), ["blocks.Claude.span", "blocks.Codex.span"])
        XCTAssertEqual(issues.first?.message, "Bar rows need the full width of the panel, so the \"bar\" widget of \"Claude\" "
                       + "cannot take half a line. span \"half\" applies to the \"ring\", \"number\" and \"chart\" widgets and "
                       + "to API balances.")
        for widget in [PanelWidget.ring, .number, .chart] {
            XCTAssertEqual(PanelLayout(blocks: ["Claude": half(widget)]).issues(against: blocks), [], "\(widget)")
        }
        XCTAssertEqual(PanelLayout(blocks: ["api:DeepSeek": PanelLayout.Block(span: .half)]).issues(against: blocks), [],
                       "a balance's card takes half a line")
        XCTAssertEqual(PanelLayout(blocks: ["Claude": PanelLayout.Block(span: .full)]).issues(against: blocks), [],
                       "the whole line suits every block")
    }

    func testAProposalIsReducedToTheSpanItChanges() {
        let asked = PanelLayout(blocks: ["Claude": PanelLayout.Block(widget: .ring, span: .full),
                                         "Codex": PanelLayout.Block(span: .half), "api:DeepSeek": PanelLayout.Block(span: .full),
                                         "Cursor": half()])
        XCTAssertEqual(asked.reduced(against: blocks), PanelLayout(blocks: ["Claude": PanelLayout.Block(widget: .ring),
                                                                            "Cursor": half()]),
                       "the whole line is the default, and bar rows have no half to keep")
        XCTAssertTrue(PanelLayout(blocks: ["api:DeepSeek": PanelLayout.Block(span: .full)]).reduced(against: blocks).isDefault)
    }

    // MARK: Lines

    func testTheDefaultLayoutSetsEveryBlockAcrossTheLine() {
        for width in [nil, 480, 540, 720] {
            let planned = plan(PanelLayout(), width: width)
            XCTAssertEqual(planned.blocks.map(\.span), [.full, .full, .full, .full])
            XCTAssertEqual(planned.lines.map(\.count), [1, 1, 1, 1])
            XCTAssertEqual(planned.blocks, PanelLayoutPlan(layout: PanelLayout(), blocks: blocks).blocks, "as before blocks had spans")
        }
    }

    func testTwoHalfBlocksNextToEachOtherShareALine() {
        let layout = PanelLayout(blocks: ["Claude": half(.ring), "Codex": half(.number)])
        XCTAssertEqual(lines(layout), [["Claude", "Codex"], ["Cursor"], ["api:DeepSeek"]])
        XCTAssertEqual(plan(layout).blocks.map(\.span), [.half, .half, .full, .full])
        // A balance and a chart share one too, in the order the layout gives.
        let mixed = PanelLayout(blocks: ["Claude": half(.chart), "api:DeepSeek": PanelLayout.Block(span: .half)],
                                order: ["Claude", "api:DeepSeek"])
        XCTAssertEqual(lines(mixed), [["Claude", "api:DeepSeek"], ["Codex"], ["Cursor"]])
    }

    /// A half block with no half block beside it takes the whole line, so no line has an empty half: alone, the third
    /// of three, next to a bar block, or next to a block the layout hides.
    func testAHalfBlockWithoutAHalfBesideItTakesTheWholeLine() {
        XCTAssertEqual(lines(PanelLayout(blocks: ["Claude": half()])), [["Claude"], ["Codex"], ["Cursor"], ["api:DeepSeek"]])
        XCTAssertEqual(plan(PanelLayout(blocks: ["Claude": half()])).blocks.first?.span, .full)
        let three = PanelLayout(blocks: ["Claude": half(), "Codex": half(), "Cursor": half()])
        XCTAssertEqual(lines(three), [["Claude", "Codex"], ["Cursor"], ["api:DeepSeek"]])
        let four = PanelLayout(blocks: ["Claude": half(), "Codex": half(), "Cursor": half(), "api:DeepSeek": PanelLayout.Block(span: .half)])
        XCTAssertEqual(lines(four), [["Claude", "Codex"], ["Cursor", "api:DeepSeek"]])
        let apart = PanelLayout(blocks: ["Claude": half(), "Cursor": half()])
        XCTAssertEqual(lines(apart), [["Claude"], ["Codex"], ["Cursor"], ["api:DeepSeek"]], "next to each other in the plan's order")
        XCTAssertEqual(lines(PanelLayout(blocks: ["Claude": half(), "Cursor": half()], order: ["Claude", "Cursor"])),
                       [["Claude", "Cursor"], ["Codex"], ["api:DeepSeek"]])
        let hidden = PanelLayout(blocks: ["Claude": half(), "Codex": PanelLayout.Block(hidden: true), "Cursor": half()])
        XCTAssertEqual(lines(hidden), [["Claude", "Cursor"], ["api:DeepSeek"]], "a hidden block is no neighbour")
    }

    /// A stored half on bar rows, which a proposal is refused, falls back to the whole line, and so does its neighbour.
    func testAStoredHalfOnBarRowsFallsBackToTheWholeLine() throws {
        let stored = try JSONDecoder().decode(PanelLayout.self, from: Data(
            #"{"blocks": {"Claude": {"span": "half"}, "Codex": {"widget": "ring", "span": "half"}}}"#.utf8))
        XCTAssertEqual(stored.blocks["Claude"]?.span, .half, "kept in the document")
        XCTAssertEqual(plan(stored).blocks.map(\.span), [.full, .full, .full, .full])
        XCTAssertEqual(PanelBlockPlan(blocks[0], changed: try XCTUnwrap(stored.blocks["Claude"])).span, .full)
        XCTAssertEqual(PanelBlockPlan(blocks[1], changed: try XCTUnwrap(stored.blocks["Codex"])).span, .half,
                       "a block on its own is told the span it asks for where it can take it")
    }

    /// Two halves share a line where each is at least `PanelLines.narrowestHalf` wide: at 540 and 720 at every spacing,
    /// not at 480, and never on one agent's own panel.
    func testTwoHalvesShareALineOnlyWhereEachHasRoom() {
        XCTAssertEqual(PanelLines.narrowestHalf, 230, accuracy: 0.001, "the widest heading, wider than two cells of 102 pt")
        XCTAssertEqual(PanelLines.narrowestHalf, PanelLines.widestHeading)
        for spacing in PanelSpacing.allCases {
            func layout(_ width: Int) -> PanelLayout {
                PanelLayout(blocks: ["Claude": half(), "Codex": half(.number)], style: PanelStyle(spacing: spacing, width: width))
            }
            for width in [540, 600, 720] {
                XCTAssertTrue(plan(layout(width)).halvesFit, "\(spacing) at \(width)")
                XCTAssertEqual(lines(layout(width)).first, ["Claude", "Codex"], "\(spacing) at \(width)")
                XCTAssertEqual(lines(layout(width), width: width).first, ["Claude", "Codex"], "nil is beside the notch")
            }
            XCTAssertFalse(plan(layout(480)).halvesFit, "\(spacing)")
            XCTAssertEqual(lines(layout(480)), [["Claude"], ["Codex"], ["Cursor"], ["api:DeepSeek"]], "\(spacing) at 480")
            XCTAssertEqual(plan(layout(480)).blocks.map(\.span), [.full, .full, .full, .full])
            XCTAssertEqual(lines(layout(720), pairs: false), [["Claude"], ["Codex"], ["Cursor"], ["api:DeepSeek"]],
                           "one agent's own panel never pairs")
            // The panel's content decides, not the layout's width: a side dock's strip leaves 540 too narrow.
            let side = PanelLayoutPlan(layout: layout(540), blocks: blocks, contentWidth: 540 - 36 - 52)
            XCTAssertFalse(side.halvesFit, "\(spacing)")
        }
        // The narrowest panel beside the notch that pairs, at each spacing.
        for (spacing, width) in [(PanelSpacing.compact, 502), (.regular, 506), (.roomy, 510)] {
            let style = PanelStyle(spacing: spacing, width: width)
            XCTAssertTrue(plan(PanelLayout(blocks: ["Claude": half(), "Codex": half()], style: style)).halvesFit, "\(spacing)")
            XCTAssertFalse(PanelLayoutPlan(layout: PanelLayout(style: style), blocks: blocks,
                                           contentWidth: Double(width - 1) - PanelLines.sideInsets).halvesFit, "\(spacing)")
        }
    }

    /// In half a line, cells stand two to a line unless the layout gives columns, which are kept up to what leaves each
    /// cell as wide as the narrowest the panel draws. Across the whole line, a lone half has the columns it always had.
    func testAHalfBlocksCellsStandTwoToALineAndNeverMoreThanFit() {
        XCTAssertEqual(PanelLines.narrowestCell, (404 - 12 - 40) / 6, accuracy: 0.001)
        func columns(_ asked: Int?, width: Int, spacing: PanelSpacing = .regular) -> [Int] {
            let layout = PanelLayout(blocks: ["Claude": half(.ring, columns: asked), "Codex": half(.number, columns: asked),
                                              "Cursor": half(.chart)], style: PanelStyle(spacing: spacing, width: width))
            return plan(layout).blocks.map(\.columns)
        }
        XCTAssertEqual(columns(nil, width: 540), [2, 2, 4, 4], "two in half a line; a chart and a balance have none to set")
        XCTAssertEqual(columns(3, width: 540), [3, 3, 4, 4])
        XCTAssertEqual(columns(6, width: 540), [3, 3, 4, 4], "half of 540 holds three cells")
        XCTAssertEqual(columns(6, width: 720, spacing: .roomy), [4, 4, 4, 4])
        XCTAssertEqual(columns(6, width: 720, spacing: .compact), [5, 5, 4, 4])
        XCTAssertEqual(columns(nil, width: 480), [4, 4, 4, 4], "across the whole line, four as before")
        XCTAssertEqual(columns(6, width: 480), [6, 6, 4, 4])
        for width in stride(from: 490, through: 720, by: 10) {
            for spacing in PanelSpacing.allCases {
                let half = PanelLines.halfWidth(in: Double(width) - PanelLines.sideInsets, spacing: spacing)
                guard half >= PanelLines.narrowestHalf else { continue }
                let fitting = PanelLines.columns(fitting: half)
                XCTAssertGreaterThanOrEqual(fitting, 3, "\(width) \(spacing)")
                XCTAssertGreaterThanOrEqual(PanelLines.cellWidth(in: half, columns: fitting), PanelLines.narrowestCell)
                XCTAssertGreaterThanOrEqual(PanelLines.cellWidth(in: half, columns: PanelLines.halfColumns), 102 - 0.001,
                                            "two cells of a half are as wide as the whole 480 pt panel's default four")
            }
        }
    }

    func testTheGapBetweenTwoHalvesIsTheSpacingsGapBetweenBlocks() {
        XCTAssertEqual(PanelSpacing.allCases.map(\.blockGap), [6, 10, 14])
        XCTAssertEqual(PanelLines.halfWidth(in: 504, spacing: .regular), 247)
    }
}
