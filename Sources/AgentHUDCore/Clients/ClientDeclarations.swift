import Foundation

/// Each client's declaration, as Agent HUD Open reads it today. A client moved onto a better channel changes its
/// declaration in the same change; the tests hold the declarations to the hooks, observers and readers that exist.
public enum ClientDeclarations {
    public static let all: [ClientDeclaration] = AgentClient.allCases.map(declaration)

    public static subscript(_ client: AgentClient) -> ClientDeclaration { declaration(client) }

    private typealias Channel = ClientDeclaration.Channel
    private typealias Request = ClientDeclaration.Request

    /// A hook client's approval: shown with the answers the client takes back, and noticed as answered elsewhere only
    /// where the client's records show it.
    private static func hookApproval(_ answers: [Request.Answer], settled: [Channel] = []) -> Request {
        Request(kind: .approval, arrives: .hook("PermissionRequest"), answers: answers, settledElsewhere: settled)
    }

    private static let permissionHook = Channel.hook("PermissionRequest")
    /// How often an account answer is asked for while its client works; a quiet client is asked every 5 minutes.
    private static let accountInterval: TimeInterval = 60

    private static func declaration(_ client: AgentClient) -> ClientDeclaration {
        var declaration = ClientDeclaration(client: client)
        switch client {
        case .claude:
            let log = Channel.appended("session log")
            declaration.sessions = [log]
            declaration.usage = [log]
            declaration.state = [.running: [log], .waitingForApproval: [permissionHook, .hook("Notification")],
                                 .waitingForAnswer: [permissionHook, log], .waitingForReply: [log]]
            // The hook follows the session log from 4 MB back until the call it holds has a result.
            let settled = [Channel.appended("call result in the session log")]
            // The desktop app's own questions, its next-step box and its offer of a new session, go through no permission
            // prompt: only the session log's call says what they ask, and its result or the next prompt that they were
            // answered. The app takes the answer in its own window (`ClaudeDesktopAsks`).
            declaration.requests = [hookApproval([.allowOnce, .allowAlways, .deny], settled: settled),
                                    Request(kind: .question, arrives: permissionHook, answers: [.answers], settledElsewhere: settled),
                                    Request(kind: .plan, arrives: permissionHook, settledElsewhere: settled),
                                    Request(kind: .question, arrives: log, settledElsewhere: [log])]
        case .codex:
            let rollout = Channel.appended("rollout"), thread = Channel.subscription("Codex Desktop thread")
            declaration.sessions = [rollout]
            declaration.usage = [rollout]
            declaration.state = [.running: [rollout], .waitingForApproval: [permissionHook, thread],
                                 .waitingForAnswer: [thread], .waitingForReply: [rollout]]
            // The hook's requests reach the HUD only for a turn its user reviews; Desktop's own prompts come from the thread.
            declaration.requests = [hookApproval([.allowOnce, .deny]),
                                    Request(kind: .approval, arrives: thread, answers: [.deny, .allowForConversation, .allowAlways],
                                            settledElsewhere: [thread]),
                                    Request(kind: .question, arrives: thread, answers: [.answers], settledElsewhere: [thread])]
        case .deepseek:
            let log = Channel.appended("session log")
            let events = Channel.subscription("Harness web host events")
            declaration.sessions = [log]
            declaration.usage = [log]
            declaration.state = [.running: [log], .waitingForReply: [log],
                                 .ended: [.poll("Harness process", every: SessionPhase.Limits.processRecheck)]]
            declaration.requests = [Request(kind: .question, arrives: events, answers: [.answers], settledElsewhere: [events])]
        case .antigravity:
            let database = Channel.whole("conversation database")
            let server = Channel.poll("language server trajectories", every: 2)
            declaration.sessions = [database]
            declaration.usage = [database]
            declaration.state = [.waitingForApproval: [server], .waitingForReply: [.hook("Stop")]]
            declaration.requests = [Request(kind: .approval, arrives: server, answers: [.allowOnce, .deny], settledElsewhere: [server])]
        case .cursor:
            let account = Channel.poll("usage events", every: accountInterval)
            declaration.sessions = [account]
            declaration.usage = [account]
            declaration.state = [.waitingForReply: [.hook("stop")]]
        case .grokCLI:
            let updates = Channel.whole("session updates")
            declaration.sessions = [updates]
            declaration.usage = [updates]
            declaration.state = [.running: [updates], .waitingForReply: [updates]]
        case .grokBot:
            declaration.sessions = [.whole("bot roster")]
            declaration.usage = [.poll("Cursor usage events", every: accountInterval)]
        case .copilot:
            let events = Channel.whole("session events")
            declaration.sessions = [events]
            declaration.usage = [.whole("OpenTelemetry export")]
            declaration.state = [.running: [events], .waitingForReply: [.hook("agentStop")], .ended: [events]]
        case .openclaw:
            let gateway = Channel.whole("gateway database")
            declaration.sessions = [gateway]
            declaration.usage = [gateway]
            declaration.state = [.running: [gateway], .waitingForReply: [gateway]]
        case .hermes:
            let database = Channel.whole("state database")
            declaration.sessions = [database]
            declaration.usage = [database]
        case .zcode:
            let database = Channel.whole("session database")
            declaration.sessions = [database]
            declaration.usage = [database]
            declaration.state = [.waitingForApproval: [permissionHook], .waitingForAnswer: [permissionHook]]
            declaration.requests = [hookApproval([.allowOnce, .deny]),
                                    Request(kind: .question, arrives: permissionHook, answers: [.answers])]
        case .codebuddy, .workbuddy:
            let log = Channel.whole("session log")
            declaration.sessions = [log]
            declaration.usage = [log]
            declaration.state = [.waitingForApproval: [permissionHook]]
            if client == .codebuddy { declaration.state[.waitingForReply] = [.hook("Stop")] }
            declaration.requests = [hookApproval([.allowOnce, .deny])]
        case .qwen:
            let log = Channel.whole("chat log")
            declaration.sessions = [log]
            declaration.usage = [log]
            declaration.state = [.waitingForApproval: [permissionHook], .waitingForReply: [.hook("Stop")]]
            declaration.requests = [hookApproval([.allowOnce, .deny])]
        case .devin:
            let database = Channel.whole("session database")
            declaration.sessions = [database]
            declaration.usage = [database, .whole("user status cache")]
            declaration.state = [.running: [database], .waitingForApproval: [permissionHook],
                                 .waitingForReply: [.hook("Stop")]]
            declaration.requests = [hookApproval([.allowOnce, .deny])]
        case .opencode:
            let database = Channel.whole("session database")
            declaration.sessions = [database]
            declaration.usage = [database]
            declaration.state = [.waitingForReply: [.plugin("session.idle")]]
        case .kimi:
            let wire = Channel.whole("wire log")
            declaration.sessions = [wire]
            declaration.usage = [wire]
            declaration.state = [.running: [wire], .waitingForReply: [wire]]
        case .pi:
            let log = Channel.whole("session log")
            declaration.sessions = [log]
            declaration.usage = [log]
            declaration.state = [.running: [.plugin("agent_start")],
                                 .waitingForReply: [.plugin("agent_settled")],
                                 .ended: [.plugin("session_shutdown")]]
        case .qoder, .qoderCN, .qoderWork:
            // No sessions are read, so a request stands on its own.
            declaration.requests = [hookApproval([.allowOnce, .allowAlways, .deny])]
        }
        return declaration
    }
}
