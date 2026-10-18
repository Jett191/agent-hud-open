import Foundation
import XCTest
@testable import AgentHUDCore

final class GrokBotSpendTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testDailyRowsBecomeOneBillingSessionPerBotWithAnEventPerDay() throws {
        let billing = GrokBotSpend.merged(reply([
            spend(day: 1799999900000, category: "native-agent", cents: 12, tokens: .string("4200")),
            spend(day: 1799998200000, category: "native-agent", cents: 2, tokens: .string("800")),
            spend(day: 1799999900000, category: "second-agent", cents: 1, tokens: .integer(300)),
        ]), account: "billing-account", into: ProviderSessions())
        XCTAssertEqual(billing.sessions.map(\.id),
            ["cursor-account:billing-account:native-agent", "cursor-account:billing-account:second-agent"])
        let native = try XCTUnwrap(billing.sessions.first)
        XCTAssertEqual(native.client, "Cursor")
        XCTAssertEqual(native.title, "Cursor · native-a")
        XCTAssertTrue(native.accountWide)
        XCTAssertEqual(native.events.count, 2)
        XCTAssertEqual(native.events.map(\.input), [4200, 800])
        XCTAssertEqual(Set(native.events.map(\.model)), ["grok-bot"])
        XCTAssertEqual(native.lastSeen, Date(timeIntervalSince1970: 1_799_999_900))
    }

    func testAConversationTheRequestLevelEventsAlreadyBilledKeepsThemInsteadOfTheDailyTotal() throws {
        let events = try CursorClient.parseEvents([
            .object(["timestamp": .integer(1799999995000), "model": .string("grok-bot-default"),
                     "conversationId": .string("native-agent"),
                     "tokenUsage": .object(["inputTokens": .integer(10), "outputTokens": .integer(5),
                                            "cacheReadTokens": .integer(20), "cacheWriteTokens": .integer(2)])]),
        ], account: "billing-account")
        let billing = GrokBotSpend.merged(reply([
            spend(day: 1799999900000, category: "native-agent", cents: 5, tokens: .string("999")),
            spend(day: 1799999900000, category: "unbilled-agent", cents: 1, tokens: .string("60")),
        ]), account: "billing-account", into: events)
        let native = try XCTUnwrap(billing.sessions.first { $0.id == "cursor-account:billing-account:native-agent" })
        XCTAssertEqual(native.events.count, 1, "the request-level event and its day total must not count the same usage twice")
        XCTAssertEqual(native.events.first?.input, 12, "parseEvents folds the 2 cacheWrite tokens into input")
        XCTAssertEqual(billing.sessions.map(\.id).sorted(),
            ["cursor-account:billing-account:native-agent", "cursor-account:billing-account:unbilled-agent"])
    }

    func testAnEmptyReplyChangesNothing() {
        let billing = ProviderSessions(sessions: [
            ProviderSession(id: "cursor-account:billing-account:conversation", title: "Cursor · conversation", client: "Cursor"),
        ])
        for reply in [ProviderJSON.object([:]), .object(["dailySpend": .array([])])] {
            XCTAssertEqual(GrokBotSpend.merged(reply, account: "billing-account", into: billing).sessions.map(\.id),
                           billing.sessions.map(\.id))
        }
    }

    func testUnattributedSpendKeepsItsOwnBucketAndUnreadableRowsAreSkipped() throws {
        let billing = GrokBotSpend.merged(reply([
            spend(day: 1799999900000, category: "Other", cents: 3, tokens: .string("70")),
            spend(day: 1799999900000, category: "unattributed", cents: 1, tokens: .string("30")),
            spend(day: 1799999900000, category: "", cents: 9, tokens: .string("900")),
            spend(day: 1799999900000, category: "bad/id", cents: 9, tokens: .string("900")),
            .object(["day": .string("1799999900000"), "category": .string("zero-agent"), "totalTokens": .string("0")]),
            .object(["day": .string("1799999900000"), "category": .string("no-tokens"), "spendCents": .number(2)]),
        ]), account: "billing-account", into: ProviderSessions())
        let bucket = try XCTUnwrap(billing.sessions.first { $0.id == "cursor-account:billing-account:other-bots" })
        XCTAssertEqual(bucket.events.map(\.input), [70, 30], "both unattributed names fold into the dashboard's own bucket")
        XCTAssertEqual(billing.sessions.count, 1)
    }

    func testASubagentRowIsNamedLikeTheBillingSubagentItStandsFor() throws {
        let billing = GrokBotSpend.merged(reply([
            spend(day: 1799999900000, category: "sand-subagent-run-a", cents: 4, tokens: .string("150")),
        ]), account: "billing-account", into: ProviderSessions())
        let session = try XCTUnwrap(billing.sessions.first)
        XCTAssertEqual(session.client, "Grok Bot")
        XCTAssertEqual(session.title, L10n.text("Grok Bot 子代理", "Grok Bot subagent") + " · run-a")
        XCTAssertTrue(session.accountWide)
    }

    func testDailyRowsGiveAPureBotSessionRealTokensThroughTheExistingJoin() async throws {
        let fixture = try GrokBotCacheFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try fixture.writeRoster()
        let bot = try GrokBotSessions.read(fixture.roster)
        let billing = GrokBotSpend.merged(reply([
            spend(day: 1799999900000, category: fixture.agent, cents: 6, tokens: .string("900")),
            spend(day: 1799998200000, category: fixture.agent, cents: 4, tokens: .string("600")),
        ]), account: "billing-account", into: ProviderSessions())
        let ledger = UsageLedger.inMemory(), now = now
        let cursor = AdditionalUsageProvider(source: .cursor, readQuota: { .init() }, readSessions: { _ in billing },
                                             history: QuotaHistoryStore(), clock: { now }, ledger: ledger)
        let grok = AdditionalUsageProvider(source: .grok, readQuota: { .init() }, readSessions: { _ in bot },
                                           history: QuotaHistoryStore(), clock: { now }, ledger: ledger)
        let report = try await CombinedUsageProvider([.init("Cursor", cursor), .init("Grok", grok)], ledger: ledger)
            .fetchAccountAndLocalUsage(agents: [], historyHours: 168)
        let session = try XCTUnwrap(report.sessions.first { $0.id == fixture.sessionID })
        XCTAssertEqual(session.client, "Grok Bot")
        XCTAssertEqual(session.tokensIn, 1500)
        XCTAssertEqual(session.tokensOut, 0)
        XCTAssertEqual(session.usageKey, "cursor-account:billing-account:\(fixture.agent)")
        XCTAssertEqual(report.usage.reduce(0) { $0 + $1.tokensIn }, 1500, "the day totals count once across the account")
    }

    private func reply(_ rows: [ProviderJSON]) -> ProviderJSON {
        .object(["dailySpend": .array(rows)])
    }

    private func spend(day: Int64, category: String, cents: Int64, tokens: ProviderJSON) -> ProviderJSON {
        .object(["day": .string(String(day)), "category": .string(category),
                 "spendCents": .integer(cents), "totalTokens": tokens])
    }
}
