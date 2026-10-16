import Foundation

/// One attached display as the host tells the MCP tools of it (`PanelTools`). It is named by its role, never by its
/// system name, which can be a personal device name, and it says nothing of whose agents or accounts it shows.
public struct PanelScreen: Equatable, Sendable {
    /// The display's key, under which its placement, glow and own layout are kept.
    let key: String
    /// Its role in English: "Built-in display", "Main display", or "Display 2" and on, by its place among the displays.
    let name: String
    /// How it presents the HUD now, a style draft included.
    let mode: HUDMode
    let edge: HUDEdge
    let hasNotch: Bool
    /// The agents its resting HUD would show now without a list in its layout, by vendor, one for each mark, in the
    /// order it shows them: the glow's beside the notch, the marks of a Dynamic dock, the items of a Simple panel.
    let agents: [String]
    /// What it would show the same way in each other mode, for a proposal that changes its mode.
    let otherModes: [HUDMode: [String]]

    /// - otherModes: the agents its resting HUD would show in each other mode; a mode left out is taken to show
    ///   `agents`.
    public init(key: String, name: String, mode: HUDMode, edge: HUDEdge, hasNotch: Bool, agents: [String],
                otherModes: [HUDMode: [String]] = [:]) {
        self.key = key
        self.name = name
        self.mode = mode
        self.edge = edge
        self.hasNotch = hasNotch
        self.agents = agents
        self.otherModes = otherModes
    }

    /// The mode as Agent HUD names it to a person: notch, dynamic or simple.
    var modeName: String { mode.agentName }

    /// The agents its resting HUD would show in `mode` now.
    func agents(in mode: HUDMode) -> [String] {
        mode == self.mode ? agents : otherModes[mode] ?? agents
    }
}
