import AppKit
import SwiftUI
import XCTest
@testable import AgentHUDCore
@testable import AgentHUDDesktop

/// The hover panel under a layout's sessions and tokens: which rows the session section lists, what it says when the
/// filter keeps none, and the token chart's height in every period its picker offers, measured as the island measures
/// the panel: a fresh view tree at the panel's width.
@MainActor
final class PanelFiltersViewTests: XCTestCase {
    /// The sample's store over settings of its own, made when a test first reaches for either: two sessions running and
    /// six ended in the last day.
    private lazy var store: UsageStore = makeStore()
    private var settings: SettingsStore { store.settings }
    private var layout: PanelLayoutStore { settings.panelLayout }

    override func setUp() {
        super.setUp()
        L10n.setLanguage(.en)
    }

    override func tearDown() {
        L10n.setLanguage(.system)
        super.tearDown()
    }

    private func makeStore(sessions: Bool = true) -> UsageStore {
        _ = NSApplication.shared
        let suite = "app.agenthud.tests.panel-filters-view.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!, defaultAgents: DemoData.agents)
        let store = UsageStore(provider: DemoUsageProvider(), settings: settings, clock: { DemoClock.now })
        let sample = DemoUsageProvider.report(agents: settings.agents, historyHours: UsageStore.historyHours, now: DemoClock.now,
                                              stage: nil)
        store.replace(report: sessions ? sample : UsageReport(generatedAt: sample.generatedAt, snapshots: sample.snapshots,
                                                              sessions: [], consumers: sample.consumers, usage: sample.usage))
        return store
    }

    /// The saved layout becomes `layout`.
    private func keep(_ proposal: PanelLayout, in store: UsageStore? = nil) {
        let layout = (store ?? self.store).settings.panelLayout
        layout.propose(proposal)
        layout.save()
    }

    private func height(of store: UsageStore? = nil, vendor: String? = nil) -> CGFloat {
        let store = store ?? self.store
        let width = vendor == nil ? IslandController.expandedWidth : IslandController.agentPanelWidth
        return NSHostingView(rootView: HoverPanelView(store: store, onOpenStats: {}, focusVendor: vendor).frame(width: width))
            .fittingSize.height
    }

    private var plan: PanelLayoutPlan { PanelLayoutPlan(layout: layout.effective, blocks: store.view.panelBlocks) }

    // MARK: Sessions

    func testTheRowsFollowTheLayoutsLimitAndFilter() {
        let five = height()
        XCTAssertEqual(HoverPanelView.sessionRows(store, filter: plan.sessions).shown.count, 5)

        keep(PanelLayout(sessions: PanelLayout.Sessions(limit: 3)))
        let rows = HoverPanelView.sessionRows(store, filter: plan.sessions)
        XCTAssertEqual(rows.shown.map(\.id), ["s1", "s2", "s4"])
        XCTAssertEqual(rows.more, 5, "+5 more counts the rest")
        let three = height()
        XCTAssertLessThan(three, five - 20)

        keep(PanelLayout(sessions: PanelLayout.Sessions(limit: 10)))
        XCTAssertEqual(HoverPanelView.sessionRows(store, filter: plan.sessions).shown.count, 8)
        XCTAssertEqual(HoverPanelView.sessionRows(store, filter: plan.sessions).more, 0)
        // Three more rows, and the "+3 more" line gone.
        XCTAssertGreaterThan(height(), five + 20)

        keep(PanelLayout(sessions: PanelLayout.Sessions(states: [.running])))
        let running = HoverPanelView.sessionRows(store, filter: plan.sessions)
        XCTAssertEqual(running.shown.map(\.id), ["s1", "s2"])
        XCTAssertEqual(HoverPanelView.sessionStatus(running), "2 running")
        keep(PanelLayout(sessions: PanelLayout.Sessions(limit: 3, agents: ["Codex"], states: [.ended])))
        let codex = HoverPanelView.sessionRows(store, filter: plan.sessions)
        XCTAssertEqual(codex.shown.map(\.id), ["s4", "s7"])
        XCTAssertTrue(codex.running.isEmpty)
        XCTAssertEqual(HoverPanelView.sessionStatus(codex), "Recently ended", "the rows it lists have all ended")
    }

    /// A filter that keeps none of the day's sessions says so in one line under the header, as a day without sessions
    /// says it has none: the section is as tall either way. The header then says no state, since the sessions running
    /// now are ones the filter leaves out; a day without sessions keeps its Recently ended.
    func testAFilterThatKeepsNoneSaysSoInOneLine() {
        let onlySessions = PanelLayout(hiddenSections: [.blocks, .tokens])
        keep(PanelLayout(hiddenSections: [.blocks, .tokens], sessions: PanelLayout.Sessions(agents: ["Grok CLI"])))
        let rows = HoverPanelView.sessionRows(store, filter: plan.sessions)
        XCTAssertTrue(rows.shown.isEmpty)
        XCTAssertEqual(HoverPanelView.emptySessionsLine(rows), "No sessions match")
        XCTAssertEqual(HoverPanelView.sessionRows(store).running.count, 2, "two sessions run outside the filter")
        XCTAssertNil(HoverPanelView.sessionStatus(rows), "not Recently ended while two run")
        let matchingNone = height()

        let empty = makeStore(sessions: false)
        keep(onlySessions, in: empty)
        let none = HoverPanelView.sessionRows(empty)
        XCTAssertEqual(HoverPanelView.emptySessionsLine(none), "No sessions yet")
        XCTAssertEqual(HoverPanelView.sessionStatus(none), "Recently ended")
        XCTAssertEqual(height(of: empty), matchingNone, accuracy: 0.5, "the header keeps its height without a status")

        L10n.setLanguage(.zhHans)
        XCTAssertEqual(HoverPanelView.emptySessionsLine(rows), "没有符合条件的会话")
    }

    /// An agent's own panel on a dock that separates its agents lists its agent's sessions under the layout's filter.
    func testAnAgentsOwnPanelAppliesItsAgentAndTheLayout() {
        keep(PanelLayout(sessions: PanelLayout.Sessions(limit: 2, states: [.ended])))
        XCTAssertEqual(HoverPanelView.sessionRows(store, vendor: "Claude", filter: plan.sessions).shown.map(\.id), ["s3", "s5"])
        let narrowed = height(vendor: "Claude")
        keep(PanelLayout(sessions: PanelLayout.Sessions(agents: ["Codex"])))
        let other = HoverPanelView.sessionRows(store, vendor: "Claude", filter: plan.sessions)
        XCTAssertTrue(other.noneMatch)
        XCTAssertLessThan(height(vendor: "Claude"), narrowed - 10, "one line in place of two rows and +1 more")

        keep(PanelLayout(tokens: PanelLayout.Tokens(agents: ["Codex"])))
        XCTAssertEqual(store.panelTokenConsumers(plan.tokens, vendor: "Claude"), [], "Claude's panel charts no Codex model")
        XCTAssertEqual(store.panelTokenConsumers(plan.tokens, vendor: "Codex"),
                       Set(store.consumers.filter { $0.vendor == "Codex" }.map(\.id)))
    }

    // MARK: Tokens

    /// The picker flips the period in place and the island is sized from the period the layout opens with, so the panel
    /// is as tall in every period, with or without a filter, and on an agent's own panel.
    func testThePanelIsAsTallInEveryPeriod() {
        for tokens in [PanelLayout.Tokens(), PanelLayout.Tokens(agents: ["Codex"])] {
            for vendor in [nil, "Claude"] as [String?] {
                let heights = PanelTokenPeriod.allCases.map { period -> CGFloat in
                    keep(PanelLayout(tokens: PanelLayout.Tokens(period: period, agents: tokens.agents)))
                    return height(vendor: vendor)
                }
                XCTAssertEqual(heights.max() ?? 0, heights.min() ?? 1, accuracy: 0.5, "\(tokens) \(vendor ?? "all") \(heights)")
            }
        }
        // The chart alone, as its picker starts it.
        let width = IslandController.expandedWidth - HoverPanelView.notchInsets.leading - HoverPanelView.notchInsets.trailing
        let charts = PanelTokenPeriod.allCases.map { period in
            NSHostingView(rootView: TokenConsumptionChart(store: store, theme: .island, context: .island, period: period,
                                                          compact: true).frame(width: width)).fittingSize.height
        }
        XCTAssertEqual(charts.max() ?? 0, charts.min() ?? 1, accuracy: 0.5, "\(charts)")
    }

    /// The picker reaches past the line it stands on: the header is as tall as its text.
    func testThePickerKeepsTheHeadersHeight() {
        func header(_ picker: Bool) -> CGFloat {
            let row = HStack(alignment: .firstTextBaseline) {
                Text("Tokens").font(.ui(13, .semibold))
                Spacer()
                if picker { TokenPeriodPicker(selection: .constant(.week)) }
                Text("7d · 1.2M tok").font(.tabular(12))
            }
            return NSHostingView(rootView: row.frame(width: 500)).fittingSize.height
        }
        XCTAssertEqual(header(true), header(false), accuracy: 0.5)
    }

    /// The chart is handed its models on every pass, so a model of an agent the layout names, or of the agent whose own
    /// panel it is, that starts spending tokens while the panel is open is drawn with the next report, as a panel opened
    /// then draws it, rather than when the panel next opens.
    func testAnOpenChartDrawsAModelThatJoinsWhileItIsOpen() async throws {
        let sample = try XCTUnwrap(store.report)
        let claude = sample.consumers.filter { VendorMark.key($0.displayVendor) == VendorMark.key("Claude") }
        let late = try XCTUnwrap(claude.max { lhs, rhs in
            store.hudTokenColumns(consumerIDs: [lhs.id]).reduce(0) { $0 + $1.total }
                < store.hudTokenColumns(consumerIDs: [rhs.id]).reduce(0) { $0 + $1.total }
        })
        XCTAssertGreaterThan(store.hudTokenColumns(consumerIDs: [late.id]).reduce(0) { $0 + $1.total }, 0)
        let before = UsageReport(generatedAt: sample.generatedAt, snapshots: sample.snapshots, sessions: sample.sessions,
                                 consumers: sample.consumers.filter { $0.id != late.id }, usage: sample.usage)
        // The whole panel charting Claude's models, and Claude's own panel, each with the chart alone.
        for (tokens, vendor) in [(["Claude"], nil), ([], "Claude")] as [([String], String?)] {
            store.replace(report: before)
            keep(PanelLayout(hiddenSections: [.blocks, .sessions], tokens: PanelLayout.Tokens(agents: tokens)))
            let size = CGSize(width: vendor == nil ? IslandController.expandedWidth : IslandController.agentPanelWidth,
                              height: height(vendor: vendor))
            func host() -> NSHostingView<HoverPanelView> {
                let view = NSHostingView(rootView: HoverPanelView(store: store, onOpenStats: {}, focusVendor: vendor))
                view.appearance = NSAppearance(named: .darkAqua)
                view.frame = CGRect(origin: .zero, size: size)
                return view
            }
            let open = host()
            let opened = pixels(open)
            store.replace(report: sample)
            // The island hands its panel the store again on the next pass, and the chart keeps its identity.
            open.rootView = HoverPanelView(store: store, onOpenStats: {}, focusVendor: vendor)
            let fresh = pixels(host())
            XCTAssertNotEqual(opened, fresh, "\(vendor ?? "all"): the model that joined draws something")
            let deadline = Date().addingTimeInterval(5)
            while pixels(open) != fresh {
                guard Date() < deadline else {
                    XCTFail("\(vendor ?? "all"): the open chart still leaves out the model that joined")
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    /// What a view draws, pixel by pixel.
    private func pixels(_ view: NSView) -> Data? {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap.bitmapData.map { Data(bytes: $0, count: bitmap.bytesPerRow * bitmap.pixelsHigh) }
    }

    func testTheHeaderSaysThePeriod() {
        let columns = store.hudTokenColumns(consumerIDs: nil, period: .week)
        let total = TokenFormat.short(columns.reduce(0) { $0 + $1.total })
        XCTAssertEqual(TokenConsumptionChart.total(columns, period: .week), "7d · \(total) tok")
        XCTAssertEqual(TokenConsumptionChart.total(nil, period: .month), "30d · —")
        XCTAssertEqual(TokenConsumptionChart.total(nil), "24h · —", "the quota block's chart stays a day")
        XCTAssertEqual(PanelTokenPeriod.allCases.map(\.spokenLabel), ["Last 24 hours", "Last 7 days", "Last 30 days"])
    }
}
