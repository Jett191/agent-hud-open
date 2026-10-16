import AgentHUDCore
import XCTest
@testable import AgentHUDDesktop

/// A vendor's logo and name in the quota list lead back to its newest session that has somewhere to go.
@MainActor
final class AgentHeaderLinkTests: XCTestCase {
    private func store(_ sessions: [LiveSession], agents: [AgentDescriptor]) throws -> UsageStore {
        let domain = "app.agenthud.tests.agent-header.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        addTeardownBlock { defaults.removePersistentDomain(forName: domain) }
        let store = UsageStore(provider: DemoUsageProvider(), settings: SettingsStore(defaults: defaults, defaultAgents: agents))
        store.replace(report: UsageReport(generatedAt: Date(), snapshots: [], sessions: sessions, consumers: agents))
        return store
    }

    private func session(_ id: String, agent: AgentDescriptor, ago: TimeInterval, target: SessionNavigationTarget?) -> LiveSession {
        let at = Date().addingTimeInterval(-ago)
        return LiveSession(id: id, agentId: agent.id, task: id, terminal: "proj", startedAt: at.addingTimeInterval(-60), endedAt: at,
                           pctOfWindow: nil, tokensIn: 10, tokensOut: 5, observedAt: at, navigationTarget: target)
    }

    func testTheNewestSessionWithADestinationIsTheOneLedTo() throws {
        let codex = AgentDescriptor(id: "codex-model:test", vendor: "Codex", model: "Test", source: "Test", enabled: true)
        let claude = AgentDescriptor(id: "claude-model:test", vendor: "Claude", model: "Test", source: "Test", enabled: true)
        let store = try store([
            session("older-with-destination", agent: codex, ago: 600, target: .codexThread(id: "thread")),
            session("newer-without-destination", agent: codex, ago: 60, target: nil),
            session("newest-of-another-vendor", agent: claude, ago: 30, target: .codexThread(id: "other")),
        ], agents: [codex, claude])
        XCTAssertEqual(HoverPanelView.latestDestination(store, vendor: "Codex"), "older-with-destination")
        XCTAssertEqual(HoverPanelView.latestDestination(store, vendor: "Claude"), "newest-of-another-vendor")
    }

    func testAVendorWithoutADestinationLeadsNowhere() throws {
        let codex = AgentDescriptor(id: "codex-model:test", vendor: "Codex", model: "Test", source: "Test", enabled: true)
        let store = try store([session("no-destination", agent: codex, ago: 60, target: nil)], agents: [codex])
        XCTAssertNil(HoverPanelView.latestDestination(store, vendor: "Codex"))
        XCTAssertNil(HoverPanelView.latestDestination(store, vendor: "Cursor"))
    }
}
