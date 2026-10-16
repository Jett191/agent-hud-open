import AppKit
import AgentHUDCore
import Observation

/// What the install row on Settings → Experimental offers: the clients this Mac has that take a local MCP server
/// through their own command line, then Other; for the one chosen, Add or Remove, decided by reading the client's own
/// configuration, or for Other the server's settings to copy; and a line that says where things stand.
///
/// A client's command runs only when a person presses the button, never on its own. The executable added is the
/// running application's, and one that runs from a disk image or App Translocation is not offered, as the hooks are
/// not, since the client would lose it when the application is moved.
@MainActor
@Observable
final class MCPClientSetup {
    enum Choice: Hashable {
        case client(MCPClient)
        case other
    }

    enum Action: Equatable {
        case add, remove, copySettings
    }

    /// What happened last, until the choice changes or another action starts.
    enum Note: Equatable {
        case failed(Action, String)
        case copiedCommand
        case copiedSettings
    }

    /// Which controls a person can use, with the switch on or off.
    struct Controls: Equatable {
        var picker: Bool
        var action: Bool
        var copyCommand: Bool
        var hint: Bool
    }

    /// Everything the row reaches outside itself, so a test can stand in for each.
    struct Environment {
        /// The running application's executable.
        var executable: URL?
        /// The client's command on this Mac, nil when it has none.
        var locate: (MCPClient) -> URL?
        /// Whether the client's configuration has the server.
        var hasServer: (MCPClient) -> Bool
        /// Runs a client's command and says how it went.
        var run: @Sendable (URL, [String]) async -> MCPCommandResult
        /// Puts text on the pasteboard.
        var copy: (String) -> Void

        static var live: Environment {
            Environment(executable: Bundle.main.executableURL,
                        locate: { $0.executable() },
                        hasServer: { $0.hasServer() },
                        run: { await MCPClientCommand.run($0, $1) },
                        copy: { text in
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        })
        }
    }

    private let environment: Environment
    private(set) var clients: [MCPClient] = []
    private(set) var added: Set<MCPClient> = []
    private(set) var running: Action?
    private(set) var note: Note?
    private var executables: [MCPClient: URL] = [:]
    private var chosen = false

    private var selected: Choice = .other

    /// The client the row is about. Choosing another starts afresh, with no note of what happened before.
    var choice: Choice {
        get { selected }
        set {
            chosen = true
            if newValue != selected { note = nil }
            selected = newValue
        }
    }

    init(environment: Environment = .live) {
        self.environment = environment
    }

    /// Looks again for the clients and reads their configurations, as when a person comes back from running the copied
    /// command in a terminal: a change there takes the place of the note about the copy. The first look chooses the
    /// first client that has the server, else the first client, else Other.
    func refresh() {
        guard running == nil else { return }
        executables = [:]
        for client in MCPClient.allCases {
            if let url = environment.locate(client) { executables[client] = url }
        }
        clients = MCPClient.allCases.filter { executables[$0] != nil }
        let before = added
        added = Set(clients.filter(environment.hasServer))
        if added != before, note == .copiedCommand { note = nil }
        let valid: Bool
        switch choice {
        case .client(let client): valid = clients.contains(client)
        case .other: valid = true
        }
        guard !chosen || !valid else { return }
        let first = clients.first { added.contains($0) } ?? clients.first
        choice = first.map(Choice.client) ?? .other
    }

    var choices: [Choice] { clients.map(Choice.client) + [.other] }

    private var chosenClient: MCPClient? {
        guard case .client(let client) = choice else { return nil }
        return client
    }

    var executablePath: String? { environment.executable?.path }

    /// Whether the application runs from a place it only stays in until it is moved, or from nowhere known.
    var isTransient: Bool { executablePath.map(HookCommand.isTransient) ?? true }

    /// What the button does for the choice: Remove where the client has the server, else Add, or for Other copying
    /// the settings; nothing where the application must be moved first.
    var action: Action? {
        switch choice {
        case .client(let client):
            if added.contains(client) { return .remove }
            return isTransient ? nil : .add
        case .other:
            return isTransient ? nil : .copySettings
        }
    }

    /// While the switch is off everything is dimmed except Remove, and the picker where Remove needs it.
    func controls(toolsOn: Bool) -> Controls {
        let idle = running == nil
        let removable = action == .remove
        let commandAction = action == .add || action == .remove
        return Controls(picker: idle && (toolsOn || !added.isEmpty),
                        action: idle && action != nil && (toolsOn || removable),
                        copyCommand: idle && commandAction && (toolsOn || removable),
                        hint: toolsOn)
    }

    /// The command the button runs, as a person would type it.
    var commandLine: String? {
        guard case .client(let client) = choice, let arguments = arguments(for: client) else { return nil }
        return client.commandLine(arguments)
    }

    private func arguments(for client: MCPClient) -> [String]? {
        switch action {
        case .add: return executablePath.map(client.addArguments(executable:))
        case .remove: return client.removeArguments
        case .copySettings, nil: return nil
        }
    }

    /// Does what the button says. A client's command reports back in the status line, which reads the client's
    /// configuration again afterwards rather than trusting the exit status alone.
    func perform() async {
        guard running == nil, let action else { return }
        note = nil
        switch (action, choice) {
        case (.copySettings, _):
            guard let executablePath else { return }
            environment.copy(MCPClient.settingsJSON(executable: executablePath))
            note = .copiedSettings
        case (.add, .client(let client)), (.remove, .client(let client)):
            guard let executable = executables[client], let arguments = arguments(for: client) else { return }
            running = action
            let result = await environment.run(executable, arguments)
            running = nil
            added = Set(clients.filter(environment.hasServer))
            if !result.succeeded {
                note = .failed(action, result.failureLine)
            } else if added.contains(client) != (action == .add) {
                note = .failed(action, L10n.text("\(client.name) 的设置里没有相应变化", "\(client.name)'s settings did not change"))
            }
        default:
            return
        }
    }

    func copyCommand() {
        guard running == nil, let commandLine else { return }
        environment.copy(commandLine)
        note = .copiedCommand
    }

    // MARK: Words

    static func label(_ choice: Choice) -> String {
        switch choice {
        case .client(let client): return client.name
        case .other: return L10n.text("其他", "Other")
        }
    }

    var buttonTitle: String {
        switch action {
        case .remove: return L10n.text("移除", "Remove")
        case .copySettings: return L10n.text("拷贝设置", "Copy settings")
        case .add, nil: return L10n.text("添加", "Add")
        }
    }

    /// One line on where things stand for the choice.
    var status: String {
        let client = chosenClient
        let name = client?.name ?? ""
        if let running {
            return running == .remove ? L10n.text("正在从 \(name) 移除…", "Removing from \(name)…")
                : L10n.text("正在添加到 \(name)…", "Adding to \(name)…")
        }
        switch note {
        case .failed(let action, let line)?:
            return action == .remove ? L10n.text("没能移除：\(line)", "Couldn't remove: \(line)")
                : L10n.text("没能添加：\(line)", "Couldn't add: \(line)")
        case .copiedCommand?: return L10n.text("已拷贝命令，粘贴到终端运行。", "Command copied. Paste it into Terminal.")
        case .copiedSettings?: return L10n.text("已拷贝设置，粘贴到客户端的 MCP 设置里。", "Settings copied. Paste them into your client's MCP settings.")
        case nil: break
        }
        if let client, added.contains(client) { return L10n.text("已添加到 \(client.name)", "Added to \(client.name)") }
        if isTransient { return L10n.text("请先把 Agent HUD 移到“应用程序”文件夹。", "Move Agent HUD to Applications first.") }
        if client == nil { return L10n.text("拷贝设置，粘贴到任何支持 MCP 的客户端。", "Copy the settings into any client that runs MCP servers.") }
        return L10n.text("尚未添加", "Not added yet")
    }

    /// What to do once the server is in.
    var hint: String {
        guard case .client(let client) = choice else {
            return L10n.text("然后在客户端里开一个新会话，请它重新排列 HUD。", "Then start a new session in your client and ask it to rearrange the HUD.")
        }
        return L10n.text("然后在 \(client.name) 里开一个新会话，请它重新排列 HUD。",
                         "Then start a new \(client.name) session and ask it to rearrange the HUD.")
    }
}
