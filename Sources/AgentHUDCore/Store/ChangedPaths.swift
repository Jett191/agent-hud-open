import Foundation

/// The paths under the sources' directories that changed since the last read, which the collector hands the host's
/// `afterPass` hook: those the file watch reported, those the look at recent logs found grown, and reminded logs. They
/// go unnamed, nil, when the collector cannot say what changed: before the first read, after events the watch dropped,
/// while nothing can be watched, at the fallback read of every source and after the agent list changed.
struct ChangedPaths {
    private(set) var paths: Set<String>?

    mutating func add(_ more: Set<String>) {
        paths?.formUnion(more)
    }

    /// The collector can no longer name what changed until the next read.
    mutating func unnamed() {
        paths = nil
    }

    /// What a read covers; what changes after it starts counts toward the next one.
    mutating func take() -> Set<String>? {
        defer { paths = [] }
        return paths
    }

    /// Puts back what a read that did not finish took, beside what changed meanwhile.
    mutating func putBack(_ taken: Set<String>?) {
        guard let taken, let current = paths else { return paths = nil }
        paths = current.union(taken)
    }
}
