import AgentHUDSupport
import Foundation

/// What `get_panel` tells an agent, and what every tool but `get_panel_image` answers with.
extension PanelTools {
    // MARK: Reading

    /// The screen argument that names a scope.
    static func name(of scope: PanelLayoutScope) -> String {
        guard case .screen(let key) = scope else { return "all" }
        return key
    }

    /// Whether the panel of a scope shows a draft: the shared layout's own, or for a screen the one its bar saves.
    func unsaved(_ scope: PanelLayoutScope) -> Bool {
        guard case .screen(let key) = scope else { return layout.hasDraft }
        return layout.hasDraft(on: key)
    }

    /// The panel as an agent reads it: which screen, the layout in effect there, with a screen's style draft in its
    /// hud, and the style it sets, its width among it, the panel's height on that display and whether it scrolls there,
    /// whether Settings shows reset countdowns, every section and every block the panel has, shown or hidden, with the
    /// span each takes there and the readings of its rows, the session rows and the token chart as the layout filters
    /// them, and the attached screens.
    /// - proposed: whether the note answers a proposal, after which it says which blocks the layout gives half a line
    ///   take the whole one there, and why.
    func panel(_ scope: PanelLayoutScope, among attached: [PanelScreen], note: String? = nil,
               proposed: Bool = false) -> [String: JSONValue] {
        let effective = effective(scope), existing = store.view.panelBlocks
        let measured = fit?(scope)
        let plan = PanelLayoutPlan(layout: effective, blocks: existing, contentWidth: measured?.contentWidth)
        let settings = store.settings.settings
        let switches: [PanelSection: Bool] = [.blocks: settings.showIslandQuota, .tokens: settings.showIslandTokens,
                                              .sessions: settings.showIslandSessions]
        let sections = plan.sections + PanelSection.allCases.filter { !plan.sections.contains($0) }
        let shown = Set(plan.blocks.map(\.key))
        let drawn = plan.blocks + existing.filter { !shown.contains($0.key) }
            .map { PanelBlockPlan($0, changed: effective.blocks[$0.key] ?? PanelLayout.Block()) }
        let style: [String: JSONValue] = ["spacing": .string(plan.style.spacing.rawValue), "separators": .bool(plan.style.separators),
                                          "width": .integer(Int64(plan.style.panelWidth))]
        var result: [String: JSONValue] = [
            "screen": .string(Self.name(of: scope)),
            "revision": .integer(revision),
            "unsaved": .bool(unsaved(scope)),
            "hasPrevious": .bool(layout.canRevert(scope)),
            "layout": layoutJSON(scope),
            "style": .object(style),
            "countdownOnInSettings": .bool(settings.showResetCountdown),
            "sections": .array(sections.map { section in
                .object(["key": .string(section.rawValue), "shown": .bool(plan.sections.contains(section)),
                         "onInSettings": .bool(switches[section] ?? true)])
            }),
            "blocks": .array(drawn.map { block(of: $0, shown: shown.contains($0.key)) }),
            "sessions": sessions(plan.sessions, listing: effective.sessions.normalized().agents),
            "tokens": tokens(plan.tokens, listing: effective.tokens.normalized().agents),
            "screens": .array(attached.map(listing)),
        ]
        if case .screen(let key) = scope { result["usesSharedLayout"] = .bool(layout.usesShared(key)) }
        if let measured {
            result["height"] = .integer(Int64(measured.height.rounded()))
            result["scrolls"] = .bool(measured.scrolls)
        }
        if let note { result["note"] = .string(proposed ? note + Self.wholeLines(plan, asked: effective) : note) }
        return result
    }

    /// What says which blocks the layout gives half a line take the whole one, and why: a sentence after a note, or
    /// nothing where every such block shares a line.
    private static func wholeLines(_ plan: PanelLayoutPlan, asked layout: PanelLayout) -> String {
        let whole = plan.blocks.filter { block in
            layout.blocks[block.key]?.span == .half && block.kind.takesHalf(under: block.widget) && block.span == .full
        }
        guard !whole.isEmpty else { return "" }
        let names = PanelLayout.quoted(whole.map(\.key))
        let reason = plan.halvesFit ? "no half block is left next to \(whole.count == 1 ? "it" : "each") to share a line with"
            : "the panel is too narrow here for two halves side by side"
        return " \(names) \(whole.count == 1 ? "takes" : "take") the whole line: \(reason)."
    }

    /// One attached screen as an agent reads it: its key and role, how it presents the HUD, which layout its panel
    /// draws, the panel's width there and whether the panel shows a draft, its resting HUD's style in effect and
    /// whether a style draft waits, the agents its resting HUD can show now, and those it shows under its layout.
    private func listing(_ screen: PanelScreen) -> JSONValue {
        let drawn = layout.effective(for: screen.key)
        let order = HUDAgentOrder(listed: drawn.hud.agents, available: screen.agents)
        return .object([
            "key": .string(screen.key), "name": .string(screen.name), "mode": .string(screen.modeName),
            "edge": .string(screen.edge.rawValue), "hasNotch": .bool(screen.hasNotch),
            "layout": .string(layout.usesShared(screen.key) ? "shared" : "own"),
            "width": .integer(Int64(drawn.style.panelWidth)),
            "unsaved": .bool(layout.hasDraft(on: screen.key)),
            "hud": styleInEffect(of: screen),
            "styleUnsaved": .bool(layout.hasStyleDraft(screen.key)),
            "agents": .array(screen.agents.map(JSONValue.string)),
            "shows": .array(order.arrange(screen.agents) { $0 }.map(JSONValue.string)),
        ])
    }

    /// One block as an agent reads it: how it is drawn, what it offers, and its readings. The countdown, the columns
    /// and the ring size are told only where the block has them to set, and the columns and the span as the panel sets
    /// the block in its line.
    private func block(of plan: PanelBlockPlan, shown: Bool) -> JSONValue {
        var block: [String: JSONValue] = [
            "key": .string(plan.key), "kind": .string(plan.kind.rawValue), "shown": .bool(shown),
            "widget": .string(plan.widget.rawValue),
            "widgets": .array(plan.kind.widgets.map { .string($0.rawValue) }),
            "measures": .array(plan.measures.map { .string($0.rawValue) }),
            "offeredMeasures": .array(plan.kind.measures(under: plan.widget).map { .string($0.rawValue) }),
        ]
        if plan.kind.takesCountdown {
            block["countdown"] = .bool(plan.countdown && store.settings.settings.showResetCountdown)
        }
        if plan.kind.takesColumns(under: plan.widget) { block["columns"] = .integer(Int64(plan.columns)) }
        if plan.kind.takesRingSize(under: plan.widget) { block["ringSize"] = .string(plan.ringSize.rawValue) }
        block["span"] = .string(plan.span.rawValue)
        switch plan.kind {
        case .quota:
            block["name"] = .string(VendorCatalog.name(plan.key))
            let rows = store.rowGroups.first { $0.vendor == plan.key }?.rows ?? []
            block["rows"] = .array(rows.map { reading(of: $0, shown: !plan.hiddenRows.contains($0.agent.windowKey)) })
        case .billing:
            let accounts = store.enabledBilling.filter { $0.panelBlockKey == plan.key }
            block["name"] = .string(accounts.first?.displayName ?? plan.key)
            block["balances"] = .array(accounts.flatMap { account in
                account.balances.map { balance -> JSONValue in
                    var entry: [String: JSONValue] = ["currency": .string(balance.currency), "amount": .string("\(balance.total)"),
                                                      "state": .string(Self.state(store.view.assessment(of: account)))]
                    if let level = store.balanceLevel(balance, billing: account) { entry["level"] = .string(level.rawValue) }
                    if let date = balance.runsOutAt { entry["runsOutAt"] = .string(Self.time(date)) }
                    return .object(entry)
                }
            })
        }
        return .object(block)
    }

    /// The session rows as an agent reads them: the limit, the agents and the states in effect, the agents that have
    /// sessions now, how many rows are shown and how many more the filter lists, and how many sessions of the last day
    /// each state has before the filter. Counts and names of agents only: no title, prompt, project, path or session id.
    private func sessions(_ filter: PanelSessionFilter, listing agents: [String]) -> JSONValue {
        let view = store.view, rows = view.panelSessions(filter)
        let states = filter.states.isEmpty ? PanelSessionState.allCases : PanelSessionState.allCases.filter(filter.states.contains)
        return .object([
            "limit": .integer(Int64(filter.limit)),
            "agents": .array(agents.map(JSONValue.string)),
            "states": .array(states.map { .string($0.rawValue) }),
            "offeredAgents": .array(view.panelSessionAgents.map(JSONValue.string)),
            "shown": .integer(Int64(rows.shown.count)),
            "more": .integer(Int64(rows.more)),
            "byState": .object(Dictionary(uniqueKeysWithValues: PanelSessionState.allCases.map {
                ($0.rawValue, JSONValue.integer(Int64(rows.counts[$0] ?? 0)))
            })),
        ])
    }

    /// The token chart as an agent reads it: the period it opens with, the agents in effect, the agents whose models it
    /// can draw now, and the tokens it counts over that period.
    private func tokens(_ filter: PanelTokenFilter, listing agents: [String]) -> JSONValue {
        let columns = store.hudTokenColumns(consumerIDs: store.panelTokenConsumers(filter), period: filter.period)
        return .object([
            "period": .string(filter.period.rawValue),
            "agents": .array(agents.map(JSONValue.string)),
            "offeredAgents": .array(store.view.panelTokenAgents.map(JSONValue.string)),
            "total": .integer(Int64(columns.reduce(0) { $0 + $1.total })),
        ])
    }

    /// One quota window's reading: numbers and times only, with no account name. Its name is the window's as the panel
    /// writes it, in the application's language: its provider worded it when it was read, and it is how the person
    /// who looks at the panel will call the row. A reading that shows no level has no burn rate, run-out time or token
    /// rate, as in the panel.
    private func reading(of row: AgentRow, shown: Bool) -> JSONValue {
        var reading: [String: JSONValue] = [
            "key": .string(row.agent.windowKey), "name": .string(row.agent.name), "shown": .bool(shown),
            "state": .string(Self.state(row.assessment)),
        ]
        if let used = row.usedPct { reading["usedPercent"] = .number(Self.tenths(used)) }
        if let level = row.level { reading["level"] = .string(level.rawValue) }
        if let reset = row.resetAt { reading["resetsAt"] = .string(Self.time(reset)) }
        if row.assessment.showsLevel, let rate = store.report?.insightsByAgent[row.id]?.burnRatePctPerHour {
            reading["burnPercentPerHour"] = .number(Self.tenths(rate))
        }
        if case .exhausts(let interval, beforeReset: true)? = store.view.outlook(for: row.id) {
            reading["runsOutAt"] = .string(Self.time(store.now.addingTimeInterval(interval)))
        }
        if let tokens = store.quotaTokensPerHour(for: row.id) { reading["tokensPerHour"] = .integer(Int64(tokens)) }
        return .object(reading)
    }

    /// The first thing that holds a reading back, in the order the panel weighs them; "normal" when nothing does.
    private static func state(_ assessment: ReadingAssessment) -> String {
        if !assessment.isCurrentAccount { return "other account" }
        switch assessment.status {
        case .readFailed: return "read failed"
        case .unverified: return "unverified"
        case .normal: break
        }
        if assessment.observedAt == nil { return "not read yet" }
        if !assessment.hasValue { return "no value" }
        if assessment.isResetPending { return "reset pending" }
        return assessment.isStale ? "stale" : "normal"
    }

    private static func tenths(_ value: Double) -> Double { (value * 10).rounded() / 10 }
    /// A picture's scale to the hundredth below it, which never reads as more pixels than were drawn.
    static func hundredths(_ value: Double) -> Double { (value * 100).rounded(.down) / 100 }
    static func points(_ value: Double) -> String { "\(Int64(value.rounded()))" }
    private static func time(_ date: Date) -> String { date.formatted(.iso8601) }
}
