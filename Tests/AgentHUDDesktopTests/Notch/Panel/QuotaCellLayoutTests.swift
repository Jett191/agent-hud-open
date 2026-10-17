import AppKit
import SwiftUI
import XCTest
@testable import AgentHUDCore
@testable import AgentHUDDesktop

/// Ring and number cells under every option a layout can ask for: two to six columns, the three ring sizes, the three
/// spacings, both panels at the default width and at the narrowest and widest a layout sets, and one to six windows, in
/// English and in Chinese, one option at a time from the default arrangement and from the tightest. Measured as the
/// island measures the panel, from a fresh view tree at a fixed width.
@MainActor
final class QuotaCellLayoutTests: XCTestCase {
    private static let languages: [AppLanguage] = [.en, .zhHans]
    private var stores: [AppLanguage: UsageStore] = [:]

    /// The sample's English quota names over settings of its own; the rest of the interface speaks `language`.
    private func sample(_ language: AppLanguage) -> UsageStore {
        L10n.setLanguage(language)
        if let known = stores[language] { return known }
        _ = NSApplication.shared
        let suite = "app.agenthud.tests.quota-cell-layout.\(UUID().uuidString)"
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

    /// The panel's content widths, inside their insets: the hover panel's and an agent's own panel's by default, then
    /// the whole panel at the narrowest and the widest width a layout sets, and an agent's own panel at the widest
    /// (at the narrowest it is 440, the default's). An agent's own panel by default has the narrowest content any panel
    /// has, which a dock on a side edge widens its panel to keep.
    private var widths: [CGFloat] {
        let insets = HoverPanelView.notchInsets.leading + HoverPanelView.notchInsets.trailing
        let narrowest = PanelStyle(width: PanelStyle.widthRange.lowerBound), widest = PanelStyle(width: PanelStyle.widthRange.upperBound)
        XCTAssertEqual(narrowest.agentPanelWidth, PanelStyle().agentPanelWidth)
        XCTAssertEqual(IslandController.agentPanelWidth - insets, HoverPanelView.narrowestContentWidth)
        return [IslandController.expandedWidth, IslandController.agentPanelWidth, CGFloat(narrowest.panelWidth),
                CGFloat(widest.panelWidth), CGFloat(widest.agentPanelWidth)].map { $0 - insets }
    }

    /// The sample's six quota windows in `language`, which the tests set side by side one to six at a time.
    private func sampleWindows(_ language: AppLanguage) -> [AgentRow] {
        Array(sample(language).rows.filter { $0.usedPct != nil }.prefix(6))
    }

    /// An explicitly long short name keeps wrapping coverage independent of a provider's compact wording.
    private func wrappingWindow(_ language: AppLanguage) throws -> AgentRow {
        let row = try XCTUnwrap(sampleWindows(language).first { $0.agent.shortName == "Spark 7d" })
        let old = row.agent
        let agent = AgentDescriptor(id: old.id, vendor: old.vendor, model: old.model, shortModel: "Spark Weekly",
                                    source: old.source, enabled: old.enabled, connected: old.connected,
                                    billingPool: old.billingPool, account: old.account, allModels: old.allModels)
        return AgentRow(agent: agent, remainingPct: row.remainingPct, level: row.level, resetAt: row.resetAt,
                        weeklyRemainingPct: row.weeklyRemainingPct, paletteIndex: row.paletteIndex,
                        account: row.account, assessment: row.assessment)
    }

    /// How a block sets out its windows: in which language, at which content width, how many to a line, as rings of
    /// which size or as numbers, at which spacing, how many of them, with or without the countdown.
    private struct Arrangement {
        var language: AppLanguage
        var width: CGFloat
        var columns: Int
        var style = QuotaCell.Style.ring
        var size: PanelRingSize
        var spacing = PanelSpacing.regular
        var count = 6
        var showReset = true
    }

    /// The language, the width, the columns, the style and the ring size one at a time, from the default arrangement
    /// and from the tightest, Chinese large rings six to a line in an agent's own panel, where names wrap and captions
    /// give way.
    private var arrangements: OneAtATime<Arrangement> {
        let widths = widths
        return OneAtATime(from: Arrangement(language: .en, width: widths[0], columns: PanelLayout.Block.defaultColumns, size: .medium),
                          Arrangement(language: .zhHans, width: widths[1], columns: PanelLayout.Block.columnRange.upperBound, size: .large))
            .varying(\.language, over: Self.languages)
            .varying(\.width, over: widths)
            .varying(\.columns, over: PanelLayout.Block.columnRange)
            .varying(\.style, over: [.ring, .number])
            .varying(\.size, over: PanelRingSize.allCases)
    }

    private var readings: [String: QuotaRowMetrics] = [:]

    /// What a window's cell reads under `measure`, as the block reads it, worked out once.
    private func metrics(_ row: AgentRow, _ measure: PanelMeasure) -> QuotaRowMetrics {
        let key = "\(L10n.resolved)|\(row.id)|\(measure.rawValue)"
        if let known = readings[key] { return known }
        let store = sample(L10n.resolved == .zhHans ? .zhHans : .en), view = store.view
        let made = QuotaRowMetrics(row: row, insights: store.report?.insightsByAgent[row.id], outlook: view.outlook(for: row.id),
                                   now: store.now, tokensPerHour: store.quotaTokensPerHour(for: row.id),
                                   cost: measure == .cost ? view.listCost(for: row.id) : nil)
        readings[key] = made
        return made
    }

    private func cell(_ row: AgentRow, _ measure: PanelMeasure, _ style: QuotaCell.Style, size: PanelRingSize = .medium,
                      loading: Bool = false) -> QuotaCell {
        QuotaCell(row: row, metrics: metrics(row, measure), metric: measure, style: style, showReset: true, isLoading: loading,
                  ringSize: size)
    }

    /// The height of a grid of `rows`, as the block draws it.
    private func height(_ rows: [AgentRow], _ measure: PanelMeasure, _ style: QuotaCell.Style, size: PanelRingSize = .medium,
                        columns: Int, spacing: PanelSpacing = .regular, width: CGFloat, loading: Bool = false) -> CGFloat {
        let grid = QuotaCellGrid(rows: rows, columns: columns) { row in self.cell(row, measure, style, size: size, loading: loading) }
            .environment(\.panelSpacing, PanelSpacingMetrics(spacing))
            .frame(width: width)
        return autoreleasepool { NSHostingView(rootView: grid).fittingSize.height }
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

    // MARK: Heights

    /// The rule the island is sized by holds under every option: a block is as tall in every measure it offers.
    func testEveryArrangementIsAsTallInEveryMeasure() {
        let measures = PanelBlockKind.quota.measures(under: .ring)
        var checked = 0
        for each in arrangements.varying(\.spacing, over: PanelSpacing.allCases).varying(\.count, over: 1...6).arrangements {
            let windows = sampleWindows(each.language)
            XCTAssertEqual(windows.count, 6)
            let rows = Array(windows.prefix(each.count))
            let heights = measures.map {
                height(rows, $0, each.style, size: each.size, columns: each.columns, spacing: each.spacing, width: each.width)
            }
            XCTAssertEqual(heights.max() ?? 0, heights.min() ?? 1, accuracy: 0.5, "\(each): \(heights)")
            checked += 1
        }
        // Each base, then the other language, 4 widths, 4 column counts, the other style, 2 ring sizes, 2 spacings and 5 counts.
        XCTAssertEqual(checked, 2 * (1 + 1 + 4 + 4 + 1 + 2 + 2 + 5))
    }

    /// While the readings load, a cell keeps the height it has once they are in, so the island does not jump.
    func testACellIsAsTallWhileItsReadingLoads() {
        for each in arrangements.arrangements {
            let rows = sampleWindows(each.language)
            for measure in PanelMeasure.allCases {
                XCTAssertEqual(height(rows, measure, each.style, size: each.size, columns: each.columns, width: each.width, loading: true),
                               height(rows, measure, each.style, size: each.size, columns: each.columns, width: each.width), accuracy: 0.5,
                               "\(each), \(measure)")
            }
        }
    }

    /// Windows whose readings show no level, not read yet beside ones that are, keep one height in every measure, with
    /// the countdown shown or hidden.
    func testWindowsWithoutALevelAreAsTallInEveryMeasure() throws {
        var unreadStores: [AppLanguage: UsageStore] = [:]
        for language in Self.languages {
            let sample = sample(language)
            let report = try XCTUnwrap(sample.report)
            let unread = Set(sampleWindows(language).prefix(2).map(\.id))
            let suite = "app.agenthud.tests.quota-cell-layout.unread.\(UUID().uuidString)"
            addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
            let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!, defaultAgents: DemoData.agents)
            let store = UsageStore(provider: DemoUsageProvider(), settings: settings, clock: { DemoClock.now })
            store.replace(report: UsageReport(
                generatedAt: report.generatedAt, snapshots: report.snapshots.filter { !unread.contains($0.agentId) },
                sessions: report.sessions, discoveredAgents: report.discoveredAgents, consumers: report.consumers, usage: report.usage,
                insightsByAgent: report.insightsByAgent, subscriptions: report.subscriptions,
                consumerIdsByQuota: report.consumerIdsByQuota, billing: report.billing, codexResetCredits: report.codexResetCredits,
                accounts: report.accounts, sessionUsage: report.sessionUsage, periods: report.periods))
            let rows = Array(store.rows.prefix(6))
            XCTAssertEqual(rows.filter { !$0.assessment.showsLevel || $0.usedPct == nil }.count, 2, "\(rows.map(\.agent.name))")
            unreadStores[language] = store
        }
        for each in arrangements.varying(\.showReset, over: [true, false]).arrangements {
            L10n.setLanguage(each.language)
            let store = try XCTUnwrap(unreadStores[each.language])
            let rows = Array(store.rows.prefix(6)), view = store.view
            let heights = PanelMeasure.allCases.map { measure -> CGFloat in
                let grid = QuotaCellGrid(rows: rows, columns: each.columns) { row in
                    QuotaCell(row: row, metrics: QuotaRowMetrics(
                        row: row, insights: store.report?.insightsByAgent[row.id], outlook: view.outlook(for: row.id),
                        now: store.now, tokensPerHour: store.quotaTokensPerHour(for: row.id),
                        cost: measure == .cost ? view.listCost(for: row.id) : nil),
                              metric: measure, style: each.style, showReset: each.showReset, ringSize: each.size)
                }
                return autoreleasepool { NSHostingView(rootView: grid.frame(width: each.width)).fittingSize.height }
            }
            XCTAssertEqual(heights.max() ?? 0, heights.min() ?? 1, accuracy: 0.5, "\(each): \(heights)")
        }
    }

    /// The spacing moves only the gaps: one line of cells grows by the room above and below the grid, two lines by
    /// the gap between them too.
    func testSpacingChangesOnlyTheGapsOfAGrid() {
        let width = widths[0], windows = sampleWindows(.en)
        let regular = PanelSpacingMetrics(.regular)
        for spacing in PanelSpacing.allCases {
            let gaps = PanelSpacingMetrics(spacing)
            let padding = 2 * (gaps.cellPadding - regular.cellPadding)
            for style in [QuotaCell.Style.ring, .number] {
                let one = height(windows, .quota, style, columns: 6, spacing: spacing, width: width)
                    - height(windows, .quota, style, columns: 6, width: width)
                XCTAssertEqual(one, padding, accuracy: 0.5, "\(style) \(spacing)")
                let two = height(windows, .quota, style, columns: 3, spacing: spacing, width: width)
                    - height(windows, .quota, style, columns: 3, width: width)
                XCTAssertEqual(two, padding + gaps.cellLines - regular.cellLines, accuracy: 0.5, "\(style) \(spacing)")
            }
        }
    }

    // MARK: Nothing cut

    /// A window's name is never cut: its full name fits the cell on one line, or its short name does, or every word of
    /// its short name does, which then wraps whole. The explicit long-name fixture exercises a wrapped short name.
    func testNoWindowNameIsCut() throws {
        var wrapped: [String] = []
        for language in Self.languages {
            let windows = sampleWindows(language) + [try wrappingWindow(language)]
            for width in widths {
                for columns in PanelLayout.Block.columnRange {
                    let room = QuotaCellGrid<EmptyView>.cellWidth(in: width, columns: columns)
                    for row in windows {
                        for (font, key) in [(Font.ui(12, .medium), "ring"), (Font.ui(11), "number")] {
                            let name = row.agent.name, short = row.agent.shortName
                            if min(textWidth(name, font, key), textWidth(short, font, key)) <= room { continue }
                            wrapped.append(short)
                            for word in short.split(separator: " ") {
                                XCTAssertLessThanOrEqual(textWidth(String(word), font, key), room,
                                                         "\(name) / \(short) in \(columns) columns at \(width)")
                            }
                        }
                    }
                }
            }
        }
        XCTAssertFalse(wrapped.isEmpty, "the explicit long short name takes two lines in six narrow columns")
    }

    /// A short name too long for one line wraps whole, and the cell is as tall in every measure with it.
    func testAWrappedNameKeepsTheCellAsTallInEveryMeasure() throws {
        let windows = sampleWindows(.zhHans)
        let row = try wrappingWindow(.zhHans)
        let single = try XCTUnwrap(windows.first { $0.agent.shortName == "Spark 5h" })
        let room = QuotaCellGrid<EmptyView>.cellWidth(in: widths[1], columns: 6)
        let line = NSHostingView(rootView: Text("Spark").font(.ui(12, .medium)).fixedSize()).fittingSize.height
        for measure in PanelMeasure.allCases {
            let tall = NSHostingView(rootView: cell(row, measure, .ring).frame(width: room)).fittingSize.height
            let short = NSHostingView(rootView: cell(single, measure, .ring).frame(width: room)).fittingSize.height
            XCTAssertEqual(tall, short + line, accuracy: 1, "\(measure): one more line for the name, and nothing else")
        }
    }

    /// The line under a cell's name, in the form the cell shows: whole where it fits, else its short form where that
    /// fits, else nothing; nil for nothing.
    private func shownCaption(_ line: (text: String?, short: String?), in room: CGFloat) -> String? {
        [line.text, line.short].compactMap { $0 }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .first { textWidth($0, .tabular(11), "caption") <= room }
    }

    /// The line under a cell's name never runs past its cell and is never cut: it is shown whole, as its short form or
    /// not at all, and whatever is shown fits. A number cell's figure fits its cell. In the panel's default four columns
    /// every caption is shown, whole or as its short form, at every width.
    func testNoCaptionOrFigureOverflowsItsCell() {
        var leftOut: Set<Int> = []
        for language in Self.languages {
            let windows = sampleWindows(language)
            for width in widths {
                for columns in PanelLayout.Block.columnRange {
                    let room = QuotaCellGrid<EmptyView>.cellWidth(in: width, columns: columns)
                    for row in windows {
                        for measure in PanelMeasure.allCases {
                            for style in [QuotaCell.Style.ring, .number] {
                                for loading in [false, true] {
                                    let line = cell(row, measure, style, loading: loading).captionLine
                                    let shown = shownCaption(line, in: room)
                                    XCTAssertLessThanOrEqual(shown.map { textWidth($0, .tabular(11), "caption") } ?? 0, room)
                                    guard let text = line.text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                                    if shown == nil { leftOut.insert(columns) }
                                    if columns == PanelLayout.Block.defaultColumns {
                                        XCTAssertNotNil(shown, "\(language) \(style) \(measure) \(text) in four columns at \(width)")
                                    }
                                }
                            }
                            let value = metrics(row, measure).value(measure) ?? "—"
                            XCTAssertLessThanOrEqual(textWidth(value, .tabular(15, .semibold), "figure"), room,
                                                     "\(value) in \(columns) columns at \(width)")
                        }
                    }
                }
            }
        }
        XCTAssertFalse(leftOut.contains(PanelLayout.Block.defaultColumns))
        XCTAssertTrue(leftOut.isSubset(of: [5, 6]), "only five and six columns leave a caption out: \(leftOut.sorted())")
    }

    /// A number cell's figure at its widest, a burn rate of 100 %/h and more or a cost of ten thousand, is shown whole
    /// where it fits and in its short form where it does not, and the short form fits the narrowest cell. A figure that
    /// fits is never shortened.
    func testAWideFigureGivesWayToItsShortForm() throws {
        let narrowest = widths.map { QuotaCellGrid<EmptyView>.cellWidth(in: $0, columns: 6) }.min() ?? 0
        let widest = widths.map { QuotaCellGrid<EmptyView>.cellWidth(in: $0, columns: 4) }.max() ?? 0
        let wide: [(rate: Double, amount: Decimal, currency: String)] = [
            (123.4, 12_345, "USD"), (499.6, 987_654, "CNY"), (12.3, 10_000, "EUR"),
        ]
        for language in Self.languages {
            let row = try XCTUnwrap(sampleWindows(language).first)
            for (rate, amount, currency) in wide {
                let insights = UsageInsights(burnRatePctPerHour: rate, timeToExhaust: 1800, weeklyCapHits: 0, weeklyWaitTotal: 0,
                                             weeklyWaitLongest: 0, weeklyWaitLongestAt: nil)
                let metrics = QuotaRowMetrics(row: row, insights: insights, outlook: nil, now: DemoClock.now, tokensPerHour: 1000,
                                              cost: QuotaListCost(amounts: [currency: amount], hours: 10))
                for measure in [PanelMeasure.burnRate, .cost] {
                    let value = try XCTUnwrap(metrics.value(measure)), short = try XCTUnwrap(metrics.shortValue(measure))
                    let font = Font.tabular(15, .semibold)
                    XCTAssertGreaterThan(textWidth(value, font, "figure"), narrowest, "\(value) is wider than six narrow columns")
                    XCTAssertLessThanOrEqual(textWidth(short, font, "figure"), narrowest, "\(language) \(value) → \(short)")
                    XCTAssertLessThanOrEqual(textWidth(value, font, "figure"), widest, "\(value) is whole in four columns")
                }
            }
        }
        L10n.setLanguage(.en)
        let row = try XCTUnwrap(sampleWindows(.en).first)
        let small = QuotaRowMetrics(row: row, insights: nil, outlook: nil, now: DemoClock.now, tokensPerHour: 1000,
                                    cost: QuotaListCost(amounts: ["USD": 12_345], hours: 10))
        XCTAssertEqual(small.shortValue(.cost), "$12K")
        XCTAssertNil(small.shortValue(.quota), "a share used is short already")
        XCTAssertNil(small.shortValue(.tokens))
        XCTAssertNil(small.shortValue(.burnRate), "nothing to shorten without a burn rate")
    }

    /// A ring's figure fits inside the ring at "100%", the box it is set in corners and all, at every size and in the
    /// narrowest cell, where a ring wider than its cell is as wide as the cell.
    func testTheFigureFitsInsideTheRingAtEverySize() {
        let narrowest = widths.map { QuotaCellGrid<EmptyView>.cellWidth(in: $0, columns: 6) }.min() ?? 0
        for size in PanelRingSize.allCases {
            let figure = NSHostingView(rootView: Text("100%").font(.tabular(size.figureSize, .semibold)).lineLimit(1).fixedSize()).fittingSize
            for diameter in [size.diameter, min(size.diameter, narrowest)] {
                let inside = diameter - 2 * size.lineWidth
                // The figure's box, corners included, stays inside the ring's inner edge.
                let corner = (figure.width * figure.width + figure.height * figure.height).squareRoot()
                XCTAssertLessThanOrEqual(corner, inside, "\(size) at \(diameter) pt: \(figure)")
            }
        }
        XCTAssertLessThan(PanelRingSize.small.diameter, PanelRingSize.medium.diameter)
        XCTAssertLessThan(PanelRingSize.medium.diameter, PanelRingSize.large.diameter)
        XCTAssertEqual(PanelRingSize.medium.diameter, 46, "medium is the ring the default view draws")
        XCTAssertEqual(PanelRingSize.medium.lineWidth, 4)
        XCTAssertEqual(PanelRingSize.medium.figureSize, 11)
    }

    /// A ring is drawn at its size, and in a cell narrower than that, as wide as the cell: a large ring in six columns
    /// of an agent's own panel does not reach into the next cell.
    func testARingNeverOutgrowsItsCell() {
        let row = sampleWindows(.en)[0]
        func tall(_ size: PanelRingSize, in width: CGFloat) -> CGFloat {
            NSHostingView(rootView: cell(row, .quota, .ring, size: size).frame(width: width)).fittingSize.height
        }
        for size in PanelRingSize.allCases {
            for width in widths {
                for columns in PanelLayout.Block.columnRange {
                    let room = QuotaCellGrid<EmptyView>.cellWidth(in: width, columns: columns)
                    let shrunk = max(0, size.diameter - room)
                    XCTAssertEqual(tall(size, in: room), tall(size, in: 200) - shrunk, accuracy: 0.5,
                                   "\(size) in \(columns) columns at \(width)")
                }
            }
        }
    }
}
