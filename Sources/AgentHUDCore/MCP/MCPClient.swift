import AgentHUDSupport
import Foundation

/// A client that takes a local MCP server through its own command line, and how Agent HUD's server is added to it:
/// by the client's own command, run when a person asks, which writes the client's configuration. Agent HUD reads that
/// configuration to know whether the server is there and never writes it.
///
/// The commands were checked against `claude mcp --help` and `claude mcp add --help` of Claude Code 2.1.300, whose
/// `mcp remove <name>` takes `-s, --scope <scope>`, and `codex mcp --help` and `codex mcp add --help` of Codex 0.162.1,
/// whose `mcp remove <NAME>` removes the server `mcp add` wrote to its global `config.toml`.
package enum MCPClient: String, CaseIterable, Sendable, Identifiable {
    case claudeCode, codex

    package var id: String { rawValue }

    /// The name every client lists the server under.
    static let serverName = "agent-hud"
    /// The argument the client's command runs the executable with.
    static let serverArgument = "--mcp"

    /// The client's name as a person knows it, the same in every language.
    package var name: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// The command as a person types it.
    package var command: String {
        switch self {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        }
    }

    /// The arguments that add the server with `executable` as its command. Claude Code keeps it for the user, in every
    /// project, rather than in the folder the command runs in.
    package func addArguments(executable: String) -> [String] {
        switch self {
        case .claudeCode: return ["mcp", "add", "--scope", "user", Self.serverName, "--", executable, Self.serverArgument]
        case .codex: return ["mcp", "add", Self.serverName, "--", executable, Self.serverArgument]
        }
    }

    /// The arguments that remove the server `addArguments(executable:)` added.
    package var removeArguments: [String] {
        switch self {
        case .claudeCode: return ["mcp", "remove", "--scope", "user", Self.serverName]
        case .codex: return ["mcp", "remove", Self.serverName]
        }
    }

    /// `arguments` after the command, as a line to paste into a terminal.
    package func commandLine(_ arguments: [String]) -> String {
        ([command] + arguments).map(Self.quoted).joined(separator: " ")
    }

    /// The server's settings as a client that takes JSON keeps them, for a client this list does not have.
    package static func settingsJSON(executable: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let command = (try? encoder.encode(executable)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
        return """
            {
              "mcpServers": {
                "\(serverName)": {
                  "command": \(command),
                  "args": ["\(serverArgument)"]
                }
              }
            }
            """
    }

    // MARK: This Mac

    /// The client's command on this Mac, at the places its installers use and then on `path`; nil when it has none.
    /// Codex's own app carries one, which comes first. Claude Code's desktop app keeps an engine of its own, which is
    /// not a command a person runs and is passed over.
    package func executable(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                           applications: URL = URL(fileURLWithPath: "/Applications"),
                           path: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
                           registered: @autoclosure () -> [URL] = VendorCatalog.applications("Codex")) -> URL? {
        switch self {
        case .claudeCode: return Executables.first(ClaudeEngineLocator.cli(home: home, path: path))
        case .codex: return CodexLocator.find(home: home, applications: applications, path: path, registered: registered())
        }
    }

    /// The file the client keeps its servers in: Claude Code's `.claude.json`, beside its configuration directory
    /// where `CLAUDE_CONFIG_DIR` moves it, else in the home folder; Codex's `config.toml` in `CODEX_HOME`, else `~/.codex`.
    package func configurationURL(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                 environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        switch self {
        case .claudeCode:
            return (ClaudeSubscription.configDirectory(environment) ?? home).appendingPathComponent(".claude.json")
        case .codex:
            return CodexLocator.dataDirectory(home: home, environment: environment).appendingPathComponent("config.toml")
        }
    }

    /// Whether the client's configuration has a server named `agent-hud`, read and never written. A file that is
    /// missing or cannot be read has none.
    package func hasServer(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                          environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        let url = configurationURL(home: home, environment: environment)
        guard let data = try? Data(contentsOf: url) else { return false }
        return hasServer(in: data)
    }

    /// Whether `configuration`, the file's contents, has a server named `agent-hud`: for Claude Code one in the
    /// user's `mcpServers`, where `addArguments` puts it, and not one kept for a single project; for Codex a
    /// `[mcp_servers.agent-hud]` table in whatever way TOML spells it.
    func hasServer(in configuration: Data) -> Bool {
        switch self {
        case .claudeCode:
            guard let servers = (try? JSONValue.parse(configuration))?.objectValue?["mcpServers"]?.objectValue else { return false }
            return servers[Self.serverName] != nil
        case .codex:
            return MCPTOMLTables.names(server: Self.serverName, in: String(decoding: configuration, as: UTF8.self))
        }
    }

    /// An argument as a shell reads it back: as it is where it holds nothing the shell treats specially, else in
    /// single quotes.
    static func quoted(_ argument: String) -> String {
        let plain = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./:=@%+,")
        if !argument.isEmpty, argument.allSatisfy(plain.contains) { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
