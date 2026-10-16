import AppKit
import SwiftUI
import XCTest
@testable import AgentHUDCore
@testable import AgentHUDDesktop

/// The whole hover panel at the widths a layout sets: every widget as tall in every measure at every spacing, in English
/// and in Chinese, for the whole panel and an agent's own; a wider panel is never taller; and the bar that says a draft
/// waits keeps one line in an agent's own panel at its narrowest. Measured as the island measures the panel, from a
/// fresh view tree at its width.
@MainActor
final class PanelWidthViewTests: XCTestCase {
    private var stores: [AppLanguage: UsageStore] = [:]

    /// The sample in `language`, over settings of its own. The interface speaks `language` from here on.
    private func sample(_ language: AppLanguage) -> UsageStore {
        L10n.setLanguage(language)
        if let known = stores[language] { return known }
        _ = NSApplication.shared
        let suite = "app.agenthud.tests.panel-width.\(UUID().uuidString)"
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

    /// The whole panel at the narrowest, the default and the widest width, and an agent's own at the narrowest and widest.
    private let whole = [PanelStyle.widthRange.lowerBound, PanelStyle.defaultWidth, PanelStyle.widthRange.upperBound]
    private var agent: [Int] { [PanelStyle(width: whole[0]).agentPanelWidth, PanelStyle(width: whole[2]).agentPanelWidth] }

    /// The panel's natural height at `width` under the shared layout, an agent's own panel when `focus` names one.
    private func height(_ store: UsageStore, width: Int, focus: String? = nil) -> CGFloat {
        autoreleasepool {
            NSHostingView(rootView: HoverPanelView(store: store, onOpenStats: {}, focusVendor: focus).frame(width: CGFloat(width)))
                .fittingSize.height
        }
    }

    /// Every quota block drawn with `widget` at `spacing`, its picker offering every measure with `measure` first, at the
    /// width `width` sets.
    private func keep(_ store: UsageStore, _ widget: PanelWidget, first measure: PanelMeasure, spacing: PanelSpacing, width: Int) {
        let offered = PanelBlockKind.quota.measures(under: widget)
        let keys = store.view.panelBlocks.filter { $0.kind == .quota }.map(\.key)
        let block = PanelLayout.Block(widget: widget, measures: [measure] + offered.filter { $0 != measure })
        store.settings.panelLayout.propose(PanelLayout(blocks: Dictionary(uniqueKeysWithValues: keys.map { ($0, block) }),
                                                       style: PanelStyle(spacing: spacing, width: width)))
        store.settings.panelLayout.save()
    }

    /// A panel's widget, spacing and width, in a language.
    private struct Arrangement {
        var language: AppLanguage
        var widget: PanelWidget
        var spacing: PanelSpacing
        var width: Int
    }

    /// The island is sized from the measure a block shows first, so every widget is as tall in every measure it offers,
    /// at every width and spacing, in both languages and in an agent's own panel: one option at a time, from the default
    /// panel and from Chinese compact rings at the narrowest width.
    func testEveryWidgetIsAsTallInEveryMeasureAtEveryWidth() {
        var checked = 0
        let arrangements = OneAtATime(from: Arrangement(language: .en, widget: .bar, spacing: .regular, width: PanelStyle.defaultWidth),
                                      Arrangement(language: .zhHans, widget: .ring, spacing: .compact, width: whole[0]))
            .varying(\.language, over: [.en, .zhHans])
            .varying(\.widget, over: PanelBlockKind.quota.widgets)
            .varying(\.spacing, over: PanelSpacing.allCases)
            .varying(\.width, over: whole)
        for each in arrangements.arrangements {
            let store = sample(each.language)
            let measures = PanelBlockKind.quota.measures(under: each.widget)
            var heights: [CGFloat] = [], own: [CGFloat] = []
            for measure in measures {
                keep(store, each.widget, first: measure, spacing: each.spacing, width: each.width)
                heights.append(height(store, width: each.width))
                own.append(height(store, width: PanelStyle(width: each.width).agentPanelWidth, focus: "Claude"))
            }
            XCTAssertEqual(heights.max() ?? 0, heights.min() ?? 1, accuracy: 0.5, "\(each): \(heights)")
            XCTAssertEqual(own.max() ?? 0, own.min() ?? 1, accuracy: 0.5, "\(each), Claude's own panel: \(own)")
            checked += 1
        }
        // Each base, then the other language, the other widgets, 2 spacings and 2 widths.
        XCTAssertEqual(checked, 2 * (1 + 1 + (PanelBlockKind.quota.widgets.count - 1) + 2 + 2))
    }

    /// The type scale is the same at every width: a wider panel lays the same text out on no more lines, so it is never
    /// taller, and the default panel is the panel it was.
    func testAWiderPanelIsNeverTaller() {
        for language in [AppLanguage.en, .zhHans] {
            let store = sample(language)
            for widget in PanelBlockKind.quota.widgets {
                let measure = PanelBlockKind.quota.measures(under: widget)[0]
                var previous = CGFloat.infinity
                for width in [whole[0], whole[1], 600, whole[2]] {
                    keep(store, widget, first: measure, spacing: .regular, width: width)
                    let drawn = height(store, width: width)
                    XCTAssertLessThanOrEqual(drawn, previous + 0.5, "\(language) \(widget) at \(width)")
                    previous = drawn
                }
            }
            store.settings.panelLayout.reset()
            XCTAssertEqual(height(store, width: PanelStyle.defaultWidth),
                           height(store, width: Int(IslandController.expandedWidth)), "540 is today's panel")
        }
    }

    /// Codex's earned resets name their first expiry whole in the default panel, and where the row has no room for that,
    /// as at the narrowest content any panel has, the date alone fits: the expiry gives way rather than being cut.
    func testTheResetsExpiryGivesWayRatherThanBeingCut() {
        for language in [AppLanguage.en, .zhHans] {
            _ = sample(language)
            let resets = DemoData.codexResetCredits(now: DemoClock.now)
            let label = CodexResetCreditsView(resets: resets, showExpiry: true).nextExpiryLabel
            XCTAssertNotEqual(label.short, label.full)
            func wide(_ text: String) -> CGFloat {
                NSHostingView(rootView: Text(text).font(.tabular(11)).lineLimit(1).fixedSize()).fittingSize.width
            }
            // The row at its own width, with the whole label: everything it holds, and the least room before the icon.
            let row = NSHostingView(rootView: CodexResetCreditsView(resets: resets, showExpiry: true).fixedSize()).fittingSize.width
            let content = CGFloat(PanelStyle.defaultWidth) - HoverPanelView.notchInsets.leading - HoverPanelView.notchInsets.trailing
            XCTAssertLessThanOrEqual(row, content, "\(language): whole in the default panel")
            XCTAssertLessThanOrEqual(row - wide(label.full) + wide(label.short), HoverPanelView.narrowestContentWidth,
                                     "\(language): the date alone fits the narrowest content")
        }
    }

    /// The bar that says a draft waits keeps one line, a style alone or a layout, in an agent's own panel at its narrowest
    /// and in the whole panel at its narrowest, in both languages.
    func testTheDraftBarKeepsOneLineAtTheNarrowestPanels() {
        for language in [AppLanguage.en, .zhHans] {
            let store = sample(language)
            let layout = store.settings.panelLayout
            layout.reset()
            let screen = "screen:width"
            func bar(_ width: Int) -> CGFloat {
                NSHostingView(rootView: PanelDraftBar(layout: layout, screen: screen).frame(width: CGFloat(width - 36)))
                    .fittingSize.height
            }
            layout.propose(.own(PanelLayout(hiddenSections: [.tokens])), for: screen)
            let line = bar(PanelStyle.defaultWidth)
            for width in [agent[0], whole[0]] { XCTAssertEqual(bar(width), line, accuracy: 0.5, "\(language) layout at \(width)") }
            layout.discard(.screen(screen))
            layout.proposeStyle(HUDStyle(logoSize: 30), for: screen, hasNotch: false)
            for width in [agent[0], whole[0]] { XCTAssertEqual(bar(width), line, accuracy: 0.5, "\(language) style at \(width)") }
            layout.discard(.screen(screen))
        }
    }
}
