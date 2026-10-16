import AppKit
import SwiftUI
import XCTest
@testable import AgentHUDCore
@testable import AgentHUDDesktop

/// Nothing in half a line is cut, in English and in Chinese, at the narrowest width two halves share a line at, 540,
/// 600 and 720 pt and every spacing: a window's name, the line under it and its figure fit their cell or give way to
/// their short forms as in the whole panel, a block's heading keeps its logo, every agent's name and its picker, an
/// account's name stays whole, Codex's earned resets keep their name and count, and a balance's amounts fit, side by
/// side or one under the other. The narrowest half drawn has cells as wide as the whole 480 pt panel's default four,
/// which a half of that panel would not.
@MainActor
final class PanelHalfFitTests: XCTestCase {
    private static let languages: [AppLanguage] = [.en, .zhHans]
    private var stores: [AppLanguage: UsageStore] = [:]

    private func sample(_ language: AppLanguage) -> UsageStore {
        L10n.setLanguage(language)
        if let known = stores[language] { return known }
        _ = NSApplication.shared
        let suite = "app.agenthud.tests.panel-half-fit.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!, defaultAgents: DemoData.agents)
        let store = UsageStore(provider: DemoUsageProvider(), settings: settings, clock: { DemoClock.now })
        store.replace(report: DemoUsageProvider.report(agents: settings.agents, historyHours: UsageStore.historyHours, now: DemoClock.now))
        stores[language] = store
        return store
    }

    override func tearDown() {
        L10n.setLanguage(.system)
        super.tearDown()
    }

    private var textWidths: [String: CGFloat] = [:]

    /// How wide `text` is on one line in `font`, measured once.
    private func textWidth(_ text: String, _ font: Font, _ key: String) -> CGFloat {
        let id = key + "|" + text
        if let known = textWidths[id] { return known }
        let measured = NSHostingView(rootView: Text(text).font(font).lineLimit(1).fixedSize()).fittingSize.width
        textWidths[id] = measured
        return measured
    }

    private func idealWidth<V: View>(_ view: V) -> CGFloat {
        NSHostingView(rootView: view.environment(\.panelHalf, true).fixedSize()).fittingSize.width
    }

    /// Every arrangement a half is drawn in: the widths beside the notch where two halves share a line, the narrowest
    /// of them at each spacing first, every spacing.
    private var arrangements: [(width: Int, spacing: PanelSpacing, half: CGFloat)] {
        PanelSpacing.allCases.flatMap { spacing in
            let half = { (width: Int) in PanelLines.halfWidth(in: Double(width) - PanelLines.sideInsets, spacing: spacing) }
            let narrowest = PanelStyle.widthRange.first { half($0) >= PanelLines.narrowestHalf } ?? PanelStyle.defaultWidth
            return [narrowest, PanelStyle.defaultWidth, 600, PanelStyle.widthRange.upperBound].map { width in
                (width, spacing, CGFloat(half(width)))
            }
        }
    }

    /// The name of every agent the app reads quota for, as its block's heading writes it.
    private static var agentNames: [String] {
        (["Claude", "Codex", "Grok", "Grok Bot", "Kimi", "GLM", "OpenCode Go", "Pi", "OpenClaw"]
            + AdditionalSource.allCases.map(\.vendor)).map(VendorCatalog.name)
    }

    /// The plan of Claude's and Codex's blocks drawn with `widget` in half a line, `columns` to a line where given.
    private func plan(_ store: UsageStore, _ widget: PanelWidget, columns: Int?, width: Int, spacing: PanelSpacing) -> PanelLayoutPlan {
        let block = PanelLayout.Block(widget: widget, columns: columns, span: .half)
        let layout = PanelLayout(blocks: ["Claude": block, "Codex": block], style: PanelStyle(spacing: spacing, width: width))
        return PanelLayoutPlan(layout: layout, blocks: store.view.panelBlocks)
    }

    /// The plan weighs a half's room by the numbers the panel's views draw to.
    func testThePanelDrawsToTheNumbersThePlanWeighs() {
        let insets = HoverPanelView.notchInsets
        XCTAssertEqual(Double(insets.leading + insets.trailing), PanelLines.sideInsets)
        XCTAssertEqual(Double(HoverPanelView.narrowestContentWidth), PanelLines.narrowestContent)
        XCTAssertEqual(Double(IslandRowLayout.inset), PanelLines.cellInset)
        XCTAssertEqual(Double(QuotaCellGrid<EmptyView>.cellGap), PanelLines.cellGap)
        for spacing in PanelSpacing.allCases {
            XCTAssertEqual(Double(PanelSpacingMetrics(spacing).blocks), spacing.blockGap, "\(spacing)")
        }
        for width in [404.0, 444, 504, 684] {
            for columns in PanelLayout.Block.columnRange {
                XCTAssertEqual(Double(QuotaCellGrid<EmptyView>.cellWidth(in: CGFloat(width), columns: columns)),
                               PanelLines.cellWidth(in: width, columns: columns), accuracy: 0.001)
            }
        }
    }

    // MARK: Cells

    /// The line under a cell's name in the form the cell shows: whole where it fits, else its short form where that
    /// fits, else nothing.
    private func shownCaption(_ line: (text: String?, short: String?), in room: CGFloat) -> String? {
        [line.text, line.short].compactMap { $0 }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .first { textWidth($0, .tabular(11), "caption") <= room }
    }

    func testNoWindowsNameCaptionOrFigureIsCut() {
        var checked = 0
        for language in Self.languages {
            let store = sample(language), view = store.view
            for (width, spacing, half) in arrangements {
                for widget in [PanelWidget.ring, .number] {
                    for asked in [nil, 3, 6] as [Int?] {
                        let planned = plan(store, widget, columns: asked, width: width, spacing: spacing)
                        for block in planned.blocks.filter({ $0.span == .half }) {
                            let room = QuotaCellGrid<EmptyView>.cellWidth(in: half, columns: block.columns)
                            XCTAssertGreaterThanOrEqual(room, CGFloat(PanelLines.narrowestCell) - 0.001)
                            if asked == nil {
                                XCTAssertEqual(block.columns, 2)
                                XCTAssertGreaterThanOrEqual(room, QuotaCellGrid<EmptyView>.cellWidth(in: 444, columns: 4) - 0.001,
                                                            "as wide as the whole 480 pt panel's four cells")
                            }
                            for row in store.rowGroups.first(where: { $0.vendor == block.key })?.rows ?? [] {
                                let font: Font = widget == .ring ? .ui(12, .medium) : .ui(11)
                                let name = row.agent.name, short = row.agent.shortName
                                if min(textWidth(name, font, "\(widget)"), textWidth(short, font, "\(widget)")) > room {
                                    for word in short.split(separator: " ") {
                                        XCTAssertLessThanOrEqual(textWidth(String(word), font, "\(widget)"), room, "\(name) in \(room)")
                                    }
                                }
                                for measure in PanelMeasure.allCases {
                                    let metrics = QuotaRowMetrics(row: row, insights: store.report?.insightsByAgent[row.id],
                                                                  outlook: view.outlook(for: row.id), now: store.now,
                                                                  tokensPerHour: store.quotaTokensPerHour(for: row.id),
                                                                  cost: measure == .cost ? view.listCost(for: row.id) : nil)
                                    let cell = QuotaCell(row: row, metrics: metrics, metric: measure,
                                                         style: widget == .ring ? .ring : .number, showReset: true)
                                    let shown = shownCaption(cell.captionLine, in: room)
                                    XCTAssertLessThanOrEqual(shown.map { textWidth($0, .tabular(11), "caption") } ?? 0, room)
                                    if block.columns == PanelLines.halfColumns, let text = cell.captionLine.text,
                                       !text.trimmingCharacters(in: .whitespaces).isEmpty {
                                        XCTAssertNotNil(shown, "\(language) \(widget) \(measure): \(text) in two columns of \(half)")
                                    }
                                    let figure = [metrics.value(measure) ?? "—", metrics.shortValue(measure)].compactMap { $0 }
                                        .map { textWidth($0, .tabular(15, .semibold), "figure") }.min() ?? 0
                                    XCTAssertLessThanOrEqual(figure, room, "\(language) \(measure) in \(room)")
                                    checked += 1
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 0)
    }

    // MARK: Headings, accounts, resets and balances

    /// A block's heading keeps its logo, its name whole on one line and its picker of four measures, or a chart's total,
    /// in half a line, for every agent the app reads quota for, the longest name, GitHub Copilot's, at the narrowest
    /// half too: `PanelLines.widestHeading` is what that heading takes, and the narrowest half has its room.
    func testAHalfBlocksHeadingKeepsItsLogoNameAndPicker() {
        let logo = IslandRowLayout.inset * 2 + IslandRowLayout.markerWidth, gap: CGFloat = 6
        let picker = CGFloat(4 * 20 + 3 * 2) + 2
        let widest = Self.agentNames.map { textWidth($0, IslandRowLayout.headingFont, "heading") }.max() ?? 0
        XCTAssertEqual(Double(logo + gap + widest + gap + 8 + gap + picker), PanelLines.widestHeading, accuracy: 0.5,
                       "GitHub Copilot's heading")
        XCTAssertGreaterThanOrEqual(PanelLines.narrowestHalf, PanelLines.widestHeading)
        for language in Self.languages {
            let store = sample(language)
            // A chart's total keeps at least its figure.
            let figure = textWidth("12.3B tok", .tabular(12), "total")
            for (width, spacing, half) in arrangements {
                let chart = logo + gap + widest + gap + 8 + gap + figure + IslandRowLayout.inset
                XCTAssertLessThanOrEqual(chart, half, "\(language) chart heading at \(width) \(spacing)")
            }
            // Drawn, the heading keeps one line, as tall as with a picker, whatever it holds, while the panel loads
            // too, when the spinner gives way rather than the name.
            let suite = "app.agenthud.tests.panel-half-fit.loading.\(UUID().uuidString)"
            addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
            let loading = UsageStore(provider: DemoUsageProvider(),
                                     settings: SettingsStore(defaults: UserDefaults(suiteName: suite)!, defaultAgents: DemoData.agents),
                                     clock: { DemoClock.now })
            XCTAssertTrue(loading.isLoading)
            let line = IslandRowLayout.headingHeight + 2 * IslandRowLayout.headingVerticalPadding
            let regular = PanelSpacingMetrics(.regular)
            // A chart block without windows is its heading and its chart, 40 pt under the spacing's gaps.
            let chart = regular.blockParts + regular.chartTop + 40
            for name in Self.agentNames {
                for widget in [PanelWidget.ring, .number, .chart] {
                    for measures in [PanelBlockKind.quota.measures(under: widget), [.quota]] where widget != .chart || measures.count == 1 {
                        for shown in [store, loading] {
                            let plan = PanelBlockPlan(key: name, kind: .quota, widget: widget, measures: measures, span: .half)
                            let drawn = NSHostingView(rootView: ProviderQuotaBlock(store: shown, rows: [], plan: plan)
                                .environment(\.panelHalf, true).frame(width: CGFloat(PanelLines.narrowestHalf))).fittingSize.height
                            XCTAssertEqual(drawn, line + (widget == .chart ? chart : 0), accuracy: 0.5,
                                           "\(language) \(name) \(widget), \(measures.count) measures, loading \(shown.isLoading)")
                        }
                    }
                }
            }
        }
    }

    /// An account's name stays whole in half a line, and its header keeps one line, its "Current account" giving way
    /// where the line is short.
    func testAnAccountsNameStaysWholeAndItsHeaderKeepsOneLine() throws {
        for language in Self.languages {
            let store = sample(language)
            for group in store.rowGroups {
                for section in store.accountSections(group.rows) {
                    guard let account = section.account else { continue }
                    let label = store.accountLabel(for: account)
                    let bare = idealWidth(AccountSectionHeader(account: account, label: ""))
                    let line = NSHostingView(rootView: AccountSectionHeader(account: account, label: label).frame(width: 2_000))
                        .fittingSize.height
                    for (width, spacing, half) in arrangements {
                        XCTAssertLessThanOrEqual(bare, half, "\(language) \(account.displayName) at \(width) \(spacing)")
                        let drawn = NSHostingView(rootView: AccountSectionHeader(account: account, label: label)
                            .environment(\.panelHalf, true).frame(width: half)).fittingSize.height
                        XCTAssertEqual(drawn, line, accuracy: 0.5, "\(language) one line at \(half)")
                    }
                }
            }
        }
    }

    /// Codex's earned resets keep their name, their count and their icon whole in half a line; the first expiry gives
    /// way where it has no room.
    func testCodexsEarnedResetsKeepTheirNameAndCount() {
        for language in Self.languages {
            _ = sample(language)
            let resets = DemoData.codexResetCredits(now: DemoClock.now)
            let needed = idealWidth(CodexResetCreditsView(resets: resets, showExpiry: false))
            for (width, spacing, half) in arrangements {
                XCTAssertLessThanOrEqual(needed, half, "\(language) at \(width) \(spacing)")
            }
            XCTAssertLessThan(needed, idealWidth(CodexResetCreditsView(resets: resets, showExpiry: false).environment(\.panelHalf, false)),
                              "the whole line's name column is wider")
        }
    }

    /// A balance's card fits half a line: its amounts side by side in two equal columns, as across the whole line, where
    /// each fits its column, else one under the other, every label and figure whole on one line; its heading is as tall
    /// as a quota block's with a picker, so the rows of two halves start level.
    func testABalanceFitsHalfALineSideBySideOrOneUnderTheOther() throws {
        for language in Self.languages {
            let store = sample(language)
            let account = try XCTUnwrap(store.enabledBilling.first)
            let balance = try XCTUnwrap(account.balances.first)
            XCTAssertNil(store.view.assessment(of: account).status.reason, "the sample's balance says nothing above its rows")
            let figures = [MoneyFormat.amount(balance.total, currency: balance.currency),
                           account.estimatedCost(currency: balance.currency, during: store.statsInterval)
                               .map { MoneyFormat.amount($0, currency: balance.currency, estimated: true) } ?? ""]
            let labels = [L10n.text("账户余额", "Account balance"), L10n.text("费用估算 · ", "Est. cost · ") + store.statsRange.recentLabel]
            // Each column, its label over its figure, on one line each: how wide and how tall.
            let columns = zip(labels, figures).map { label, figure in
                (width: max(textWidth(label, .ui(11), "label"), textWidth(figure, .tabular(15, .semibold), "money")),
                 height: NSHostingView(rootView: VStack(alignment: .leading, spacing: 3) {
                     Text(label).font(.ui(11)).lineLimit(1)
                     Text(figure).font(.tabular(15, .semibold)).lineLimit(1)
                 }.fixedSize()).fittingSize.height)
            }
            let widest = columns.map(\.width).max() ?? 0
            let heading = IslandRowLayout.inset * 2 + IslandRowLayout.markerWidth + 6
                + textWidth(account.displayName, IslandRowLayout.headingFont, "heading")
            let headingLine = IslandRowLayout.headingHeight + 2 * IslandRowLayout.headingVerticalPadding
            func card(_ width: CGFloat, _ spacing: PanelSpacing) -> CGFloat {
                NSHostingView(rootView: APIBillingCard(billing: account, store: store, theme: .island, compact: true)
                    .environment(\.panelHalf, true).environment(\.panelSpacing, PanelSpacingMetrics(spacing))
                    .frame(width: width)).fittingSize.height
            }
            var sideBySide = 0
            for (width, spacing, half) in arrangements {
                XCTAssertLessThanOrEqual(IslandRowLayout.textInset + widest + IslandRowLayout.inset, half, "\(language) at \(width)")
                XCTAssertLessThanOrEqual(heading, half, "\(language) at \(width) \(spacing)")
                let parts = PanelSpacingMetrics(spacing).blockParts
                let fits = IslandRowLayout.textInset + 2 * widest + 24 + IslandRowLayout.inset <= half
                let expected = fits ? headingLine + parts + (columns.map(\.height).max() ?? 0)
                    : headingLine + parts + columns.map(\.height).reduce(0, +) + parts
                XCTAssertEqual(card(half, spacing), expected, accuracy: 0.5,
                               "\(language) at \(width) \(spacing): \(fits ? "side by side" : "one under the other"), one line each")
                if fits { sideBySide += 1 }
            }
            XCTAssertGreaterThan(sideBySide, 0, "\(language): side by side in half of 720")
        }
    }

    /// The narrowest half that pairs is the narrowest whose two cells are as wide as the whole 480 pt panel's four: in
    /// a half of that panel a ring's caption the panel shows whole gives way to its figure alone. The sample's captions
    /// follow the wall clock, a burn rate's run-out day among them, so the caption weighed is the one the docs cite, a
    /// burn rate in the form a ring writes it, rather than whichever the sample shows at the hour the test runs.
    func testAHalfOfTheNarrowestPanelWouldDrawLessThanThatPanel() throws {
        _ = sample(.en)
        let whole = QuotaCellGrid<EmptyView>.cellWidth(in: 444, columns: 4)
        XCTAssertLessThanOrEqual(Double(whole) * 2 + 2 * PanelLines.cellInset + PanelLines.cellGap, PanelLines.narrowestHalf)
        let halves = PanelSpacing.allCases.map { CGFloat(PanelLines.halfWidth(in: 444, spacing: $0)) }
        let widest = try XCTUnwrap(halves.max())
        let room = QuotaCellGrid<EmptyView>.cellWidth(in: widest, columns: 2)
        let caption = textWidth("0.6%/h · Sun 22:02", .tabular(11), "caption")
        XCTAssertLessThanOrEqual(caption, whole + 0.01, "the 480 pt panel shows it whole")
        XCTAssertGreaterThan(caption, room, "it gives way in even the widest half of that panel")
    }
}
