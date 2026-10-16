import Foundation

/// What one client offers for each part of the contract every client meets, and the channel each part arrives
/// through. A part the client does not offer is empty, and nothing is inferred for it: a phase without a channel is
/// never shown, a client without requests never puts a card on the HUD.
///
/// The declaration describes what Agent HUD Open reads today. Its conversation turns and the delivery of a phone's
/// prompt belong to the app that syncs, which declares them beside this one.
public struct ClientDeclaration: Sendable {
    public let client: AgentClient
    /// Sessions appearing, and their metadata: title, folder, parent session, the app they run in.
    public var sessions: [Channel] = []
    /// Each model call's tokens, each with its time.
    public var usage: [Channel] = []
    /// The channels that say each phase of a session.
    public var state: [Phase: [Channel]] = [:]
    /// What the client asks its user and Agent HUD can show, each kind through each channel it arrives on.
    public var requests: [Request] = []

    /// Where a part of the contract comes from. Every channel but a whole read meets the baseline: the client tells of
    /// a change, or a change is read from where the last read stopped, or, where the client offers nothing to observe
    /// (an account answer, a process that may have gone), it is asked at a stated interval.
    public enum Channel: Hashable, Sendable {
        /// The client runs Agent HUD's command at a hook event it names.
        case hook(String)
        /// An event of the plugin or extension Agent HUD adds to the client.
        case plugin(String)
        /// Agent HUD stays connected and the client sends each change.
        case subscription(String)
        /// What a log or table gained since a saved position.
        case appended(String)
        /// Asked again at an interval, the client offering no change to observe.
        case poll(String, every: TimeInterval)
        /// The whole of a file, table or answer read again whenever it changes: below the baseline.
        case whole(String)

        public var meetsBaseline: Bool {
            if case .whole = self { return false }
            return true
        }
    }

    /// The phases every client's sessions are described in. Waiting for an answer is a question the client asked;
    /// the panel shows it as waiting for approval, as it shows any request the client holds open.
    public enum Phase: String, CaseIterable, Sendable {
        case running, waitingForApproval, waitingForAnswer, waitingForReply, ended
    }

    /// One kind of request, through one channel.
    public struct Request: Hashable, Sendable {
        public enum Kind: String, CaseIterable, Sendable {
            case approval, question, plan
        }

        /// The answers Agent HUD can send back, in the client's own terms. None shows the request and leaves it to the
        /// client's dialog.
        public enum Answer: String, Sendable {
            case allowOnce, allowForConversation, allowAlways, deny, answers
        }

        public let kind: Kind
        public let arrives: Channel
        public var answers: [Answer] = []
        /// How a request answered in the client's own dialog is noticed. None leaves only the client closing the
        /// hook's connection, which some clients never do while the request stands.
        public var settledElsewhere: [Channel] = []
    }

    /// Every channel the declaration names.
    public var channels: [Channel] {
        sessions + usage + Phase.allCases.flatMap { state[$0] ?? [] } + requests.flatMap { [$0.arrives] + $0.settledElsewhere }
    }

    /// The channels below the baseline, which a client is moved off one at a time.
    public var belowBaseline: [Channel] { channels.filter { !$0.meetsBaseline } }
}
