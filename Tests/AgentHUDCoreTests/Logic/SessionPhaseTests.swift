import AgentHUDSupport
import XCTest
@testable import AgentHUDCore

/// A session's phase: what it is on the grid of sessions the store's own tests use, how the store's answers follow it,
/// and when a client's hook turn takes the place of a reading's phase.
final class SessionPhaseTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let hour: TimeInterval = 3600

    override func setUp() {
        super.setUp()
        L10n.setLanguage(.en)
    }

    override func tearDown() {
        L10n.setLanguage(.system)
        super.tearDown()
    }

    /// The newest turn reported for the session. Every kind but `none` follows an older finished turn.
    private enum Newest: CaseIterable {
        case none, running, runningWithoutStart, waiting, completed, ended

        var state: SessionTurn.State? {
            switch self {
            case .none: return nil
            case .running, .runningWithoutStart: return .running
            case .waiting: return .waitingForApproval
            case .completed: return .completed
            case .ended: return .ended
            }
        }
    }

    /// What a phase counts from.
    private enum Since {
        case sessionStart, turnStart, turnHeard, reading, end
    }

    /// A Claude session that started five hours ago, has ended two hours ago unless the source still has it in flight, and
    /// was last read `age` seconds ago; its newest turn started three hours ago and was heard from half an hour later. In
    /// flight, a phase is vouched for until half an hour after the reading; the store is live exactly while a phase is in
    /// flight, blocked on the user while it waits for approval, and words its label from it.
    @MainActor
    func testThePhaseOnTheSessionGridAndTheStoresAnswers() throws {
        let store = try makeStore()
        let count = Newest.allCases.count
        func same<T>(_ value: T) -> [T] { Array(repeating: value, count: count) }
        // Outside the vouched window a phase counts from the last event: the reading or the end without turns, and with
        // them the later of the turn heard and the end.
        let heard = [Since.reading] + Array(repeating: Since.turnHeard, count: count - 1)
        // Live status, whether the source has the session in flight and how old its reading is; then, with each newest turn
        // in the order of `Newest.allCases`, the phase's state and what it counts from.
        let rows: [(liveStatus: Bool, inFlight: Bool, age: TimeInterval, states: [SessionPhase.State], since: [Since])] = [
            // In flight, from the turn's start, else the session's.
            (true, true, 1799.999, [.running, .running, .running, .waitingForApproval, .running, .running],
             [.sessionStart, .turnStart, .sessionStart, .turnStart, .sessionStart, .sessionStart]),
            (true, true, 1800, same(.unverified), heard),
            (true, false, 1799.999, same(.idle), same(.end)),
            (true, false, 1800, same(.idle), same(.end)),
            // With live status off, the last event.
            (false, true, 1799.999, same(.idle), heard),
            (false, true, 1800, same(.idle), heard),
            (false, false, 1799.999, same(.idle), same(.end)),
            (false, false, 1800, same(.idle), same(.end)),
        ]
        for row in rows {
            store.settings.update { $0.setLiveStatus(for: "Claude", enabled: row.liveStatus) }
            for (index, newest) in Newest.allCases.enumerated() {
                let session = session(ended: row.inFlight ? nil : -2 * hour, observed: -row.age)
                let turns = turns(newest: newest)
                store.replace(report: UsageReport(generatedAt: now, snapshots: [], sessions: [session], turns: turns))
                store.now = now
                let lastEventAt = session.lastEvent(turnAt: turns.map { RecordCoding.date($0.observedAtMs) }.max())
                let phase = SessionPhase(session: session, turn: turns.last, lastEventAt: lastEventAt, liveStatus: row.liveStatus, now: now)
                let since: Date = switch row.since[index] {
                case .sessionStart: session.startedAt
                case .turnStart: now.addingTimeInterval(-3 * hour)
                case .turnHeard: now.addingTimeInterval(-2.5 * hour)
                case .reading: session.observedAt
                case .end: now.addingTimeInterval(-2 * hour)
                }
                let name = "\(row) with the newest turn \(newest)", state = row.states[index]
                let inFlight = state == .running || state == .waitingForApproval
                XCTAssertEqual(phase, SessionPhase(state: state, since: since,
                                                   validUntil: inFlight ? session.observedAt.addingTimeInterval(1800) : nil), name)
                XCTAssertEqual(phase.nextChange, phase.validUntil, name)
                XCTAssertEqual(store.isSessionLive(session), phase.isInFlight, name)
                XCTAssertEqual(store.isSessionWaiting(session), phase.state == .waitingForApproval, name)
                XCTAssertEqual(store.sessionState(session), newest.state, name)
                let label = !row.liveStatus ? "Live status off" : phase.state == .unverified ? "Status out of date"
                    : phase.state == .waitingForApproval ? "Needs approval" : Countdown.sessionLabel(phase, now: now)
                XCTAssertEqual(store.sessionStatusLabel(session), label, name)
            }
        }
    }

    // MARK: Fixtures

    /// Times are seconds from now.
    private func session(ended: TimeInterval?, observed: TimeInterval) -> LiveSession {
        LiveSession(id: "s", agentId: "claude-model:opus", task: "s", terminal: nil, startedAt: now.addingTimeInterval(-5 * hour),
                    endedAt: ended.map { now.addingTimeInterval($0) }, pctOfWindow: nil, tokensIn: 1, tokensOut: 1,
                    observedAt: now.addingTimeInterval(observed))
    }

    /// An older finished turn, then the newest.
    private func turns(newest: Newest) -> [SessionTurn] {
        guard let state = newest.state else { return [] }
        func ms(_ offset: TimeInterval) -> Int64 { RecordCoding.milliseconds(now.addingTimeInterval(offset)) }
        return [SessionTurn(provider: "claude", sessionID: "s", turnID: "1", state: .completed, startedAtMs: ms(-5 * hour),
                            observedAtMs: ms(-4 * hour), message: "Earlier answer"),
                SessionTurn(provider: "claude", sessionID: "s", turnID: "2", state: state,
                            startedAtMs: newest == .runningWithoutStart ? nil : ms(-3 * hour), observedAtMs: ms(-2.5 * hour))]
    }

    @MainActor
    private func makeStore() throws -> UsageStore {
        let suite = "SessionPhaseTests.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return UsageStore(provider: DemoUsageProvider(), settings: SettingsStore(defaults: defaults))
    }
}
