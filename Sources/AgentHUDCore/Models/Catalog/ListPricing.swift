import Foundation

/// What calls would cost at the vendors' API list prices: what `ModelCatalog.cost(agentId:kinds:)` gives for each, added
/// up, without pricing each. A call's tokens join those of the same consumer's calls whose prompts reach the same tier,
/// and each such group is priced once when the cost is asked for. Every rate is per token with a few decimals, so the
/// decimal amounts are exact and a group costs what its calls cost one by one, to the last digit. Each consumer's list
/// is looked up once. Prices are the international list's at off-peak rates.
struct ListPricing {
    /// The calls of one consumer whose prompts reach the same tier of its list.
    struct Group: Hashable {
        fileprivate let consumer: Int
        fileprivate let tier: Int?
    }

    /// Calls' tokens by the group they are priced in; nil once a call had no list price, which leaves them without one.
    /// Only the `ListPricing` that grouped its calls can price it: a group names a consumer by its place in that one.
    struct Tally {
        fileprivate var tokens: [Group: TokenKinds]? = [:]

        /// - group: the call's group, nil when its model has no list price.
        mutating func add(_ kinds: TokenKinds, in group: Group?) {
            if let group { tokens?[group, default: TokenKinds()] += kinds } else { tokens = nil }
        }
    }

    /// Each consumer seen, by its place in `listings`.
    private var consumers: [String: Int] = [:]
    /// Each consumer's list, nil where its model has none.
    private var listings: [ModelCatalog.Listing?] = []

    /// The group a call of `agentId` is priced in; nil when its model has no list price.
    mutating func group(of agentId: String, call kinds: TokenKinds) -> Group? {
        let consumer: Int
        if let seen = consumers[agentId] {
            consumer = seen
        } else {
            consumer = listings.count
            consumers[agentId] = consumer
            listings.append(ModelCatalog.listing(for: agentId))
        }
        return listings[consumer].map { Group(consumer: consumer, tier: $0.tier(of: kinds)) }
    }

    /// What the tallied calls would cost, in US dollars; nil when a call had no list price.
    func cost(of tally: Tally) -> Decimal? {
        // Only a consumer with a list has groups. The sum is exact in any order; a fixed one keeps it the same from run to
        // run should a rate ever break that.
        tally.tokens?.sorted { ($0.key.consumer, $0.key.tier ?? -1) < ($1.key.consumer, $1.key.tier ?? -1) }.reduce(0) { sum, group in
            sum + ModelCatalog.cost(group.value, tier: group.key.tier, on: listings[group.key.consumer]!).amount
        }
    }
}
