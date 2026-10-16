import AppKit
import SwiftUI
import XCTest
@testable import AgentHUDCore
@testable import AgentHUDDesktop

/// The hover panel under the options a layout sets beside its widgets: the spacing, the separators, a block's
/// measures and its countdown. Measured as the island measures the panel, from a fresh view tree at its width.
@MainActor
final class PanelStyleViewTests: XCTestCase {
    /// The sample's store over settings of its own, made when a test first reaches for either.
    private lazy var store: UsageStore = {
        _ = NSApplication.shared
        let suite = "app.agenthud.tests.panel-style-view.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!, defaultAgents: DemoData.agents)
        let store = UsageStore(provider: DemoUsageProvider(), settings: settings, clock: { DemoClock.now })
        store.replace(report: DemoUsageProvider.report(agents: settings.agents, historyHours: UsageStore.historyHours, now: DemoClock.now))
        return store
    }()
    private var settings: SettingsStore { store.settings }
    private var layout: PanelLayoutStore { settings.panelLayout }
    private var quotaKeys: [String] { store.view.panelBlocks.filter { $0.kind == .quota }.map(\.key) }

    override func setUp() {
        super.setUp()
        L10n.setLanguage(.en)
    }

    override func tearDown() {
        L10n.setLanguage(.system)
        super.tearDown()
    }

    /// The panel's natural height, as the island measures it: a fresh view tree at the panel's width.
    private func height() -> CGFloat {
        NSHostingView(rootView: HoverPanelView(store: store, onOpenStats: {}).frame(width: IslandController.expandedWidth))
            .fittingSize.height
    }

    /// The saved layout becomes `layout`, whatever was saved before.
    private func keep(_ proposal: PanelLayout) {
        layout.propose(proposal)
        layout.save()
        XCTAssertFalse(layout.hasDraft)
    }

    /// Every quota block changed alike, with `style` for the whole panel.
    private func every(_ block: PanelLayout.Block, style: PanelStyle = PanelStyle()) -> PanelLayout {
        PanelLayout(blocks: Dictionary(uniqueKeysWithValues: quotaKeys.map { ($0, block) }), style: style)
    }

    // MARK: Spacing

    private func gaps(_ metrics: PanelSpacingMetrics) -> [CGFloat] {
        [metrics.sections, metrics.blocks, metrics.divided, metrics.blockParts, metrics.rowPadding, metrics.cellLines,
         metrics.cellPadding, metrics.chartTop, metrics.sessionRows]
    }

    /// Regular is the panel as the default view draws it: the content's 10 pt, 8 pt above a divider, a block's 8 pt, a
    /// bar row's 4 pt, the cells' 10 pt and 2 pt, a chart's 4 pt and the sessions' 6 pt.
    func testRegularIsTheDefaultViewsSpacing() {
        XCTAssertEqual(gaps(PanelSpacingMetrics(.regular)), [10, 10, 8, 8, 4, 10, 2, 4, 6])
        XCTAssertEqual(PanelSpacingMetrics(.regular), EnvironmentValues().panelSpacing, "what a view outside the panel is given")
    }

    func testCompactAndRoomyAreAboutSixAndFourteenTenthsOfEachGap() {
        let regular = gaps(PanelSpacingMetrics(.regular))
        XCTAssertEqual(gaps(PanelSpacingMetrics(.compact)), regular.map { ($0 * 0.6).rounded() })
        XCTAssertEqual(gaps(PanelSpacingMetrics(.roomy)), regular.map { ($0 * 1.4).rounded() })
    }

    /// Compact draws every widget shorter and roomy taller, while the footer and the draft bar keep their room.
    func testSpacingMovesTheGapsAndLeavesTheFooterAndTheDraftBar() {
        for widget in PanelBlockKind.quota.widgets {
            let heights = PanelSpacing.allCases.map { spacing -> CGFloat in
                keep(every(PanelLayout.Block(widget: widget), style: PanelStyle(spacing: spacing)))
                return height()
            }
            XCTAssertLessThan(heights[0], heights[1] - 20, "\(widget): compact \(heights)")
            XCTAssertLessThan(heights[1], heights[2] - 20, "\(widget): roomy \(heights)")
        }
        let footers = PanelSpacing.allCases.map { spacing -> CGFloat in
            keep(PanelLayout(hiddenSections: PanelSection.allCases, style: PanelStyle(spacing: spacing)))
            return height()
        }
        XCTAssertEqual(footers.max() ?? 0, footers.min() ?? 1, accuracy: 0.5, "only the footer is left: \(footers)")

        // The draft bar adds the same room at every spacing.
        let bars = PanelSpacing.allCases.map { spacing -> CGFloat in
            layout.reset()
            layout.propose(PanelLayout(hiddenSections: PanelSection.allCases, style: PanelStyle(spacing: spacing)))
            XCTAssertTrue(layout.hasDraft)
            let drafted = height()
            layout.save()
            return drafted - height()
        }
        XCTAssertEqual(bars.max() ?? 0, bars.min() ?? 1, accuracy: 0.5, "\(bars)")
        XCTAssertGreaterThan(bars[0], 20)
    }

    /// A bar row's type is the same at every spacing: the row moves by its padding alone.
    func testABarRowChangesOnlyByItsPadding() throws {
        let row = try XCTUnwrap(store.rows.first { $0.agent.windowKey == "claude-session" })
        func tall(_ spacing: PanelSpacing) -> CGFloat {
            let view = ModelUsageRow(row: row, now: store.now, showReset: true, showVendor: false)
                .environment(\.panelSpacing, PanelSpacingMetrics(spacing))
            return NSHostingView(rootView: view.frame(width: 504)).fittingSize.height
        }
        let regular = tall(.regular)
        for spacing in PanelSpacing.allCases {
            let padding = 2 * (PanelSpacingMetrics(spacing).rowPadding - PanelSpacingMetrics(.regular).rowPadding)
            XCTAssertEqual(tall(spacing), regular + padding, accuracy: 0.5, "\(spacing)")
        }
    }

    /// A balance's card is a block too: its heading stands from its rows by the spacing's gap, as a quota block's does,
    /// and outside the panel it keeps the regular one.
    func testABalanceCardFollowsTheSpacing() throws {
        let account = try XCTUnwrap(store.enabledBilling.first)
        let width = IslandController.expandedWidth - HoverPanelView.notchInsets.leading - HoverPanelView.notchInsets.trailing
        func tall(_ spacing: PanelSpacing?) -> CGFloat {
            let card = APIBillingCard(billing: account, store: store, theme: .island, compact: true).frame(width: width)
            guard let spacing else { return NSHostingView(rootView: card).fittingSize.height }
            return NSHostingView(rootView: card.environment(\.panelSpacing, PanelSpacingMetrics(spacing))).fittingSize.height
        }
        let regular = tall(.regular), gaps = CGFloat(max(1, account.balances.count))
        XCTAssertEqual(tall(nil), regular, accuracy: 0.5)
        for spacing in [PanelSpacing.compact, .roomy] {
            let gap = PanelSpacingMetrics(spacing).blockParts - PanelSpacingMetrics(.regular).blockParts
            XCTAssertEqual(tall(spacing), regular + gaps * gap, accuracy: 0.5, "\(spacing)")
        }
    }

    // MARK: Separators

    /// Without separators the lines go and their room stays, at every spacing and under every widget.
    func testWithoutSeparatorsThePanelIsAsTall() {
        for spacing in PanelSpacing.allCases {
            for widget in PanelBlockKind.quota.widgets {
                keep(every(PanelLayout.Block(widget: widget), style: PanelStyle(spacing: spacing)))
                let with = height()
                keep(every(PanelLayout.Block(widget: widget), style: PanelStyle(spacing: spacing, separators: false)))
                XCTAssertEqual(height(), with, accuracy: 0.5, "\(widget) \(spacing)")
            }
        }
    }

    /// A style that spells out the default view's is the default layout, and draws the default view.
    func testTheDefaultStyleWrittenOutIsTheDefaultView() {
        let plain = height()
        keep(PanelLayout(blocks: [quotaKeys[0]: PanelLayout.Block(countdown: true)], style: PanelStyle(spacing: .regular, separators: true)))
        XCTAssertTrue(layout.current.isDefault)
        XCTAssertEqual(height(), plain, accuracy: 0.5)
    }

    // MARK: Measures and countdown

    /// A block offering one measure draws no picker and is as tall whichever measure that is; one offering two draws a
    /// picker as tall as the one with every measure.
    func testABlocksPickerFollowsTheMeasuresItOffers() {
        for widget in [PanelWidget.bar, .ring, .number] {
            keep(every(PanelLayout.Block(widget: widget)))
            let full = height()
            let ones = PanelMeasure.allCases.map { measure -> CGFloat in
                keep(every(PanelLayout.Block(widget: widget, measures: [measure])))
                return height()
            }
            XCTAssertEqual(ones.max() ?? 0, ones.min() ?? 1, accuracy: 0.5, "\(widget) \(ones)")
            XCTAssertLessThanOrEqual(ones[0], full + 0.5, "\(widget): no picker in the heading")
            keep(every(PanelLayout.Block(widget: widget, measures: [.cost, .quota])))
            XCTAssertEqual(height(), full, accuracy: 0.5, "\(widget): a picker of two buttons")
        }
    }

    /// Hiding a block's countdown takes its reset times away and keeps every height: the line they stood in stays.
    /// It never brings back a countdown the Settings switch turned off.
    func testHidingTheCountdownKeepsEveryHeight() {
        for widget in PanelBlockKind.quota.widgets {
            for measure in PanelBlockKind.quota.measures(under: widget) {
                let offered = PanelBlockKind.quota.measures(under: widget)
                let measures = [measure] + offered.filter { $0 != measure }
                keep(every(PanelLayout.Block(widget: widget, measures: measures)))
                let shown = height()
                keep(every(PanelLayout.Block(widget: widget, measures: measures, countdown: false)))
                XCTAssertEqual(height(), shown, accuracy: 0.5, "\(widget) \(measure)")
                settings.update { $0.showResetCountdown = false }
                XCTAssertEqual(height(), shown, accuracy: 0.5, "\(widget) \(measure) with the switch off too")
                keep(every(PanelLayout.Block(widget: widget, measures: measures)))
                XCTAssertEqual(height(), shown, accuracy: 0.5, "\(widget) \(measure) with the switch off alone")
                settings.update { $0.showResetCountdown = true }
            }
        }
    }

    /// The cell's line under the quota measure is the reset where the countdown is shown, and nothing where the layout
    /// or the switch hides it.
    func testAHiddenCountdownLeavesACellsLineEmpty() throws {
        let row = try XCTUnwrap(store.rows.first { $0.agent.windowKey == "claude-session" })
        let metrics = QuotaRowMetrics(row: row, insights: nil, outlook: nil, now: store.now, tokensPerHour: nil)
        for style in [QuotaCell.Style.ring, .number] {
            XCTAssertEqual(QuotaCell(row: row, metrics: metrics, metric: .quota, style: style, showReset: true).captionLine.text,
                           row.resetLabel(now: store.now))
            XCTAssertNil(QuotaCell(row: row, metrics: metrics, metric: .quota, style: style, showReset: false).captionLine.text)
        }
    }
}
