import Foundation

/// Usage that an earlier version of a log's reader recorded, counting on in the ledger while this version reads the log
/// again, so day totals, and a session's breakdown and share of a window, never drop while its history is read once
/// more. The log's one contribution holds both: this version's usage and marks at the times `span` covers, and the
/// earlier version's outside it; `span` is all this keeps. A write first deletes the earlier usage at the times it adds
/// to the span, so nothing counts twice, and once this version has read the whole log, back to its start or the
/// ledger's retention and up to its end, the rest of the earlier usage leaves. A session's own token count, which the
/// reader's summary keeps, follows the new read.
///
/// The cut goes by time, in the ledger's milliseconds, because two versions may key the same usage differently. A line
/// the client wrote out of time order can therefore leave a little before this version reads it again, but nothing is
/// counted twice and nothing stays once the log is read whole.
struct CarriedUsage: Codable, Equatable, Sendable {
    /// The first and last time of the usage and marks this version has written; nil before it wrote any.
    private(set) var span: ClosedRange<Int64>?

    /// What a write of usage and marks at `times` replaces of the earlier usage, deleted before the write, and what is
    /// carried on after it: nothing once `whole` says this version has now read the whole log, so the write replaces
    /// all the earlier usage left.
    func writing(_ times: [Int64], whole: Bool) -> (replaced: [ClosedRange<Int64>], carried: CarriedUsage?) {
        if whole { return (Self.outside(span), nil) }
        guard let first = times.min(), let last = times.max() else { return ([], self) }
        guard let span else { return ([first...last], CarriedUsage(span: first...last)) }
        var replaced: [ClosedRange<Int64>] = []
        if first < span.lowerBound { replaced.append(first...(span.lowerBound - 1)) }
        if last > span.upperBound { replaced.append((span.upperBound + 1)...last) }
        return (replaced, CarriedUsage(span: min(first, span.lowerBound)...max(last, span.upperBound)))
    }

    /// Every time outside `span`, or every time without one.
    private static func outside(_ span: ClosedRange<Int64>?) -> [ClosedRange<Int64>] {
        guard let span else { return [Int64.min...Int64.max] }
        var times: [ClosedRange<Int64>] = []
        if span.lowerBound > Int64.min { times.append(Int64.min...(span.lowerBound - 1)) }
        if span.upperBound < Int64.max { times.append((span.upperBound + 1)...Int64.max) }
        return times
    }
}
