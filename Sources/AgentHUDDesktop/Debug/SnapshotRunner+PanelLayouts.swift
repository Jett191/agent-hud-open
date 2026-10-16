import AppKit
import SwiftUI
import AgentHUDCore

#if DEBUG
/// The hover panel's stills under layouts an agent might propose, named `panel-layout-…`.
extension SnapshotRunner {
    /// The hover panel under layouts an agent might propose: each widget with each measure first; an unsaved draft that
    /// mixes widgets, reorders the blocks and hides a section; each spacing, the panel without separators, a ring block
    /// at each size, a block of six windows in two and in six columns, blocks offering two measures and one, a block
    /// with its countdown hidden, the layouts kept per screen (`saveScreenLayouts`), an agent's style drafts and the
    /// panel's widths (`saveHUDStyles`), the session rows and the token chart under a layout's filters (`saveFilters`),
    /// and blocks that take half a line (`saveHalves`). They are drawn from a settings store of their own, with the
    /// preferences the other stills have at this point: a layout once saved leaves a previous one behind, which every
    /// Settings still after these would show as something to revert to.
    static func saveLayouts(preferences: AgentHUDCore.Settings, folder: URL) {
        if let prefix = ProcessInfo.processInfo.environment["AGENTHUD_SNAPSHOT_PREFIX"],
           !"panel-layout".hasPrefix(prefix) && !prefix.hasPrefix("panel-layout") { return }
        let suite = "app.agenthud.open.snapshot.layout"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, defaultAgents: DemoData.agents)
        settings.update { $0 = preferences }
        let store = demoStore(settings)
        store.sampleTurnCalls = { DemoData.turnCalls(session: $0.id, turn: $1) }
        store.replace(report: DemoUsageProvider.report(agents: settings.agents, historyHours: UsageStore.historyHours, now: DemoClock.now))

        let layout = settings.panelLayout
        let quota = store.view.panelBlocks.filter { $0.kind == .quota }
        func every(_ block: PanelLayout.Block) -> PanelLayout {
            PanelLayout(blocks: Dictionary(uniqueKeysWithValues: quota.map { ($0.key, block) }))
        }
        func shoot(_ name: String, _ proposal: PanelLayout) {
            layout.propose(proposal)
            layout.save()
            save("panel-layout-\(name)", IslandScene(store: store, settings: settings, open: true, light: false),
                 folder: folder, scheme: .dark)
        }
        for widget in PanelBlockKind.quota.widgets {
            let offered = PanelBlockKind.quota.measures(under: widget)
            for measure in offered where !(widget == .bar && measure != .cost) {
                // The measure first and the others after it, so the picker offers them all.
                let measures = [measure] + offered.filter { $0 != measure }
                shoot("\(widget.rawValue)-\(measure.rawValue)", every(PanelLayout.Block(widget: widget, measures: measures)))
            }
        }
        for spacing in [PanelSpacing.compact, .roomy] {
            shoot("spacing-\(spacing.rawValue)", PanelLayout(style: PanelStyle(spacing: spacing)))
        }
        shoot("no-separators", PanelLayout(style: PanelStyle(separators: false)))
        for size in PanelRingSize.allCases {
            shoot("ring-\(size.rawValue)", every(PanelLayout.Block(widget: .ring, ringSize: size)))
        }
        if let first = quota.first, let last = quota.last, quota.count > 1 {
            shoot("measures-two", PanelLayout(blocks: [first.key: PanelLayout.Block(measures: [.quota, .cost])]))
            shoot("measures-one", PanelLayout(blocks: [first.key: PanelLayout.Block(measures: [.burnRate])]))
            shoot("countdown-hidden", PanelLayout(blocks: [first.key: PanelLayout.Block(countdown: false),
                                                           last.key: PanelLayout.Block(widget: .ring, countdown: false)]))
        }
        saveColumns(preferences: preferences, folder: folder)
        saveScreenLayouts(preferences: preferences, folder: folder)
        saveHUDStyles(preferences: preferences, folder: folder)
        saveFilters(preferences: preferences, folder: folder)
        saveHalves(preferences: preferences, folder: folder)

        layout.reset()
        var blocks: [String: PanelLayout.Block] = [:]
        if let first = quota.first { blocks[first.key] = PanelLayout.Block(widget: .ring) }
        if let last = quota.last, quota.count > 1 {
            blocks[last.key] = PanelLayout.Block(widget: .number, measures: [.burnRate, .quota, .tokens, .cost])
        }
        layout.propose(PanelLayout(blocks: blocks, order: quota.last.map { [$0.key] } ?? [], hiddenSections: [.tokens]))
        save("panel-layout-draft", IslandScene(store: store, settings: settings, open: true, light: false), folder: folder, scheme: .dark)
        save("panel-layout-settings-dark", SettingsView(settings: settings, store: store, initialTab: .display)
            .frame(width: SettingsWindowLayout.size.width, height: SettingsWindowLayout.size.height), folder: folder, scheme: .dark,
             scrollToBottom: true)
    }

    /// Claude's block with six windows, three more of its models' weeks than the sample has, as rings in two columns
    /// and in six: three lines of two, and one line of six. Then with five, two more weeks than the sample has, four
    /// to a line: four, and one centred under them (`panel-layout-triangle-five`).
    private static func saveColumns(preferences: AgentHUDCore.Settings, folder: URL) {
        func shoot(_ name: String, weeks used: [String: Double], columns: Int) {
            let suite = "app.agenthud.open.snapshot.layout-columns"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            defer { defaults.removePersistentDomain(forName: suite) }
            let now = DemoClock.now
            let weeks = ClaudeUsage(fiveHour: nil, sevenDay: nil, modelWeekly: used.mapValues {
                ClaudeUsageWindow(utilizationPct: $0, resetsAt: nil)
            }).rows
            let added = weeks.map { row in
                AgentDescriptor(id: DemoData.claudeAccount.windowID(row.id), vendor: "Claude", model: row.label,
                                source: L10n.sourceClaudeCode, enabled: true, account: DemoData.claudeAccount, allModels: false)
            }
            let settings = SettingsStore(defaults: defaults, defaultAgents: DemoData.agents + added)
            settings.update { $0 = preferences }
            let sample = DemoUsageProvider.report(agents: DemoData.agents, historyHours: UsageStore.historyHours, now: now)
            let readings = zip(weeks, added).map { row, agent in
                UsageSnapshot(agentId: agent.id, remainingPct: QuotaMath.remaining(usedPercent: row.window.utilizationPct),
                              resetAt: now.addingTimeInterval(5 * 86400), windowDuration: 7 * 86400, updatedAt: now)
            }
            let store = demoStore(settings)
            store.replace(report: UsageReport(
                generatedAt: now, snapshots: sample.snapshots + readings, sessions: sample.sessions,
                discoveredAgents: sample.discoveredAgents + added, consumers: sample.consumers, usage: sample.usage,
                insightsByAgent: sample.insightsByAgent, subscriptions: sample.subscriptions,
                consumerIdsByQuota: sample.consumerIdsByQuota, billing: sample.billing, codexResetCredits: sample.codexResetCredits,
                accounts: sample.accounts, sessionUsage: sample.sessionUsage, periods: sample.periods, recached: sample.recached))
            settings.panelLayout.propose(PanelLayout(blocks: ["Claude": PanelLayout.Block(widget: .ring, columns: columns)]))
            settings.panelLayout.save()
            save("panel-layout-\(name)", IslandScene(store: store, settings: settings, open: true, light: false),
                 folder: folder, scheme: .dark)
        }
        let three: [String: Double] = ["opus": 35, "sonnet": 22, "haiku": 8]
        for columns in [2, 6] {
            shoot("columns-\(columns)", weeks: three, columns: columns)
        }
        shoot("triangle-five", weeks: ["opus": 35, "sonnet": 22], columns: 4)
    }
}
#endif
