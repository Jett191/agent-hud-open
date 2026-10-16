import AppKit
import SwiftUI
import AgentHUDCore

#if DEBUG
/// The stills of blocks that take half a line, named `panel-layout-half-…`.
extension SnapshotRunner {
    /// Half blocks in the hover panel: Claude's rings beside Codex's numbers at the default width and at the widest; a
    /// chart beside a balance, with Codex's bars across the line below; three half blocks, Claude's rings beside the
    /// balance and Codex's numbers alone on the line below, so across the whole of it in four columns; and the rings and
    /// numbers at the narrowest width, where a half would be too narrow and each block takes the whole line; and
    /// Claude's and Codex's rings side by side, three windows each, two and one centred under them
    /// (`panel-layout-triangle-half`). They are drawn from a settings store of their own, with the preferences the
    /// other stills have at this point.
    static func saveHalves(preferences: AgentHUDCore.Settings, folder: URL) {
        let suite = "app.agenthud.open.snapshot.layout-halves"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, defaultAgents: DemoData.agents)
        settings.update { $0 = preferences }
        let store = demoStore(settings)
        store.replace(report: DemoUsageProvider.report(agents: settings.agents, historyHours: UsageStore.historyHours, now: DemoClock.now))
        let balance = store.view.panelBlocks.first { $0.kind == .billing }?.key ?? "api:DeepSeek"
        func shoot(_ name: String, _ proposal: PanelLayout) {
            settings.panelLayout.propose(proposal)
            settings.panelLayout.save()
            save("panel-layout-half-\(name)", IslandScene(store: store, settings: settings, open: true, light: false),
                 folder: folder, scheme: .dark)
        }
        let ringsAndNumbers: [String: PanelLayout.Block] = [
            "Claude": PanelLayout.Block(widget: .ring, span: .half),
            "Codex": PanelLayout.Block(widget: .number, span: .half),
        ]
        shoot("rings-numbers", PanelLayout(blocks: ringsAndNumbers))
        shoot("rings-numbers-\(PanelStyle.widthRange.upperBound)",
              PanelLayout(blocks: ringsAndNumbers, style: PanelStyle(width: PanelStyle.widthRange.upperBound)))
        shoot("chart-balance", PanelLayout(blocks: ["Claude": PanelLayout.Block(widget: .chart, span: .half),
                                                    balance: PanelLayout.Block(span: .half)],
                                           order: ["Claude", balance]))
        var lone = ringsAndNumbers
        lone[balance] = PanelLayout.Block(span: .half)
        shoot("lone", PanelLayout(blocks: lone, order: ["Claude", balance, "Codex"]))
        shoot("rings-numbers-\(PanelStyle.widthRange.lowerBound)",
              PanelLayout(blocks: ringsAndNumbers, style: PanelStyle(width: PanelStyle.widthRange.lowerBound)))
        // Three windows two to a line in each half: two, and one centred under them.
        settings.panelLayout.propose(PanelLayout(blocks: ["Claude": PanelLayout.Block(widget: .ring, span: .half),
                                                          "Codex": PanelLayout.Block(widget: .ring, span: .half)]))
        settings.panelLayout.save()
        save("panel-layout-triangle-half", IslandScene(store: store, settings: settings, open: true, light: false),
             folder: folder, scheme: .dark)
        settings.panelLayout.reset()
    }
}
#endif
