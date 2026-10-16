import AppKit
import SwiftUI
import XCTest
@testable import AgentHUDCore
@testable import AgentHUDDesktop

/// The hover panel under a layout: what a layout changes about the panel's natural height, which is what the island is
/// sized from, and what the cost measure reads.
@MainActor
final class PanelLayoutViewTests: XCTestCase {
    /// The sample's store over settings of its own, made when a test first reaches for either.
    private lazy var store: UsageStore = {
        _ = NSApplication.shared
        let suite = "app.agenthud.tests.panel-layout-view.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!, defaultAgents: DemoData.agents)
        let store = UsageStore(provider: DemoUsageProvider(), settings: settings, clock: { DemoClock.now })
        store.replace(report: DemoUsageProvider.report(agents: settings.agents, historyHours: UsageStore.historyHours, now: DemoClock.now))
        return store
    }()
    private var settings: SettingsStore { store.settings }

    override func setUp() {
        super.setUp()
        L10n.setLanguage(.en)
    }

    override func tearDown() {
        L10n.setLanguage(.system)
        super.tearDown()
    }

    private var layout: PanelLayoutStore { settings.panelLayout }
    private var quotaKeys: [String] { store.view.panelBlocks.filter { $0.kind == .quota }.map(\.key) }

    /// The panel's natural height, as the island measures it: a fresh view tree at the panel's width.
    private func height() -> CGFloat {
        NSHostingView(rootView: HoverPanelView(store: store, onOpenStats: {}).frame(width: IslandController.expandedWidth))
            .fittingSize.height
    }

    /// Every quota block drawn with `widget`, its picker offering every measure the widget offers with `measure` first.
    private func every(_ widget: PanelWidget, first measure: PanelMeasure? = nil) -> PanelLayout {
        let offered = PanelBlockKind.quota.measures(under: widget)
        let measures: [PanelMeasure] = measure.map { first in [first] + offered.filter { $0 != first } } ?? []
        return PanelLayout(blocks: Dictionary(uniqueKeysWithValues: quotaKeys.map {
            ($0, PanelLayout.Block(widget: widget, measures: measures))
        }))
    }

    /// The saved layout becomes `layout`, whatever was saved before.
    private func keep(_ proposal: PanelLayout) {
        layout.propose(proposal)
        layout.save()
        XCTAssertFalse(layout.hasDraft)
    }

    func testTheSampleHasQuotaBlocksToArrange() {
        XCTAssertGreaterThanOrEqual(quotaKeys.count, 2)
        XCTAssertGreaterThan(height(), 200)
    }

    /// The picker flips a block's measure in place and the island is sized from the measure shown first, so a widget
    /// must be as tall in every measure it offers.
    func testAWidgetIsAsTallInEveryMeasure() {
        for widget in PanelBlockKind.quota.widgets {
            let heights = PanelBlockKind.quota.measures(under: widget).map { measure -> CGFloat in
                keep(every(widget, first: measure))
                return height()
            }
            XCTAssertEqual(heights.max() ?? 0, heights.min() ?? 1, accuracy: 0.5, "\(widget) \(heights)")
        }
    }

    func testTheDefaultLayoutIsTheBarsAndAResetReturnsToIt() {
        let bars = height()
        keep(every(.bar))
        XCTAssertEqual(height(), bars, accuracy: 0.5, "bars are the default view of a quota block")
        keep(every(.number, first: .cost))
        XCTAssertFalse(layout.current.isDefault)
        layout.reset()
        XCTAssertEqual(height(), bars, accuracy: 0.5)
        XCTAssertTrue(layout.canRevert)
    }

    func testHidingABlockARowOrASectionShortensThePanelAndOrderDoesNot() throws {
        let full = height()
        let first = try XCTUnwrap(quotaKeys.first), last = try XCTUnwrap(quotaKeys.last)
        keep(PanelLayout(order: [last]))
        XCTAssertEqual(height(), full, accuracy: 0.5, "another order is the same blocks")

        keep(PanelLayout(blocks: [first: PanelLayout.Block(hidden: true)]))
        let withoutBlock = height()
        XCTAssertLessThan(withoutBlock, full - 20)

        let rows = try XCTUnwrap(store.view.panelBlocks.first { $0.key == first }).rowKeys
        XCTAssertGreaterThan(rows.count, 1)
        keep(PanelLayout(blocks: [first: PanelLayout.Block(hiddenRows: [rows[0]])]))
        let withoutRow = height()
        XCTAssertLessThan(withoutRow, full - 10)
        XCTAssertGreaterThan(withoutRow, withoutBlock)

        keep(PanelLayout(hiddenSections: [.tokens]))
        XCTAssertLessThan(height(), full - 20)
        keep(PanelLayout(hiddenSections: [.blocks, .tokens, .sessions]))
        XCTAssertLessThan(height(), 120, "only the footer is left")
    }

    /// One agent's own panel, on a dock that separates its agents, says whose it is: its quota block names the agent,
    /// and where none is drawn the panel's title does, whether a Settings switch or the layout took the block away.
    func testAnAgentsOwnPanelSaysWhoseItIsWhateverTheLayoutHides() {
        func own() -> CGFloat {
            NSHostingView(rootView: HoverPanelView(store: store, onOpenStats: {}, focusVendor: "Claude")
                .frame(width: IslandController.agentPanelWidth)).fittingSize.height
        }
        let whole = own()
        settings.update { $0.showIslandQuota = false }
        let titled = own()
        XCTAssertLessThan(titled, whole - 20)
        settings.update { $0.showIslandQuota = true }
        XCTAssertEqual(own(), whole, accuracy: 0.5)

        keep(PanelLayout(hiddenSections: [.blocks]))
        XCTAssertEqual(own(), titled, accuracy: 0.5, "the section hidden by the layout leaves the title, as the switch does")
        keep(PanelLayout(blocks: ["Claude": PanelLayout.Block(hidden: true)]))
        XCTAssertEqual(own(), titled, accuracy: 0.5, "and so does the hidden block")
        // Sessions first with the quota block still drawn below: no title, so nothing stands above the sessions and
        // they start the panel without a divider. The same sections in another order are as tall.
        keep(PanelLayout(sections: [.sessions, .tokens, .blocks]))
        XCTAssertEqual(own(), whole, accuracy: 0.5)
    }

    // MARK: Balances

    private let balanceTime = Date(timeIntervalSince1970: 1_800_000_000)

    private func balance(_ vendor: String, pool: BillingPool? = nil) -> APIBilling {
        APIBilling(vendor: vendor, balances: [AccountBalance(currency: "CNY", total: 20, granted: 0, toppedUp: 20)],
                   isAvailable: true, updatedAt: balanceTime, notice: nil, billingPool: pool)
    }

    /// A panel of API balances and nothing else, over a suite of its own: `pools` accounts of one provider, and
    /// DeepSeek's where asked. Returns its height and each card's own.
    private func balances(pools names: [String], deepseek: Bool) throws -> (panel: CGFloat, cards: [CGFloat]) {
        let now = balanceTime
        let own = "app.agenthud.tests.panel-layout-balances.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: own))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: own) }
        let pools = names.map {
            BillingPool(provider: "Moonshot", realm: "CN", product: .api, scope: $0, evidence: .credential, entitlement: "api")
        }
        var agents = pools.map {
            AgentDescriptor(id: $0.windowID("kimi-k3"), vendor: "Kimi", model: "K3", source: "", enabled: true, billingPool: $0)
        }
        var billing = pools.map { balance("Kimi", pool: $0) }
        if deepseek {
            agents.append(AgentDescriptor(id: "deepseek", vendor: "DeepSeek", model: "API", source: "", enabled: true))
            billing.append(balance("DeepSeek"))
        }
        let settings = SettingsStore(defaults: defaults, defaultAgents: agents)
        settings.update { $0.showIslandTokens = false; $0.showIslandSessions = false }
        let store = UsageStore(provider: DemoUsageProvider(), settings: settings, clock: { now })
        store.replace(report: UsageReport(generatedAt: now, snapshots: [], sessions: [], billing: billing))
        XCTAssertEqual(store.enabledBilling.count, billing.count)
        XCTAssertTrue(settings.panelLayout.current.isDefault)
        let width = IslandController.expandedWidth
        let insets = HoverPanelView.notchInsets
        let cards = store.enabledBilling.map { account in
            NSHostingView(rootView: APIBillingCard(billing: account, store: store, theme: .island, compact: true)
                .frame(width: width - insets.leading - insets.trailing)).fittingSize.height
        }
        return (NSHostingView(rootView: HoverPanelView(store: store, onOpenStats: {}).frame(width: width)).fittingSize.height, cards)
    }

    /// In the default view every API account's card stands under its own divider with 8 pt above it, the first one
    /// too and with or without a quota block before it, 10 pt from the card above: the panel as it was drawn before
    /// there were layouts, for which the heights here are 90, 160 and 240 pt.
    func testEveryBalanceCardKeepsItsOwnDividerAndRoomInTheDefaultView() throws {
        let none = try balances(pools: [], deepseek: false)
        XCTAssertEqual(none.cards, [])
        let one = try balances(pools: ["first"], deepseek: false)
        let card = try XCTUnwrap(one.cards.first)
        XCTAssertGreaterThan(card, 30)
        XCTAssertEqual(one.panel, none.panel + card + 8, accuracy: 0.5, "a first card, with nothing above it")
        let alone = try balances(pools: [], deepseek: true)
        let aloneCard = try XCTUnwrap(alone.cards.first)
        XCTAssertEqual(alone.panel, none.panel + aloneCard + 8, accuracy: 0.5)

        // Two cards: each with its 8 pt, and 10 pt between them.
        func room(_ cards: [CGFloat]) -> CGFloat {
            var room: CGFloat = 10
            for card in cards { room += card + 8 }
            return room
        }
        let twoOfOneProvider = try balances(pools: ["first", "second"], deepseek: false)
        XCTAssertEqual(twoOfOneProvider.cards.count, 2)
        XCTAssertEqual(twoOfOneProvider.panel, none.panel + room(twoOfOneProvider.cards), accuracy: 0.5,
                       "accounts of one provider share a block, and each keeps its divider")
        let twoProviders = try balances(pools: ["first"], deepseek: true)
        XCTAssertEqual(twoProviders.cards.count, 2)
        XCTAssertEqual(twoProviders.panel, none.panel + room(twoProviders.cards), accuracy: 0.5)

        // After quota blocks, in the sample: hiding the balance takes its card, its 8 pt and the 10 pt before it.
        let full = height()
        let account = try XCTUnwrap(store.enabledBilling.first)
        let inSample = NSHostingView(rootView: APIBillingCard(billing: account, store: store, theme: .island, compact: true)
            .frame(width: IslandController.expandedWidth - HoverPanelView.notchInsets.leading - HoverPanelView.notchInsets.trailing))
            .fittingSize.height
        keep(PanelLayout(blocks: [account.panelBlockKey: PanelLayout.Block(hidden: true)]))
        XCTAssertEqual(height(), full - inSample - 18, accuracy: 0.5)
    }

    // MARK: Widgets

    private func insights(burning rate: Double) -> UsageInsights {
        UsageInsights(burnRatePctPerHour: rate, timeToExhaust: 1800, weeklyCapHits: 0, weeklyWaitTotal: 0, weeklyWaitLongest: 0,
                      weeklyWaitLongestAt: nil)
    }

    /// A bar row is one line in every measure whatever it reads: a value wider than its column takes room from the
    /// bar and does not wrap, so the rule that a widget is as tall in every measure holds for a window that burns at
    /// 100 %/h and more.
    func testABarRowIsAsTallWhenItsValueIsWiderThanItsColumn() throws {
        let row = try XCTUnwrap(store.rows.first { $0.agent.windowKey == "claude-session" })
        XCTAssertTrue(row.assessment.showsLevel)
        func tall(_ measure: PanelMeasure, burning rate: Double, cost: QuotaListCost? = nil) -> CGFloat {
            let view = ModelUsageRow(row: row, now: store.now, metric: measure, showReset: true, showVendor: false,
                                     insights: insights(burning: rate), outlook: nil, tokensPerHour: 1000, cost: cost)
            return NSHostingView(rootView: view.frame(width: 504)).fittingSize.height
        }
        let fast = QuotaRowMetrics(row: row, insights: insights(burning: 120), outlook: nil, now: store.now, tokensPerHour: 1000)
        XCTAssertEqual(fast.value(.burnRate), "120.0%/h")
        let quota = tall(.quota, burning: 12)
        XCTAssertEqual(tall(.burnRate, burning: 12), quota, accuracy: 0.5)
        XCTAssertEqual(tall(.burnRate, burning: 120), quota, accuracy: 0.5, "100.0%/h and up is wider than the value's 62 pt")
        XCTAssertEqual(tall(.burnRate, burning: 1234.5), quota, accuracy: 0.5)
        XCTAssertEqual(tall(.cost, burning: 12, cost: QuotaListCost(amounts: ["USD": 123_456], hours: 100)), quota, accuracy: 0.5)
    }

    /// A ring shows the share used whatever the measure, so a ring cell says it first in every measure; a number cell
    /// shows the selected measure alone.
    func testARingCellSaysTheShareItShowsInEveryMeasure() throws {
        let row = try XCTUnwrap(store.rows.first { $0.agent.windowKey == "claude-session" })
        let share = try XCTUnwrap(row.usedPct.map(TokenFormat.percent))
        let metrics = QuotaRowMetrics(row: row, insights: insights(burning: 1.4), outlook: nil, now: store.now, tokensPerHour: 1000)
        func spoken(_ style: QuotaCell.Style, _ measure: PanelMeasure) -> String {
            QuotaCell(row: row, metrics: metrics, metric: measure, style: style, showReset: false).spokenValue
        }
        XCTAssertEqual(spoken(.ring, .quota), share, "once, not twice")
        XCTAssertEqual(spoken(.ring, .burnRate), "\(share), 1.4%/h, —")
        XCTAssertEqual(spoken(.ring, .tokens), "\(share), 1.0k/h, 24k / day")
        XCTAssertEqual(spoken(.number, .tokens), "1.0k/h, 24k / day")
        XCTAssertEqual(spoken(.number, .quota), share)
        for measure in PanelMeasure.allCases {
            XCTAssertTrue(spoken(.ring, measure).hasPrefix(share), "\(measure)")
        }
    }

    /// The layout hides and orders what the Settings switches leave: a section a switch turned off stays off.
    func testASettingsSwitchStillDecidesWhatExists() {
        settings.update { $0.showIslandTokens = false }
        let withoutTokens = height()
        keep(PanelLayout(sections: [.tokens, .blocks, .sessions]))
        XCTAssertEqual(height(), withoutTokens, accuracy: 0.5)
    }

    /// An unsaved draft is drawn at once, with the bar that says so above the footer; saving or discarding it takes
    /// the bar away.
    func testADraftIsDrawnWithItsBarUntilItIsSavedOrDiscarded() throws {
        let bars = height()
        keep(every(.ring))
        let rings = height()
        layout.reset()
        XCTAssertEqual(height(), bars, accuracy: 0.5)

        XCTAssertTrue(layout.propose(every(.ring)))
        let draft = height()
        XCTAssertGreaterThan(draft, rings + 20, "the draft's rings and the bar that says it is unsaved")
        layout.discard()
        XCTAssertEqual(height(), bars, accuracy: 0.5)

        layout.propose(every(.ring))
        layout.save()
        XCTAssertEqual(height(), rings, accuracy: 0.5)
    }

    /// The cost measure of a window that counts a priced model is the list price of its cycle so far and the pace per
    /// hour; a row asks for it only while the measure is shown.
    func testTheCostMeasureReadsTheCyclesListPrice() throws {
        let row = try XCTUnwrap(store.rows.first { store.view.listCost(for: $0.id) != nil }, "the sample has a priced window")
        let cost = try XCTUnwrap(store.view.listCost(for: row.id))
        let currency = try XCTUnwrap(cost.currencies.first)
        let metrics = QuotaRowMetrics(row: row, insights: nil, outlook: nil, now: store.now, tokensPerHour: nil, cost: cost)
        XCTAssertEqual(metrics.value(.cost), MoneyFormat.short(try XCTUnwrap(cost.amounts[currency]), currency: currency))
        if cost.currencies.count == 1 {
            XCTAssertEqual(metrics.detail(.cost, isLoading: false),
                           MoneyFormat.short(try XCTUnwrap(cost.perHour(currency)), currency: currency) + "/h")
        }
        let without = QuotaRowMetrics(row: row, insights: nil, outlook: nil, now: store.now, tokensPerHour: nil)
        XCTAssertNil(without.value(.cost))
        XCTAssertEqual(without.detail(.cost, isLoading: false), "—")
    }

    func testEveryMeasureHasALabelAndASymbolForThePicker() {
        XCTAssertEqual(Set(PanelMeasure.allCases.map(\.symbol)).count, PanelMeasure.allCases.count)
        XCTAssertFalse(PanelMeasure.allCases.contains { $0.label.isEmpty })
    }
}
