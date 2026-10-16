import XCTest
@testable import AgentHUDCore

/// Sources are read when they signal new data, and only the signalled sources are read.
final class CollectionSignalTests: XCTestCase, @unchecked Sendable {
    private actor Source: UsageProvider {
        nonisolated let watchedDirectories: [URL]?
        nonisolated let readsAccount: Bool
        private let sessions: [LiveSession]
        private(set) var fetches = 0
        /// When each read began.
        private(set) var readTimes: [Date] = []
        private(set) var accountReads = 0
        private(set) var changedPaths: [Set<String>?] = []
        init(directory: URL?, sessions: [LiveSession] = [], readsAccount: Bool = false) {
            watchedDirectories = directory.map { [$0] }
            self.sessions = sessions
            self.readsAccount = readsAccount
        }
        nonisolated var accountRefreshSteps: [AccountRefreshStep] { readsAccount ? [{ _ in await self.readAccount() }] : [] }
        private func readAccount() { accountReads += 1 }
        func fileChanges(_ paths: Set<String>?) async { changedPaths.append(paths) }
        func fetchUsage(agents: [AgentDescriptor], historyHours: Int) async throws -> UsageReport {
            fetches += 1
            readTimes.append(Date())
            return UsageReport(generatedAt: Date(), snapshots: [], sessions: sessions)
        }
    }

    private actor PausingSource: UsageProvider {
        nonisolated let watchedDirectories: [URL]? = []
        nonisolated let accountRefreshSteps: [AccountRefreshStep] = []
        private let pausesFirstRead: Bool
        private let discovered: [AgentDescriptor]
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var inputs: [[AgentDescriptor]] = []

        init(pausesFirstRead: Bool, discovered: [AgentDescriptor] = []) {
            self.pausesFirstRead = pausesFirstRead
            self.discovered = discovered
        }

        func fetchUsage(agents: [AgentDescriptor], historyHours: Int) async throws -> UsageReport {
            inputs.append(agents)
            if pausesFirstRead && inputs.count == 1 {
                await withCheckedContinuation { continuation = $0 }
            }
            return UsageReport(generatedAt: Date(), snapshots: [], sessions: [], discoveredAgents: discovered)
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    /// A provider that records when each of its reads began, and runs no account step.
    private actor Timed: UsageProvider {
        private let provider: any UsageProvider
        nonisolated let watchedDirectories: [URL]?
        nonisolated let accountRefreshSteps: [AccountRefreshStep] = []
        private(set) var readTimes: [Date] = []

        init(_ provider: any UsageProvider) {
            self.provider = provider
            watchedDirectories = provider.watchedDirectories
        }

        func fileChanges(_ paths: Set<String>?) async { await provider.fileChanges(paths) }

        func fetchUsage(agents: [AgentDescriptor], historyHours: Int) async throws -> UsageReport {
            readTimes.append(Date())
            return try await provider.fetchUsage(agents: agents, historyHours: historyHours)
        }
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agenthud-signals-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.resolvingSymlinksInPath()
    }

    /// File events for directories created just before the stream starts can still arrive; wait them out first.
    @MainActor
    private func start(_ provider: any UsageProvider, hooks: UsageCollectionHooks = UsageCollectionHooks()) async throws -> UsageStore {
        try await Task.sleep(for: .seconds(1.5))
        let suite = "CollectionSignalTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let store = UsageStore(provider: provider, settings: SettingsStore(defaults: defaults), hooks: hooks)
        addTeardownBlock { @MainActor in
            store.stop()
            defaults.removePersistentDomain(forName: suite)
        }
        store.start()
        return store
    }

    @MainActor
    private func wait(timeout: TimeInterval = 8, until condition: @MainActor () async -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return await condition()
    }

    @MainActor
    func testAFileChangeReadsOnlyTheSourceThatOwnsIt() async throws {
        let first = try directory(), second = try directory()
        let a = Source(directory: first), b = Source(directory: second)
        let store = try await start(CombinedUsageProvider([.init("A", a), .init("B", b)]))
        let initial = try await wait { let x = await a.fetches; let y = await b.fetches; return x == 1 && y == 1 }
        XCTAssertTrue(initial, "the first pass reads every source")
        XCTAssertNotNil(store.report)
        try await Task.sleep(for: .seconds(1.5))
        let changedFile = first.appendingPathComponent("session.jsonl")
        try Data("{}\n".utf8).write(to: changedFile)
        let read = try await wait { await a.fetches >= 2 }
        XCTAssertTrue(read, "a change under A's directory reads A")
        let signalled = await a.changedPaths
        XCTAssertTrue(signalled.contains { paths in
            paths?.contains(where: { $0.hasSuffix("/session.jsonl") }) == true
        }, "the collector hands the affected path to the source before it reads")
        let others = await b.fetches
        XCTAssertEqual(others, 1, "B keeps its last result")
    }

    @MainActor
    func testLookingAtTheAccountsWithAWorkingWatchListsNoFileAgain() async throws {
        let a = Source(directory: try directory())
        let store = try await start(CombinedUsageProvider([.init("A", a)]))
        let initial = try await wait { await a.fetches == 1 }
        XCTAssertTrue(initial)
        let before = await a.changedPaths.count
        await store.refreshAccounts()
        // A refresh that arrives during a pass is served by the next pass, after the read spacing, so it can return
        // before the read. A has no account steps, so here a pass is nearly always running.
        let read = try await wait { await a.fetches >= 2 }
        XCTAssertTrue(read, "opening the panel still reads")
        let after = await a.changedPaths.dropFirst(before)
        XCTAssertFalse(after.contains { $0 == nil }, "a nil would make every listing list all its roots: \(after)")
    }

    @MainActor
    func testQuietSourcesAreNotReadAgain() async throws {
        let a = Source(directory: try directory())
        _ = try await start(CombinedUsageProvider([.init("A", a)]))
        let initial = try await wait { await a.fetches == 1 }
        XCTAssertTrue(initial)
        try await Task.sleep(for: .seconds(3))
        let fetches = await a.fetches
        XCTAssertEqual(fetches, 1, "no signal, no read: there is no polling interval for a watched source")
    }

    @MainActor
    func testASourceIsReadAgainWhenItsActivityAges() async throws {
        let observed = Date().addingTimeInterval(-UsageRefresh.liveThreshold + 2)
        let live = LiveSession(id: "s", agentId: "a-model:x", task: "Task", terminal: nil, startedAt: observed.addingTimeInterval(-60),
                               pctOfWindow: nil, tokensIn: 1, tokensOut: 1, observedAt: observed)
        let a = Source(directory: try directory(), sessions: [live]), b = Source(directory: try directory())
        _ = try await start(CombinedUsageProvider([.init("A", a), .init("B", b)]))
        let initial = try await wait { let x = await a.fetches; let y = await b.fetches; return x == 1 && y == 1 }
        XCTAssertTrue(initial)
        let aged = try await wait { await a.fetches >= 2 }
        XCTAssertTrue(aged, "A's live session reaches the live threshold, so A is read again")
        let others = await b.fetches
        XCTAssertEqual(others, 1)
    }

    @MainActor
    func testASourceWithoutDirectoriesIsPolled() async throws {
        let a = Source(directory: nil), b = Source(directory: try directory())
        _ = try await start(CombinedUsageProvider([.init("A", a), .init("B", b)]))
        let polled = try await wait(timeout: 12) { await a.fetches >= 2 }
        XCTAssertTrue(polled, "a source that cannot name its directories is read every poll interval")
        let others = await b.fetches
        XCTAssertEqual(others, 1, "polling one source does not read the others")
    }

    @MainActor
    func testASettingsChangeThatNeedsAReadWakesTheCollector() async throws {
        let copilot = Source(directory: try directory(), readsAccount: true), b = Source(directory: try directory(), readsAccount: true)
        let store = try await start(CombinedUsageProvider([.init(AdditionalSource.copilot.vendor, copilot), .init("B", b)]))
        // The first pass reads both accounts, and each finished step signals one more read of its source.
        let settled = try await wait {
            let reads = (await copilot.fetches, await b.fetches), accounts = (await copilot.accountReads, await b.accountReads)
            return reads == (2, 2) && accounts == (1, 1)
        }
        XCTAssertTrue(settled)
        // Without a wake the next pass would be an account interval away, five minutes.
        store.settings.update { $0.readCopilotQuota = true }
        let swept = try await wait { await copilot.accountReads == 2 }
        XCTAssertTrue(swept, "consent to read Copilot quota reads Copilot's account at once")
        let signalled = try await wait { await copilot.fetches == 3 }
        XCTAssertTrue(signalled)
        let spaced = await b.accountReads
        XCTAssertEqual(spaced, 1, "another account read seconds ago waits out the request spacing")
        store.settings.updateAgents { $0 + [AgentDescriptor(id: "b-window", vendor: "B", model: "Window", source: "Fixture", enabled: true)] }
        let reread = try await wait { let x = await copilot.fetches; let y = await b.fetches; return x == 4 && y == 3 }
        XCTAssertTrue(reread, "a changed agent list is read from every source at once")
    }

    @MainActor
    func testAnAgentChangeDuringASuspendedReadReadsEverySourceWithTheNewInput() async throws {
        let first = PausingSource(pausesFirstRead: true), second = PausingSource(pausesFirstRead: false)
        let store = try await start(CombinedUsageProvider([.init("A", first), .init("B", second)]))
        addTeardownBlock { await first.release() }
        let started = try await wait { await first.inputs.count == 1 }
        XCTAssertTrue(started)
        XCTAssertTrue(store.isRefreshing, "the old-input pass is suspended inside the first provider")
        let original = store.settings.agents
        store.settings.updateAgents { $0 + [AgentDescriptor(id: "b-window", vendor: "B", model: "Window", source: "Fixture", enabled: true)] }
        let changed = store.settings.agents
        await first.release()
        let reread = try await wait {
            let inputs = (await first.inputs, await second.inputs)
            return inputs.0.count >= 2 && inputs.1.count >= 2
        }
        XCTAssertTrue(reread, "an edit while the old pass waits must remain due for the next full read")
        let inputs = (await first.inputs, await second.inputs)
        XCTAssertEqual(inputs.0.first, original)
        XCTAssertEqual(inputs.1.first, original)
        XCTAssertEqual(inputs.0.last, changed)
        XCTAssertEqual(inputs.1.last, changed)
    }

    @MainActor
    func testARowsOwnDiscoveryDoesNotScheduleAnotherRead() async throws {
        let discovered = AgentDescriptor(id: "a-window", vendor: "A", model: "Window", source: "Fixture", enabled: true)
        let source = PausingSource(pausesFirstRead: false, discovered: [discovered])
        let store = try await start(CombinedUsageProvider([.init("A", source)]))
        let collected = try await wait { store.report != nil && !store.isRefreshing }
        XCTAssertTrue(collected)
        XCTAssertTrue(store.settings.agents.contains { $0.id == discovered.id })
        try await Task.sleep(for: .seconds(UsageRefresh.readSpacing + 0.5))
        let reads = await source.inputs.count
        XCTAssertEqual(reads, 1, "rows discovered by the completed pass are already consumed")
    }

    func testNamedSourcesAreReadAndTheOthersKeepTheirLastResult() async throws {
        let a = Source(directory: nil), b = Source(directory: nil)
        let provider = CombinedUsageProvider([.init("A", a), .init("B", b)])
        _ = try await provider.fetchUsage(agents: [], historyHours: 24)
        _ = try await provider.fetchUsage(agents: [], historyHours: 24, sources: ["A"])
        let (first, second) = (await a.fetches, await b.fetches)
        XCTAssertEqual(first, 2)
        XCTAssertEqual(second, 1)
        _ = try await provider.fetchUsage(agents: [], historyHours: 48, sources: ["A"])
        let reread = await b.fetches
        XCTAssertEqual(reread, 2, "a result read for other hours is not reused")
    }

    // MARK: Reminders

    /// A hook's reminder reads the source that owns the log at once: without a file event, which a log written through an
    /// open handle may never give, and without waiting for the read spacing.
    @MainActor
    func testAReminderReadsOnlyTheSourceThatOwnsItsLogAtOnce() async throws {
        let first = try directory(), second = try directory()
        let a = Source(directory: first), b = Source(directory: second)
        let store = try await start(CombinedUsageProvider([.init("A", a), .init("B", b)]))
        let initial = try await wait { let x = await a.fetches; let y = await b.fetches; return x == 1 && y == 1 }
        XCTAssertTrue(initial)
        let log = first.appendingPathComponent("session.jsonl").path
        store.remind(paths: [log])
        let read = try await wait { await a.fetches >= 2 }
        XCTAssertTrue(read, "the reminder reads A")
        let times = await a.readTimes
        XCTAssertLessThan(times[1].timeIntervalSince(times[0]), UsageRefresh.readSpacing / 2, "a reminder does not wait for the spacing")
        let signalled = await a.changedPaths
        XCTAssertTrue(signalled.contains { $0?.contains(log) == true }, "A is handed the log before it reads")
        let others = await b.fetches
        XCTAssertEqual(others, 1, "B keeps its last result")
    }

    /// A reminder that arrives while a pass reads is read by the next pass, which starts after it: the pass under way may
    /// have read the log before the client wrote what the hook is about.
    @MainActor
    func testAReminderDuringAReadIsReadByTheNextPass() async throws {
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        let folder = try directory(), source = Source(directory: folder)
        var publishes = 0
        let store = try await start(CombinedUsageProvider([.init("A", source)]), hooks: UsageCollectionHooks(publish: { _ in
            publishes += 1
            if publishes == 1 { for await _ in gate.stream { break } }
        }))
        let reading = try await wait { await source.fetches == 1 }
        XCTAssertTrue(reading, "the first pass waits in its publish hook")
        store.remind(paths: [folder.appendingPathComponent("session.jsonl").path])
        try await Task.sleep(for: .milliseconds(300))
        let during = await source.fetches
        XCTAssertEqual(during, 1, "nothing reads beside the pass under way")
        gate.continuation.finish()
        let next = try await wait { await source.fetches >= 2 }
        XCTAssertTrue(next, "the next pass reads the log the reminder named")
    }

    /// The host's after-pass hook runs inside each pass, after the providers, with what changed since the read before:
    /// nothing named at the first read, then the paths the file watch and reminders gave, and nothing named again once
    /// the agent list changed. No read starts while it runs.
    @MainActor
    func testTheAfterPassHookGetsWhatChangedAndNoReadRunsBesideIt() async throws {
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        let folder = try directory(), source = Source(directory: folder)
        var passes: [(changed: Set<String>?, fetches: Int)] = [], holds = false
        let store = try await start(CombinedUsageProvider([.init("A", source)]), hooks: UsageCollectionHooks(afterPass: { changed in
            passes.append((changed, await source.fetches))
            if holds { for await _ in gate.stream { break } }
        }))
        let first = try await wait { passes.count == 1 }
        XCTAssertTrue(first)
        XCTAssertNil(passes[0].changed, "the first read cannot say what changed")
        XCTAssertEqual(passes[0].fetches, 1, "the hook runs after the provider")

        let written = folder.appendingPathComponent("written.jsonl"), reminded = folder.appendingPathComponent("reminded.jsonl").path
        try Data("{}\n".utf8).write(to: written)
        let watched = try await wait { passes.contains { $0.changed?.contains { $0.hasSuffix("/written.jsonl") } == true } }
        XCTAssertTrue(watched, "a file event's path is handed over")
        holds = true
        store.remind(paths: [reminded])
        let held = try await wait { passes.last?.changed?.contains(reminded) == true }
        XCTAssertTrue(held, "a reminded log's path is handed over")
        let reads = await source.fetches
        store.remind(paths: [reminded])
        try await Task.sleep(for: .milliseconds(300))
        let during = await source.fetches
        XCTAssertEqual(during, reads, "no read starts while the hook runs")
        holds = false
        gate.continuation.finish()
        let after = try await wait { await source.fetches > reads }
        XCTAssertTrue(after, "the reminder is read once the hook returns")

        let count = passes.count
        store.settings.updateAgents { $0 + [AgentDescriptor(id: "a-window", vendor: "A", model: "Window", source: "Fixture", enabled: true)] }
        let reread = try await wait { passes.count > count && passes.last?.changed == nil }
        XCTAssertTrue(reread, "a changed agent list reads every source, and nothing names what changed")
    }

    /// The fallback read of every source stands in for file events the watch missed, so it cannot say what changed: the
    /// after-pass hook gets nil from it, even when the watch named a path since the read before.
    @MainActor
    func testTheFallbackReadNamesNothingToTheAfterPassHook() async throws {
        let folder = try directory(), source = Source(directory: folder)
        var handed: [Set<String>?] = []
        let store = try await start(CombinedUsageProvider([.init("A", source)]),
                                    hooks: UsageCollectionHooks(afterPass: { handed.append($0) }))
        let first = try await wait { handed.count == 1 }
        XCTAssertTrue(first)
        try Data("{}\n".utf8).write(to: folder.appendingPathComponent("first.jsonl"))
        let named = try await wait { handed.last??.contains { $0.hasSuffix("/first.jsonl") } == true }
        XCTAssertTrue(named, "a pass the file watch started names its path")

        // The fallback read now falls due at the next pass.
        store.collector.fallbackInterval = 0.5
        let count = handed.count
        try Data("{}\n".utf8).write(to: folder.appendingPathComponent("second.jsonl"))
        let fallback = try await wait { handed.count > count }
        XCTAssertTrue(fallback)
        XCTAssertNil(handed[count], "the fallback read names nothing, though the watch named a path")
    }

    /// A watch that cannot name what changed, as after events it dropped, makes the next pass read every source and hand
    /// the after-pass hook nil; the pass after it names the paths the watch saw again. A watch started anew is such a
    /// watch: it cannot say what happened before it.
    @MainActor
    func testAPassAfterTheWatchLostTrackNamesNothingAndTheNextNamesItsPaths() async throws {
        let folder = try directory(), source = Source(directory: folder)
        var handed: [Set<String>?] = []
        let store = try await start(CombinedUsageProvider([.init("A", source)]),
                                    hooks: UsageCollectionHooks(afterPass: { handed.append($0) }))
        let first = try await wait { handed.count == 1 }
        XCTAssertTrue(first)
        try Data("{}\n".utf8).write(to: folder.appendingPathComponent("before.jsonl"))
        let named = try await wait { handed.last??.contains { $0.hasSuffix("/before.jsonl") } == true }
        XCTAssertTrue(named)

        store.stop()
        store.start()
        let count = handed.count, reads = await source.fetches
        let lost = try await wait { handed.count > count }
        XCTAssertTrue(lost)
        XCTAssertNil(handed[count], "a watch that cannot name its events names nothing to the hook")
        let refetched = await source.fetches
        XCTAssertGreaterThan(refetched, reads, "the source is read in full")
        try Data("{}\n".utf8).write(to: folder.appendingPathComponent("after.jsonl"))
        let renamed = try await wait { handed.last??.contains { $0.hasSuffix("/after.jsonl") } == true }
        XCTAssertTrue(renamed, "the pass after it names the paths the watch saw")
    }

    // MARK: Requested passes

    /// A host's request for a pass reads the source that owns its paths at the time asked, once however many paths it
    /// names. Nothing changed, so the provider is told of no change, the after-pass hook is named none of the paths, and
    /// no look follows the request up.
    @MainActor
    func testARequestedPassReadsTheSourceThatOwnsItsPathsOnceAtTheTimeAsked() async throws {
        let first = try directory(), second = try directory()
        let a = Source(directory: first), b = Source(directory: second)
        var handed: [Set<String>?] = []
        let store = try await start(CombinedUsageProvider([.init("A", a), .init("B", b)]),
                                    hooks: UsageCollectionHooks(afterPass: { handed.append($0) }))
        let initial = try await wait { let x = await a.fetches; let y = await b.fetches; return x == 1 && y == 1 }
        XCTAssertTrue(initial)
        let paths = Set((0..<50).map { first.appendingPathComponent("session-\($0).jsonl").path })
        let asked = Date().addingTimeInterval(UsageRefresh.readSpacing + 1)
        store.requestPass(for: paths, at: asked)
        let read = try await wait { await a.fetches >= 2 }
        XCTAssertTrue(read, "the request reads A")
        let times = await a.readTimes
        XCTAssertGreaterThanOrEqual(times[1].timeIntervalSince(asked), 0, "not before the time asked")
        try await Task.sleep(for: .seconds(Double(LogReminders.followUps + 1) * LogReminders.followUpInterval))
        let (reads, others) = (await a.fetches, await b.fetches)
        XCTAssertEqual(reads, 2, "one read for all the paths it names, and no look follows it up")
        XCTAssertEqual(others, 1, "B keeps its last result")
        let told = await a.changedPaths
        XCTAssertFalse(told.contains { $0.map { !$0.isDisjoint(with: paths) } ?? false }, "the provider is told of no change")
        XCTAssertEqual(handed.count, 2)
        XCTAssertEqual(handed.last, Set<String>(), "the hook is named none of the paths")
    }

    /// A pass asked for at once still waits for the read spacing, as a reminder does not.
    @MainActor
    func testAPassAskedForAtOnceWaitsForTheReadSpacing() async throws {
        let folder = try directory(), source = Source(directory: folder)
        let store = try await start(CombinedUsageProvider([.init("A", source)]))
        let initial = try await wait { await source.fetches == 1 }
        XCTAssertTrue(initial)
        store.requestPass(for: [folder.appendingPathComponent("session.jsonl").path])
        let read = try await wait { await source.fetches >= 2 }
        XCTAssertTrue(read)
        let times = await source.readTimes
        XCTAssertGreaterThan(times[1].timeIntervalSince(times[0]), UsageRefresh.readSpacing - 0.1)
    }

    /// A pass asked for paths no watched source owns still runs, and reads every source.
    @MainActor
    func testAPassAskedForAPathNoSourceOwnsReadsEverySource() async throws {
        let a = Source(directory: try directory()), b = Source(directory: try directory())
        let store = try await start(CombinedUsageProvider([.init("A", a), .init("B", b)]))
        let initial = try await wait { let x = await a.fetches; let y = await b.fetches; return x == 1 && y == 1 }
        XCTAssertTrue(initial)
        store.requestPass(for: ["/nowhere/session.jsonl"])
        let read = try await wait { let x = await a.fetches; let y = await b.fetches; return x == 2 && y == 2 }
        XCTAssertTrue(read)
    }

    /// A Stop hook makes the session's log be read at once, and the log, which recorded the turn's end before the hook ran,
    /// ends the turn: the panel follows the stop within one read, not the file watch and the spacing.
    @MainActor
    func testAStopReminderReadsTheLogAtOnceAndTheLogEndsTheTurn() async throws {
        let root = try directory().appendingPathComponent("projects", isDirectory: true)
        let file = root.appendingPathComponent("-p/s.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        func line(_ type: String, _ message: String, at date: Date) -> String {
            #"{"sessionId":"s","cwd":"/p","type":"\#(type)","message":\#(message),"timestamp":"\#(date.ISO8601Format())"}"#
        }
        func assistant(_ id: String, stop: String, at date: Date) -> String {
            line("assistant", #"{"id":"\#(id)","role":"assistant","model":"claude-opus-5-5","content":[{"type":"text","text":"Done."}],"stop_reason":"\#(stop)","usage":{"input_tokens":1,"output_tokens":1}}"#,
                 at: date)
        }
        let begun = Date().addingTimeInterval(-60)
        try ([line("user", #"{"role":"user","content":"Build it"}"#, at: begun), assistant("m1", stop: "tool_use", at: begun.addingTimeInterval(1))]
            .joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let claude = Timed(ClaudeCodeProvider(engine: nil, transcripts: ClaudeTranscriptStore(roots: [root]), history: QuotaHistoryStore()))
        let store = try await start(claude)
        let running = try await wait { store.view.session("s")?.turn?.state == .running }
        XCTAssertTrue(running)

        // Claude Code writes the turn's end, then runs its Stop hooks.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((assistant("m2", stop: "end_turn", at: Date()) + "\n").utf8))
        try handle.close()
        store.remind(paths: [file.path])
        let ended = try await wait { store.view.session("s")?.turn?.state == .completed }
        XCTAssertTrue(ended, "the log ends the turn")
        XCTAssertEqual(store.view.session("s")?.phase.state, .idle)
        let times = await claude.readTimes
        XCTAssertLessThan(times[times.count - 1].timeIntervalSince(times[times.count - 2]), UsageRefresh.readSpacing / 2,
                          "the read that ended it waited neither for the file watch nor for the spacing")
    }

    /// A client that keeps its log open reaches the file watch late, so recent logs are compared with their last look.
    @MainActor
    func testARecentLogThatGrewIsReportedOnceAndAFirstLookOnlyNotesIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agenthud-logs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let quiet = directory.appendingPathComponent("quiet.jsonl"), busy = directory.appendingPathComponent("busy.jsonl")
        try Data("a\n".utf8).write(to: quiet)
        try Data("a\n".utf8).write(to: busy)
        let paths = [quiet.path, busy.path, directory.appendingPathComponent("gone.jsonl").path]
        var known: [String: String] = [:]
        XCTAssertEqual(UsageCollector.changedLogs(paths, known: &known), [], "The read that listed a log has just read it")
        XCTAssertEqual(Set(known.keys), [quiet.path, busy.path], "A log that is not there is not kept")
        XCTAssertEqual(UsageCollector.changedLogs(paths, known: &known), [])

        // Appended through a handle that stays open, as Codex writes its rollouts.
        let handle = try FileHandle(forWritingTo: busy)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("b\n".utf8))
        XCTAssertEqual(UsageCollector.changedLogs(paths, known: &known), [busy.path])
        XCTAssertEqual(UsageCollector.changedLogs(paths, known: &known), [], "One change is reported once")

        XCTAssertEqual(UsageCollector.changedLogs([quiet.path], known: &known), [])
        XCTAssertEqual(Set(known.keys), [quiet.path], "A session that is no longer recent is forgotten")
    }
}
