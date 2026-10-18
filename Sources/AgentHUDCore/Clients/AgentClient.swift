import Foundation

/// Every agent client Agent HUD reads or hears from, one case per client a user installs. A billing service whose
/// sessions belong to another client (GLM) is not one. What each client offers, and through which channel, is its
/// declaration (`ClientDeclarations`).
public enum AgentClient: String, CaseIterable, Sendable {
    case claude, codex, deepseek, antigravity, cursor, grokCLI, grokBot, copilot, openclaw, hermes, zcode, codebuddy,
         workbuddy, qwen, opencode, kimi, pi, qoder, qoderCN, qoderWork, devin

    /// The execution agent its sessions are grouped under (`SessionSource.agentVendors`); nil for a client whose
    /// sessions are not read, as the Qoder builds', which only ask for approvals.
    public var sessionVendor: String? {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .deepseek: "DeepSeek"
        case .grokCLI: "Grok CLI"
        case .grokBot: "Grok Bot"
        case .antigravity, .cursor, .copilot, .openclaw, .hermes, .zcode, .codebuddy, .workbuddy, .qwen, .devin:
            AdditionalSource(rawValue: rawValue)!.vendor
        case .opencode, .kimi, .pi: OpenAgentSource(rawValue: rawValue)!.name
        case .qoder, .qoderCN, .qoderWork: nil
        }
    }
}

extension PermissionHooks.Source {
    /// The client whose approvals this source carries.
    var client: AgentClient { AgentClient(rawValue: rawValue)! }
}

extension CompletionHooks.Source {
    /// The client whose finished turns this stop hook reports.
    var client: AgentClient { AgentClient(rawValue: rawValue)! }
}
