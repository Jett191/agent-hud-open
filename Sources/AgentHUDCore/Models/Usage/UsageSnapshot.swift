import Foundation

/// Latest quota reading for one agent.
public struct UsageSnapshot: Hashable, Codable, Sendable {
    public let agentId: String
    /// Remaining % of this quota window; nil when the source reports the window without a quota value.
    public let remainingPct: Double?
    /// Remaining % of the weekly (7d) window, when the source reports one.
    public let weeklyRemainingPct: Double?
    public let resetAt: Date?
    /// Full reset period reported by the source, in seconds.
    public let windowDuration: TimeInterval?
    public let weeklyResetAt: Date?
    public let updatedAt: Date
    /// The amount consumed this cycle in the window's own unit (tokens, credits, minutes), where the source reports
    /// one; `capacity` is the cycle's size. Either nil where it only reports a percentage.
    public let used: Int64?
    public let capacity: Int64?

    public init(
        agentId: String,
        remainingPct: Double?,
        weeklyRemainingPct: Double? = nil,
        resetAt: Date? = nil,
        windowDuration: TimeInterval? = nil,
        weeklyResetAt: Date? = nil,
        updatedAt: Date,
        used: Int64? = nil,
        capacity: Int64? = nil
    ) {
        self.agentId = agentId
        self.remainingPct = remainingPct
        self.weeklyRemainingPct = weeklyRemainingPct
        self.resetAt = resetAt
        self.windowDuration = windowDuration
        self.weeklyResetAt = weeklyResetAt
        self.updatedAt = updatedAt
        self.used = used
        self.capacity = capacity
    }

    public var cycle: QuotaCycle? { QuotaCycle(resetAt: resetAt, duration: windowDuration) }
}
