import Foundation

/// The logs a host asked the collector to read now, because a client's hook said something happened in them, such as a
/// prompt submitted or a turn stopped (`UsageStore.remind(paths:)`). A reminder carries nothing the collector keeps: the
/// log, read at once, says what happened. A reminded log is read at the next pass without waiting for the read spacing or
/// for a file event, which a client that keeps its log open, as Codex does, delivers late or not at all. The client can
/// still be writing when its hook runs, so the log is then looked at `followUps` more times, `followUpInterval` apart, and
/// read again whenever it changed since the look before; after that the file watch and the look at recent logs follow it
/// as they follow every log.
struct LogReminders {
    static let followUps = 3
    static let followUpInterval: TimeInterval = 0.5

    /// One log's follow-up looks: its signature at the last look, how many looks are left and when the next is due.
    private struct FollowUp {
        let signature: String?
        let looksLeft: Int
        let due: Date
    }

    /// Logs reminded of since a pass last took them.
    private var fresh: Set<String> = []
    private var followUps: [String: FollowUp] = [:]

    /// Whether a reminded log waits for its read.
    var isPending: Bool { !fresh.isEmpty }

    /// When the next follow-up look is due; nil when no log is followed up.
    var nextLook: Date? { followUps.values.map(\.due).min() }

    mutating func remind(_ paths: Set<String>) {
        fresh.formUnion(paths)
    }

    /// The logs the pass at `date` reads: those reminded of since the last pass, which start their follow-up looks, and
    /// those whose look is due and finds them changed.
    mutating func due(at date: Date) -> Set<String> {
        var due: Set<String> = []
        for (path, followUp) in followUps where followUp.due <= date && !fresh.contains(path) {
            let signature = LogSignature.of(path)
            if signature != followUp.signature { due.insert(path) }
            followUps[path] = followUp.looksLeft > 1
                ? FollowUp(signature: signature, looksLeft: followUp.looksLeft - 1, due: date.addingTimeInterval(Self.followUpInterval))
                : nil
        }
        for path in fresh {
            due.insert(path)
            followUps[path] = FollowUp(signature: LogSignature.of(path), looksLeft: Self.followUps,
                                       due: date.addingTimeInterval(Self.followUpInterval))
        }
        fresh = []
        return due
    }
}
