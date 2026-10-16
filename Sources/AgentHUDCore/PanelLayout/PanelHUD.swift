import AgentHUDSupport
import Foundation

public extension PanelLayout {
    /// Which agents the resting HUD of a screen that draws the layout shows: the Dynamic dock's marks, the Simple
    /// panel's items, and the colours and alert pulse of that screen's glow. `HUD()` shows every agent, as it comes, and
    /// is not written.
    struct HUD: Hashable, Codable, Sendable {
        /// The agents shown, by vendor, in that order, each matched by the mark it is drawn with (`VendorMark`), so
        /// "Codex" names the mark Codex and ChatGPT share. Empty for every agent.
        public var agents: [String]

        public init(agents: [String] = []) {
            self.agents = agents
        }

        /// Whether the HUD shows every agent as it comes.
        var isDefault: Bool { normalized().agents.isEmpty }

        /// Each mark named once, by the first name given for it, and no empty name.
        func normalized() -> HUD {
            HUD(agents: VendorMark.merged(agents.filter { !$0.isEmpty }))
        }

        private enum CodingKeys: String, CodingKey { case agents }

        /// Nil when the value is not an object. A name that is not a string is left out.
        init?(json: JSONValue) {
            guard let fields = json.objectValue else { return nil }
            self.init(agents: PanelLayout.strings(fields["agents"]))
        }

        public init(from decoder: Decoder) throws {
            guard let hud = HUD(json: try decoder.singleValueContainer().decode(JSONValue.self)) else {
                throw DecodingError.typeMismatch(HUD.self, DecodingError.Context(
                    codingPath: decoder.codingPath, debugDescription: "The hud of a panel layout is a JSON object."))
            }
            self = hud
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            if !agents.isEmpty { try c.encode(agents, forKey: .agents) }
        }
    }
}

/// The agents one screen's resting HUD shows under its layout's list (`PanelLayout.HUD`), resolved against the agents
/// it would show now: those listed, matched by mark, in the order listed. A list that is empty, or names none of the
/// agents the HUD would show now, narrows nothing, so a screen never shows an empty HUD for its list.
public struct HUDAgentOrder: Equatable, Sendable {
    /// The listed marks in the order listed; empty when the list narrows nothing.
    let marks: [String]

    /// - listed: the layout's agents.
    /// - available: the vendors the screen's resting HUD would show now without a list.
    public init(listed: [String], available: [String]) {
        let present = Set(available.map(VendorMark.key))
        let named = listed.filter { !$0.isEmpty }.map(VendorMark.key).withoutRepeats
        marks = named.contains(where: present.contains) ? named : []
    }

    /// Whether the list narrows what the HUD shows.
    public var narrows: Bool { !marks.isEmpty }

    /// Whether the HUD shows a vendor's agent: always while the list narrows nothing.
    public func shows(_ vendor: String) -> Bool {
        !narrows || marks.contains(VendorMark.key(vendor))
    }

    /// The items whose vendor is listed, in the list's order; items that share a mark keep the order they came in. The
    /// items as they are while the list narrows nothing.
    public func arrange<Item>(_ items: [Item], vendor: (Item) -> String) -> [Item] {
        guard narrows else { return items }
        var rank: [String: Int] = [:]
        for (index, mark) in marks.enumerated() where rank[mark] == nil { rank[mark] = index }
        var ranked: [(rank: Int, offset: Int, item: Item)] = []
        for (offset, item) in items.enumerated() {
            if let position = rank[VendorMark.key(vendor(item))] { ranked.append((position, offset, item)) }
        }
        ranked.sort { $0.rank != $1.rank ? $0.rank < $1.rank : $0.offset < $1.offset }
        return ranked.map(\.item)
    }
}

extension PanelLayout {
    /// Every agent of `hud.agents` that the screens the layout is for cannot show now, by position: matched by mark
    /// against `available`, the vendors their resting HUDs would show now. An agent one of the `held` layouts already
    /// lists is no issue: a layout keeps it for when it returns, so a proposal built on a layout that was read may
    /// carry it.
    ///
    /// - whose: who cannot show it, in words, such as "this screen's resting HUD".
    func hudIssues(against available: [String], whose: String, holding held: [PanelLayout] = []) -> [PanelLayoutIssue] {
        let shown = Set(available.map(VendorMark.key))
        var kept = Set<String>()
        for layout in held { kept.formUnion(layout.hud.agents.map(VendorMark.key)) }
        let offered = available.isEmpty ? "It shows no agent now." : "It can show: \(Self.quoted(VendorMark.merged(available)))."
        var issues: [PanelLayoutIssue] = []
        for (index, agent) in hud.agents.enumerated() {
            let mark = VendorMark.key(agent)
            guard !agent.isEmpty, !shown.contains(mark), !kept.contains(mark) else { continue }
            issues.append(PanelLayoutIssue(path: "hud.agents[\(index)]",
                                           message: "\"\(agent)\" is not an agent \(whose) can show now. \(offered)"))
        }
        return issues
    }
}
