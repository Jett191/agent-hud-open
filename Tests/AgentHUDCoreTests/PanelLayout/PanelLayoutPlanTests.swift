import XCTest
@testable import AgentHUDCore

/// What the hover panel shows under a layout, against the blocks it has.
final class PanelLayoutPlanTests: XCTestCase {
    /// Three quota blocks and a balance, in default order.
    private let blocks = [
        PanelBlockInfo(key: "Claude", kind: .quota, rowKeys: ["claude-session", "claude-weekly"]),
        PanelBlockInfo(key: "Codex", kind: .quota, rowKeys: ["codex"]),
        PanelBlockInfo(key: "Cursor", kind: .quota, rowKeys: []),
        PanelBlockInfo(key: "api:DeepSeek", kind: .billing),
    ]

    private func plan(_ layout: PanelLayout) -> PanelLayoutPlan { PanelLayoutPlan(layout: layout, blocks: blocks) }

    private func block(_ key: String, in layout: PanelLayout) -> PanelBlockPlan? {
        plan(layout).blocks.first { $0.key == key }
    }

    private let everyMeasure: [PanelMeasure] = [.quota, .burnRate, .tokens, .cost]

    func testTheDefaultLayoutIsTheDefaultView() {
        let planned = plan(PanelLayout())
        XCTAssertEqual(planned.blocks, [
            PanelBlockPlan(key: "Claude", kind: .quota, widget: .bar, measures: everyMeasure),
            PanelBlockPlan(key: "Codex", kind: .quota, widget: .bar, measures: everyMeasure),
            PanelBlockPlan(key: "Cursor", kind: .quota, widget: .bar, measures: everyMeasure),
            PanelBlockPlan(key: "api:DeepSeek", kind: .billing, widget: .number, measures: [.quota]),
        ])
        XCTAssertEqual(planned.blocks.map(\.measure), [.quota, .quota, .quota, .quota])
        XCTAssertEqual(planned.blocks.map(\.countdown), [true, true, true, true])
        XCTAssertEqual(planned.blocks.map(\.columns), [4, 4, 4, 4])
        XCTAssertEqual(planned.blocks.map(\.ringSize), [.medium, .medium, .medium, .medium])
        XCTAssertEqual(planned.sections, [.blocks, .tokens, .sessions])
        XCTAssertEqual(planned.style, PanelStyle())
        XCTAssertEqual(planned.blocks.map(\.key), blocks.map(\.key))
        XCTAssertEqual(planned, PanelLayoutPlan(layout: PanelLayout(blocks: ["Claude": PanelLayout.Block()], order: [""]), blocks: blocks),
                       "a layout that normalizes to the default plans as the default")
        XCTAssertEqual(PanelLayoutPlan(layout: PanelLayout(), blocks: []).blocks, [])
    }

    func testNamedBlocksComeFirstInTheOrderNamedAndTheOthersFollowInDefaultOrder() {
        XCTAssertEqual(plan(PanelLayout(order: ["api:DeepSeek", "Codex"])).blocks.map(\.key), ["api:DeepSeek", "Codex", "Claude", "Cursor"])
        XCTAssertEqual(plan(PanelLayout(order: ["Cursor", "Claude", "Cursor", "Codex", "Claude"])).blocks.map(\.key),
                       ["Cursor", "Claude", "Codex", "api:DeepSeek"], "a key named twice counts where it is named first")
        XCTAssertEqual(plan(PanelLayout(order: ["Codex"])).blocks.map(\.key), ["Codex", "Claude", "Cursor", "api:DeepSeek"])
    }

    func testEntriesThatNameNoBlockArePassedOverAndStayInTheDocument() {
        let layout = PanelLayout(blocks: ["Grok": PanelLayout.Block(widget: .ring, hidden: true)], order: ["Grok", "Codex", "Kimi"])
        XCTAssertEqual(plan(layout).blocks.map(\.key), ["Codex", "Claude", "Cursor", "api:DeepSeek"])
        XCTAssertEqual(layout.normalized(), layout, "nothing about a block that is away is dropped")
        // The block returns, and what the layout says about it applies again.
        let returned = blocks + [PanelBlockInfo(key: "Grok", kind: .quota, rowKeys: ["grok"]), PanelBlockInfo(key: "Kimi", kind: .quota)]
        XCTAssertEqual(PanelLayoutPlan(layout: layout, blocks: returned).blocks.map(\.key), ["Codex", "Kimi", "Claude", "Cursor", "api:DeepSeek"])
        let shown = PanelLayout(blocks: ["Grok": PanelLayout.Block(widget: .ring)], order: ["Grok"])
        XCTAssertEqual(PanelLayoutPlan(layout: shown, blocks: returned).blocks.first,
                       PanelBlockPlan(key: "Grok", kind: .quota, widget: .ring, measures: everyMeasure))
    }

    func testAHiddenBlockIsLeftOut() {
        let layout = PanelLayout(blocks: ["Codex": PanelLayout.Block(hidden: true), "api:DeepSeek": PanelLayout.Block(hidden: true)],
                                 order: ["Codex"])
        XCTAssertEqual(plan(layout).blocks.map(\.key), ["Claude", "Cursor"])
    }

    func testABlockWithEveryRowHiddenIsLeftOutAndOneWithoutRowsIsNot() {
        XCTAssertNil(block("Claude", in: PanelLayout(blocks: ["Claude": PanelLayout.Block(hiddenRows: ["claude-weekly", "claude-session"])])))
        XCTAssertNil(block("Codex", in: PanelLayout(blocks: ["Codex": PanelLayout.Block(hiddenRows: ["codex", "codex", "gone"])])))
        XCTAssertEqual(block("Claude", in: PanelLayout(blocks: ["Claude": PanelLayout.Block(hiddenRows: ["claude-weekly", "gone"])]))?.hiddenRows,
                       ["claude-weekly"], "a row the block does not have hides nothing")
        // No row keys: nothing covers them, whatever is named.
        XCTAssertEqual(block("Cursor", in: PanelLayout(blocks: ["Cursor": PanelLayout.Block(hiddenRows: ["cursor"])]))?.hiddenRows, [])
        XCTAssertEqual(block("api:DeepSeek", in: PanelLayout(blocks: ["api:DeepSeek": PanelLayout.Block(hiddenRows: ["CNY"])]))?.hiddenRows, [])
        XCTAssertEqual(block("Cursor", in: PanelLayout(blocks: ["Cursor": PanelLayout.Block(hiddenRows: [])]))?.hiddenRows, [])
    }

    func testAWidgetItsKindDoesNotAcceptFallsBackToTheKindsDefault() {
        for widget in PanelWidget.allCases {
            let quota = block("Claude", in: PanelLayout(blocks: ["Claude": PanelLayout.Block(widget: widget)]))
            XCTAssertEqual(quota?.widget, widget, "quota windows take \(widget)")
            let balance = block("api:DeepSeek", in: PanelLayout(blocks: ["api:DeepSeek": PanelLayout.Block(widget: widget)]))
            XCTAssertEqual(balance?.widget, .number, "a balance asked for \(widget) is a number: it has no ceiling")
            XCTAssertEqual(balance?.measures, [.quota])
        }
    }

    /// The picker offers the measures the layout lists, in that order and each once, where the block's widget offers
    /// them; the first is the one shown when the panel opens.
    func testThePickerOffersTheListedMeasuresInTheirOrder() {
        func expect(_ key: String, _ change: PanelLayout.Block, offers measures: [PanelMeasure], line: UInt = #line) {
            let planned = block(key, in: PanelLayout(blocks: [key: change]))
            XCTAssertEqual(planned?.measures, measures, line: line)
            XCTAssertEqual(planned?.measure, measures.first, "the first is shown first", line: line)
        }
        expect("Claude", PanelLayout.Block(measures: [.cost, .quota]), offers: [.cost, .quota])
        expect("Claude", PanelLayout.Block(widget: .ring, measures: [.burnRate]), offers: [.burnRate])
        expect("Claude", PanelLayout.Block(measures: [.tokens, .cost, .tokens, .quota, .cost]), offers: [.tokens, .cost, .quota])
        expect("Claude", PanelLayout.Block(measures: []), offers: everyMeasure)
        expect("Claude", PanelLayout.Block(widget: .number, measures: Array(everyMeasure.reversed())), offers: Array(everyMeasure.reversed()))
    }

    func testAMeasureTheWidgetDoesNotOfferIsLeftOutAndNoneLeftIsEveryOne() {
        let ofAChart: [PanelMeasure] = [.tokens]
        func expect(_ key: String, _ change: PanelLayout.Block, offers measures: [PanelMeasure], line: UInt = #line) {
            XCTAssertEqual(block(key, in: PanelLayout(blocks: [key: change]))?.measures, measures, line: line)
        }
        expect("Claude", PanelLayout.Block(widget: .chart), offers: ofAChart)
        expect("Claude", PanelLayout.Block(widget: .chart, measures: [.cost]), offers: ofAChart)
        expect("Claude", PanelLayout.Block(widget: .chart, measures: [.quota, .tokens]), offers: ofAChart)
        expect("Claude", PanelLayout.Block(widget: .chart, measures: [.burnRate, .quota]), offers: ofAChart)
        expect("api:DeepSeek", PanelLayout.Block(measures: [.cost]), offers: [.quota])
        expect("api:DeepSeek", PanelLayout.Block(measures: [.cost, .quota]), offers: [.quota])
        // The widget falls back first, and the measures are weighed under the widget that results.
        expect("api:DeepSeek", PanelLayout.Block(widget: .chart, measures: [.tokens]), offers: [.quota])
        expect("Claude", PanelLayout.Block(widget: .chart, measures: [.burnRate]), offers: ofAChart)
    }

    func testEveryPlannedMeasureIsOneItsWidgetOffers() {
        var widgets: [PanelWidget?] = [nil]
        widgets.append(contentsOf: PanelWidget.allCases)
        var lists: [[PanelMeasure]] = [[], PanelMeasure.allCases, Array(PanelMeasure.allCases.reversed())]
        lists += PanelMeasure.allCases.map { [$0] }
        for widget in widgets {
            for measures in lists {
                let change = PanelLayout.Block(widget: widget, measures: measures)
                for planned in plan(PanelLayout(blocks: ["Claude": change, "api:DeepSeek": change])).blocks {
                    let offered = planned.kind.measures(under: planned.widget)
                    XCTAssertTrue(planned.kind.widgets.contains(planned.widget), "\(planned)")
                    XCTAssertFalse(planned.measures.isEmpty, "\(planned)")
                    XCTAssertEqual(planned.measures, planned.measures.withoutRepeats, "\(planned)")
                    XCTAssertTrue(planned.measures.allSatisfy(offered.contains), "\(planned)")
                    XCTAssertTrue(offered.contains(planned.measure), "\(planned)")
                }
            }
        }
    }

    /// A countdown hidden by the layout is told to the panel for a quota block; a balance has none to hide.
    func testTheCountdownIsHiddenOnlyWhereTheLayoutHidesItOnAQuotaBlock() {
        XCTAssertEqual(block("Claude", in: PanelLayout(blocks: ["Claude": PanelLayout.Block(countdown: false)]))?.countdown, false)
        XCTAssertEqual(block("Claude", in: PanelLayout(blocks: ["Claude": PanelLayout.Block(widget: .chart, countdown: false)]))?.countdown,
                       false, "a chart's block keeps its earned resets, whose expiry is a countdown")
        XCTAssertEqual(block("Codex", in: PanelLayout(blocks: ["Claude": PanelLayout.Block(countdown: false)]))?.countdown, true)
        XCTAssertEqual(block("api:DeepSeek", in: PanelLayout(blocks: ["api:DeepSeek": PanelLayout.Block(countdown: false)]))?.countdown, true)
    }

    /// Columns and ring sizes reach only the blocks drawn in cells and rings; anywhere else, and where none is given or
    /// one out of range, the plan has the default view's.
    func testColumnsAndRingSizesApplyWhereTheBlockHasCellsAndRings() {
        func planned(_ key: String, _ change: PanelLayout.Block) -> (columns: Int?, ringSize: PanelRingSize?) {
            let made = block(key, in: PanelLayout(blocks: [key: change]))
            return (made?.columns, made?.ringSize)
        }
        for columns in 2...6 {
            XCTAssertEqual(planned("Claude", PanelLayout.Block(widget: .ring, columns: columns)).columns, columns)
            XCTAssertEqual(planned("Claude", PanelLayout.Block(widget: .number, columns: columns)).columns, columns)
            XCTAssertEqual(planned("Claude", PanelLayout.Block(widget: .bar, columns: columns)).columns, 4)
            XCTAssertEqual(planned("Claude", PanelLayout.Block(widget: .chart, columns: columns)).columns, 4)
            XCTAssertEqual(planned("api:DeepSeek", PanelLayout.Block(columns: columns)).columns, 4, "a balance's number is its card")
        }
        for columns in [0, 1, 7, 40, -2] {
            XCTAssertEqual(planned("Claude", PanelLayout.Block(widget: .ring, columns: columns)).columns, 4, "\(columns)")
        }
        for size in PanelRingSize.allCases {
            XCTAssertEqual(planned("Claude", PanelLayout.Block(widget: .ring, ringSize: size)).ringSize, size)
            XCTAssertEqual(planned("Claude", PanelLayout.Block(widget: .number, ringSize: size)).ringSize, .medium)
            XCTAssertEqual(planned("api:DeepSeek", PanelLayout.Block(widget: .ring, ringSize: size)).ringSize, .medium,
                           "a balance asked for rings is its card")
        }
        XCTAssertEqual(planned("Claude", PanelLayout.Block(widget: .ring)).columns, 4)
        XCTAssertEqual(planned("Claude", PanelLayout.Block(widget: .ring)).ringSize, .medium)
    }

    func testThePlanCarriesTheLayoutsStyle() {
        let style = PanelStyle(spacing: .roomy, separators: false)
        XCTAssertEqual(plan(PanelLayout(style: style)).style, style)
        XCTAssertEqual(plan(PanelLayout(style: style)).blocks, plan(PanelLayout()).blocks, "the style draws the same blocks")
    }

    func testSectionsFollowTheSameOrderRuleWithoutTheHiddenOnes() {
        XCTAssertEqual(plan(PanelLayout(sections: [.sessions])).sections, [.sessions, .blocks, .tokens])
        XCTAssertEqual(plan(PanelLayout(sections: [.tokens, .sessions, .tokens, .blocks])).sections, [.tokens, .sessions, .blocks])
        XCTAssertEqual(plan(PanelLayout(hiddenSections: [.tokens])).sections, [.blocks, .sessions])
        XCTAssertEqual(plan(PanelLayout(sections: [.sessions, .tokens], hiddenSections: [.sessions, .sessions])).sections, [.tokens, .blocks],
                       "a hidden section is left out wherever it is named")
        XCTAssertEqual(plan(PanelLayout(hiddenSections: PanelSection.allCases)).sections, [])
        XCTAssertEqual(plan(PanelLayout(hiddenSections: [.blocks])).blocks.count, 4,
                       "hiding the section says nothing about its blocks, which a reader of the plan then does not draw")
    }

    func testABlockListedTwiceIsPlannedOnce() {
        let twice = blocks + [PanelBlockInfo(key: "Claude", kind: .quota, rowKeys: ["other"])]
        let planned = PanelLayoutPlan(layout: PanelLayout(blocks: ["Claude": PanelLayout.Block(hiddenRows: ["claude-session"])]), blocks: twice)
        XCTAssertEqual(planned.blocks.map(\.key), ["Claude", "Codex", "Cursor", "api:DeepSeek"])
        XCTAssertEqual(planned.blocks.first?.hiddenRows, ["claude-session"])
    }

    func testTheDemosViewPlansAsItsDefault() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let report = DemoUsageProvider.report(agents: DemoData.agents, historyHours: 24, now: now, stage: nil)
        let view = ReportView(report: report, agents: DemoData.agents, settings: Settings(), now: now)
        let plan = PanelLayoutPlan(layout: PanelLayout(), blocks: view.panelBlocks)
        XCTAssertEqual(plan.blocks.map(\.key), ["Claude", "Codex", "api:DeepSeek"])
        XCTAssertEqual(plan.blocks.map(\.widget), [.bar, .bar, .number])
        let changed = PanelLayout(blocks: ["Codex": PanelLayout.Block(widget: .ring, hiddenRows: ["codex:spark:primary"])],
                                  order: ["api:DeepSeek"], hiddenSections: [.sessions])
        XCTAssertEqual(changed.issues(against: view.panelBlocks), [])
        let custom = PanelLayoutPlan(layout: changed, blocks: view.panelBlocks)
        XCTAssertEqual(custom.blocks.map(\.key), ["api:DeepSeek", "Claude", "Codex"])
        XCTAssertEqual(custom.blocks.last?.hiddenRows, ["codex:spark:primary"])
        XCTAssertEqual(custom.sections, [.blocks, .tokens])
    }
}
