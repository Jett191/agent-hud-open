import AppKit
import SwiftUI
import XCTest
@testable import AgentHUDCore
@testable import AgentHUDDesktop

/// The height the panel reports, as the island reads it.
private final class ReportedHeight: @unchecked Sendable {
    var value: CGFloat = 0
}

/// Half blocks in the hover panel, measured as the island measures it, from a fresh view tree at the panel's width: two
/// halves share a line as tall as the taller of them at 540 and 720 pt, take the whole line each at 480 pt and in one
/// agent's own panel, keep one height in every measure, and have a thin divider between them where separators are on.
/// The default layout is the panel it was.
@MainActor
final class PanelHalfViewTests: XCTestCase {
    private var stores: [AppLanguage: UsageStore] = [:]

    /// The sample in `language`, over settings of its own, without the token chart and the sessions, which no span moves.
    /// The interface speaks `language` from here on.
    private func sample(_ language: AppLanguage) -> UsageStore {
        L10n.setLanguage(language)
        if let known = stores[language] { return known }
        _ = NSApplication.shared
        let suite = "app.agenthud.tests.panel-half.\(UUID().uuidString)"
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

    private static let balance = "api:DeepSeek"

    /// The saved layout becomes `layout`.
    private func keep(_ store: UsageStore, _ layout: PanelLayout) {
        store.settings.panelLayout.propose(layout)
        store.settings.panelLayout.save()
    }

    /// The panel's natural height at its layout's width beside the notch; one agent's own panel when `focus` names one.
    private func height(_ store: UsageStore, focus: String? = nil) -> CGFloat {
        let style = store.settings.panelLayout.effective.style
        let width = focus == nil ? style.panelWidth : style.agentPanelWidth
        return autoreleasepool {
            NSHostingView(rootView: HoverPanelView(store: store, onOpenStats: {}, focusVendor: focus).frame(width: CGFloat(width)))
                .fittingSize.height
        }
    }

    /// Claude's and Codex's blocks drawn with `widgets`, each its first measure first, both half a line where `half`;
    /// Claude beside the balance where `besideBalance`; the token chart and the sessions hidden.
    private func layout(_ widgets: (PanelWidget, PanelWidget), first measure: PanelMeasure = .quota, half: Bool = true,
                        besideBalance: Bool = false, spacing: PanelSpacing = .regular, separators: Bool = true,
                        width: Int = PanelStyle.defaultWidth, hidden: [PanelSection] = [.tokens, .sessions]) -> PanelLayout {
        func block(_ widget: PanelWidget) -> PanelLayout.Block {
            let offered = PanelBlockKind.quota.measures(under: widget)
            let measures = offered.contains(measure) ? [measure] + offered.filter { $0 != measure } : []
            return PanelLayout.Block(widget: widget, measures: measures, span: half ? .half : nil)
        }
        var blocks = ["Claude": block(widgets.0), "Codex": block(widgets.1)]
        if besideBalance { blocks[Self.balance] = PanelLayout.Block(span: half ? .half : nil) }
        return PanelLayout(blocks: blocks, order: besideBalance ? ["Claude", Self.balance, "Codex"] : [], hiddenSections: hidden,
                           style: PanelStyle(spacing: spacing, separators: separators, width: width))
    }

    /// A half block of the plan drawn alone, at half the content's width less the gap, as its line draws it.
    private func ownHeight(_ store: UsageStore, _ block: PanelBlockPlan, plan: PanelLayoutPlan) -> CGFloat {
        let content = CGFloat(plan.style.panelWidth) - HoverPanelView.notchInsets.leading - HoverPanelView.notchInsets.trailing
        let spacing = PanelSpacingMetrics(plan.style.spacing)
        let half = (content - spacing.blocks) / 2
        let view: AnyView
        switch block.kind {
        case .quota:
            let rows = store.rowGroups.first { $0.vendor == block.key }?.rows ?? []
            view = AnyView(ProviderQuotaBlock(store: store, rows: rows, plan: block))
        case .billing:
            let accounts = store.enabledBilling.filter { $0.panelBlockKey == block.key }
            view = AnyView(VStack(spacing: spacing.blocks) {
                ForEach(accounts) { APIBillingCard(billing: $0, store: store, theme: .island, compact: true) }
            })
        }
        return NSHostingView(rootView: view.environment(\.panelHalf, true).environment(\.panelSpacing, spacing).frame(width: half))
            .fittingSize.height
    }

    // MARK: Lines

    /// Two halves share a line as tall as the taller of them, at 540 and 720 pt, at every spacing, in both languages,
    /// beside each other and beside a balance; the panel is shorter than with each across the whole line.
    func testTwoHalvesShareALineAsTallAsTheTallerOfThem() throws {
        for language in [AppLanguage.en, .zhHans] {
            let store = sample(language)
            for width in [PanelStyle.defaultWidth, PanelStyle.widthRange.upperBound] {
                for spacing in PanelSpacing.allCases {
                    for (widgets, beside) in [((PanelWidget.ring, PanelWidget.number), false), ((.chart, .number), true)] {
                        let asked = layout(widgets, besideBalance: beside, spacing: spacing, width: width)
                        keep(store, asked)
                        let plan = PanelLayoutPlan(layout: asked, blocks: store.view.panelBlocks)
                        let pair = try XCTUnwrap(plan.lines.first, "\(language) \(width) \(spacing)")
                        XCTAssertEqual(pair.map(\.span), [.half, .half], "\(language) \(width) \(spacing) \(widgets)")
                        let paired = height(store)
                        var alone = asked
                        alone.blocks = alone.blocks.filter { !pair.map(\.key).contains($0.key) }
                        for key in pair.map(\.key) { alone.blocks[key] = PanelLayout.Block(hidden: true) }
                        keep(store, alone)
                        let line = paired - height(store)
                        let tallest = pair.map { ownHeight(store, $0, plan: plan) }.max() ?? 0
                        // The line is the first, and the gap below it goes with it; the block after it, Codex's,
                        // has a divider only below another, where a balance's card always has its own.
                        let gaps = PanelSpacingMetrics(spacing)
                        let below = gaps.blocks + (beside ? gaps.divided : 0)
                        XCTAssertEqual(line, tallest + below, accuracy: 0.5, "\(language) \(width) \(spacing) \(widgets)")
                        keep(store, layout(widgets, half: false, besideBalance: beside, spacing: spacing, width: width))
                        XCTAssertLessThan(paired, height(store) - 20, "\(language) \(width) \(spacing): one line instead of two")
                    }
                }
            }
        }
    }

    /// At 480 pt a half would be too narrow, and in one agent's own panel only one block is drawn: each half takes the
    /// whole line, so the panel is the panel those blocks draw without a span.
    func testAtTheNarrowestWidthAndInAnAgentsOwnPanelHalvesTakeTheWholeLine() {
        for language in [AppLanguage.en, .zhHans] {
            let store = sample(language)
            for spacing in PanelSpacing.allCases {
                for beside in [false, true] {
                    let narrow = PanelStyle.widthRange.lowerBound
                    keep(store, layout((.ring, .number), besideBalance: beside, spacing: spacing, width: narrow))
                    let halves = height(store), own = height(store, focus: "Codex")
                    keep(store, layout((.ring, .number), half: false, besideBalance: beside, spacing: spacing, width: narrow))
                    XCTAssertEqual(halves, height(store), accuracy: 0.5, "\(language) \(spacing) at 480")
                    XCTAssertEqual(own, height(store, focus: "Codex"), accuracy: 0.5, "\(language) \(spacing), Codex's own panel")
                    keep(store, layout((.ring, .number), besideBalance: beside, spacing: spacing))
                    let wide = height(store, focus: "Codex")
                    keep(store, layout((.ring, .number), half: false, besideBalance: beside, spacing: spacing))
                    XCTAssertEqual(wide, height(store, focus: "Codex"), accuracy: 0.5, "\(language) \(spacing), Codex's own at 540")
                }
            }
        }
    }

    /// How the panel sets out two halves: in which language, at which width and spacing, with which widgets, beside each
    /// other or beside a balance, with or without separators.
    private struct Arrangement {
        var language = AppLanguage.en
        var width = PanelStyle.defaultWidth
        var spacing = PanelSpacing.regular
        var widgets: [PanelWidget]
        var beside = false
        var separators = true

        var pair: (PanelWidget, PanelWidget) { (widgets[0], widgets[1]) }
    }

    /// The island is sized from the measure each block shows first, so a half block of each kind keeps one height in
    /// every measure: rings, numbers and charts beside each other and beside a balance, one option at a time from rings
    /// side by side in the default panel and from Chinese compact charts beside a balance at 720 pt.
    func testAHalfBlockOfEachKindIsAsTallInEveryMeasure() {
        var checked = 0
        let arrangements = OneAtATime(from: Arrangement(widgets: [.ring, .ring]),
                                      Arrangement(language: .zhHans, width: PanelStyle.widthRange.upperBound, spacing: .compact,
                                                  widgets: [.chart, .chart], beside: true))
            .varying(\.language, over: [.en, .zhHans])
            .varying(\.width, over: [PanelStyle.defaultWidth, PanelStyle.widthRange.upperBound])
            .varying(\.spacing, over: PanelSpacing.allCases)
            .varying(\.widgets, over: [PanelWidget.ring, .number, .chart].map { [$0, $0] })
            .varying(\.beside, over: [false, true])
        for each in arrangements.arrangements {
            let store = sample(each.language)
            let heights = PanelBlockKind.quota.measures(under: each.widgets[0]).map { measure -> CGFloat in
                keep(store, layout(each.pair, first: measure, besideBalance: each.beside, spacing: each.spacing, width: each.width))
                return height(store)
            }
            XCTAssertEqual(heights.max() ?? 0, heights.min() ?? 1, accuracy: 0.5, "\(each): \(heights)")
            checked += 1
        }
        // Each base, then the other language, the other width, 2 spacings, 2 widgets and the other neighbour.
        XCTAssertEqual(checked, 2 * (1 + 1 + 1 + 2 + 2 + 1))
    }

    /// The island opens the panel at the height a fresh view tree measures; drawn as the island draws it, at that height
    /// with its content scrolling, the panel reports the same height, so two halves set no height from anything a view
    /// keeps. In both languages, at 540 and 720 pt, at every spacing, with and without separators, with every section:
    /// one option at a time from a ring beside a number in the default panel and from a Chinese compact chart beside a
    /// ring and a balance at 720 pt without separators.
    func testThePanelDrawnAsTheIslandDrawsItReportsTheHeightAFreshTreeMeasures() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 720, height: 1_200), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var checked = 0
        let arrangements = OneAtATime(from: Arrangement(widgets: [.ring, .number]),
                                      Arrangement(language: .zhHans, width: PanelStyle.widthRange.upperBound, spacing: .compact,
                                                  widgets: [.chart, .ring], beside: true, separators: false))
            .varying(\.language, over: [.en, .zhHans])
            .varying(\.width, over: [PanelStyle.defaultWidth, PanelStyle.widthRange.upperBound])
            .varying(\.spacing, over: PanelSpacing.allCases)
            .varying(\.widgets, over: [[.ring, .number], [.chart, .ring]])
            .varying(\.beside, over: [false, true])
            .varying(\.separators, over: [true, false])
        for each in arrangements.arrangements {
            let store = sample(each.language), width = CGFloat(each.width)
            keep(store, layout(each.pair, besideBalance: each.beside, spacing: each.spacing, separators: each.separators,
                               width: each.width, hidden: []))
            let natural = IslandWindowController.naturalHeight(of: HoverPanelView(store: store, onOpenStats: {}).frame(width: width))
            let reported = ReportedHeight()
            let hosting = NSHostingView(rootView: HoverPanelView(store: store, onOpenStats: {}, height: natural)
                .frame(width: width, alignment: .top)
                .fixedSize(horizontal: false, vertical: true)
                .onPreferenceChange(PanelHeightKey.self) { reported.value = $0 })
            window.contentView = hosting
            hosting.frame = CGRect(x: 0, y: 0, width: width, height: natural + 100)
            for _ in 0..<50 where reported.value == 0 {
                hosting.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            window.contentView = nil
            XCTAssertEqual(reported.value, natural, accuracy: 0.5, "\(each)")
            checked += 1
        }
        // Each base, then the other language, the other width, 2 spacings, the other widgets, the other neighbour and
        // the other separators.
        XCTAssertEqual(checked, 2 * (1 + 1 + 1 + 2 + 1 + 1 + 1))
    }

    // MARK: Identity

    /// Where one of two halves asks for another widget, only that one is another view and its picker starts again; the
    /// line and the other half stay, and so does the measure a person flipped that half to. A line of one block is that
    /// block, as before blocks shared lines.
    func testAHalfKeepsItsPickerWhenOnlyTheBlockBesideItChanges() throws {
        let store = sample(.en)
        let panel = HoverPanelView(store: store, onOpenStats: {})
        func lines(_ codex: PanelWidget, half: Bool = true) -> [HoverPanelView.BlockLine] {
            panel.blockLines(PanelLayoutPlan(layout: layout((.ring, codex), half: half), blocks: store.view.panelBlocks))
        }
        let before = try XCTUnwrap(lines(.number).first), after = try XCTUnwrap(lines(.chart).first)
        XCTAssertEqual(before.blocks.map(\.plan.key), ["Claude", "Codex"])
        XCTAssertEqual(after.id, before.id, "the shared line stays")
        XCTAssertEqual(after.blocks[0].id, before.blocks[0].id, "Claude's block, and its picker, stay")
        XCTAssertNotEqual(after.blocks[1].id, before.blocks[1].id, "Codex's block is another view")
        for line in lines(.number, half: false) {
            XCTAssertEqual(line.id, try XCTUnwrap(line.blocks.first).id)
        }
    }

    /// While a half fades over to another block both are drawn, and both stand in the half that block takes.
    func testAViewStandsInTheHalfItsSideNames() throws {
        func bar(_ color: Color, _ side: Int) -> some View {
            color.frame(height: 20).layoutValue(key: PanelHalves.Side.self, value: side)
        }
        let renderer = ImageRenderer(content: PanelHalves(gap: 10) {
            bar(Color(red: 1, green: 0, blue: 0), 0)
            bar(Color(red: 0, green: 1, blue: 0), 1)
            bar(Color(red: 0, green: 0, blue: 1), 1)
        }
        .frame(width: 210, height: 20))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        let rep = NSBitmapImageRep(cgImage: image)
        func color(at x: Int) throws -> NSColor { try XCTUnwrap(rep.colorAt(x: x, y: 10)?.usingColorSpace(.deviceRGB)) }
        XCTAssertGreaterThan(try color(at: 50).redComponent, 0.8, "the left half")
        XCTAssertGreaterThan(try color(at: 160).blueComponent, 0.8, "the right half, drawn over by the view fading in")
        XCTAssertLessThan(try color(at: 160).greenComponent, 0.5)
    }

    // MARK: The divider between

    /// Where separators are on, a thin divider stands in the middle of the gap between two halves, down the line; where
    /// they are off, nothing does, and the panel is as tall.
    func testAThinDividerStandsBetweenTwoHalvesWhereSeparatorsAreOn() throws {
        let store = sample(.en)
        func column(separators: Bool) throws -> (lit: Int, height: Double) {
            var asked = layout((.ring, .number), separators: separators, hidden: [.tokens, .sessions])
            asked.blocks[Self.balance] = PanelLayout.Block(hidden: true)
            keep(store, asked)
            let renderer = PanelPictureRenderer(store: store, display: .init(insets: HoverPanelView.notchInsets, maximumHeight: 2_000))
            let picture = try XCTUnwrap(renderer.draw(masked: false))
            let rep = try XCTUnwrap(NSBitmapImageRep(data: picture.png))
            let scale = picture.scale
            let insets = HoverPanelView.notchInsets
            let middle = insets.leading + (CGFloat(picture.width) - insets.leading - insets.trailing) / 2
            // The line's own rows, from the top inset to well above the footer's line.
            let top = Int(insets.top * scale), bottom = Int((picture.fit.height - 60) * scale)
            var lit = 0
            for y in top..<bottom {
                let brightest = [-1, 0].compactMap { rep.colorAt(x: Int(middle * scale) + $0, y: y)?.usingColorSpace(.deviceRGB) }
                    .map { max($0.redComponent, $0.greenComponent, $0.blueComponent) }.max() ?? 0
                if brightest > 0.05 { lit += 1 }
            }
            return (lit, picture.fit.height)
        }
        let on = try column(separators: true), off = try column(separators: false)
        XCTAssertGreaterThan(on.lit, Int(100 * PanelPicture.pointScale), "the divider runs down the line")
        XCTAssertEqual(off.lit, 0, "no divider without separators, and nothing else in the gap")
        XCTAssertEqual(on.height, off.height, "the divider takes no room")
    }

    // MARK: The default view

    /// The default layout draws the panel it drew before blocks had spans, and so do the whole line spelt out for every
    /// block and a stored half on bar rows, which falls back to the whole line.
    func testTheDefaultLayoutIsThePanelItWas() throws {
        for language in [AppLanguage.en, .zhHans] {
            let store = sample(language)
            store.settings.panelLayout.reset()
            XCTAssertTrue(store.settings.panelLayout.effective.isDefault)
            let plan = PanelLayoutPlan(layout: PanelLayout(), blocks: store.view.panelBlocks)
            XCTAssertTrue(plan.lines.allSatisfy { $0.count == 1 })
            let before = height(store), own = height(store, focus: "Claude")
            let keys = store.view.panelBlocks.map(\.key)
            keep(store, PanelLayout(blocks: Dictionary(uniqueKeysWithValues: keys.map { ($0, PanelLayout.Block(span: .full)) })))
            XCTAssertEqual(height(store), before, accuracy: 0.5, "\(language): the whole line, spelt out")
            let stored = try JSONDecoder().decode(PanelLayout.self, from: Data(
                #"{"blocks": {"Claude": {"span": "half"}, "Codex": {"span": "half"}}}"#.utf8))
            keep(store, stored)
            XCTAssertEqual(height(store), before, accuracy: 0.5, "\(language): bar rows keep the whole line")
            XCTAssertEqual(height(store, focus: "Claude"), own, accuracy: 0.5)
            store.settings.panelLayout.reset()
        }
    }
}
