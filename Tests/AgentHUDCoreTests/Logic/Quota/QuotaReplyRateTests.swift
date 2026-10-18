import XCTest
import AgentHUDSupport
@testable import AgentHUDCore

final class QuotaReplyRateTests: XCTestCase {
    func testASelectedModelUsesThePreviousCallEvenWhenItUsedAnotherModel() throws {
        let events: [UsageLedger.ReplyEvent] = [
            .init(contribution: 1, agent: "A", atMs: 0, out: 1_000),
            .init(contribution: 1, agent: "B", atMs: 100_000, out: 500),
            .init(contribution: 1, agent: "A", atMs: 130_000, out: 300),
        ]
        let rate = try XCTUnwrap(QuotaMath.replyRate(events: events.reversed(), consumers: ["A"]))
        XCTAssertEqual(rate.tokensPerSecond, 10, accuracy: 0.0001)
        XCTAssertEqual(rate.calls, 1)
        XCTAssertEqual(rate.tokensOut, 300, "only the selected model's later call contributes output")
        let other = try XCTUnwrap(QuotaMath.replyRate(events: events, consumers: ["B"]))
        XCTAssertEqual(other.tokensPerSecond, 5, accuracy: 0.0001)
        XCTAssertEqual(other.tokensOut, 500)
    }

    func testCallGapsStillExcludeIdleTimeAndNeverCrossLogs() throws {
        let events: [UsageLedger.ReplyEvent] = [
            .init(contribution: 1, agent: "A", atMs: 0, out: 1_000),
            .init(contribution: 1, agent: "B", atMs: 130_000, out: 500),
            .init(contribution: 1, agent: "A", atMs: 160_000, out: 300),
            .init(contribution: 2, agent: "A", atMs: 159_000, out: 9_000),
        ]
        let rate = try XCTUnwrap(QuotaMath.replyRate(events: events, consumers: ["A", "B"]))
        XCTAssertEqual(rate.tokensPerSecond, 10, accuracy: 0.0001)
        XCTAssertEqual(rate.calls, 1)
        XCTAssertEqual(rate.tokensOut, 300)
        XCTAssertNil(QuotaMath.replyRate(events: events, consumers: []))
    }

    func testLedgerSelectionKeepsOtherModelsAsContextOnlyInMatchingLogs() async throws {
        let ledger = UsageLedger.inMemory()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        @Sendable func event(_ key: String, _ second: Double, _ agent: String, _ output: Int) -> UsageLedger.Event {
            .init(key: key, timestamp: base.addingTimeInterval(second), agentId: agent, tokensIn: 1, tokensOut: output)
        }
        try await ledger.write { writer in
            try writer.upsert(source: "test", contribution: "mixed", events: [
                event("a0", 0, "A", 1_000), event("b", 100, "B", 500), event("a1", 130, "A", 300),
            ])
            try writer.upsert(source: "test", contribution: "unrelated", events: [
                event("b0", 99, "B", 9_000), event("b1", 101, "B", 9_000),
            ])
        }
        let events = try await ledger.replyEvents(agents: ["A"], sinceMs: RecordCoding.milliseconds(base))
        XCTAssertEqual(events.map(\.agent), ["A", "B", "A"])
        XCTAssertEqual(Set(events.map(\.contribution)).count, 1, "an unrelated log contributes no timing context")
        let rate = try XCTUnwrap(QuotaMath.replyRate(events: events, consumers: ["A"]))
        XCTAssertEqual(rate.tokensPerSecond, 10, accuracy: 0.0001)
        XCTAssertEqual(rate.calls, 1)
        XCTAssertEqual(rate.tokensOut, 300)
    }
}
