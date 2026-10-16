import XCTest
@testable import AgentHUDCore

/// A session's list price, priced per model and tier, against each call priced on its own and added up in time order.
final class SessionUsageListCostTests: XCTestCase {
    /// Priced with tiers (one above the base for GPT-5.5 and Grok, three for Qwen through Alibaba), priced without, priced
    /// at nothing, a peak-hours model priced off-peak, a dated 1M snapshot, and without a price: a gateway's route and a
    /// model the catalog lacks.
    private let consumers = [
        "codex-model:gpt-5.5", "pi-model:qwen3-coder-plus#alibaba", "opencode-model:grok-4.7#xai", "claude-model:claude-opus-4-5",
        "claude-model:claude-sonnet-4-5-20250929[1m]", "opencode-model:glm-4.7-flash#zai", "deepseek-model:deepseek-flash",
        "opencode-model:gpt-5.5#openrouter", "kimi-model:kimi-for-coding#kimi-code",
    ]

    func testGroupedPriceEqualsEachCallPricedAndAddedUp() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let listings = Dictionary(uniqueKeysWithValues: consumers.map { ($0, ModelCatalog.listing(for: $0)) })
        var pricedSessions = 0, pricedTurns = 0, unpricedTurns = 0, tiers: Set<Int> = [], trimmed = 0
        for seed in 0..<300 {
            var random = SplitMix64(state: UInt64(seed))
            let session = randomSession(&random)
            var builder = SessionUsageBuilder(prompts: session.prompts, compactions: session.compactions)
            session.calls.forEach { builder.add($0) }
            let usage = builder.build(costs: nil) { _, reported in reported }

            // Each call priced on its own, added up into its session and its turn as the builder used to.
            let prompts = session.prompts.sorted()
            var total: Decimal? = 0, turns: [Int: Decimal?] = [:]
            for call in session.calls {
                let cost = Self.pricedOnItsOwn(call)
                XCTAssertEqual(ModelCatalog.cost(agentId: call.agentId, kinds: call.tokens.kinds)?.amount, cost, "seed \(seed)")
                total = total.flatMap { sum in cost.map { sum + $0 } }
                if let tier = listings[call.agentId]??.tier(of: call.tokens.kinds) { tiers.insert(tier) }
                guard !prompts.isEmpty else { continue }
                let turn = prompts.lastIndex { $0 <= call.timestamp } ?? -1, sum: Decimal? = turns[turn] ?? 0
                turns.updateValue(sum.flatMap { sum in cost.map { sum + $0 } }, forKey: turn)
            }
            let expected = turns.keys.sorted().suffix(SessionUsage.turnLimit).map { turns[$0]! }
            trimmed += turns.count > SessionUsage.turnLimit ? 1 : 0

            XCTAssertEqual(usage.listCost, total, "seed \(seed)")
            XCTAssertEqual(usage.listCost.map(Self.text), total.map(Self.text), "seed \(seed)")
            XCTAssertEqual(usage.turnCount, turns.count, "seed \(seed)")
            XCTAssertEqual(usage.turns.map(\.listCost), expected, "seed \(seed)")
            XCTAssertEqual(usage.turns.map { $0.listCost.map(Self.text) }, expected.map { $0.map(Self.text) }, "seed \(seed)")
            let reference = SessionUsage(
                models: usage.models, periods: usage.periods, subagents: usage.subagents, calls: usage.calls, contextTokens: usage.contextTokens,
                costs: usage.costs, turns: zip(usage.turns, expected).map { turn, cost in
                    SessionUsage.Turn(start: turn.start, end: turn.end, tokens: turn.tokens, calls: turn.calls, contextTokens: turn.contextTokens,
                                      compacted: turn.compacted, subagents: turn.subagents, peakContextTokens: turn.peakContextTokens,
                                      recachedTokens: turn.recachedTokens, listCost: cost)
                }, turnCount: usage.turnCount, contextWindow: usage.contextWindow, listCost: total)
            XCTAssertEqual(try encoder.encode(usage), try encoder.encode(reference), "seed \(seed): the same bytes, not only the same values")

            pricedSessions += total == nil ? 0 : 1
            pricedTurns += expected.filter { $0 != nil }.count
            unpricedTurns += expected.filter { $0 == nil }.count
        }
        // The sessions reach what the comparison is about.
        XCTAssertGreaterThan(pricedSessions, 100)
        XCTAssertGreaterThan(pricedTurns, 1000)
        XCTAssertGreaterThan(unpricedTurns, 100)
        XCTAssertTrue(tiers.isSuperset(of: [0, 1, 2]), "calls reach a first tier and Qwen's higher ones")
        XCTAssertGreaterThan(trimmed, 0, "some sessions have more turns than a breakdown keeps")
    }

    /// Pricing calls together is exact only while no amount needs more than a Decimal's 38 digits. A rate with at most six
    /// decimals below a million needs 12, so a whole `Int` of tokens of each kind, priced and added up, needs at most 32.
    /// A rate such as a third of another would round, and calls priced together could then differ in the last digit.
    func testEveryRateIsShortEnoughToPriceCallsTogetherExactly() {
        for (name, model) in ModelCatalog.models {
            for (region, price) in model.prices {
                for rates in [price.rates] + price.tiers.map(\.rates) {
                    for rate in [rates.input, rates.cacheWrite, rates.cacheRead, rates.output] {
                        XCTAssertTrue(rate.exponent >= -6 && rate >= 0 && rate < 1_000_000, "\(name) on \(region): \(rate)")
                    }
                }
            }
        }
    }

    /// What a call cost before calls were priced together, worked out here from the public list alone, so that a mistake in
    /// the catalog's shared tier or formula code cannot move this reference along with what it checks: the international
    /// list at the tier the call's prompt reaches, off-peak.
    private static func pricedOnItsOwn(_ call: SessionUsageBuilder.Call) -> Decimal? {
        let kinds = call.tokens.kinds, prompt = kinds.input + kinds.cacheWrite + kinds.cacheRead
        guard let list = ModelCatalog.model(for: call.agentId)?.price(in: .international) else { return nil }
        let rates = list.price.tiers.last { prompt >= $0.from }?.rates ?? list.price.rates
        return (Decimal(kinds.input) * rates.input + Decimal(kinds.cacheWrite) * rates.cacheWrite
            + Decimal(kinds.cacheRead) * rates.cacheRead + Decimal(kinds.output + kinds.reasoning) * rates.output) / 1_000_000
    }

    /// The text a breakdown is encoded with and the text the sync payload sends.
    private static func text(_ amount: Decimal) -> String { amount.description + " " + NSDecimalNumber(decimal: amount).stringValue }

    private struct RandomSession {
        var prompts: [Date] = [], compactions: [Date] = [], calls: [SessionUsageBuilder.Call] = []
    }

    /// A few hours of calls by a few consumers, a quarter of them sub-agents', with prompts before, among and after them,
    /// compactions, calls at the same moment, empty calls, calls past every tier and a few billion-token ones.
    private func randomSession(_ random: inout SplitMix64) -> RandomSession {
        let start = Date(timeIntervalSince1970: 1_800_000_000), hours = Double.random(in: 0.1...6, using: &random) * 3600
        let pool = (0..<Int.random(in: 1...4, using: &random)).map { _ in consumers.randomElement(using: &random)! }
        // One in twelve has more turns than a breakdown keeps, its prompts made with its calls; one in five marks no prompts.
        let long = Int.random(in: 0..<12, using: &random) == 0
        let prompts = long ? Int.random(in: 320...400, using: &random)
            : Int.random(in: 0..<5, using: &random) == 0 ? 0 : Int.random(in: 1...40, using: &random)
        let calls = long ? Int.random(in: 450...600, using: &random) : Int.random(in: 0...160, using: &random)
        let times = (0..<calls).map { _ in Double.random(in: 0...hours, using: &random).rounded() }.sorted()
        var session = RandomSession()
        session.prompts = (0..<prompts).map { _ in
            start.addingTimeInterval(long ? times.randomElement(using: &random)! : Double.random(in: -600...hours + 600, using: &random).rounded())
        }
        session.compactions = (0..<Int.random(in: 0...3, using: &random)).map { _ in start.addingTimeInterval(Double.random(in: 0...hours, using: &random)) }
        let callLog = Bool.random(using: &random)
        session.calls = times.map { time in
            let prompt = [0, 2_000, 40_000, 150_000, 600_000].randomElement(using: &random)!
            let input = Int.random(in: 0...prompt, using: &random), read = Int.random(in: 0...prompt, using: &random)
            let output = Int.random(in: 0...20_000, using: &random)
            var tokens = SessionUsage.Tokens(tokensIn: input, tokensOut: output, cacheReadTokens: read,
                                             cacheWriteTokens: Int.random(in: 0...input + 100, using: &random),
                                             reasoningTokens: Int.random(in: 0...output + 100, using: &random))
            if Int.random(in: 0..<200, using: &random) == 0 {
                tokens.tokensIn = Int.random(in: 0...3_000_000_000, using: &random)
                tokens.cacheReadTokens = Int.random(in: 0...3_000_000_000, using: &random)
            }
            let own = Int.random(in: 0..<4, using: &random) > 0
            return SessionUsageBuilder.Call(timestamp: start.addingTimeInterval(time), agentId: pool.randomElement(using: &random)!, tokens: tokens,
                                            own: own, callLog: own && callLog,
                                            contextWindow: Bool.random(using: &random) ? 200_000 : nil)
        }
        return session
    }
}

/// A fixed-seed generator, so every run builds the same sessions.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
