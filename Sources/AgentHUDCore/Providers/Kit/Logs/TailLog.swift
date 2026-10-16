import Foundation

/// An append-only log format: what a client supplies to `TailLogStore`. Sendable, so its decoding can run off the
/// store's actor.
protocol TailLog: Sendable {
    /// What the store keeps of one log between reads, such as counters and turn state; never conversation text.
    associatedtype Summary: Codable & Sendable
    /// The ledger source that owns the logs' contributions and stored states.
    static var source: String { get }
    /// The summary's key in the stored JSON state, and that state's version; a log whose state has another version is
    /// read again, as a log seen for the first time is, and what it recorded counts on until the new read covers the
    /// same times (`CarriedUsage`); a log that also shrank or was rewritten replaces it at once.
    static var summaryKey: String { get }
    static var version: Int { get }
    static func summary(for url: URL) -> Summary
    /// The name that copies of one log share in several places, of which only the most recently modified is read and
    /// the others are treated as missing from the listing; nil for a log that is never copied whole.
    static func copyName(_ path: String) -> String?
    /// The decoded log from `start`, for a format that cannot be read from an offset, with the places a later read can
    /// start from; nil reads the file itself from where the last read stopped.
    static func contents(of url: URL, from start: DecodedPosition) async throws -> DecodedLog?
    /// The suffix the client adds to a log it compresses where it lies, as one Zstandard frame, such as Codex's `.zst`;
    /// nil for a format whose logs are never compressed. See `CompressedLogs`.
    static var compressedSuffix: String? { get }
    /// Reads one or more complete lines, each ending in a newline, that begin `offset` bytes into the log (into its
    /// decoded text, for a log that has to be decoded), and returns the usage they added. An event is keyed by what it
    /// is or where it lies, never by the order lines are read in: a log's history is read after its end.
    static func ingest(_ lines: Data, at offset: Int, into summary: inout Summary) throws -> [UsageLedger.Event]
    /// Whether a line starts a turn, by the client's own mark. A log that can tell is first read from its newest turn
    /// on, and its history a page at a time after that, newest first; nil reads the log from its start, as a log that
    /// has to be decoded is.
    static var startsTurn: LogPager.StartsTurn? { get }
    /// What every page needs before its own lines, such as the log's session and its first prompt: read from the log's
    /// first complete lines, without counting their usage.
    static func head(_ lines: Data, into summary: inout Summary)
    /// Takes in what an older page of the same log read, into the summary of everything after it.
    static func merge(older: Summary, into summary: inout Summary)
    /// Whether a line, judged by its first bytes, carries state the lines after it are read against, such as a running
    /// total. A page, and a log first read from its newest turn, starts from the newest such line before it, as a read
    /// from the log's start would have; nil when no line does.
    static var carriesState: (@Sendable (Data) -> Bool)? { get }
    /// Takes the state such a line carries, counting nothing.
    static func seed(_ line: Data, into summary: inout Summary)
    /// The prompts and compactions read since the last call.
    static func drainMarks(_ summary: inout Summary) -> [UsageLedger.Mark]
    /// Runs once a read has reached the end of the log; not after a read the budget stopped short, which the next poll
    /// takes up.
    static func finishRead(_ summary: inout Summary, now: Date)
    /// The session of a log that can be copied to several places, where only the newest copy counts; "" for such a log
    /// without a session. Nil for a format whose logs all count.
    static func group(_ summary: Summary) -> String?
}

extension TailLog {
    static func copyName(_ path: String) -> String? { nil }
    static func contents(of url: URL, from start: DecodedPosition) async throws -> DecodedLog? { nil }
    static var compressedSuffix: String? { nil }
    static func drainMarks(_ summary: inout Summary) -> [UsageLedger.Mark] { [] }
    static func finishRead(_ summary: inout Summary, now: Date) {}
    static func group(_ summary: Summary) -> String? { nil }
    static var startsTurn: LogPager.StartsTurn? { nil }
    static func head(_ lines: Data, into summary: inout Summary) {}
    static func merge(older: Summary, into summary: inout Summary) {}
    static var carriesState: (@Sendable (Data) -> Bool)? { nil }
    static func seed(_ line: Data, into summary: inout Summary) {}
}

/// A place a log that has to be decoded can be read from: the byte of the file and the byte of the decoded text it
/// starts at, such as the start of a compressed frame.
struct DecodedPosition: Codable, Hashable, Sendable {
    var stored = 0
    var decoded = 0
}

/// Part of a decoded log: its text from `start` on, and the places inside it a later read can start from, in order.
struct DecodedLog: Sendable {
    let start: DecodedPosition
    let data: Data
    let restarts: [DecodedPosition]
}
