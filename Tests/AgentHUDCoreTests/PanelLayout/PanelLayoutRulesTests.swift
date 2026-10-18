import AgentHUDSupport
import XCTest
@testable import AgentHUDCore

/// What a block accepts, which blocks a report view has, and what a proposed layout is told about itself.
final class PanelLayoutRulesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Two quota blocks and a balance, as `ReportView.panelBlocks` lists them.
    private let blocks = [
        PanelBlockInfo(key: "Claude", kind: .quota, rowKeys: ["claude-session", "claude-weekly"]),
        PanelBlockInfo(key: "Codex", kind: .quota, rowKeys: ["codex"]),
        PanelBlockInfo(key: "api:DeepSeek", kind: .billing),
    ]

    override func setUp() {
        super.setUp()
        L10n.setLanguage(.en)
    }

    override func tearDown() {
        L10n.setLanguage(.system)
        super.tearDown()
    }

    // MARK: What a kind accepts

    func testQuotaWindowsTakeEveryWidgetAndABalanceANumberOrAChart() {
        XCTAssertEqual(PanelBlockKind.quota.widgets, [.bar, .ring, .number, .chart])
        XCTAssertEqual(PanelBlockKind.billing.widgets, [.number, .chart], "a balance has no ceiling for a bar or a ring to fill")
        XCTAssertEqual(PanelBlockKind.quota.defaultWidget, .bar)
        XCTAssertEqual(PanelBlockKind.billing.defaultWidget, .number)
        XCTAssertEqual(Set(PanelBlockKind.quota.widgets), Set(PanelWidget.allCases))
    }

    func testTheMeasuresOfferedFollowTheKindAndTheWidget() {
        for widget in [PanelWidget.bar, .ring, .number] {
            XCTAssertEqual(PanelBlockKind.quota.measures(under: widget), [.quota, .burnRate, .tokens, .consumed, .cost], "\(widget)")
        }
        XCTAssertEqual(PanelBlockKind.quota.measures(under: .chart), [.tokens])
        XCTAssertEqual(PanelBlockKind.billing.measures(under: .number), [.quota, .burnRate, .tokens, .consumed, .cost],
                       "a balance also reads its models' reply speed and recorded tokens")
        XCTAssertEqual(PanelBlockKind.billing.measures(under: .chart), [.cost], "a balance's chart draws its estimated cost")
        for widget in [PanelWidget.bar, .ring] {
            XCTAssertEqual(PanelBlockKind.billing.measures(under: widget), [], "\(widget) is not a balance's widget")
        }
    }

    func testAListOfMeasuresIsKeptToWhatTheWidgetOffersAndNoneLeftIsEveryOne() {
        let every: [PanelMeasure] = [.quota, .burnRate, .tokens, .consumed, .cost]
        XCTAssertEqual(PanelBlockKind.quota.measures([], under: .bar), every)
        XCTAssertEqual(PanelBlockKind.quota.measures([.cost, .quota], under: .ring), [.cost, .quota])
        XCTAssertEqual(PanelBlockKind.quota.measures([.cost, .cost, .burnRate], under: .number), [.cost, .burnRate])
        XCTAssertEqual(PanelBlockKind.quota.measures([.quota, .tokens], under: .chart), [.tokens])
        XCTAssertEqual(PanelBlockKind.quota.measures([.quota], under: .chart), [.tokens])
        XCTAssertEqual(PanelBlockKind.billing.measures([.cost], under: .number), [.cost])
        XCTAssertEqual(PanelBlockKind.billing.measures([.tokens, .consumed, .burnRate, .tokens], under: .number),
                       [.tokens, .consumed, .burnRate])
        XCTAssertEqual(PanelBlockKind.billing.measures([.quota, .burnRate], under: .chart), [.cost])
        for kind in [PanelBlockKind.quota, .billing] {
            for widget in kind.widgets {
                XCTAssertEqual(kind.measures([], under: widget), kind.measures(under: widget), "\(kind) \(widget)")
            }
        }
    }

    func testWhatAKindDoesNotAcceptFallsBackToItsDefault() {
        XCTAssertEqual(PanelBlockKind.quota.widget(for: .ring), .ring)
        XCTAssertEqual(PanelBlockKind.quota.widget(for: nil), .bar)
        XCTAssertEqual(PanelBlockKind.billing.widget(for: .ring), .number)
        XCTAssertEqual(PanelBlockKind.billing.widget(for: .bar), .number)
        XCTAssertEqual(PanelBlockKind.billing.widget(for: .chart), .chart)
    }

    func testWhatAKindHasToSetUnderAWidget() {
        XCTAssertTrue(PanelBlockKind.quota.takesCountdown)
        XCTAssertFalse(PanelBlockKind.billing.takesCountdown, "a balance does not reset")
        XCTAssertEqual(PanelWidget.allCases.filter { PanelBlockKind.quota.takesColumns(under: $0) }, [.ring, .number])
        XCTAssertEqual(PanelWidget.allCases.filter { PanelBlockKind.quota.takesRingSize(under: $0) }, [.ring])
        XCTAssertFalse(PanelWidget.allCases.contains { PanelBlockKind.billing.takesColumns(under: $0) }, "a balance's number is its card")
        XCTAssertFalse(PanelWidget.allCases.contains { PanelBlockKind.billing.takesRingSize(under: $0) })
        XCTAssertTrue(PanelBlockKind.billing.takesHalf(under: .chart), "a balance's chart can take half a line, as its card can")
        XCTAssertTrue(PanelBlockKind.billing.takesPeriod(under: .chart))
    }

    // MARK: The blocks of a view

    func testTheDemoHasABlockForEachAccountsWindowsAndOneForItsBalance() {
        let report = DemoUsageProvider.report(agents: DemoData.agents, historyHours: 24, now: now, stage: nil)
        let view = ReportView(report: report, agents: DemoData.agents, settings: Settings(), now: now)
        let claude = ["claude-session", "claude-weekly", "claude-weekly-fable"]
        let codex = ["codex", "codex:spark:primary", "codex:spark:secondary"]
        XCTAssertEqual(view.panelBlocks, [
            PanelBlockInfo(key: "Claude", kind: .quota, rowKeys: claude,
                           accounts: [.init(id: DemoData.claudeAccount.id, name: "Personal", rowKeys: claude)]),
            PanelBlockInfo(key: "Codex", kind: .quota, rowKeys: codex,
                           accounts: [.init(id: DemoData.codexAccount.id, name: "Personal", rowKeys: codex)]),
            PanelBlockInfo(key: "api:DeepSeek", kind: .billing, rowKeys: [], accounts: [.init(id: "DeepSeek", name: "DeepSeek · API")]),
        ])
        XCTAssertEqual(view.panelBlocks.filter { $0.kind == .quota }.map(\.key), view.rowGroups.map(\.vendor))
    }

    /// Two accounts of one vendor share a window, one row is switched off, and two API accounts are billed by one provider.
    func testAWindowIsOneRowHoweverManyAccountsHaveItAndAccountsOfOneProviderShareABlock() {
        let accounts = ["one@example.com", "two@example.com"].map {
            ProviderAccount.identified(provider: "Codex", user: $0, workspace: nil)!
        }
        let pools = ["first", "second"].map {
            BillingPool(provider: "Moonshot", realm: "CN", product: .api, scope: $0, evidence: .credential, entitlement: "api")
        }
        func window(_ account: ProviderAccount, _ key: String) -> AgentDescriptor {
            AgentDescriptor(id: account.windowID(key), vendor: "Codex", model: key, source: "", enabled: true, account: account)
        }
        let agents = [
            window(accounts[0], "codex"), window(accounts[0], "codex:spark"), window(accounts[1], "codex"),
            AgentDescriptor(id: "claude-session", vendor: "Claude", model: "5h", source: "", enabled: true),
            AgentDescriptor(id: "claude-weekly", vendor: "Claude", model: "Weekly", source: "", enabled: false),
            AgentDescriptor(id: "deepseek", vendor: "DeepSeek", model: "API", source: "", enabled: true),
        ] + pools.map {
            AgentDescriptor(id: $0.windowID("kimi-k3"), vendor: "Kimi", model: "K3", source: "", enabled: true, billingPool: $0)
        }
        func balance(_ vendor: String, pool: BillingPool? = nil) -> APIBilling {
            APIBilling(vendor: vendor, balances: [AccountBalance(currency: "CNY", total: 20, granted: 0, toppedUp: 20)],
                       isAvailable: true, updatedAt: now, notice: nil, billingPool: pool)
        }
        let report = UsageReport(generatedAt: now, snapshots: [], sessions: [],
                                 billing: [balance("Kimi", pool: pools[0]), balance("DeepSeek"), balance("Kimi", pool: pools[1])])
        let view = ReportView(report: report, agents: agents, settings: Settings(), now: now)

        XCTAssertEqual(view.billing.count, 3)
        XCTAssertEqual(view.billing.map(\.panelBlockKey), ["api:Moonshot", "api:DeepSeek", "api:Moonshot"],
                       "a pool's balance is keyed by the provider that bills it, any other by its vendor")
        XCTAssertEqual(view.panelBlocks, [
            PanelBlockInfo(key: "Codex", kind: .quota, rowKeys: ["codex", "codex:spark"], accounts: [
                .init(id: accounts[0].id, rowKeys: ["codex", "codex:spark"]), .init(id: accounts[1].id, rowKeys: ["codex"]),
            ]),
            PanelBlockInfo(key: "Claude", kind: .quota, rowKeys: ["claude-session"], accounts: [.init(id: "", rowKeys: ["claude-session"])]),
            PanelBlockInfo(key: "api:Moonshot", kind: .billing, accounts: pools.map { .init(id: $0.id, name: "Moonshot · API") }),
            PanelBlockInfo(key: "api:DeepSeek", kind: .billing, accounts: [.init(id: "DeepSeek", name: "DeepSeek · API")]),
        ])
        XCTAssertEqual(ReportView(report: nil, agents: agents, settings: Settings(), now: now).panelBlocks.map(\.key), ["Codex", "Claude"],
                       "before any report there are rows and no balances")
        XCTAssertEqual(ReportView(report: report, agents: [], settings: Settings(), now: now).panelBlocks, [])
    }

    // MARK: What a proposed layout is told

    func testALayoutThePanelCanDoAsAskedHasNoIssues() {
        XCTAssertEqual(PanelLayout().issues(against: blocks), [])
        let layout = PanelLayout(blocks: [
            "Claude": PanelLayout.Block(widget: .ring, measures: [.burnRate, .cost, .burnRate], hiddenRows: ["claude-weekly"],
                                        countdown: false, columns: 6, ringSize: .small),
            "Codex": PanelLayout.Block(widget: .chart, measures: [.tokens], hidden: true, countdown: false),
            "api:DeepSeek": PanelLayout.Block(widget: .number, measures: [.quota]),
        ], order: ["api:DeepSeek", "Codex", "Codex"], sections: [.sessions], hiddenSections: [.tokens],
           style: PanelStyle(spacing: .compact, separators: false))
        XCTAssertEqual(layout.issues(against: blocks), [])
        XCTAssertEqual(PanelLayout(blocks: ["Codex": PanelLayout.Block(widget: .number, columns: 2)]).issues(against: blocks), [])
    }

    func testABlockKeyOrOrderEntryThatNamesNoBlockListsTheBlocksThereAre() {
        let layout = PanelLayout(blocks: ["Cursor": PanelLayout.Block(widget: .ring)], order: ["Claude", "claude", "Cursor"])
        func unknown(_ key: String) -> String {
            "No block has the key \"\(key)\". The panel's blocks now: \"Claude\", \"Codex\", \"api:DeepSeek\"."
        }
        XCTAssertEqual(layout.issues(against: blocks), [
            PanelLayoutIssue(path: "blocks.Cursor", message: unknown("Cursor")),
            PanelLayoutIssue(path: "order[1]", message: unknown("claude")),
            PanelLayoutIssue(path: "order[2]", message: unknown("Cursor")),
        ])
        XCTAssertEqual(PanelLayout(order: ["Claude"]).issues(against: []), [
            PanelLayoutIssue(path: "order[0]", message: #"No block has the key "Claude". The panel has no blocks now."#),
        ])
    }

    func testAWidgetABalanceCannotTakeSaysWhyAndWhatItAccepts() {
        func issues(_ widget: PanelWidget) -> [PanelLayoutIssue] {
            PanelLayout(blocks: ["api:DeepSeek": PanelLayout.Block(widget: widget)]).issues(against: blocks)
        }
        func noCeiling(_ widget: String) -> String {
            "\"api:DeepSeek\" is an API balance, which has no ceiling, so the \"\(widget)\" widget has nothing to measure it against."
                + " It accepts: \"number\", \"chart\"."
        }
        XCTAssertEqual(issues(.number), [])
        XCTAssertEqual(issues(.chart), [], "a balance is charted by its estimated cost")
        XCTAssertEqual(issues(.ring), [PanelLayoutIssue(path: "blocks.api:DeepSeek.widget", message: noCeiling("ring"))])
        XCTAssertEqual(issues(.bar).map(\.message), [noCeiling("bar")])
        for widget in PanelWidget.allCases {
            XCTAssertEqual(PanelLayout(blocks: ["Claude": PanelLayout.Block(widget: widget)]).issues(against: blocks), [], "\(widget)")
        }
    }

    func testEachMeasureIsCheckedUnderTheWidgetTheBlockIsDrawnWith() {
        func issues(_ key: String, _ block: PanelLayout.Block) -> [PanelLayoutIssue] {
            PanelLayout(blocks: [key: block]).issues(against: blocks)
        }
        XCTAssertEqual(issues("Claude", PanelLayout.Block(widget: .chart, measures: [.tokens, .burnRate, .cost])), [
            PanelLayoutIssue(path: "blocks.Claude.measures[1]", message:
                #"The "chart" widget of "Claude" does not offer the measure "burn". It offers: "tokens"."#),
            PanelLayoutIssue(path: "blocks.Claude.measures[2]", message:
                #"The "chart" widget of "Claude" does not offer the measure "cost". It offers: "tokens"."#),
        ])
        XCTAssertEqual(issues("Claude", PanelLayout.Block(widget: .chart, measures: [.tokens])), [])
        XCTAssertEqual(issues("Claude", PanelLayout.Block(measures: [.cost])), [], "without a widget the default one decides")
        XCTAssertEqual(issues("api:DeepSeek", PanelLayout.Block(measures: [.cost, .burnRate, .quota, .tokens, .consumed])), [],
                       "a balance's number offers money, reply speed and consumption")
        let charted = [
            #"The "chart" widget of "api:DeepSeek" does not offer the measure "burn"."#,
            #" The "chart" widget of an API balance draws its estimated cost over its period. It offers: "cost"."#,
        ].joined()
        XCTAssertEqual(issues("api:DeepSeek", PanelLayout.Block(widget: .chart, measures: [.cost, .burnRate])), [
            PanelLayoutIssue(path: "blocks.api:DeepSeek.measures[1]", message: charted),
        ])
        // A widget the block cannot take is drawn as its default, and the measures are weighed under that one.
        XCTAssertEqual(issues("api:DeepSeek", PanelLayout.Block(widget: .ring, measures: [.tokens])).map(\.path),
                       ["blocks.api:DeepSeek.widget"])
        XCTAssertEqual(issues("api:DeepSeek", PanelLayout.Block(widget: .ring, measures: [.burnRate])).map(\.path), ["blocks.api:DeepSeek.widget"])
    }

    func testACountdownColumnsOrARingSizeWhereTheBlockHasNoneToSetIsAnIssue() {
        func issues(_ key: String, _ block: PanelLayout.Block) -> [PanelLayoutIssue] {
            PanelLayout(blocks: [key: block]).issues(against: blocks)
        }
        XCTAssertEqual(issues("api:DeepSeek", PanelLayout.Block(countdown: false)), [
            PanelLayoutIssue(path: "blocks.api:DeepSeek.countdown",
                             message: #""api:DeepSeek" is an API balance, which has no reset to count down to. countdown applies to quota blocks."#),
        ])
        XCTAssertEqual(issues("Claude", PanelLayout.Block(columns: 3)), [
            PanelLayoutIssue(path: "blocks.Claude.columns",
                             message: #"The "bar" widget of "Claude" draws no cells. columns applies to the "ring" and "number" widgets."#),
        ])
        XCTAssertEqual(issues("Claude", PanelLayout.Block(widget: .chart, columns: 2)).map(\.path), ["blocks.Claude.columns"])
        XCTAssertEqual(issues("api:DeepSeek", PanelLayout.Block(widget: .number, columns: 2)), [
            PanelLayoutIssue(path: "blocks.api:DeepSeek.columns",
                             message: #""api:DeepSeek" is an API balance, drawn as its card, which has no cells to set in columns."#),
        ])
        XCTAssertEqual(issues("api:DeepSeek", PanelLayout.Block(widget: .chart, columns: 2)).map(\.message), [
            #""api:DeepSeek" is an API balance, drawn as a chart of its estimated cost, which has no cells to set in columns."#,
        ])
        XCTAssertEqual(issues("Claude", PanelLayout.Block(widget: .number, ringSize: .large)), [
            PanelLayoutIssue(path: "blocks.Claude.ringSize",
                             message: #"The "number" widget of "Claude" draws no ring. ringSize applies to the "ring" widget."#),
        ])
        XCTAssertEqual(issues("Claude", PanelLayout.Block(ringSize: .medium)).map(\.path), ["blocks.Claude.ringSize"],
                       "even the default size, which the agent believes was heeded")
        XCTAssertEqual(issues("api:DeepSeek", PanelLayout.Block(widget: .ring, ringSize: .small)).map(\.message), [
            #""api:DeepSeek" is an API balance, which has no ceiling, so the "ring" widget has nothing to measure it against. It accepts: "number", "chart"."#,
            #""api:DeepSeek" is an API balance, which draws no ring."#,
        ])
        for widget in [PanelWidget.ring, .number] {
            XCTAssertEqual(issues("Codex", PanelLayout.Block(widget: widget, countdown: false, columns: 5)), [], "\(widget)")
        }
    }

    func testAHiddenRowTheBlockDoesNotHaveListsItsRows() {
        let layout = PanelLayout(blocks: [
            "Claude": PanelLayout.Block(hiddenRows: ["claude-weekly", "codex", "weekly"]),
            "api:DeepSeek": PanelLayout.Block(hiddenRows: ["CNY"]),
        ])
        func noRow(_ row: String) -> String {
            "\"Claude\" has no row \"\(row)\". Its rows: \"claude-session\", \"claude-weekly\"."
        }
        XCTAssertEqual(layout.issues(against: blocks), [
            PanelLayoutIssue(path: "blocks.Claude.hiddenRows[1]", message: noRow("codex")),
            PanelLayoutIssue(path: "blocks.Claude.hiddenRows[2]", message: noRow("weekly")),
            PanelLayoutIssue(path: "blocks.api:DeepSeek.hiddenRows[0]",
                             message: #""api:DeepSeek" has no row "CNY". It has no rows to hide."#),
        ])
    }

    func testIssuesComeBlockByBlockInKeyOrderThenTheOrderList() {
        let layout = PanelLayout(blocks: [
            "api:DeepSeek": PanelLayout.Block(widget: .bar, measures: [.tokens], hiddenRows: ["x"], countdown: false, columns: 3,
                                              ringSize: .large),
            "Zed": PanelLayout.Block(hidden: true),
            "Claude": PanelLayout.Block(widget: .chart, measures: [.quota], hiddenRows: ["x"], ringSize: .small),
        ], order: ["Zed"])
        XCTAssertEqual(layout.issues(against: blocks).map(\.path), [
            "blocks.Claude.measures[0]", "blocks.Claude.ringSize", "blocks.Claude.hiddenRows[0]", "blocks.Zed",
            "blocks.api:DeepSeek.widget", "blocks.api:DeepSeek.countdown",
            "blocks.api:DeepSeek.columns", "blocks.api:DeepSeek.ringSize", "blocks.api:DeepSeek.hiddenRows[0]", "order[0]",
        ])
        // A layout with issues still resolves: what cannot be done as asked falls back or waits.
        XCTAssertEqual(PanelLayoutPlan(layout: layout, blocks: blocks).blocks.map(\.key), ["Claude", "Codex", "api:DeepSeek"])
    }

    // MARK: What a layout already holds

    private let held = PanelLayout(blocks: ["Cursor": PanelLayout.Block(widget: .ring, hiddenRows: ["cursor-auto"]),
                                            "Claude": PanelLayout.Block(hiddenRows: ["claude-weekly-fable"])],
                                   order: ["Zed", "Claude"])

    /// A layout keeps what it holds for a block or a row that is away, so a layout that was read can be sent back.
    func testWhatALayoutAlreadyHoldsForSomethingThatIsAwayIsNoIssue() {
        XCTAssertEqual(held.issues(against: blocks).map(\.path), ["blocks.Claude.hiddenRows[0]", "blocks.Cursor", "order[0]"],
                       "asked for anew, each of them names something the panel does not have")
        XCTAssertEqual(held.issues(against: blocks, holding: [held]), [])

        var more = held
        more.blocks["Codex"] = PanelLayout.Block(widget: .number)
        more.blocks["Claude"]?.hiddenRows += ["claude-weekly"]
        more.blocks["Cursor"]?.hiddenRows = ["cursor-auto", "cursor-auto", ""]
        more.order = ["Codex", "Cursor", "Zed"]
        more.hiddenSections = [.tokens]
        XCTAssertEqual(more.issues(against: blocks, holding: [PanelLayout(), held]), [],
                       "a change to what is there, beside what is held: an away block's key may be ordered")
    }

    func testOnlyWhatIsHeldIsLetThrough() {
        var changed = held
        changed.blocks["Cursor"]?.widget = .chart
        let away = "No block has the key \"Cursor\" now. The layout holds it for a block that is away: send it back as it is, "
            + "or leave it out. The panel's blocks now: \"Claude\", \"Codex\", \"api:DeepSeek\"."
        XCTAssertEqual(changed.issues(against: blocks, holding: [held]), [PanelLayoutIssue(path: "blocks.Cursor", message: away)],
                       "a block that is away has no kind to weigh a new widget against")

        var newer = held
        newer.blocks["Claude"]?.hiddenRows += ["claude-monthly"]
        newer.blocks["Trae"] = PanelLayout.Block(hidden: true)
        newer.order += ["Trae", "Kiro"]
        XCTAssertEqual(newer.issues(against: blocks, holding: [held]).map(\.path),
                       ["blocks.Claude.hiddenRows[1]", "blocks.Trae", "order[2]", "order[3]"])
        // What is held is still weighed where the block is there to weigh it.
        let unfit = PanelLayout(blocks: ["api:DeepSeek": PanelLayout.Block(widget: .ring)])
        XCTAssertEqual(unfit.issues(against: blocks, holding: [unfit]).map(\.path), ["blocks.api:DeepSeek.widget"])
    }

    // MARK: What a layout changes

    /// An agent reads every block's widget and measure and may send them all back: spelled out, the default is still
    /// the default.
    func testALayoutThatSpellsOutTheDefaultViewIsTheDefaultLayout() {
        let spelled = PanelLayout(blocks: [
            "Claude": PanelLayout.Block(widget: .bar, measures: [.quota, .burnRate, .tokens, .consumed, .cost]),
            "Codex": PanelLayout.Block(widget: .bar),
            "api:DeepSeek": PanelLayout.Block(widget: .number, measures: [.quota, .burnRate, .tokens, .consumed, .cost]),
        ], order: ["Claude", "Codex", "api:DeepSeek"], sections: [.blocks, .tokens, .sessions],
           style: PanelStyle(spacing: .regular, separators: true))
        XCTAssertFalse(spelled.isDefault)
        XCTAssertEqual(spelled.reduced(against: blocks), PanelLayout())
        XCTAssertEqual(PanelLayout(order: ["Claude"]).reduced(against: blocks), PanelLayout(), "Claude comes first anyway")
        XCTAssertEqual(PanelLayout().reduced(against: blocks), PanelLayout())
    }

    func testOnlyWhatDiffersFromTheDefaultIsKept() {
        let layout = PanelLayout(blocks: [
            "Claude": PanelLayout.Block(widget: .chart, measures: [.tokens], hiddenRows: ["claude-weekly"]),
            "Codex": PanelLayout.Block(widget: .bar, measures: [.cost, .quota], hidden: true),
            "api:DeepSeek": PanelLayout.Block(widget: .chart, measures: [.cost]),
        ], order: ["Codex", "Claude", "api:DeepSeek"], hiddenSections: [.tokens], style: PanelStyle(spacing: .roomy))
        XCTAssertEqual(layout.reduced(against: blocks), PanelLayout(blocks: [
            "Claude": PanelLayout.Block(widget: .chart, hiddenRows: ["claude-weekly"]),
            "Codex": PanelLayout.Block(measures: [.cost, .quota], hidden: true),
            "api:DeepSeek": PanelLayout.Block(widget: .chart),
        ], order: ["Codex"], hiddenSections: [.tokens], style: PanelStyle(spacing: .roomy)),
                       "tokens is all a quota block's chart offers and cost all a balance's, and the rest of the order follows anyway")
        XCTAssertEqual(PanelLayout(order: ["api:DeepSeek", "Claude", "Codex"]).reduced(against: blocks), PanelLayout(order: ["api:DeepSeek"]))
        XCTAssertEqual(PanelLayout(order: ["Codex", "api:DeepSeek", "Claude"]).reduced(against: blocks),
                       PanelLayout(order: ["Codex", "api:DeepSeek"]))
    }

    func testAnExplicitEarlierMeasureListKeepsItsSelectionAfterNewMeasuresAreAdded() {
        let layout = PanelLayout(blocks: [
            "Claude": PanelLayout.Block(measures: [.quota, .burnRate, .tokens, .cost]),
            "api:DeepSeek": PanelLayout.Block(measures: [.quota, .burnRate, .cost]),
        ])
        XCTAssertEqual(layout.reduced(against: blocks), layout,
                       "an explicit list does not acquire consumption or a balance's reply speed")
    }

    /// A list of measures that is everything its widget offers in the widget's order, columns of four and a medium ring
    /// are the default view's; what a block has nothing to set for draws nothing.
    func testWhatABlockWouldDrawAnywayIsLeftOut() {
        let layout = PanelLayout(blocks: [
            "Claude": PanelLayout.Block(widget: .ring, measures: [.quota, .burnRate, .tokens, .consumed, .cost, .quota], columns: 4, ringSize: .medium),
            "Codex": PanelLayout.Block(widget: .bar, measures: [.burnRate, .quota], columns: 3, ringSize: .large),
            "api:DeepSeek": PanelLayout.Block(widget: .number, measures: [.quota, .burnRate, .tokens, .consumed, .cost], countdown: false,
                                              columns: 3),
        ])
        XCTAssertEqual(layout.reduced(against: blocks), PanelLayout(blocks: [
            "Claude": PanelLayout.Block(widget: .ring),
            "Codex": PanelLayout.Block(measures: [.burnRate, .quota]),
        ]), "a balance has no countdown and no cells; its default measures need no override")
        XCTAssertEqual(PanelLayout(blocks: ["api:DeepSeek": PanelLayout.Block(measures: [.cost, .quota])]).reduced(against: blocks),
                       PanelLayout(blocks: ["api:DeepSeek": PanelLayout.Block(measures: [.cost, .quota])]), "two of a balance's measures draw")
        let kept = PanelLayout(blocks: ["Claude": PanelLayout.Block(widget: .number, measures: [.cost, .quota, .burnRate, .tokens],
                                                                    countdown: false, columns: 6),
                                        "Codex": PanelLayout.Block(widget: .ring, measures: [.quota], ringSize: .small)])
        XCTAssertEqual(kept.reduced(against: blocks), kept, "another order, one measure, a hidden countdown and six columns all draw")
        XCTAssertEqual(PanelLayout(blocks: ["Claude": PanelLayout.Block(widget: .chart, measures: [.quota, .tokens])]).reduced(against: blocks),
                       PanelLayout(blocks: ["Claude": PanelLayout.Block(widget: .chart)]), "what a chart offers is tokens alone")
        XCTAssertEqual(PanelLayout(style: PanelStyle(spacing: .regular, separators: true)).reduced(against: blocks), PanelLayout())
    }

    /// What it draws now is the same for both, and so are the plans.
    func testAReducedLayoutDrawsWhatTheLayoutDraws() {
        let layouts = [
            PanelLayout(blocks: ["Claude": PanelLayout.Block(widget: .ring, measures: [.quota], columns: 3, ringSize: .medium),
                                 "Codex": PanelLayout.Block(widget: .bar, measures: [.burnRate, .burnRate], countdown: false, columns: 2)],
                        order: ["Codex", "Zed", "Claude", "api:DeepSeek"], sections: [.sessions], style: PanelStyle(separators: false)),
            PanelLayout(blocks: ["Claude": PanelLayout.Block(widget: .chart, measures: [.cost, .tokens, .quota], ringSize: .large)]),
            PanelLayout(blocks: ["api:DeepSeek": PanelLayout.Block(widget: .number, hidden: true)], order: ["api:DeepSeek", "Codex"]),
            held,
        ]
        for layout in layouts {
            XCTAssertEqual(PanelLayoutPlan(layout: layout.reduced(against: blocks), blocks: blocks),
                           PanelLayoutPlan(layout: layout, blocks: blocks))
        }
    }

    func testWhatIsHeldForABlockThatIsAwayStaysAsWritten() {
        var kept = held
        kept.order = ["Zed"]
        XCTAssertEqual(held.reduced(against: blocks), kept, "an away block's widget and its place stay; Claude comes first after it anyway")
        let trailing = PanelLayout(blocks: ["Cursor": PanelLayout.Block(widget: .bar, measures: [.quota, .burnRate, .tokens, .cost], columns: 4)],
                                   order: ["Codex", "Claude", "Zed"])
        XCTAssertEqual(trailing.reduced(against: blocks), trailing, "nothing is known of Cursor's default, and Zed keeps its place")
        XCTAssertEqual(PanelLayout(order: ["Zed", "Claude", "Codex"]).reduced(against: blocks), PanelLayout(order: ["Zed"]))
    }

    // MARK: Periods

    func testAChartAndABalanceCoverAPeriodAndNoOtherBlockDoes() throws {
        XCTAssertEqual(PanelWidget.allCases.filter { PanelBlockKind.quota.takesPeriod(under: $0) }, [.chart])
        XCTAssertTrue(PanelBlockKind.billing.takesPeriod(under: .number))
        XCTAssertEqual(PanelBlockKind.quota.defaultPeriod(tokens: .month), .day, "a chart stays at the latest 24 hours")
        XCTAssertEqual(PanelBlockKind.billing.defaultPeriod(tokens: .month), .month, "a balance follows the token chart")

        let json = #"{"blocks":{"Claude":{"period":"week","widget":"chart"}}}"#
        let layout = PanelLayout(blocks: ["Claude": PanelLayout.Block(widget: .chart, period: .week)])
        XCTAssertEqual(try JSONDecoder().decode(PanelLayout.self, from: Data(json.utf8)), layout)
        XCTAssertEqual(String(decoding: try RecordCoding.encoder().encode(layout), as: UTF8.self), json)
        let stored = try JSONDecoder().decode(PanelLayout.self, from: Data(#"{"blocks":{"Claude":{"widget":"chart","period":"year"}}}"#.utf8))
        XCTAssertNil(stored.blocks["Claude"]?.period, "a period this build does not know is not given")
        XCTAssertTrue(PanelLayout(blocks: ["Codex": PanelLayout.Block(period: .day)]).blocks["Codex"]?.isEmpty == false)
    }

    func testAPeriodWhereTheBlockDrawsNoChartIsAnIssue() {
        func issues(_ key: String, _ block: PanelLayout.Block) -> [PanelLayoutIssue] {
            PanelLayout(blocks: [key: block]).issues(against: blocks)
        }
        XCTAssertEqual(issues("Claude", PanelLayout.Block(period: .week)), [
            PanelLayoutIssue(path: "blocks.Claude.period",
                             message: #"The "bar" widget of "Claude" draws no chart. period applies to the "chart" widget, whose bars cover it, and to API balances, whose estimated cost, burn rate and chart cover it."#),
        ])
        for widget in [PanelWidget.ring, .number] {
            XCTAssertEqual(issues("Codex", PanelLayout.Block(widget: widget, period: .day)).map(\.path), ["blocks.Codex.period"],
                           "even the default, which the agent believes was heeded")
        }
        XCTAssertEqual(issues("Claude", PanelLayout.Block(widget: .chart, period: .month)), [])
        XCTAssertEqual(issues("api:DeepSeek", PanelLayout.Block(period: .week)), [])
        XCTAssertEqual(issues("api:DeepSeek", PanelLayout.Block(widget: .chart, period: .month)), [])
    }

    /// A chart's day and a balance's token chart period are what they cover anyway; a balance's own period where the
    /// token chart starts from another draws.
    func testAPeriodABlockCoversAnywayIsLeftOut() {
        let layout = PanelLayout(blocks: ["Claude": PanelLayout.Block(widget: .chart, period: .day),
                                          "Codex": PanelLayout.Block(widget: .chart, period: .week),
                                          "api:DeepSeek": PanelLayout.Block(period: .week)],
                                 tokens: PanelLayout.Tokens(period: .week))
        let reduced = PanelLayout(blocks: ["Claude": PanelLayout.Block(widget: .chart), "Codex": PanelLayout.Block(widget: .chart, period: .week)],
                                  tokens: PanelLayout.Tokens(period: .week))
        XCTAssertEqual(layout.reduced(against: blocks), reduced)
        XCTAssertEqual(PanelLayoutPlan(layout: reduced, blocks: blocks), PanelLayoutPlan(layout: layout, blocks: blocks))
        let day = PanelLayout(blocks: ["api:DeepSeek": PanelLayout.Block(period: .day)], tokens: PanelLayout.Tokens(period: .month))
        XCTAssertEqual(day.reduced(against: blocks), day)
        XCTAssertEqual(PanelLayout(blocks: ["Claude": PanelLayout.Block(period: .month)]).reduced(against: blocks), PanelLayout(),
                       "a stored period on bars draws nothing")
    }

    func testThePlanGivesEachBlockThePeriodItCovers() {
        let layout = PanelLayout(blocks: ["Claude": PanelLayout.Block(widget: .chart),
                                          "Codex": PanelLayout.Block(widget: .chart, span: .half, period: .month)],
                                 tokens: PanelLayout.Tokens(period: .week))
        let plan = PanelLayoutPlan(layout: layout, blocks: blocks)
        XCTAssertEqual(plan.blocks.map(\.period), [.day, .month, .week], "a chart's day, its own month, the token chart's week")
        XCTAssertEqual(plan.lines.flatMap { $0 }.map(\.period), [.day, .month, .week], "kept as the blocks are set in lines")
        let own = PanelLayout(blocks: ["api:DeepSeek": PanelLayout.Block(period: .day)], tokens: PanelLayout.Tokens(period: .week))
        XCTAssertEqual(PanelLayoutPlan(layout: own, blocks: blocks).blocks.last?.period, .day)
        XCTAssertEqual(PanelLayoutPlan(layout: PanelLayout(blocks: ["Claude": PanelLayout.Block(period: .month)]), blocks: blocks)
            .blocks.first?.period, .day, "bars cover none")
    }
}
