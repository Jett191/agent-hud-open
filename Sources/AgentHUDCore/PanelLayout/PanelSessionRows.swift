import Foundation

/// Which sessions the hover panel's rows list under a layout, and how many rows they take: a layout's `sessions` in
/// effect (`PanelLayout.Sessions`). `PanelSessionFilter()` lists the default view's five rows of every session.
public struct PanelSessionFilter: Hashable, Sendable {
    /// How many rows the section shows at most.
    let limit: Int
    /// The marks (`VendorMark.key`) of the agents whose sessions are listed; empty for every agent.
    let agents: Set<String>
    /// The states listed; empty for every state.
    let states: Set<PanelSessionState>

    public init(_ sessions: PanelLayout.Sessions = PanelLayout.Sessions()) {
        limit = sessions.rowLimit
        agents = Set(sessions.agents.filter { !$0.isEmpty }.map(VendorMark.key))
        states = Set(sessions.states)
    }

    /// Whether a session of the execution agent `vendor` in `state` is listed.
    func keeps(vendor: String?, state: PanelSessionState) -> Bool {
        (agents.isEmpty || vendor.map { agents.contains(VendorMark.key($0)) } == true)
            && (states.isEmpty || states.contains(state))
    }
}

/// The hover panel's token chart under a layout: the period it starts from and whose tokens it draws, a layout's
/// `tokens` in effect (`PanelLayout.Tokens`). `PanelTokenFilter()` is the default view's: every agent's tokens over the
/// latest 24 hours.
public struct PanelTokenFilter: Hashable, Sendable {
    public let period: PanelTokenPeriod
    /// The marks (`VendorMark.key`) of the agents whose models are charted; empty for every agent.
    let agents: Set<String>

    public init(_ tokens: PanelLayout.Tokens = PanelLayout.Tokens()) {
        period = tokens.chartPeriod
        agents = Set(tokens.agents.filter { !$0.isEmpty }.map(VendorMark.key))
    }

    /// Whether the chart leaves out any agent's models.
    var narrows: Bool { !agents.isEmpty }

    /// Whether a model's tokens are charted: those of every model while no agent is named, else those of a model whose
    /// vendor as the panel's blocks show it (`AgentDescriptor.displayVendor`, as a quota block's chart matches its
    /// models) is drawn with a named agent's mark.
    func keeps(_ consumer: AgentDescriptor) -> Bool {
        agents.isEmpty || agents.contains(VendorMark.key(consumer.displayVendor))
    }
}

/// The sessions the hover panel lists, as `ReportView.panelSessions(_:vendor:)` chooses them.
public struct PanelSessionRows: Sendable {
    /// The listed sessions with work in flight, those waiting for the user first, newest started first within each;
    /// the header counts them as running.
    public let running: [LiveSession]
    /// The rows, in order: those in flight, then those ended in the last day, newest last event first, up to the limit.
    public let shown: [LiveSession]
    /// How many sessions the filter lists beyond the rows, which "+N more" counts.
    public let more: Int
    /// How many sessions of the last day, or in flight, each state has before the layout's filter: what a filter can
    /// choose from. An agent's own panel counts its agent's alone.
    let counts: [PanelSessionState: Int]
    /// Whether the layout's filter leaves out every session the panel would list without it; the section then says
    /// that none matches rather than that there are none.
    public let noneMatch: Bool
}

public extension ReportView {
    /// How long after its last event an ended session is still listed in the hover panel: a day.
    internal static let panelSessionRecency: TimeInterval = 24 * 3600

    /// The hover panel's session rows: of the sessions with work in flight or last active in the past day, without
    /// account-wide API receipts, those `filter` keeps; first those in flight, waiting for the user ahead of running and
    /// newest started first within each, then the ended ones by their last event, the newest first; at most
    /// `filter.limit` of them, with "+N more" counting the rest of what the filter keeps. Each step is a set operation
    /// over the view's sessions, cheap on every pass.
    /// - vendor: an agent's own panel's vendor on a dock that separates its agents: only the sessions of agents drawn
    ///   with its mark are listed, and the filter applies among them.
    func panelSessions(_ filter: PanelSessionFilter = PanelSessionFilter(), vendor: String? = nil) -> PanelSessionRows {
        let cutoff = now.addingTimeInterval(-Self.panelSessionRecency), mark = vendor.map(VendorMark.key)
        let window = sessions.filter {
            !$0.session.accountWide && ($0.phase.isInFlight || $0.lastEventAt >= cutoff)
                && (mark == nil || $0.markVendor.map(VendorMark.key) == mark)
        }
        var counts: [PanelSessionState: Int] = [:]
        for session in window { counts[PanelSessionState(session.phase.state), default: 0] += 1 }
        let kept = window.filter { filter.keeps(vendor: $0.markVendor, state: PanelSessionState($0.phase.state)) }
        let active = kept.filter(\.phase.isInFlight).sorted {
            let lhsWaiting = $0.phase.state == .waitingForApproval, rhsWaiting = $1.phase.state == .waitingForApproval
            if lhsWaiting != rhsWaiting { return lhsWaiting }
            return $0.session.startedAt > $1.session.startedAt
        }
        // The view orders by the last event, so ended rows follow recent work rather than when a session was created.
        let summary = active + kept.filter { !$0.phase.isInFlight }
        let shown = summary.prefix(filter.limit).map(\.session)
        return PanelSessionRows(running: active.map(\.session), shown: shown, more: summary.count - shown.count,
                                counts: counts, noneMatch: summary.isEmpty && !window.isEmpty)
    }

    /// The agents that have sessions now, by the name of their execution client, one per mark, in name order: the names a
    /// layout's `sessions.agents` can list. Account-wide API receipts are no one's session here.
    internal var panelSessionAgents: [String] {
        VendorMark.merged(sessions.filter { !$0.session.accountWide }.compactMap(\.markVendor)).sorted()
    }

    /// The agents whose models spend the tokens the chart draws now, by the vendor the panel's blocks show
    /// (`AgentDescriptor.displayVendor`), one per mark, in the report's order: the names a layout's `tokens.agents` can
    /// list.
    internal var panelTokenAgents: [String] {
        VendorMark.merged((report?.consumers ?? []).map(\.displayVendor))
    }
}

extension ReportView.Session {
    /// The execution agent the session belongs to, whose mark its row is drawn with: Grok's clients apart, Codex's
    /// clients as Codex.
    var markVendor: String? { source.agentVendor ?? source.vendor }
}
