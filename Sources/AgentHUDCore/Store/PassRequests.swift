import Foundation

/// The passes hosts asked the collector for (`UsageStore.requestPass(for:at:)`), by the paths whose sources they read,
/// each due at the earliest time asked for it. A request due at a pass signals the sources that own its paths, which the
/// pass reads once the read spacing allows, as it reads any signalled source. A request is not a change: the provider is
/// told of none, the after-pass hook is named none, and no look follows it up, unlike a reminder (`LogReminders`).
struct PassRequests {
    private var due: [String: Date] = [:]

    /// When the first request falls due; nil when none waits.
    var next: Date? { due.values.min() }

    mutating func request(_ paths: Set<String>, at date: Date) {
        for path in paths { due[path] = min(due[path] ?? date, date) }
    }

    /// The paths whose requests are due at `date`, which the pass at `date` takes.
    mutating func take(at date: Date) -> Set<String> {
        let taken = Set(due.filter { $0.value <= date }.keys)
        for path in taken { due[path] = nil }
        return taken
    }
}
