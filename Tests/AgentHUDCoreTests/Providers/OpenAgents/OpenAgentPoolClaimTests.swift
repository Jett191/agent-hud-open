import AgentHUDSupport
import Foundation
import XCTest
@testable import AgentHUDCore

final class OpenAgentPoolClaimTests: XCTestCase, @unchecked Sendable {
    func testExplicitPoolMustKeepItsQuotaLinkWhenAnotherAccountUsesTheSameService() async throws {
        let now = Date(timeIntervalSince1970: 1_788_800_000)
        let credentials = ["fixture-key-a", "fixture-key-b"].map {
            OpenAgentCredentials.credential(.kimi, token: $0, client: "Pi")
        }.sorted { $0.pool.id < $1.pool.id }
        let first = credentials[0], actual = credentials[1]
        let consumer = "pi-model:kimi-k2#kimi-code"
        let event = UsageEvent(timestamp: now, agentId: consumer, tokensIn: 10, tokensOut: 20, eventID: "event",
                               attribution: .init(client: "Pi", providerID: "kimi-code", pool: actual.pool))
        let session = OpenAgentSession(id: "pi:fixture", client: .pi, title: "Fixture", path: "/fixture.jsonl",
                                       events: [event], start: now, end: now)
        let provider = OpenAgentUsageProvider(credentials: { credentials }, sessions: { _ in .init(sessions: [session]) },
            fetchQuota: { credential, _ in
                .init(windows: [.init(id: credential.pool.windowID("weekly"), label: "Weekly", remaining: 70)])
            }, history: QuotaHistoryStore(), clock: { now }, ledger: .inMemory())
        let report = try await provider.fetchAccountAndLocalUsage(agents: [], historyHours: 168)
        XCTAssertEqual(report.consumers.first?.billingPool, actual.pool)
        XCTAssertEqual(report.consumerIdsByQuota[actual.pool.windowID("weekly")], [consumer], "an explicitly tagged call belongs to its actual account")
        XCTAssertEqual(report.consumerIdsByQuota[first.pool.windowID("weekly")], [], "another account must not claim this call")
    }

    func testAnAmbiguousRouteDoesNotChooseTheFirstAccount() async throws {
        let now = Date(timeIntervalSince1970: 1_788_800_000)
        let credentials = ["account-a", "account-b"].map {
            OpenAgentCredentials.credential(.kimi, token: $0, client: "Pi")
        }
        let consumer = "pi-model:kimi-k2#kimi-code"
        let event = UsageEvent(timestamp: now, agentId: consumer, tokensIn: 10, tokensOut: 20, eventID: "event",
                               attribution: .init(client: "Pi", providerID: "kimi-code"))
        let session = OpenAgentSession(id: "pi:fixture", client: .pi, title: "Fixture", path: "/fixture.jsonl",
                                       events: [event], start: now, end: now)
        let provider = OpenAgentUsageProvider(credentials: { credentials }, sessions: { _ in .init(sessions: [session]) },
            fetchQuota: { credential, _ in
                .init(windows: [.init(id: credential.pool.windowID("weekly"), label: "Weekly", remaining: 70)])
            }, history: QuotaHistoryStore(), clock: { now })
        let report = try await provider.fetchAccountAndLocalUsage(agents: [], historyHours: 168)
        XCTAssertNil(report.consumers.first?.billingPool)
        XCTAssertTrue(report.consumerIdsByQuota.values.allSatisfy(\.isEmpty))
    }

    func testLedgerOnlyRouteFollowsAnUnambiguousReplacementKey() async throws {
        let now = Date(timeIntervalSince1970: 1_788_800_000), ledger = UsageLedger.inMemory()
        let key = OpenAgentCredentials.credential(.go, token: "replacement-key", client: "OpenCode")
        let consumer = "opencode-model:glm-5#opencode-go"
        try await ledger.write { writer in
            try writer.upsert(source: OpenAgentUsageProvider.source, contribution: "old-session", events: [
                .init(key: "old-event", timestamp: now.addingTimeInterval(-86400), agentId: consumer, tokensIn: 10, tokensOut: 20),
            ])
        }
        let provider = OpenAgentUsageProvider(credentials: { [key] }, sessions: { _ in .init() }, fetchQuota: { credential, _ in
            .init(windows: [.init(id: credential.pool.windowID("weekly"), label: "Weekly", remaining: 70)])
        }, history: QuotaHistoryStore(), clock: { now }, ledger: ledger)
        let report = try await provider.fetchAccountAndLocalUsage(agents: [], historyHours: 168)
        XCTAssertEqual(report.consumerIdsByQuota[key.pool.windowID("weekly")], [consumer])
    }

    func testExplicitPoolKeepsACustomRouteThatCannotBeResolvedByName() async throws {
        let now = Date(timeIntervalSince1970: 1_788_800_000)
        let key = OpenAgentCredentials.credential(.go, token: "fixture-key", client: "OpenCode")
        let consumer = "opencode-model:glm-5#custom-go"
        let event = UsageEvent(timestamp: now, agentId: consumer, tokensIn: 10, tokensOut: 20, eventID: "event",
                               attribution: .init(client: "OpenCode", providerID: "custom-go", pool: key.pool))
        let session = OpenAgentSession(id: "opencode:fixture", client: .opencode, title: "Fixture", path: "/fixture.json",
                                       events: [event], start: now, end: now)
        let provider = OpenAgentUsageProvider(credentials: { [key] }, sessions: { _ in .init(sessions: [session]) },
            fetchQuota: { credential, _ in
                .init(windows: [.init(id: credential.pool.windowID("weekly"), label: "Weekly", remaining: 70)])
            }, history: QuotaHistoryStore(), clock: { now })
        let report = try await provider.fetchAccountAndLocalUsage(agents: [], historyHours: 168)
        XCTAssertEqual(report.consumerIdsByQuota[key.pool.windowID("weekly")], [consumer])
    }

    func testNewAccountAmbiguityClearsAPreviouslyRetainedClaim() {
        let now = Date(timeIntervalSince1970: 1_788_800_000)
        let pools = ["account-a", "account-b"].map {
            OpenAgentCredentials.credential(.kimi, token: $0, client: "Pi").pool
        }
        let consumer = "pi-model:kimi-k2#kimi-code"
        func report(_ active: [BillingPool], claims: [String: Set<String>]) -> UsageReport {
            UsageReport(generatedAt: now, snapshots: active.map {
                UsageSnapshot(agentId: $0.windowID("weekly"), remainingPct: 70, updatedAt: now)
            }, sessions: [], discoveredAgents: active.map {
                AgentDescriptor(id: $0.windowID("weekly"), vendor: "Kimi", model: "Weekly", source: "Pi", enabled: true, billingPool: $0)
            }, consumerIdsByQuota: claims, activeQuotaPoolIDs: ["Kimi": Set(active.map(\.id))])
        }
        let first = report([pools[0]], claims: [pools[0].windowID("weekly"): [consumer]])
        let ambiguous = report(pools, claims: Dictionary(uniqueKeysWithValues: pools.map { ($0.windowID("weekly"), Set<String>()) }))
        let retained = ambiguous.retainingReadings(from: first)
        XCTAssertEqual(retained.consumerIdsByQuota[pools[0].windowID("weekly")], [])
        XCTAssertEqual(retained.consumerIdsByQuota[pools[1].windowID("weekly")], [])
    }
}
