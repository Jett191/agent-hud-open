import Foundation

/// Shows Desktop's app and browser approvals and unanswered mid-turn questions. Engine approvals continue through their hook.
///
/// The threads with a session in flight are followed; their owners say what changes, and nothing is asked again.
@MainActor
public final class CodexDesktopPermissionObserver {
    private let requests: PermissionRequests
    private let client: CodexDesktopPermissions
    private var task: Task<Void, Never>?
    private var sessionIDs: Set<String> = []
    /// When each thread's session was last reported in flight, on the system's uptime. A thread stays followed for a
    /// while after: following it again would have its owner send the whole state again, and a conversation is a turn
    /// after a turn.
    private var reported: [String: TimeInterval] = [:]
    static let linger: TimeInterval = 600
    /// Retained while a thread's state is unknown, so a disconnect does not settle a dismissed native prompt.
    private var pending: [String: CodexDesktopPermissions.Pending] = [:]

    /// The observer's own name among the users of the stream.
    private static let interest = "approvals"

    public init() {
        requests = .shared
        client = CodexDesktopPermissions(stream: .shared)
    }

    init(requests: PermissionRequests, client: CodexDesktopPermissions) {
        self.requests = requests
        self.client = client
    }

    public func updateSessions(_ sessions: [LiveSession]) { updateSessions(sessions, at: ProcessInfo.processInfo.systemUptime) }

    func updateSessions(_ sessions: [LiveSession], at uptime: TimeInterval) {
        for id in Self.threadIDs(in: sessions) { reported[id] = uptime }
        reported = reported.filter { uptime - $0.value < Self.linger }
        sessionIDs = Set(reported.keys)
        follow()
    }

    static func threadIDs(in sessions: [LiveSession]) -> Set<String> {
        Set(sessions.flatMap { [$0] + $0.descendantSessions }.compactMap { session in
            guard session.isLive, case .codexThread(let id) = session.navigationTarget else { return nil }
            return id
        })
    }

    public func setEnabled(_ enabled: Bool) {
        guard enabled else { return stop() }
        guard task == nil else { return }
        let client = client
        task = Task { [weak self] in
            for await _ in client.stream.changes {
                // Reading a thread for its requests is kept off the main actor.
                let snapshot = await Task.detached(priority: .utility) { client.snapshot() }.value
                guard !Task.isCancelled, let self else { return }
                reconcile(snapshot)
            }
        }
        follow()
    }

    /// A thread is followed while its session is in flight and for a while after, and while a card of its is waiting to be settled.
    private func follow() {
        client.stream.follow(task == nil ? [] : sessionIDs.union(pending.values.map(\.threadID)), for: Self.interest)
    }

    func reconcile(_ snapshot: CodexDesktopPermissions.Snapshot) {
        requests.updateWaitingSessions(snapshot.waitingThreadIDs, source: .codex)
        let current = Dictionary(snapshot.pending.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for item in pending.values where snapshot.observedThreadIDs.contains(item.threadID) && current[item.id] == nil {
            requests.settleNativeRequest(item.id, source: .codex)
            pending.removeValue(forKey: item.id)
        }
        for item in snapshot.pending { pending[item.id] = item }
        requests.updateNativeRequests(snapshot.pending.map(\.request), source: .codex, preservesDismissals: true) { [client] request, decision in
            guard let item = current[request.id] else { return }
            try await client.resolve(decision, for: item)
        }
        follow()
    }

    public func stop() {
        task?.cancel()
        task = nil
        pending.removeAll()
        reported.removeAll()
        sessionIDs.removeAll()
        follow()
        requests.stopNativeRequests(source: .codex)
    }
}
