import Foundation

/// The span of actual readings in the same uninterrupted series used for the burn rate, while it is still shorter than
/// the burn rate needs.
public struct QuotaSampling: Hashable, Codable, Sendable {
    /// Seconds between the series' first and latest reading.
    public let elapsed: TimeInterval
    /// Seconds the series must span for a burn rate: the cycle's `sampleInterval`.
    public let required: TimeInterval
    /// Whether older readings show that a previous series ended, at a reset.
    public let afterReset: Bool

    public init(elapsed: TimeInterval, required: TimeInterval, afterReset: Bool) {
        self.elapsed = elapsed
        self.required = required
        self.afterReset = afterReset
    }

    /// The island row's burn-rate detail: whether readings are collected for the first time or again after a reset.
    public var label: String {
        afterReset ? L10n.text("重新采样", "Resampling") : L10n.text("采样中", "Sampling")
    }

    /// The hover hint: the same, then the span observed so far beside the span needed.
    public var hint: String {
        let reason = afterReset
            ? L10n.text("额度已重置，正在重新采样", "Quota reset; collecting new readings")
            : L10n.text("首次采样，正在积累预测数据", "Collecting initial readings for a forecast")
        // Round down the observed span: a partial minute must not claim the minimum has been met.
        let observed = elapsed < 60 ? L10n.text("不足1分", "less than 1m") : Countdown.forecast(floor(elapsed / 60) * 60)
        let minimum = Countdown.forecast(required)
        return reason + "\n" + L10n.text("已采样 \(observed)，预测至少需要\(minimum)的有效记录", "Sampled \(observed); at least \(minimum) of readings needed")
    }
}
