import AppKit
import SwiftUI
import XCTest
@testable import AgentHUDCore
@testable import AgentHUDDesktop

/// An API balance's card under each measure its block offers and drawn as a chart: what each figure says and where it
/// comes from, that the card is as tall in every measure with every caption and figure on one line, across the whole
/// line and in half of one, in English and in Chinese, that its picker leaves the default view as tall as it was, and
/// that its chart draws its period.
@MainActor
final class BalanceMeasuresViewTests: XCTestCase {
    /// On a quarter hour, so the panel's periods end at it and have run their whole length.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func tearDown() {
        L10n.setLanguage(.system)
        super.tearDown()
    }

    /// A store over settings of its own whose one account is DeepSeek's, read at `now` unless its read failed: its CNY
    /// balance and its recorded costs, as (hours before `now`, amounts by currency).
    private func store(_ total: String = "8.85", costs: [(Double, [String: String])], failed: Bool = false,
                       consumers: [AgentDescriptor] = [], usage: [UsageBucket] = [],
                       replyRates: [String: QuotaReplyRate]? = nil) throws -> UsageStore {
        _ = NSApplication.shared
        let suite = "app.agenthud.tests.balance-measures.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let agents = [AgentDescriptor(id: "deepseek", vendor: "DeepSeek", model: "API", source: "", enabled: true)]
        let settings = SettingsStore(defaults: defaults, defaultAgents: agents)
        let now = now
        let store = UsageStore(provider: DemoUsageProvider(), settings: settings, clock: { now })
        let billing = APIBilling(
            vendor: "DeepSeek",
            balances: [AccountBalance(currency: "CNY", total: Decimal(string: total)!, granted: 0, toppedUp: Decimal(string: total)!)],
            isAvailable: true, updatedAt: now,
            costs: costs.map { hours, amounts in
                CostBucket(start: now.addingTimeInterval(-hours * 3600), amounts: amounts.mapValues { Decimal(string: $0)! })
            },
            notice: failed ? "offline" : nil, readingIssue: failed ? .readFailed("offline") : nil)
        store.replace(report: UsageReport(generatedAt: now, snapshots: [], sessions: [], consumers: consumers, usage: usage,
                                         billing: [billing], replyRates: replyRates))
        XCTAssertEqual(store.enabledBilling.count, 1)
        return store
    }

    private func metrics(_ store: UsageStore, period: PanelTokenPeriod = .week) throws -> BalanceMetrics {
        let account = try XCTUnwrap(store.enabledBilling.first)
        return BalanceMetrics(billing: account, balance: account.balances.first, currency: "CNY", store: store, period: period)
    }

    private func figure(_ caption: String, _ value: String, _ ink: BalanceMetrics.Ink) -> BalanceMetrics.Figure {
        BalanceMetrics.Figure(caption: caption, value: value, ink: ink)
    }

    // MARK: What each measure says

    /// Seventy fen spent over the week is ten fen a day, at which ¥8.85 lasts 88 and a half days from its reading.
    func testEachMeasureSaysWhatItReadsOverItsPeriod() throws {
        L10n.setLanguage(.en)
        let store = try store(costs: [(1, ["CNY": "0.3"]), (72, ["CNY": "0.4"]), (200, ["CNY": "9"])])
        let week = try metrics(store)
        XCTAssertEqual(week.spend?.cost, Decimal(string: "0.7"), "the costs of the week, and none from before it")
        XCTAssertEqual(week.spend?.perDay, Decimal(string: "0.1"))
        let runsOut = try XCTUnwrap(week.runsOut)
        XCTAssertEqual(runsOut.timeIntervalSince(now), 88.5 * 86400, accuracy: 0.001)
        XCTAssertEqual(week.figure(.first, of: .quota), figure("Account balance", "¥8.85", .level))
        XCTAssertEqual(week.figure(.second, of: .quota), figure("Est. cost · Last 7 days", "¥0.70", .text))
        XCTAssertEqual(week.figure(.first, of: .burnRate), figure("Burn rate · Last 7 days", "¥0.10/day", .level))
        XCTAssertEqual(week.figure(.second, of: .burnRate), figure("Runs out", BalanceMetrics.runOutLabel(runsOut, now: now), .text))
        XCTAssertEqual(week.figure(.first, of: .cost), figure("Est. cost · Last 7 days", "¥0.70", .text))
        XCTAssertEqual(week.figure(.second, of: .cost), figure("Burn rate", "¥0.10/day", .level),
                       "the burn rate is written the same way under either measure")
        XCTAssertEqual(week.level, .warning, "¥8.85 is under the ¥10 at which a balance runs low")

        let day = try metrics(store, period: .day)
        XCTAssertEqual(day.figure(.second, of: .quota), figure("Est. cost · Last 24 h", "¥0.30", .text))
        XCTAssertEqual(day.figure(.first, of: .burnRate), figure("Burn rate · Last 24 h", "¥0.30/day", .level))
        XCTAssertEqual(day.runsOut?.timeIntervalSince(now) ?? 0, 8.85 / 0.3 * 86400, accuracy: 0.001)

        L10n.setLanguage(.zhHans)
        let chinese = try metrics(store)
        XCTAssertEqual(chinese.figure(.first, of: .burnRate), figure("消耗速率 · 近 7 天", "¥0.10/天", .level))
        XCTAssertEqual(chinese.figure(.second, of: .burnRate).caption, "预计耗尽")
        XCTAssertEqual(chinese.figure(.second, of: .cost), figure("消耗速率", "¥0.10/天", .level))
    }

    func testWhatIsNotKnownSaysSo() throws {
        L10n.setLanguage(.en)
        let unpriced = try metrics(try store(costs: [(1, ["CNY": "0.3"]), (2, ["USD": "0.04"])]))
        XCTAssertNil(unpriced.spend, "a request without a price in yuan leaves the cost in yuan unknown")
        XCTAssertEqual(unpriced.figure(.second, of: .quota), figure("Est. cost · Last 7 days", "Unpriced", .text))
        XCTAssertEqual(unpriced.figure(.first, of: .burnRate), figure("Burn rate · Last 7 days", "Unpriced", .secondary))
        XCTAssertEqual(unpriced.figure(.second, of: .burnRate), figure("Runs out", "—", .secondary))

        let idle = try metrics(try store(costs: []))
        XCTAssertEqual(idle.figure(.first, of: .burnRate).value, "¥0.00/day")
        XCTAssertEqual(idle.figure(.second, of: .burnRate), figure("Runs out", "No usage", .secondary), "nothing spent gives no time")
        for measure in [PanelMeasure.tokens, .consumed] {
            XCTAssertEqual(idle.figure(.first, of: measure).value, "—")
            XCTAssertEqual(idle.figure(.second, of: measure).value, "—")
        }

        let failed = try metrics(try store(costs: [(1, ["CNY": "0.3"])], failed: true))
        XCTAssertNil(failed.level, "a balance whose read failed shows no level")
        XCTAssertNil(failed.runsOut)
        XCTAssertEqual(failed.figure(.first, of: .burnRate).value, "¥0.04/day", "what its requests cost is still known")
        XCTAssertEqual(failed.figure(.second, of: .burnRate), figure("Runs out", "—", .secondary))

        let empty = try metrics(try store("0", costs: [(1, ["CNY": "0.3"])]))
        XCTAssertEqual(empty.level, .critical)
        XCTAssertEqual(empty.figure(.second, of: .burnRate), figure("Runs out", "Exhausted", .level))
    }

    func testTokenMeasuresReadOnlyTheBalancesConsumersAndSelectedPeriod() throws {
        L10n.setLanguage(.en)
        let model = AgentDescriptor(id: "deepseek-model:test", vendor: "DeepSeek", model: "test", source: "local", enabled: true)
        let other = AgentDescriptor(id: "claude-model:test", vendor: "Claude", model: "test", source: "local", enabled: true)
        let usage = [
            UsageBucket(start: now.addingTimeInterval(-3600), agentId: model.id, tokensIn: 1400, tokensOut: 400, cacheReadTokens: 200),
            UsageBucket(start: now.addingTimeInterval(-72 * 3600), agentId: model.id, tokensIn: 2800, tokensOut: 100, cacheReadTokens: 100),
            UsageBucket(start: now.addingTimeInterval(-200 * 3600), agentId: model.id, tokensIn: 9000, tokensOut: 0),
            UsageBucket(start: now.addingTimeInterval(-3600), agentId: other.id, tokensIn: 999_000, tokensOut: 0),
            UsageBucket(start: now.addingTimeInterval(3600), agentId: model.id, tokensIn: 9000, tokensOut: 0),
        ]
        let store = try store(costs: [], consumers: [model, other], usage: usage,
            replyRates: ["api:DeepSeek": .init(tokensPerSecond: 8.5, calls: 17, tokensOut: 1700),
                         "api:other": .init(tokensPerSecond: 999, calls: 99, tokensOut: 99_000)])
        let week = try metrics(store)
        XCTAssertEqual(week.tokens, 5000, "input, output and cache reads belong to this balance, within its period")
        XCTAssertEqual(week.figure(.first, of: .tokens), figure("Reply rate · Last 7 days", "8.5/s", .text))
        XCTAssertEqual(week.figure(.second, of: .tokens), figure("Replies", "17", .text))
        XCTAssertEqual(week.figure(.first, of: .consumed), figure("Tokens · Last 7 days", "5.0k", .text))
        XCTAssertEqual(week.figure(.second, of: .consumed), figure("Pace", "30/h", .text))
        let day = try metrics(store, period: .day)
        XCTAssertEqual(day.tokens, 2000)
        XCTAssertEqual(day.figure(.first, of: .consumed), figure("Tokens · Last 24 h", "2.0k", .text))
        XCTAssertEqual(day.figure(.second, of: .consumed), figure("Pace", "83/h", .text))
        L10n.setLanguage(.zhHans)
        let chinese = try metrics(store)
        XCTAssertEqual(chinese.figure(.first, of: .tokens), figure("回复速率 · 近 7 天", "8.5/s", .text))
        XCTAssertEqual(chinese.figure(.second, of: .tokens).caption, "回复次数")
        XCTAssertEqual(chinese.figure(.first, of: .consumed).caption, "Token 消耗 · 近 7 天")
        XCTAssertEqual(chinese.figure(.second, of: .consumed).caption, "平均速率")
    }

    /// Within a week a run-out is a weekday and a time, as a window's is; then a date and a time; and from a year on, the
    /// month and the year, which a slow pace reaches.
    func testARunOutIsWrittenByHowFarAheadItIs() {
        L10n.setLanguage(.en)
        let soon = now.addingTimeInterval(3 * 86400)
        XCTAssertEqual(BalanceMetrics.runOutLabel(soon, now: now), ChartData.weekdayTime(soon))
        let month = BalanceMetrics.runOutLabel(now.addingTimeInterval(30 * 86400), now: now)
        XCTAssertTrue(month.contains(":"), month)
        XCTAssertFalse(month.contains("2027"), month)
        let far = BalanceMetrics.runOutLabel(now.addingTimeInterval(400 * 86400), now: now)
        XCTAssertTrue(far.hasSuffix("2028"), far)
        XCTAssertFalse(far.contains(":"), far)
    }

    // MARK: How tall

    private func card(_ store: UsageStore, measure: PanelMeasure, measures: [PanelMeasure] = [.quota, .burnRate, .tokens, .consumed, .cost],
                      picker: Bool = true, width: CGFloat, half: Bool, spacing: PanelSpacing = .regular,
                      period: PanelTokenPeriod = .week) throws -> CGFloat {
        let account = try XCTUnwrap(store.enabledBilling.first)
        return NSHostingView(rootView: APIBillingCard(billing: account, store: store, theme: .island, compact: true, period: period,
                                                      measures: measures, measure: measure,
                                                      picker: picker ? .constant(measure) : nil)
            .environment(\.panelHalf, half).environment(\.panelSpacing, PanelSpacingMetrics(spacing))
            .frame(width: width)).fittingSize.height
    }

    private func textWidth(_ text: String, _ font: Font) -> CGFloat {
        NSHostingView(rootView: Text(text).font(font).lineLimit(1).fixedSize()).fittingSize.width
    }

    /// The card's two columns, a caption over a figure each, weighed in every measure: side by side where the widest of
    /// them fits each column, else one under the other, each caption and figure on one line, whatever measure is shown.
    func testTheCardIsAsTallInEveryMeasureWithEveryCaptionAndFigureOnOneLine() throws {
        for language in [AppLanguage.en, .zhHans] {
            L10n.setLanguage(language)
            let model = AgentDescriptor(id: "deepseek-model:test", vendor: "DeepSeek", model: "test", source: "local", enabled: true)
            let store = try store(costs: [(1, ["CNY": "0.3"]), (72, ["CNY": "0.4"])], consumers: [model],
                usage: [.init(start: now.addingTimeInterval(-3600), agentId: model.id, tokensIn: 12_345_678, tokensOut: 3000)],
                replyRates: ["api:DeepSeek": .init(tokensPerSecond: 123.4, calls: 1234, tokensOut: 3000)])
            let metrics = try metrics(store)
            let measures: [PanelMeasure] = [.quota, .burnRate, .tokens, .consumed, .cost]
            let figures = measures.flatMap { [metrics.figure(.first, of: $0), metrics.figure(.second, of: $0)] }
            let widest = figures.map { max(textWidth($0.caption, .ui(11)), textWidth($0.value, .tabular(15, .semibold))) }.max() ?? 0
            let column = figures.map { figure in
                NSHostingView(rootView: VStack(alignment: .leading, spacing: 3) {
                    Text(figure.caption).font(.ui(11)).lineLimit(1)
                    Text(figure.value).font(.tabular(15, .semibold)).lineLimit(1)
                }.fixedSize()).fittingSize.height
            }.max() ?? 0
            let headingLine = IslandRowLayout.headingHeight + 2 * IslandRowLayout.headingVerticalPadding
            let whole = IslandController.expandedWidth - HoverPanelView.notchInsets.leading - HoverPanelView.notchInsets.trailing
            let wholeHeights = try measures.map { try card(store, measure: $0, width: whole, half: false) }
            XCTAssertEqual(wholeHeights.max() ?? 0, wholeHeights.min() ?? 1, accuracy: 0.5, "\(language) across the line: \(wholeHeights)")
            for spacing in PanelSpacing.allCases {
                for width in [230, 260, 300, 340] as [CGFloat] {
                    let parts = PanelSpacingMetrics(spacing).blockParts
                    let fits = IslandRowLayout.textInset + 2 * widest + 24 + IslandRowLayout.inset <= width
                    let expected = fits ? headingLine + parts + column : headingLine + parts + column + parts + column
                    for measure in measures {
                        XCTAssertEqual(try card(store, measure: measure, width: width, half: true, spacing: spacing), expected,
                                       accuracy: 0.5, "\(language) \(measure) in \(width) pt at \(spacing) spacing, "
                                       + (fits ? "side by side" : "one under the other"))
                    }
                }
            }
        }
    }

    /// The picker stands over the heading's padding: a balance's card is as tall with it as without, so the default view,
    /// which now offers every measure, is the panel as it was.
    func testThePickerLeavesTheCardAsTallAsItWas() throws {
        L10n.setLanguage(.en)
        let store = try store(costs: [(1, ["CNY": "0.3"])])
        let whole = IslandController.expandedWidth - HoverPanelView.notchInsets.leading - HoverPanelView.notchInsets.trailing
        for (width, half) in [(whole, false), (CGFloat(230), true), (CGFloat(260), true)] {
            XCTAssertEqual(try card(store, measure: .quota, width: width, half: half),
                           try card(store, measure: .quota, measures: [.quota], picker: false, width: width, half: half),
                           accuracy: 0.5, "in \(width) pt")
        }
    }

    // MARK: In the panel

    /// In the panel a balance's block starts from the first measure its layout lists and is as tall in each, the default
    /// view's five included; drawn as a chart it is taller, and it takes half a line beside another chart.
    func testThePanelDrawsABalanceAsItsLayoutAsks() throws {
        L10n.setLanguage(.en)
        _ = NSApplication.shared
        let suite = "app.agenthud.tests.balance-measures-panel.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)), defaultAgents: DemoData.agents)
        let store = UsageStore(provider: DemoUsageProvider(), settings: settings, clock: { DemoClock.now })
        store.replace(report: DemoUsageProvider.report(agents: settings.agents, historyHours: UsageStore.historyHours, now: DemoClock.now))
        let key = try XCTUnwrap(store.enabledBilling.first?.panelBlockKey)
        func height(_ layout: PanelLayout) -> CGFloat {
            settings.panelLayout.propose(layout)
            settings.panelLayout.save()
            return NSHostingView(rootView: HoverPanelView(store: store, onOpenStats: {}).frame(width: IslandController.expandedWidth))
                .fittingSize.height
        }
        let plain = height(PanelLayout())
        let offered = PanelBlockKind.billing.measures(under: .number)
        for first in offered {
            let measures = [first] + offered.filter { $0 != first }
            XCTAssertEqual(height(PanelLayout(blocks: [key: PanelLayout.Block(measures: measures)])), plain, accuracy: 0.5, "\(first) first")
        }
        let chart = height(PanelLayout(blocks: [key: PanelLayout.Block(widget: .chart)]))
        XCTAssertGreaterThan(chart, plain + 30, "its bars stand under its estimated cost")
        let whole = height(PanelLayout(blocks: ["Codex": PanelLayout.Block(widget: .chart), key: PanelLayout.Block(widget: .chart)]))
        let halves = height(PanelLayout(blocks: ["Codex": PanelLayout.Block(widget: .chart, span: .half),
                                                 key: PanelLayout.Block(widget: .chart, span: .half)]))
        XCTAssertLessThan(halves, whole - 30, "the two charts share a line")
    }

    // MARK: The chart

    private func pixels(_ view: some View) -> Data? {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap.bitmapData.map { Data(bytes: $0, count: bitmap.bytesPerRow * bitmap.pixelsHigh) }
    }

    /// A balance drawn as a chart is its estimated cost over its period above its bars, in that period's columns, as tall
    /// in every period; another period is other bars and another figure.
    func testAChartDrawsTheEstimatedCostOverItsPeriod() throws {
        L10n.setLanguage(.en)
        let store = try store(costs: [(1, ["CNY": "0.3"]), (72, ["CNY": "0.4"])])
        let account = try XCTUnwrap(store.enabledBilling.first)
        let width = IslandController.expandedWidth - HoverPanelView.notchInsets.leading - HoverPanelView.notchInsets.trailing
        func chart(_ period: PanelTokenPeriod) -> some View {
            APIBillingCard(billing: account, store: store, theme: .island, compact: true, period: period, widget: .chart,
                           measures: [.cost], measure: .cost).frame(width: width)
        }
        let heights = PanelTokenPeriod.allCases.map { NSHostingView(rootView: chart($0)).fittingSize.height }
        XCTAssertEqual(heights.max() ?? 0, heights.min() ?? 1, accuracy: 0.5, "\(heights)")
        XCTAssertGreaterThan(heights[0], try card(store, measure: .cost, measures: [.cost], picker: false, width: width, half: false),
                             "its bars stand under the figure")
        XCTAssertNotEqual(pixels(chart(.day)), pixels(chart(.week)), "a week is other bars and another total")

        XCTAssertEqual(store.balanceCostColumns(account, currency: "CNY", period: .day).count, 96, "a day in quarter hours")
        XCTAssertEqual(store.balanceCostColumns(account, currency: "CNY", period: .week).compactMap(\.amount).reduce(0, +),
                       Decimal(string: "0.7"))
    }

    /// A chart with no bar says why, as the figure above it does: no price where a request in its period had none in the
    /// currency, which the figure calls Unpriced, else no cost; one that draws a bar, or still loads, says nothing.
    func testAChartWithNoBarSaysWhy() throws {
        L10n.setLanguage(.en)
        let unpriced = try store(costs: [(1, ["USD": "0.3"])])
        let account = try XCTUnwrap(unpriced.enabledBilling.first)
        let columns = unpriced.balanceCostColumns(account, currency: "CNY", period: .day)
        XCTAssertEqual(try metrics(unpriced, period: .day).figure(.first, of: .cost).value, "Unpriced")
        XCTAssertEqual(CostBarsChart.emptyText(columns, isLoading: false), "No price for the requests in this range")
        XCTAssertNil(CostBarsChart.emptyText(columns, isLoading: true))

        let quiet = try store(costs: [(72, ["CNY": "0.4"])])
        let none = quiet.balanceCostColumns(try XCTUnwrap(quiet.enabledBilling.first), currency: "CNY", period: .day)
        XCTAssertEqual(CostBarsChart.emptyText(none, isLoading: false), "No cost in this range")
        let spent = try store(costs: [(1, ["CNY": "0.3"]), (2, ["USD": "0.3"])])
        let drawn = spent.balanceCostColumns(try XCTUnwrap(spent.enabledBilling.first), currency: "CNY", period: .day)
        XCTAssertNil(CostBarsChart.emptyText(drawn, isLoading: false), "a bar is drawn; the unpriced column says so on hover")
    }
}
