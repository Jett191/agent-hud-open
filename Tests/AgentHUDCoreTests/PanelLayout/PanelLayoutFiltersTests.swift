import AgentHUDSupport
import XCTest
@testable import AgentHUDCore

/// A layout's sessions and tokens: their JSON, what reading them forgives, when two are the same, what an agent is told
/// it cannot list, and the plan they resolve to.
final class PanelLayoutFiltersTests: XCTestCase {
    private func decode(_ json: String) throws -> PanelLayout {
        try JSONDecoder().decode(PanelLayout.self, from: Data(json.utf8))
    }

    private func encode(_ layout: PanelLayout) throws -> String {
        String(decoding: try RecordCoding.encoder().encode(layout), as: UTF8.self)
    }

    // MARK: Coding

    func testTheDocumentedShapeReadsAndWritesBack() throws {
        let json = #"{"sessions":{"agents":["Codex"],"limit":3,"states":["waiting","running"]},"tokens":{"agents":["Claude"],"period":"week"}}"#
        let layout = PanelLayout(sessions: PanelLayout.Sessions(limit: 3, agents: ["Codex"], states: [.waiting, .running]),
                                 tokens: PanelLayout.Tokens(period: .week, agents: ["Claude"]))
        XCTAssertEqual(try decode(json), layout)
        XCTAssertEqual(try encode(layout), json, "keys are sorted and nothing unset is written")
        XCTAssertEqual(try encode(try decode(json)), json)
    }

    func testTheDefaultsAreNotWritten() throws {
        XCTAssertEqual(try encode(PanelLayout(sessions: PanelLayout.Sessions(limit: 5), tokens: PanelLayout.Tokens(period: .day))), "{}")
        XCTAssertEqual(try encode(PanelLayout(sessions: PanelLayout.Sessions(states: PanelSessionState.allCases))), "{}",
                       "every state is what no state means")
        XCTAssertTrue(PanelLayout(sessions: PanelLayout.Sessions(limit: 5, states: PanelSessionState.allCases)).isDefault)
        XCTAssertEqual(try encode(PanelLayout(sessions: PanelLayout.Sessions(limit: 10))), #"{"sessions":{"limit":10}}"#)
        XCTAssertEqual(try encode(PanelLayout(tokens: PanelLayout.Tokens(period: .month))), #"{"tokens":{"period":"month"}}"#)
        XCTAssertEqual(try decode("{}").sessions.rowLimit, 5)
        XCTAssertEqual(try decode("{}").tokens.chartPeriod, .day)
    }

    /// A stored layout from a newer build still loads: what this build cannot read in them counts as not given.
    func testStoredSessionsAndTokensAreReadForgivingly() throws {
        let layout = try decode("""
            {"sessions": {"limit": 11, "agents": ["Claude", 4], "states": ["idle", "ended"], "project": "x"},
             "tokens": {"period": "year", "agents": "Codex"}}
            """)
        XCTAssertEqual(layout.sessions, PanelLayout.Sessions(agents: ["Claude"], states: [.ended]))
        XCTAssertEqual(layout.tokens, PanelLayout.Tokens())
        for limit in ["0", "2.5", "\"3\"", "-1", "true"] {
            XCTAssertNil(try decode(#"{"sessions": {"limit": \#(limit)}}"#).sessions.limit, limit)
        }
        XCTAssertEqual(try decode(#"{"sessions": {"limit": 7.0}}"#).sessions.limit, 7)
        XCTAssertEqual(try decode(#"{"sessions": [1], "tokens": "week"}"#), PanelLayout(), "neither is an object")
    }

    func testTheSameFilterIsTheSameLayout() {
        let spelled = PanelLayout(sessions: PanelLayout.Sessions(limit: 5, agents: ["DeepSeek", "Codex", "ChatGPT", ""],
                                                                 states: [.ended, .waiting, .ended]),
                                  tokens: PanelLayout.Tokens(period: .day, agents: ["Codex", "Claude", "ChatGPT"]))
        let plain = PanelLayout(sessions: PanelLayout.Sessions(agents: ["Codex", "DeepSeek"], states: [.waiting, .ended]),
                                tokens: PanelLayout.Tokens(agents: ["Claude", "Codex"]))
        XCTAssertEqual(spelled.normalized(), plain.normalized(),
                       "a filter has no order, and Codex and ChatGPT are one mark, named as first given")
        XCTAssertEqual(spelled.normalized().sessions, PanelLayout.Sessions(agents: ["Codex", "DeepSeek"], states: [.waiting, .ended]))
        XCTAssertEqual(PanelLayout(sessions: PanelLayout.Sessions(limit: 0)).normalized(), PanelLayout())
    }

    // MARK: What an agent is told

    func testAnAgentWithNoSessionsOrTokensNowIsAnIssueUnlessTheLayoutHoldsIt() {
        let layout = PanelLayout(sessions: PanelLayout.Sessions(agents: ["ChatGPT", "Grok", ""]),
                                 tokens: PanelLayout.Tokens(agents: ["Claude", "Gemini"]))
        let issues = layout.filterIssues(sessionAgents: ["Claude", "Codex"], tokenAgents: ["Claude", "Codex"])
        XCTAssertEqual(issues.map(\.path), ["sessions.agents[1]", "tokens.agents[1]"], "ChatGPT is Codex's mark")
        XCTAssertEqual(issues.first?.message, "\"Grok\" has no session now. Agents with sessions now: \"Claude\", \"Codex\".")
        XCTAssertEqual(issues.last?.message,
                       "\"Gemini\" has no model in the token chart now. Agents in the chart now: \"Claude\", \"Codex\".")
        XCTAssertEqual(layout.filterIssues(sessionAgents: [], tokenAgents: []).map(\.message).last,
                       "\"Gemini\" has no model in the token chart now. The chart has no agent's tokens now.")

        let held = PanelLayout(sessions: PanelLayout.Sessions(agents: ["Grok CLI"]), tokens: PanelLayout.Tokens(agents: ["Gemini"]))
        XCTAssertTrue(layout.filterIssues(sessionAgents: ["Claude", "Codex"], tokenAgents: ["Claude"], holding: [held]).isEmpty,
                      "what a layout holds for an agent that is away may come back, matched by mark")
    }

    // MARK: The plan

    func testThePlanResolvesTheFiltersAndTheDefaultViewNarrowsNothing() {
        let plain = PanelLayoutPlan(layout: PanelLayout(), blocks: [])
        XCTAssertEqual(plain.sessions.limit, 5)
        XCTAssertEqual(plain.tokens.period, .day)
        XCTAssertFalse(plain.tokens.narrows)
        XCTAssertTrue(plain.sessions.keeps(vendor: nil, state: .ended))

        let plan = PanelLayoutPlan(layout: PanelLayout(
            sessions: PanelLayout.Sessions(limit: 8, agents: ["ChatGPT", "Grok CLI"], states: [.running]),
            tokens: PanelLayout.Tokens(period: .month, agents: ["Codex"])), blocks: [])
        XCTAssertEqual(plan.sessions.limit, 8)
        XCTAssertTrue(plan.sessions.keeps(vendor: "Codex", state: .running), "matched by mark")
        XCTAssertTrue(plan.sessions.keeps(vendor: "Grok CLI", state: .running))
        XCTAssertFalse(plan.sessions.keeps(vendor: "Grok Bot", state: .running), "Grok's clients are apart")
        XCTAssertFalse(plan.sessions.keeps(vendor: "Codex", state: .waiting))
        XCTAssertFalse(plan.sessions.keeps(vendor: nil, state: .running), "a session of no agent is no listed agent's")
        XCTAssertEqual(plan.tokens.period, .month)
        let codex = AgentDescriptor(id: "codex-model:gpt", vendor: "Codex", model: "GPT", source: "", enabled: true)
        let claude = AgentDescriptor(id: "claude-model:opus", vendor: "Claude", model: "Opus", source: "", enabled: true)
        XCTAssertTrue(plan.tokens.keeps(codex))
        XCTAssertFalse(plan.tokens.keeps(claude))
        XCTAssertEqual(PanelSessionFilter(PanelLayout.Sessions(states: PanelSessionState.allCases)).states.count, 3)
    }

    func testThePeriodsAreTheStatisticsRangesInTheirOwnColumns() {
        XCTAssertEqual(PanelTokenPeriod.allCases.map(\.label), ["24h", "7d", "30d"])
        XCTAssertEqual(PanelTokenPeriod.allCases.map(\.duration), [86400, 7 * 86400, 30 * 86400] as [TimeInterval])
        XCTAssertEqual(PanelTokenPeriod.allCases.map(\.bucketSize), [.minutes15, .day1, .day1])
        XCTAssertEqual(PanelTokenPeriod.allCases.map(\.range), [.hours24, .days7, .days30])
    }
}
