import AgentHUDSupport
import Foundation

/// Claude Code style `Stop` handler in `~/.config/devin/config.json`, whose `hooks` object lists matcher groups per
/// event like Claude's own. Devin's `Stop` runs when a turn ends; `prompt_id` names the turn.
enum DevinHookFormat: CompletionHookFormat {
    static let timeout = 10

    static func configuration(home: URL) -> URL { home.appendingPathComponent(".config/devin/config.json") }

    static func completion(_ payload: ProviderJSON, now: Date) -> CompletionHookEvent? {
        guard payload["hook_event_name"].stringValue == "Stop", let session = payload["session_id"].stringValue, !session.isEmpty else { return nil }
        let turn = payload["prompt_id"].stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "stop-\(RecordCoding.milliseconds(now))"
        return .init(session: session, turn: turn, workspace: payload["cwd"].stringValue)
    }

    static func commands(in configuration: [String: ProviderJSON]) -> [String] {
        ClaudeStyleHooks.commands(in: configuration, event: "Stop") { CompletionHooks.ownsCommand($0, source: .devin) }
    }

    static func updating(_ configuration: [String: ProviderJSON], command: String?) throws -> [String: ProviderJSON] {
        try ClaudeStyleHooks.updating(configuration, event: "Stop", owns: { CompletionHooks.ownsCommand($0, source: .devin) },
                                      command: command, group: ClaudeStyleHooks.group(timeout: timeout))
    }
}
