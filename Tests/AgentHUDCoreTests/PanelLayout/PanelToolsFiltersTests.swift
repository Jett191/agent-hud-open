import AgentHUDSupport
import Foundation
import XCTest
@testable import AgentHUDCore

/// The session rows and the token chart under a layout's filters, over the sample: two sessions running (Claude's and
/// Codex's), six ended in the last day (three Claude, two Codex, one DeepSeek) and one Codex session ended before that;
/// and what the tools read and take of them.
final class PanelToolsFiltersTests: PanelToolsCase {
    private func rows(_ sessions: PanelLayout.Sessions = PanelLayout.Sessions(), vendor: String? = nil) -> PanelSessionRows {
        store.view.panelSessions(PanelSessionFilter(sessions), vendor: vendor)
    }

    private func ids(_ rows: PanelSessionRows) -> [String] { rows.shown.map(\.id) }

    // MARK: Rows

    func testTheDefaultRowsAreFiveOfTheDaysSessionsWithWorkInFlightFirst() {
        let rows = rows()
        XCTAssertEqual(ids(rows), ["s1", "s2", "s4", "s7", "s8"])
        XCTAssertEqual(rows.running.map(\.id), ["s1", "s2"])
        XCTAssertEqual(rows.more, 3, "the day's other ended sessions; the one before it is not counted")
        XCTAssertEqual(rows.counts, [.running: 2, .ended: 6])
        XCTAssertFalse(rows.noneMatch)
    }

    func testTheLimitSetsTheRowsAndMoreCountsTheRest() {
        XCTAssertEqual(ids(rows(PanelLayout.Sessions(limit: 3))), ["s1", "s2", "s4"])
        XCTAssertEqual(rows(PanelLayout.Sessions(limit: 3)).more, 5)
        let ten = rows(PanelLayout.Sessions(limit: 10))
        XCTAssertEqual(ids(ten), ["s1", "s2", "s4", "s7", "s8", "s3", "s5", "s6"])
        XCTAssertEqual(ten.more, 0)
    }

    func testStatesAndAgentsChooseTheRowsInTheSameOrderAndMoreCountsWhatTheyKeep() {
        let running = rows(PanelLayout.Sessions(states: [.running]))
        XCTAssertEqual(ids(running), ["s1", "s2"])
        XCTAssertEqual(running.more, 0)
        let ended = rows(PanelLayout.Sessions(states: [.ended]))
        XCTAssertEqual(ids(ended), ["s4", "s7", "s8", "s3", "s5"])
        XCTAssertEqual(ended.more, 1)
        XCTAssertTrue(ended.running.isEmpty, "the header counts only what the filter keeps")
        XCTAssertEqual(ended.counts, [.running: 2, .ended: 6], "the counts are before the filter")

        let codex = rows(PanelLayout.Sessions(agents: ["Codex"]))
        XCTAssertEqual(ids(codex), ["s2", "s4", "s7"])
        XCTAssertEqual(ids(rows(PanelLayout.Sessions(agents: ["ChatGPT"]))), ids(codex), "matched by mark")
        XCTAssertEqual(ids(rows(PanelLayout.Sessions(limit: 2, agents: ["Claude", "DeepSeek"], states: [.ended]))), ["s8", "s3"])
        XCTAssertEqual(rows(PanelLayout.Sessions(limit: 2, agents: ["Claude", "DeepSeek"], states: [.ended])).more, 2)
    }

    func testAFilterThatKeepsNothingSaysSoAndNoSessionsAtAllDoesNot() {
        let none = rows(PanelLayout.Sessions(agents: ["Grok CLI"]))
        XCTAssertTrue(none.shown.isEmpty)
        XCTAssertEqual(none.more, 0)
        XCTAssertTrue(none.noneMatch)
        XCTAssertTrue(rows(PanelLayout.Sessions(states: [.waiting])).noneMatch)

        // With no session in the day at all, the section has none yet, whatever the filter.
        store.replace(report: UsageReport(generatedAt: DemoClock.now, snapshots: [], sessions: [], usage: []))
        let empty = rows(PanelLayout.Sessions(agents: ["Grok CLI"]))
        XCTAssertTrue(empty.shown.isEmpty)
        XCTAssertFalse(empty.noneMatch)
    }

    /// An agent's own panel lists its agent's sessions, and the layout's filter applies among them.
    func testAnAgentsOwnPanelAppliesItsAgentAndTheFilter() {
        XCTAssertEqual(ids(rows(vendor: "Claude")), ["s1", "s3", "s5", "s6"])
        XCTAssertEqual(rows(vendor: "Claude").counts, [.running: 1, .ended: 3])
        XCTAssertEqual(ids(rows(PanelLayout.Sessions(limit: 2, states: [.ended]), vendor: "Claude")), ["s3", "s5"])
        let other = rows(PanelLayout.Sessions(agents: ["Codex"]), vendor: "Claude")
        XCTAssertTrue(other.shown.isEmpty)
        XCTAssertTrue(other.noneMatch, "Claude's panel has sessions; the layout keeps none of them")
    }

    // MARK: The token chart's columns

    func testEachPeriodIsDrawnInItsColumnsEndingAtTheSameQuarterAndKeptForTheReport() throws {
        let day = store.hudTokenColumns(consumerIDs: nil), week = store.hudTokenColumns(consumerIDs: nil, period: .week)
        let month = store.hudTokenColumns(consumerIDs: nil, period: .month)
        XCTAssertEqual(day.count, 96)
        XCTAssertTrue((7...8).contains(week.count), "\(week.count) days")
        XCTAssertTrue((30...31).contains(month.count), "\(month.count) days")
        XCTAssertTrue(week.allSatisfy { $0.interval.duration >= 23 * 3600 })
        for period in PanelTokenPeriod.allCases {
            let interval = store.hudTokenInterval(period)
            XCTAssertEqual(interval.end, store.hudTokenInterval.end)
            XCTAssertEqual(interval.duration, period.duration)
        }
        func total(_ columns: [TokenColumn]) -> Int { columns.reduce(0) { $0 + $1.total } }
        XCTAssertLessThan(total(day), total(week))
        XCTAssertLessThan(total(week), total(month), "the sample has a month of tokens")

        let codex = Set(store.consumers.filter { $0.vendor == "Codex" }.map(\.id))
        XCTAssertLessThan(total(store.hudTokenColumns(consumerIDs: codex, period: .week)), total(week))
        XCTAssertEqual(store.panelTokenConsumers(PanelTokenFilter(PanelLayout.Tokens(agents: ["ChatGPT"]))), codex)
        XCTAssertNil(store.panelTokenConsumers(PanelTokenFilter()), "nothing narrows the default chart")
        XCTAssertEqual(store.panelTokenConsumers(PanelTokenFilter(PanelLayout.Tokens(agents: ["Codex"])), vendor: "Claude"), [],
                       "an agent's own panel and the layout both apply")

        // Kept for the report: the same report gives the same columns, and a new one is counted again.
        XCTAssertEqual(store.hudTokenColumns(consumerIDs: nil, period: .week), week)
        let consumers = try XCTUnwrap(store.report).consumers
        store.replace(report: UsageReport(generatedAt: DemoClock.now, snapshots: [], sessions: [], consumers: consumers, usage: []))
        XCTAssertEqual(total(store.hudTokenColumns(consumerIDs: nil, period: .week)), 0)
    }

    // MARK: Reading

    func testThePanelIsReadWithItsSessionsAndTokens() throws {
        let panel = try result(MCPTools.getPanel)
        XCTAssertEqual(panel["sessions"], .object([
            "limit": .integer(5), "agents": .array([]), "states": .array(["waiting", "running", "ended"].map(JSONValue.string)),
            "offeredAgents": .array(["Claude", "Codex", "DeepSeek"].map(JSONValue.string)),
            "shown": .integer(5), "more": .integer(3),
            "byState": .object(["waiting": .integer(0), "running": .integer(2), "ended": .integer(6)]),
        ]))
        let day = store.hudTokenColumns(consumerIDs: nil).reduce(0) { $0 + $1.total }
        XCTAssertEqual(panel["tokens"], .object([
            "period": .string("day"), "agents": .array([]),
            "offeredAgents": .array(["Claude", "Codex", "DeepSeek"].map(JSONValue.string)), "total": .integer(Int64(day)),
        ]))
    }

    /// Counts and agents' names only: a session's title, project, path and id never reach an agent.
    func testWhatIsReadOfSessionsNamesNoTitleProjectOrPath() throws {
        let text = String(decoding: try RecordCoding.encoder().encode(JSONValue.object(try result(MCPTools.getPanel))), as: UTF8.self)
        for session in store.view.sessions.map(\.session) {
            for written in [session.task, session.terminal, session.workingDirectory].compactMap({ $0 }) {
                XCTAssertFalse(text.contains(written), written)
            }
            XCTAssertFalse(text.contains("\"\(session.id)\""), session.id)
        }
    }

    // MARK: Proposing

    func testSessionsAndTokensAreProposedAndToldBack() throws {
        let panel = try result(MCPTools.setPanelLayout, [
            "sessions": .object(["limit": .integer(3), "agents": .array([.string("ChatGPT")]),
                                 "states": .array([.string("ended"), .string("running")])]),
            "tokens": .object(["period": .string("week"), "agents": .array([.string("Claude")])]),
        ])
        XCTAssertEqual(layout.draft, PanelLayout(sessions: PanelLayout.Sessions(limit: 3, agents: ["ChatGPT"], states: [.running, .ended]),
                                                 tokens: PanelLayout.Tokens(period: .week, agents: ["Claude"])))
        let sessions = try XCTUnwrap(panel["sessions"]?.objectValue)
        XCTAssertEqual(sessions["limit"], .integer(3))
        XCTAssertEqual(sessions["agents"], .array([.string("ChatGPT")]))
        XCTAssertEqual(sessions["states"], .array([.string("running"), .string("ended")]))
        XCTAssertEqual(sessions["shown"], .integer(3), "s2, s4, s7")
        XCTAssertEqual(sessions["more"], .integer(0))
        let tokens = try XCTUnwrap(panel["tokens"]?.objectValue)
        XCTAssertEqual(tokens["period"], .string("week"))
        XCTAssertEqual(tokens["agents"], .array([.string("Claude")]))
        let claude = Set(store.consumers.filter { $0.vendor == "Claude" }.map(\.id))
        XCTAssertEqual(tokens["total"], .integer(Int64(store.hudTokenColumns(consumerIDs: claude, period: .week).reduce(0) { $0 + $1.total })))
        XCTAssertEqual(changes, 0, "a proposal writes no setting")

        // The default spelled out is the default layout: no draft.
        layout.discard()
        let spelled = try result(MCPTools.setPanelLayout, [
            "sessions": .object(["limit": .integer(5), "states": .array(["waiting", "running", "ended"].map(JSONValue.string))]),
            "tokens": .object(["period": .string("day"), "agents": .array([])]),
        ])
        XCTAssertFalse(layout.hasDraft)
        XCTAssertEqual(spelled["unsaved"], .bool(false))
    }

    func testSessionsAndTokensAreReadStrictly() throws {
        let typed = try refusal([
            "sessions": .object(["limit": .integer(11), "states": .array([.string("idle"), .integer(2)]),
                                 "agents": .string("Claude"), "project": .string("hud")]),
            "tokens": .object(["period": .string("year"), "agents": .array([.string("")]), "model": .string("opus")]),
        ])
        for part in ["sessions.limit is a whole number from 1 to 10.",
                     "sessions.states[0]: \"idle\" is not one of \"waiting\", \"running\", \"ended\".",
                     "sessions.states[1] is a string.", "sessions.agents is a list.",
                     "sessions has no property \"project\"; sessions take limit, agents and states.",
                     "tokens.period is one of \"day\", \"week\", \"month\".",
                     "tokens.agents[0] is an agent's name from get_panel's tokens.offeredAgents.",
                     "tokens has no property \"model\"; tokens take period and agents."] {
            XCTAssertTrue(typed.contains(part), "\(part) — \(typed)")
        }
        for limit in [JSONValue.integer(0), .number(2.5), .string("3"), .integer(-1)] {
            XCTAssertTrue(try refusal(["sessions": .object(["limit": limit])]).contains("sessions.limit is a whole number from 1 to 10."),
                          "\(limit)")
        }
        XCTAssertTrue(try refusal(["sessions": .integer(3)]).contains("sessions is an object."))
        XCTAssertTrue(try refusal(["tokens": .string("week")]).contains("tokens is an object."))
    }

    func testAnAgentWithNoSessionsOrTokensIsRefusedUnlessTheLayoutHoldsIt() throws {
        let sentence = try refusal(["sessions": .object(["agents": .array([.string("Grok CLI")])]),
                                    "tokens": .object(["agents": .array([.string("Gemini")])])])
        XCTAssertTrue(sentence.contains("sessions.agents[0]: \"Grok CLI\" has no session now. Agents with sessions now: "
                                        + "\"Claude\", \"Codex\", \"DeepSeek\"."), sentence)
        XCTAssertTrue(sentence.contains("tokens.agents[0]: \"Gemini\" has no model in the token chart now. Agents in the chart "
                                        + "now: \"Claude\", \"Codex\", \"DeepSeek\"."), sentence)

        // Saved by a person while it had sessions; the layout that was read can be sent back with it.
        layout.propose(PanelLayout(sessions: PanelLayout.Sessions(agents: ["Grok CLI", "Claude"])))
        layout.save()
        let read = try XCTUnwrap(try result(MCPTools.getPanel)["layout"])
        var arguments = try XCTUnwrap(read.objectValue)
        arguments["tokens"] = .object(["period": .string("month")])
        _ = try result(MCPTools.setPanelLayout, arguments)
        XCTAssertEqual(layout.draft?.sessions.agents, ["Claude", "Grok CLI"])
        XCTAssertEqual(layout.draft?.tokens.period, .month)
    }
}
