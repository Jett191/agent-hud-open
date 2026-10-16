import XCTest
@testable import AgentHUDCore

private let sessionID = "01a1154d-5774-78b2-818d-2d420c3ec554"

/// Codex compresses a rollout it has not written for a week into `<rollout>.jsonl.zst` where it lies, and turns it back
/// into the plain rollout before writing to that session again. Either way the rollout stays one contribution: its usage
/// and turns never leave the ledger, and only text the ledger has not read is read.
final class CodexCompressedRolloutTests: XCTestCase, @unchecked Sendable {

    /// A Codex Desktop rollout as Codex 0.162 writes it, line for line and field for field: the session's metadata, then
    /// per turn the task's start, the instructions, the turn's settings, the prompt as a response item and as a completed
    /// item, a tool call and its output, the answer as a completed item and as a response item, the call's usage record,
    /// the running totals and the task's end.
    private struct Rollout {
        let start: Date
        private(set) var text = ""
        private var ordinal = 0
        private var totals = (input: 0, cached: 0, output: 0)
        /// Fresh input plus output of every call so far: what the ledger counts.
        private(set) var counted = 0

        init(start: Date) {
            self.start = start
            line(0, #""type":"session_meta","payload":{"id":"\#(sessionID)","timestamp":"\#(time(0))","cwd":"/Users/me/project","originator":"Codex Desktop","cli_version":"0.162.0","source":"vscode","history_mode":"paginated"}"#)
        }

        private func time(_ second: Int) -> String {
            Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(start.addingTimeInterval(Double(second)))
        }

        private mutating func line(_ second: Int, _ body: String) {
            text += #"{"timestamp":"\#(time(second))","ordinal":\#(ordinal),"# + body + "}\n"
            ordinal += 1
        }

        /// A turn of one model call that sends `input` tokens, `cached` of them read from the cache, and gets `output`
        /// back; its tool output makes the rollout as long as a test needs.
        mutating func turn(_ number: Int, at second: Int, input: Int, cached: Int, output: Int, toolOutput: Int = 200) {
            let turn = "turn-\(number)", prompt = "Question \(number)", answer = "Answer \(number)"
            totals = (totals.input + input, totals.cached + cached, totals.output + output)
            counted += input - cached + output
            let epoch = Int(start.timeIntervalSince1970) + second
            line(second, #""type":"event_msg","payload":{"type":"task_started","turn_id":"\#(turn)","root_turn_id":"\#(turn)","started_at":\#(epoch),"model_context_window":258400,"collaboration_mode_kind":"default"}"#)
            line(second, #""type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"<permissions instructions>"}]}"#)
            line(second, #""type":"world_state","payload":{"cwd":"/Users/me/project"}"#)
            line(second + 1, #""type":"turn_context","payload":{"turn_id":"\#(turn)","cwd":"/Users/me/project","model":"gpt-6.1-sol"}"#)
            line(second + 1, #""type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"\#(prompt)"}]}"#)
            line(second + 1, #""type":"event_msg","payload":{"type":"item_completed","thread_id":"\#(sessionID)","turn_id":"\#(turn)","item":{"type":"UserMessage","id":"user-\#(number)","content":[{"type":"text","text":"\#(prompt)","text_elements":[]}]}}"#)
            line(second + 2, #""type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"cat build.log\"}","call_id":"call-\#(number)"}"#)
            line(second + 3, #""type":"response_item","payload":{"type":"function_call_output","call_id":"call-\#(number)","output":"\#(String(repeating: "x", count: toolOutput))"}"#)
            line(second + 4, #""type":"event_msg","payload":{"type":"item_completed","thread_id":"\#(sessionID)","turn_id":"\#(turn)","item":{"type":"AgentMessage","id":"msg-\#(number)","content":[{"type":"Text","text":"\#(answer)"}],"phase":"final_answer"}}"#)
            line(second + 4, #""type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"\#(answer)"}],"phase":"final_answer"}"#)
            func usage(_ input: Int, _ cached: Int, _ output: Int) -> String {
                #"{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"cache_write_input_tokens":0,"output_tokens":\#(output),"reasoning_output_tokens":0,"total_tokens":\#(input + output)}"#
            }
            line(second + 5, #""type":"token_usage_record","payload":{"thread_id":"\#(sessionID)","turn_id":"\#(turn)","usage":\#(usage(input, cached, output))}"#)
            line(second + 5, #""type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":\#(usage(totals.input, totals.cached, totals.output)),"last_token_usage":\#(usage(input, cached, output)),"model_context_window":258400}}"#)
            line(second + 6, #""type":"event_msg","payload":{"type":"task_complete","turn_id":"\#(turn)","last_agent_message":"\#(answer)","duration_ms":6000}"#)
        }
    }

    /// Nine days ago: inside the ledger's retention, and old enough for Codex to have compressed it.
    private let started = Date().addingTimeInterval(-9 * 86400)
    private var sessions: URL!, archived: URL!

    override func setUpWithError() throws {
        // The listing names files by their real path: /private/var rather than /var.
        let temporary = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(temporary) }
        let root = URL(fileURLWithPath: String(cString: temporary)).appendingPathComponent(UUID().uuidString)
        sessions = root.appendingPathComponent("sessions/2026/10/06")
        archived = root.appendingPathComponent("archived_sessions")
        for directory in [sessions!, archived!] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    }

    private var roots: [URL] { [sessions.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(), archived] }

    private func makeStore(_ ledger: UsageLedger) -> TailLogStore<CodexRollouts> {
        let store = TailLogStore<CodexRollouts>(roots: roots, ledger: ledger, watchesChanges: false, accepts: CodexRollouts.accepts)
        store.historyBudget = 5
        return store
    }

    /// Writes the rollout in `directory` with the modification time of its last line.
    @discardableResult
    private func write(_ rollout: Rollout, in directory: URL? = nil, modified: Date? = nil) throws -> URL {
        let url = (directory ?? sessions).appendingPathComponent("rollout-2026-10-06T10-00-00-\(sessionID).jsonl")
        try Data(rollout.text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified ?? started.addingTimeInterval(3600)], ofItemAtPath: url.path)
        return url
    }

    private func modified(_ url: URL) throws -> Date {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
    }

    /// What Codex's compression pass does: the frame beside the rollout with the rollout's modification time, then the
    /// rollout removed.
    @discardableResult
    private func compress(_ url: URL, keepingPlain: Bool = false) throws -> URL {
        let compressed = url.appendingPathExtension("zst")
        try ZstandardFrames.rollout(Data(contentsOf: url)).write(to: compressed)
        try FileManager.default.setAttributes([.modificationDate: try modified(url)], ofItemAtPath: compressed.path)
        if !keepingPlain { try FileManager.default.removeItem(at: url) }
        return compressed
    }

    /// What Codex does before it writes to a compressed session: the plain rollout back with the same modification time,
    /// then the frame removed.
    @discardableResult
    private func decompress(_ compressed: URL) throws -> URL {
        let url = compressed.deletingPathExtension()
        try ZstandardReader(url: compressed).read(upToCount: .max).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: try modified(compressed)], ofItemAtPath: url.path)
        try FileManager.default.removeItem(at: compressed)
        return url
    }

    private func tokensByKey(_ ledger: UsageLedger) async throws -> [String: Int] {
        try await ledger.tokens(source: CodexRollouts.source, since: .distantPast)
    }

    private func bucketTotal(_ ledger: UsageLedger) async throws -> Int {
        try await ledger.buckets(since: .distantPast, source: CodexRollouts.source).reduce(0) { $0 + $1.tokensIn + $1.tokensOut }
    }

    private func turnCount(_ ledger: UsageLedger, key: String) async throws -> Int? {
        try await ledger.sessionUsage([SessionUsageRequest(sessionID: sessionID, keys: [key, sessionID])])[sessionID]?.turnCount
    }

    func testACompressedRolloutKeepsItsContributionWithoutBeingReadAgain() async throws {
        var rollout = Rollout(start: started)
        rollout.turn(1, at: 10, input: 1_000, cached: 200, output: 50)
        rollout.turn(2, at: 100, input: 3_000, cached: 1_000, output: 80)
        let plain = try write(rollout), ledger = UsageLedger.inMemory(), store = makeStore(ledger)
        _ = await store.index(since: .distantPast, timeBudget: 5)
        var counted = try await tokensByKey(ledger)
        XCTAssertEqual(counted, [plain.path: rollout.counted])
        var turns = try await turnCount(ledger, key: plain.path)
        XCTAssertEqual(turns, 2)

        let compressed = try compress(plain)
        let pass = await store.index(since: .distantPast, timeBudget: 5)
        XCTAssertEqual(pass.filesRead, 0, "the ledger holds all of its text")
        XCTAssertEqual(pass.logs.map(\.path), [compressed.path])
        XCTAssertEqual(store.entry(compressed.path)?.summary.id, sessionID)
        counted = try await tokensByKey(ledger)
        XCTAssertEqual(counted, [compressed.path: rollout.counted], "the same contribution under the new name")
        let total = try await bucketTotal(ledger)
        XCTAssertEqual(total, rollout.counted)
        turns = try await turnCount(ledger, key: compressed.path)
        XCTAssertEqual(turns, 2, "its turns stay with it")
        let files = try await ledger.fileStates(source: CodexRollouts.source)
        XCTAssertEqual(Array(files.keys), [compressed.path])

        let restarted = await makeStore(ledger).index(since: .distantPast, timeBudget: 5)
        XCTAssertEqual(restarted.filesRead, 0, "a restart finds the state under the new name")
        XCTAssertEqual(restarted.logs.map(\.path), [compressed.path])
    }

    /// Codex writes the frame before it removes the rollout, and the rollout before it removes the frame.
    func testWhileBothFormsExistOnlyThePlainRolloutCounts() async throws {
        var rollout = Rollout(start: started)
        rollout.turn(1, at: 10, input: 1_000, cached: 0, output: 10)
        let plain = try write(rollout), ledger = UsageLedger.inMemory(), store = makeStore(ledger)
        let compressed = try compress(plain, keepingPlain: true)
        var pass = await store.index(since: .distantPast, timeBudget: 5)
        XCTAssertEqual(pass.logs.map(\.path), [plain.path])
        var counted = try await tokensByKey(ledger)
        XCTAssertEqual(counted, [plain.path: rollout.counted])

        try FileManager.default.removeItem(at: plain)
        pass = await store.index(since: .distantPast, timeBudget: 5)
        XCTAssertEqual(pass.filesRead, 0)
        counted = try await tokensByKey(ledger)
        XCTAssertEqual(counted, [compressed.path: rollout.counted])
    }

    func testARolloutCodexDecompressesToWriteToGoesOnFromWhereTheLedgerStopped() async throws {
        var rollout = Rollout(start: started)
        rollout.turn(1, at: 10, input: 1_000, cached: 100, output: 10)
        rollout.turn(2, at: 100, input: 2_000, cached: 900, output: 20)
        let compressed = try compress(try write(rollout)), ledger = UsageLedger.inMemory(), store = makeStore(ledger)
        var pass = await store.index(since: .distantPast, timeBudget: 5)
        XCTAssertEqual(pass.filesRead, 1, "a ledger that never saw the rollout reads the compressed one from its start")
        var counted = try await tokensByKey(ledger)
        XCTAssertEqual(counted, [compressed.path: rollout.counted])
        XCTAssertEqual(store.entry(compressed.path)?.summary.task, "Question 1")

        let plain = try decompress(compressed)
        pass = await store.index(since: .distantPast, timeBudget: 5)
        XCTAssertEqual(pass.filesRead, 0)
        counted = try await tokensByKey(ledger)
        XCTAssertEqual(counted, [plain.path: rollout.counted])

        let before = rollout.text.utf8.count
        rollout.turn(3, at: 9 * 86400, input: 4_000, cached: 2_000, output: 30)
        try write(rollout, modified: Date())
        pass = await store.index(since: .distantPast, timeBudget: 5)
        XCTAssertEqual(pass.bytesRead, rollout.text.utf8.count - before, "only the new turn")
        counted = try await tokensByKey(ledger)
        XCTAssertEqual(counted, [plain.path: rollout.counted])
        let turns = try await turnCount(ledger, key: plain.path)
        XCTAssertEqual(turns, 3)
    }

    /// Codex wrote to the session after the ledger's last read, then compressed it while the app was not running.
    func testLinesTheLedgerHadNotReadAreReadFromTheDecodedText() async throws {
        var rollout = Rollout(start: started)
        rollout.turn(1, at: 10, input: 1_000, cached: 100, output: 10)
        let plain = try write(rollout), ledger = UsageLedger.inMemory()
        _ = await makeStore(ledger).index(since: .distantPast, timeBudget: 5)
        rollout.turn(2, at: 3600, input: 2_000, cached: 900, output: 20)
        let compressed = try compress(try write(rollout, modified: started.addingTimeInterval(7200)))
        XCTAssertEqual(compressed.deletingPathExtension(), plain)

        let pass = await makeStore(ledger).index(since: .distantPast, timeBudget: 5)
        XCTAssertEqual(pass.filesRead, 1)
        XCTAssertEqual(pass.bytesRead, rollout.text.utf8.count, "decoded from the frame's start, read from where the ledger stopped")
        let counted = try await tokensByKey(ledger)
        XCTAssertEqual(counted, [compressed.path: rollout.counted], "the first turn counted once")
        let turns = try await turnCount(ledger, key: compressed.path)
        XCTAssertEqual(turns, 2)
    }

    func testALongCompressedRolloutIsReadAcrossPassesDecodingItOnce() async throws {
        var rollout = Rollout(start: started)
        for number in 1...6 { rollout.turn(number, at: number * 100, input: 1_000 * number, cached: 0, output: number, toolOutput: 1 << 20) }
        let compressed = try compress(try write(rollout)), ledger = UsageLedger.inMemory(), store = makeStore(ledger)
        var passes = 0, decoded = 0, pass = TailLogStore<CodexRollouts>.Pass()
        repeat {
            pass = await store.index(since: .distantPast, timeBudget: 0)
            passes += 1
            decoded += pass.bytesRead
        } while pass.pending > 0 && passes < 10
        XCTAssertGreaterThan(passes, 1, "a pass reads a chunk past its budget, not the whole log")
        XCTAssertEqual(decoded, rollout.text.utf8.count, "each pass goes on with the reader the last one stopped")
        let counted = try await tokensByKey(ledger)
        XCTAssertEqual(counted, [compressed.path: rollout.counted])
    }

    /// A compressed rollout is older than the cutoff, so nothing but the stopped read itself brings the store back to it.
    func testAReadStoppedShortGoesOnAfterARestartWhenTheRolloutIsOlderThanTheCutoff() async throws {
        var rollout = Rollout(start: started)
        for number in 1...6 { rollout.turn(number, at: number * 100, input: 1_000 * number, cached: 0, output: number, toolOutput: 1 << 20) }
        try compress(try write(rollout))
        let ledger = UsageLedger.inMemory()
        var pass = await makeStore(ledger).index(since: .distantPast, timeBudget: 0)
        XCTAssertGreaterThan(pass.pending, 0)
        var counted = try await tokensByKey(ledger).values.reduce(0, +)
        XCTAssertLessThan(counted, rollout.counted, "the budget stopped the first read")

        let restarted = makeStore(ledger)
        var passes = 0
        repeat {
            pass = await restarted.index(since: Date(), timeBudget: 0)
            passes += 1
        } while pass.pending > 0 && passes < 10
        counted = try await tokensByKey(ledger).values.reduce(0, +)
        XCTAssertEqual(counted, rollout.counted)
    }

    /// The app read the newest turn, then quit before the history; Codex compressed the rollout a week later.
    func testHistoryLeftUnreadWhenTheRolloutWasCompressedIsReadFromItsStart() async throws {
        var rollout = Rollout(start: started)
        rollout.turn(1, at: 10, input: 1_000, cached: 100, output: 10)
        rollout.turn(2, at: 100, input: 2_000, cached: 900, output: 20)
        rollout.turn(3, at: 200, input: 3_000, cached: 1_500, output: 30)
        let plain = try write(rollout), ledger = UsageLedger.inMemory(), first = makeStore(ledger)
        first.historyBudget = 0
        _ = await first.index(since: .distantPast, timeBudget: 5)
        var counted = try await tokensByKey(ledger)
        XCTAssertEqual(counted, [plain.path: 3_000 - 1_500 + 30], "the newest turn alone")
        XCTAssertNotNil(first.entry(plain.path)?.back)

        let compressed = try compress(plain), store = makeStore(ledger)
        _ = await store.index(since: .distantPast, timeBudget: 5)
        counted = try await tokensByKey(ledger)
        XCTAssertEqual(counted, [compressed.path: rollout.counted])
        XCTAssertNil(store.entry(compressed.path)?.back)
        XCTAssertEqual(store.entry(compressed.path)?.summary.task, "Question 1", "the history's first prompt names the session")
        XCTAssertEqual(store.entry(compressed.path)?.summary.sessionTurns.map(\.turnID), ["turn-1", "turn-2", "turn-3"])
    }

    /// Codex compresses both copies of a session that sits in sessions/ and archived_sessions/; the newer still counts.
    func testCopiesOfASessionKeepWhichOneCounts() async throws {
        var rollout = Rollout(start: started)
        rollout.turn(1, at: 10, input: 1_000, cached: 100, output: 10)
        let older = try write(rollout, modified: started.addingTimeInterval(600))
        rollout.turn(2, at: 1200, input: 2_000, cached: 900, output: 20)
        let newer = try write(rollout, in: archived, modified: started.addingTimeInterval(1800))
        let ledger = UsageLedger.inMemory(), store = makeStore(ledger)
        _ = await store.index(since: .distantPast, timeBudget: 5)
        var total = try await bucketTotal(ledger)
        XCTAssertEqual(total, rollout.counted, "only the newer copy counts")

        try compress(older)
        try compress(newer)
        let pass = await store.index(since: .distantPast, timeBudget: 5)
        XCTAssertEqual(pass.filesRead, 0)
        total = try await bucketTotal(ledger)
        XCTAssertEqual(total, rollout.counted)
        let counted = try await tokensByKey(ledger)
        XCTAssertEqual(Set(counted.keys), [older.path + ".zst", newer.path + ".zst"])
    }

    func testTheSessionListShowsACompressedSessionUnderItsNewName() async throws {
        var rollout = Rollout(start: started)
        rollout.turn(1, at: 10, input: 1_000, cached: 100, output: 10)
        let plain = try write(rollout), ledger = UsageLedger.inMemory()
        let transcripts = CodexTranscriptStore(roots: roots, ledger: ledger)
        var result = await transcripts.index(since: .distantPast)
        XCTAssertEqual(result.sessions.map(\.path), [plain.path])
        let usage = await transcripts.usage(since: .distantPast)

        let compressed = try compress(plain)
        result = await transcripts.index(since: .distantPast)
        XCTAssertEqual(result.sessions.map(\.path), [compressed.path])
        XCTAssertEqual(result.sessions.first?.transcript.inputTokens, 900)
        let after = await transcripts.usage(since: .distantPast)
        XCTAssertEqual(after, usage)
    }
}
