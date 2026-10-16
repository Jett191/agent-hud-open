import AppKit
import SwiftUI
import AgentHUDCore

#if DEBUG
/// The stills of layouts kept per screen, named `panel-layout-…`.
extension SnapshotRunner {
    /// A screen's resting HUD under its own layout's list of agents, narrowed and reordered: a Dynamic dock, a Simple
    /// panel, and the glow beside the notch with only some agents' colours; that screen's panel with a draft of its own,
    /// whole and as an agent's own narrower panel; and the Display page of Settings with the first display using a
    /// layout of its own. They are drawn from a settings store of their own, with every agent the demo has, so the list
    /// has a full queue to narrow.
    static func saveScreenLayouts(preferences: AgentHUDCore.Settings, folder: URL) {
        let suite = "app.agenthud.open.snapshot.layout-screens"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, defaultAgents: DemoData.everyAgent)
        settings.update { $0 = preferences }
        let store = demoStore(settings)
        store.replace(report: DemoUsageProvider.report(agents: settings.agents, historyHours: UsageStore.historyHours, now: DemoClock.now))
        let layout = settings.panelLayout
        func keep(_ own: PanelLayout, for screen: String) {
            layout.propose(.own(own), for: screen)
            layout.save(.screen(screen))
        }

        // Four of the queue's marks, in an order of their own: Kimi first, Cursor last.
        let listed = ["Kimi", "Codex", "Claude", "Cursor"]
        keep(PanelLayout(hud: PanelLayout.HUD(agents: listed)), for: "snapshot-dock")
        save("panel-layout-hud-dynamic",
             LogoQueueScene(settings: settings, store: store, placement: ScreenPlacement(mode: .logos, logoSize: 24),
                            screen: "snapshot-dock"),
             folder: folder, scheme: .dark)
        let simple = ScreenPlacement(mode: .simple, simpleSize: 26)
        let items = ScreenAgents(store: store, listed: layout.effective(for: "snapshot-dock").hud.agents, mode: .simple).meterItems
        let meter = SimpleMeterConfig(items: items, placement: simple)
        save("panel-layout-hud-simple",
             SimpleMeterView(config: meter)
                .frame(width: meter.stripSize.width, height: meter.stripSize.height)
                .frame(width: 420, height: 90)
                .background(Color(white: 0.10)),
             folder: folder, scheme: .dark)

        // Beside the notch: a warning and a critical agent's colours alone, where every agent's would be many.
        keep(PanelLayout(hud: PanelLayout.HUD(agents: ["OpenClaw", "GitHub Copilot", "Claude"])), for: "snapshot-notch")
        save("panel-layout-hud-notch-glow", IslandScene(store: store, settings: settings, open: false, light: false,
                                                        screen: "snapshot-notch"),
             folder: folder, scheme: .dark)
        // That screen's panel with a draft of its own, whose bar says it is this display's alone.
        layout.propose(.own(PanelLayout(hiddenSections: [.blocks], hud: PanelLayout.HUD(agents: ["OpenClaw", "Claude"]))),
                       for: "snapshot-notch")
        save("panel-layout-screen-draft", IslandScene(store: store, settings: settings, open: true, light: false,
                                                      screen: "snapshot-notch"),
             folder: folder, scheme: .dark)
        // The same draft in Claude's own panel on a dock that separates its agents, whose narrower bar keeps one line.
        let agentPanel = HoverPanelView(store: store, onOpenStats: {},
                                        insets: IslandRootView.dockInsets(edge: .top, collapsedSize: CGSize(width: 120, height: 36)),
                                        focusVendor: "Claude", showsRefreshError: false, screen: "snapshot-notch")
        save("panel-layout-screen-draft-agent",
             agentPanel.frame(width: CGFloat(layout.effective(for: "snapshot-notch").style.agentPanelWidth), alignment: .top)
                .fixedSize(horizontal: false, vertical: true)
                .background(Color.black, in: RoundedRectangle(cornerRadius: IslandController.expandedRadius))
                .padding(20).background(Color(white: 0.10)),
             folder: folder, scheme: .dark)
        layout.discard(.screen("snapshot-notch"))

        // The first display keeps a layout of its own: rings for Claude, no token chart, and its own agents; and a
        // placement of its own, the one its hardware is given, so the HUD style's Reset to Default is offered beside the
        // layout's, and the layout's row says nothing of the style.
        if let first = ScreensPane.attached().first {
            keep(PanelLayout(blocks: ["Claude": PanelLayout.Block(widget: .ring)], hiddenSections: [.tokens],
                             hud: PanelLayout.HUD(agents: listed)), for: first.key)
            settings.update { $0.screens[first.key] = $0.screens[first.key] ?? .default(hasNotch: first.hasNotch) }
            saveDisplaySettings("panel-layout-settings-screen-dark", settings: settings, store: store, folder: folder)
        }
    }

    /// The Display page of Settings at the window's size.
    static func saveDisplaySettings(_ name: String, settings: SettingsStore, store: UsageStore, folder: URL) {
        save(name, SettingsView(settings: settings, store: store, initialTab: .display)
            .frame(width: SettingsWindowLayout.size.width, height: SettingsWindowLayout.size.height), folder: folder, scheme: .dark)
    }
}
#endif
