import AgentHUDSupport
import Foundation

/// A standing subscription to the Codex Desktop threads it is asked to follow.
///
/// The Desktop client that owns a thread sends a follower the thread's whole state once and then only what changes, as
/// patches numbered by revision. The stream keeps each followed thread's state current from those. Long strings are
/// left out as each message is read: a thread's state is mostly the screenshots and page dumps of its tool results,
/// 102 MB of 108 MB in one measured, and nothing here reads them. Nothing is asked for again while the revisions run
/// on; a missed one, or a patch that names no place in the kept state, asks the owner for the whole state once more.
///
/// One connection serves every followed thread and is open only while there is a thread to follow. A thread that no
/// Desktop client owns, such as a CLI session's, is looked for again every so often. Each user of the stream names the
/// threads it wants under an interest of its own, and a thread is followed while any of them wants it.
public final class CodexDesktopStream: @unchecked Sendable {
    /// The stream on the user's own Codex home, which everything in the process that reads a Desktop thread shares.
    public static let shared = CodexDesktopStream()

    /// A followed thread as its owner last described it, long strings left out.
    public struct Thread: Sendable {
        public let ownerClientID: String
        public let state: JSONValue
        public let revision: Int64
    }

    /// A string value longer than this is left out of what is kept. What is read here is ids, settings, a request's
    /// own fields and a question's wording.
    static let stringLimit = 16 * 1024
    /// The whole state of a long thread arrives as one message.
    static let messageLimit = 1 << 30
    /// A thread without an owner is looked for again this often, and a thread's whole state is asked for at most this
    /// often: a state that did not come, or one the changes could not be applied to, is unknown until the next asking.
    /// The whole state of a long thread is the one costly thing here, for its owner above all, and what goes wrong once
    /// with a change can go wrong with every change.
    var retry: TimeInterval = 30
    /// A followed thread's owner is confirmed this often: a thread can pass to another client while its old owner stays.
    static let confirm: TimeInterval = 60
    /// How long a whole state may take to arrive once it has begun to.
    static let messageTime: TimeInterval = 120
    /// Followers hear of changes at most this often.
    static let pace: TimeInterval = 0.2
    /// How long the connection waits for a message before it looks again at which threads are asked for.
    static let idle: TimeInterval = 1

    private let socketPath: String
    private let lock = NSCondition()
    private var interests: [String: Set<String>] = [:]
    /// Every thread an interest names.
    private var wanted: Set<String> = []
    /// Until when each thread asked for once stays followed, on the system's uptime.
    private var asked: [String: TimeInterval] = [:]
    private var published: [String: Thread] = [:]
    private var running = false
    private var generation = 0
    private var listeners: [UUID: AsyncStream<Void>.Continuation] = [:]

    public init(dataDirectory: URL = CodexLocator.dataDirectory) {
        socketPath = dataDirectory.appendingPathComponent("ipc/ipc.sock").path
    }

    // MARK: What is followed

    /// The threads one interest wants followed from now on. A thread no interest names any longer is left, and its
    /// state is dropped. The connection opens with the first thread wanted and closes with the last.
    public func follow(_ threadIDs: Set<String>, for interest: String = "") {
        let run = lock.withLock { () -> Int? in
            guard interests[interest, default: []] != threadIDs else { return nil }
            interests[interest] = threadIDs.isEmpty ? nil : threadIDs
            wanted = interests.values.reduce(into: []) { $0.formUnion($1) }
            lock.broadcast()
            guard !wanted.isEmpty, !running else { return nil }
            running = true
            generation += 1
            return generation
        }
        guard let run else { return }
        let worker = Foundation.Thread { [weak self] in self?.work(run) }
        worker.name = "Codex Desktop stream"
        worker.qualityOfService = .utility
        worker.start()
    }

    /// The thread as its owner now describes it, for a reader that needs it once: followed for the asking when it is
    /// not followed already, and kept followed for `linger` after, since what is asked about once is often asked about
    /// again. Nil when no owner has described it within `seconds`.
    public func thread(_ threadID: String, within seconds: TimeInterval, linger: TimeInterval = 600) async -> Thread? {
        let interest = "asked:" + threadID, uptime = ProcessInfo.processInfo.systemUptime
        lock.withLock { asked[threadID] = uptime + linger }
        follow([threadID], for: interest)
        Task.detached { [weak self] in
            try? await Task.sleep(for: .seconds(linger + 1))
            guard let self else { return }
            // A later asking moved the time on, and has a wait of its own.
            let over = lock.withLock { (asked[threadID] ?? 0) <= ProcessInfo.processInfo.systemUptime }
            if over { follow([], for: interest) }
        }
        while ProcessInfo.processInfo.systemUptime - uptime < seconds {
            if let known = thread(threadID) { return known }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
        }
        return thread(threadID)
    }

    /// The threads asked for, followed yet or not.
    var following: Set<String> { lock.withLock { wanted } }

    /// The followed threads whose state is known at this moment. A thread missing here is unknown, not empty.
    public var threads: [String: Thread] { lock.withLock { published } }

    public func thread(_ threadID: String) -> Thread? { lock.withLock { published[threadID] } }

    /// One element whenever `threads` changed, and one to begin with for what is known already. Changes that come
    /// close together arrive as one.
    public var changes: AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            lock.withLock { listeners[id] = continuation }
            continuation.yield()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                lock.withLock { _ = self.listeners.removeValue(forKey: id) }
            }
        }
    }

    /// Leaves every thread whatever wanted it, and closes the connection.
    public func stop() {
        lock.withLock {
            interests = [:]
            wanted = []
            asked = [:]
            running = false
            generation += 1
            lock.broadcast()
        }
        publish([:])
    }

    // MARK: The connection

    private struct Followed {
        var owner: String
        var state: JSONValue?
        var revision: Int64 = 0
        /// When the whole state was last asked for, on the system's uptime.
        var asked: TimeInterval
    }

    private func active(_ run: Int) -> Bool { lock.withLock { running && generation == run } }

    private func work(_ run: Int) {
        var wait: TimeInterval = 1
        while active(run) {
            // With nothing left to follow the stream rests, and the next thread wanted starts it again.
            let rests = lock.withLock { () -> Bool in
                guard wanted.isEmpty, running, generation == run else { return false }
                running = false
                return true
            }
            if rests { break }
            let began = ProcessInfo.processInfo.systemUptime
            do {
                let connection = try CodexDesktopIPC(path: socketPath, timeout: 5)
                defer { connection.close() }
                try serve(connection, run: run)
            } catch {}
            publish([:], run: run)
            // A connection that held starts the next attempt soon; one refused again and again waits longer.
            wait = ProcessInfo.processInfo.systemUptime - began > 30 ? 1 : min(wait * 2, 15)
            lock.withLock { if running, generation == run, !wanted.isEmpty { lock.wait(until: Date().addingTimeInterval(wait)) } }
        }
        publish([:], run: nil, unlessRunning: true)
    }

    private func serve(_ connection: CodexDesktopIPC, run: Int) throws {
        let initialized = try connection.request(method: "initialize", version: 0, source: "initializing-client",
                                                 params: ["clientType": "agent-hud"])
        guard let clientID = (initialized["result"] as? [String: Any])?["clientId"] as? String, !clientID.isEmpty else {
            throw CodexDesktopIPC.Failure.protocolError
        }
        var followed: [String: Followed] = [:]
        // Owner searches in flight by request, and when each thread's owner is looked for next.
        var searches: [String: (thread: String, sent: TimeInterval)] = [:]
        var searchAfter: [String: TimeInterval] = [:]
        // Threads whose owner speaks a version of the stream this reader does not know: left alone on this connection.
        var foreign: Set<String> = []
        var dirty = false, lastPublished: TimeInterval = 0

        func unfollow(_ thread: String) {
            guard let entry = followed.removeValue(forKey: thread) else { return }
            try? connection.follow(false, source: clientID, owner: entry.owner, threadID: thread)
            dirty = true
        }
        defer { for thread in Array(followed.keys) { unfollow(thread) } }

        while active(run) {
            let now = ProcessInfo.processInfo.systemUptime
            let wanted = lock.withLock { self.wanted }
            if wanted.isEmpty { return }
            for thread in followed.keys where !wanted.contains(thread) { unfollow(thread) }
            searches = searches.filter { wanted.contains($0.value.thread) && now - $0.value.sent < retry }
            searchAfter = searchAfter.filter { wanted.contains($0.key) }
            foreign.formIntersection(wanted)
            let searching = Set(searches.values.map(\.thread))
            for thread in wanted where !foreign.contains(thread) && !searching.contains(thread) && (searchAfter[thread] ?? 0) <= now {
                let request = UUID().uuidString.lowercased()
                connection.renew(timeout: 5)
                try connection.post(["type": "request", "requestId": request, "sourceClientId": clientID, "version": 1,
                                     "method": "thread-owner-discovery", "timeoutMs": Int(retry * 1000),
                                     "params": ["hostId": "local", "conversationId": thread]])
                searches[request] = (thread, now)
            }
            // A state asked for and never sent, or dropped for a missed revision, is asked for again.
            for (thread, entry) in followed where entry.state == nil && now - entry.asked >= retry {
                connection.renew(timeout: 5)
                try connection.follow(true, source: clientID, owner: entry.owner, threadID: thread)
                followed[thread]?.asked = now
            }

            if try connection.waitForMessage(dirty ? Self.pace : Self.idle) {
                connection.renew(timeout: Self.messageTime)
                let message = try JSONValue.parse(connection.message(limit: Self.messageLimit), leavingOutStringsOver: Self.stringLimit)
                connection.renew(timeout: 5)
                if try connection.declines(message) { continue }
                switch message["type"].stringValue {
                case "response":
                    guard let request = message["requestId"].stringValue, let search = searches.removeValue(forKey: request) else { break }
                    guard message["resultType"].stringValue == "success", let owner = message["handledByClientId"].stringValue,
                          !owner.isEmpty, wanted.contains(search.thread) else {
                        // Only the hub's own word that nobody owns the thread ends a following; a search that failed
                        // some other way says nothing about the owner.
                        if message["error"].stringValue == "no-client-found" { unfollow(search.thread) }
                        searchAfter[search.thread] = now + retry
                        break
                    }
                    searchAfter[search.thread] = now + Self.confirm
                    guard followed[search.thread]?.owner != owner else { break }
                    unfollow(search.thread)
                    try connection.follow(true, source: clientID, owner: owner, threadID: search.thread)
                    followed[search.thread] = Followed(owner: owner, asked: now)
                case "broadcast":
                    let params = message["params"]
                    switch message["method"].stringValue {
                    case "thread-stream-state-changed":
                        guard params["hostId"].stringValue == "local", let thread = params["conversationId"].stringValue,
                              var entry = followed[thread], message["sourceClientId"].stringValue == entry.owner else { break }
                        guard message["version"] == .integer(11) else {
                            unfollow(thread)
                            foreign.insert(thread)
                            break
                        }
                        let change = params["change"]
                        switch change["type"].stringValue {
                        case "snapshot":
                            guard change["conversationState"].objectValue != nil, case .integer(let revision) = change["revision"] else {
                                throw CodexDesktopIPC.Failure.protocolError
                            }
                            entry.state = change["conversationState"]
                            entry.revision = revision
                            followed[thread] = entry
                            dirty = true
                        case "patches":
                            // Patches sent before the state they follow has arrived are covered by that state.
                            guard var state = entry.state else { break }
                            // The entry gives its state up while it changes, so the state changes in place.
                            followed[thread]?.state = nil
                            entry.state = nil
                            if case .integer(let revision) = change["revision"], revision <= entry.revision {
                                // A change the kept state already includes: it was on its way when the state was sent.
                                entry.state = state
                            } else if case .integer(let base) = change["baseRevision"], base == entry.revision,
                                      case .integer(let revision) = change["revision"], let patches = change["patches"].arrayValue,
                                      (try? CodexDesktopPatches.apply(patches, to: &state)) != nil {
                                entry.state = state
                                entry.revision = revision
                                dirty = true
                            } else {
                                // The kept state fell behind its owner's: unknown until the owner sends it whole again,
                                // which it is asked to at once unless it was asked a moment ago.
                                if now - entry.asked >= retry {
                                    try connection.follow(true, source: clientID, owner: entry.owner, threadID: thread)
                                    entry.asked = now
                                }
                                dirty = true
                            }
                            followed[thread] = entry
                        default: break
                        }
                    case "client-status-changed":
                        // An owner that left takes its threads with it; they are looked for again.
                        guard params["status"].stringValue != "connected", let client = params["clientId"].stringValue else { break }
                        for (thread, entry) in followed where entry.owner == client {
                            followed.removeValue(forKey: thread)
                            searchAfter[thread] = now + 5
                            dirty = true
                        }
                    default: break
                    }
                default: break
                }
            }
            if dirty, ProcessInfo.processInfo.systemUptime - lastPublished >= Self.pace {
                publish(followed.compactMapValues { entry in
                    entry.state.map { Thread(ownerClientID: entry.owner, state: $0, revision: entry.revision) }
                }, run: run)
                dirty = false
                lastPublished = ProcessInfo.processInfo.systemUptime
            }
        }
    }

    /// A connection that has been replaced, or stopped, no longer says what is known. A stream that came to rest says
    /// that nothing is, unless it was started again meanwhile.
    private func publish(_ threads: [String: Thread], run: Int? = nil, unlessRunning: Bool = false) {
        let waiting = lock.withLock { () -> [AsyncStream<Void>.Continuation] in
            if let run, !(running && generation == run) { return [] }
            if unlessRunning, running { return [] }
            guard !(published.isEmpty && threads.isEmpty) else { return [] }
            published = threads
            return Array(listeners.values)
        }
        for listener in waiting { listener.yield() }
    }
}
