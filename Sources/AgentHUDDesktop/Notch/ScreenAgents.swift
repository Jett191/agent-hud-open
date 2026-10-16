import AgentHUDCore

/// What one screen's resting HUD shows of the agents: the marks of its Dynamic dock, the items of its Simple panel, and
/// the colours, alert pulse and pace of its glow, each narrowed to the agents its layout lists (`PanelLayout.HUD`) and
/// put in their order. A list that names none of the agents the HUD would show now narrows nothing
/// (`HUDAgentOrder`), so the screen shows every agent rather than an empty HUD.
///
/// Only this screen's resting HUD follows the list. The menu bar, quota alerts, requests, other screens and the hover
/// panel's blocks read the store as it is.
@MainActor
struct ScreenAgents {
    private let store: UsageStore
    /// The layout's list, resolved against what this screen's resting HUD would show now.
    let order: HUDAgentOrder

    /// - listed: the agents the layout the screen draws lists.
    /// - mode: how the screen presents the HUD, which decides what it would show without a list.
    init(store: UsageStore, listed: [String], mode: HUDMode) {
        self.store = store
        order = listed.isEmpty ? HUDAgentOrder(listed: [], available: [])
            : HUDAgentOrder(listed: listed, available: Self.available(store: store, mode: mode))
    }

    /// The agents a resting HUD in `mode` would show now without a list, one vendor for each mark, in its order: the
    /// glow's parts beside the notch, the marks of a Dynamic dock, the items of a Simple panel.
    static func available(store: UsageStore, mode: HUDMode) -> [String] {
        switch mode {
        case .notch: VendorMark.merged(store.alertPulseVendors)
        case .logos: LogoQueueItem.queue(rows: store.queueVendors).map(\.vendor)
        case .simple: allMeterItems(store).map(\.vendor)
        }
    }

    /// The marks this screen's Dynamic dock shows: the watched agents and anything else run in the last day.
    var queueItems: [LogoQueueItem] {
        order.arrange(LogoQueueItem.queue(rows: store.queueVendors), vendor: \.vendor)
    }

    /// The agents with a quota row, each with its tightest window, then those with only a balance.
    var meterItems: [SimpleMeterItem] {
        order.arrange(Self.allMeterItems(store), vendor: \.vendor)
    }

    private static func allMeterItems(_ store: UsageStore) -> [SimpleMeterItem] {
        SimpleMeterItem.items(rows: store.rows, balances: SimpleMeterItem.balances(store),
                              working: store.queueVendors.filter(\.isWorking).map(\.vendor))
    }

    /// The parts of this screen's glow, in glow order. Its colours and an alert's pulse both come from this one list.
    var glowSegments: [ReportView.GlowSegment] {
        order.arrange(store.view.glowSegments, vendor: \.vendor)
    }

    /// Each part's vendor, which an alert's pulse is placed by.
    var pulseVendors: [String] { glowSegments.map(\.vendor) }

    /// Whether the glow breathes at its working pace: a session of a shown agent is in flight.
    var anyAgentActive: Bool {
        guard order.narrows else { return store.hasLiveSession }
        return store.view.liveSessions.contains { session in
            (session.source.agentVendor ?? session.source.vendor).map(order.shows) ?? false
        }
    }

    /// This screen's glow under its own settings, drawn from its own parts and pace.
    func glowAppearance(light: Bool, on screen: String) -> GlowAppearance {
        guard order.narrows else { return store.glowAppearance(light: light, on: screen) }
        return store.glowAppearance(light: light, on: screen, levels: glowSegments.map(\.level), anyAgentActive: anyAgentActive)
    }
}
