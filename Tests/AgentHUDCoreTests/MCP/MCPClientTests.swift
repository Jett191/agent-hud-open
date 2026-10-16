import AgentHUDSupport
import Foundation
import XCTest
@testable import AgentHUDCore

/// The clients Agent HUD's server is added to: the commands it runs for a person, the settings it copies for any other
/// client, where each client is found and how its configuration is read, on sample files and never on this Mac's.
final class MCPClientTests: XCTestCase {
    private let executable = "/Applications/Agent HUD Open.app/Contents/MacOS/Agent HUD Open"

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-client-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func testTheCommandsAreTheOnesTheClientsDocument() {
        XCTAssertEqual(MCPClient.claudeCode.addArguments(executable: executable),
                       ["mcp", "add", "--scope", "user", "agent-hud", "--", executable, "--mcp"])
        XCTAssertEqual(MCPClient.claudeCode.removeArguments, ["mcp", "remove", "--scope", "user", "agent-hud"])
        XCTAssertEqual(MCPClient.codex.addArguments(executable: executable), ["mcp", "add", "agent-hud", "--", executable, "--mcp"])
        XCTAssertEqual(MCPClient.codex.removeArguments, ["mcp", "remove", "agent-hud"])
        XCTAssertEqual(MCPClient.claudeCode.commandLine(MCPClient.claudeCode.addArguments(executable: executable)),
                       "claude mcp add --scope user agent-hud -- '/Applications/Agent HUD Open.app/Contents/MacOS/Agent HUD Open' --mcp")
        XCTAssertEqual(MCPClient.codex.commandLine(MCPClient.codex.removeArguments), "codex mcp remove agent-hud")
        XCTAssertEqual(MCPClient.quoted("/Users/o'neil/AgentHUDOpen"), #"'/Users/o'\''neil/AgentHUDOpen'"#)
        XCTAssertEqual(MCPClient.quoted(""), "''")
        XCTAssertEqual(MCPClient.allCases.map(\.name), ["Claude Code", "Codex"])
    }

    func testTheSettingsForAnyOtherClientAreTheServerAsJSON() throws {
        let text = MCPClient.settingsJSON(executable: "/Users/me/Apps/Agent \"HUD\".app/Contents/MacOS/Agent HUD Open")
        XCTAssertEqual(try JSONValue.parse(Data(text.utf8)), .object(["mcpServers": .object(["agent-hud": .object([
            "command": .string("/Users/me/Apps/Agent \"HUD\".app/Contents/MacOS/Agent HUD Open"),
            "args": .array([.string("--mcp")]),
        ])])]))
        XCTAssertFalse(text.contains("\\/"), "a path reads as it is written")
        XCTAssertTrue(text.hasPrefix("{\n  \"mcpServers\""), "laid out to be read and pasted")
    }

    func testClaudeCodeHasTheServerOnlyAmongTheUsersServers() throws {
        let home = try directory()
        let config = home.appendingPathComponent(".claude.json")
        let client = MCPClient.claudeCode
        XCTAssertEqual(client.configurationURL(home: home, environment: [:]), config)
        XCTAssertFalse(client.hasServer(home: home, environment: [:]), "no file")
        let samples: [(String, Bool, String)] = [
            (#"{"numStartups":3,"mcpServers":{"agent-hud":{"type":"stdio","command":"/x","args":["--mcp"],"env":{}}}}"#, true, "the user's server"),
            (#"{"mcpServers":{"other":{"command":"/x"}},"projects":{"/Users/me/p":{"mcpServers":{"agent-hud":{"command":"/x"}}}}}"#, false,
             "one kept for a single project is not where the row adds it"),
            (#"{"mcpServers":{}}"#, false, "none"),
            (#"{"mcpServers":{"agent-hud-old":{"command":"/x"}}}"#, false, "another name"),
            (#"{"mcpServers":{"agent-hud":"#, false, "a file in the middle of being written"),
            ("", false, "an empty file"),
        ]
        for (text, expected, why) in samples {
            try write(text, to: config)
            XCTAssertEqual(client.hasServer(home: home, environment: [:]), expected, why)
        }
        let moved = home.appendingPathComponent("elsewhere", isDirectory: true)
        try write(samples[0].0, to: moved.appendingPathComponent(".claude.json"))
        try write("{}", to: config)
        XCTAssertTrue(client.hasServer(home: home, environment: ["CLAUDE_CONFIG_DIR": moved.path]), "CLAUDE_CONFIG_DIR moves it")
    }

    func testCodexHasTheServerHoweverTOMLSpellsIt() throws {
        let home = try directory()
        let config = home.appendingPathComponent(".codex/config.toml")
        let client = MCPClient.codex
        XCTAssertEqual(client.configurationURL(home: home, environment: [:]), config)
        XCTAssertFalse(client.hasServer(home: home, environment: [:]), "no file")
        let samples: [(String, Bool, String)] = [
            ("model = \"gpt-6\"\n\n[mcp_servers.agent-hud]\ncommand = \"/x\"\nargs = [\"--mcp\"]\n", true, "as codex mcp add writes it"),
            ("[mcp_servers.\"agent-hud\"]\ncommand = \"/x\"\n", true, "a quoted key"),
            ("[ mcp_servers . 'agent-hud' ] # mine\ncommand = \"/x\"\n", true, "a literal key, spaces and a comment"),
            ("[mcp_servers.agent-hud.env]\nA = \"1\"\n", true, "only a table under it"),
            ("[mcp_servers]\nagent-hud = { command = \"/x\", args = [\"--mcp\"] }\n", true, "a key under mcp_servers"),
            ("mcp_servers.agent-hud.command = \"/x\"\n", true, "a dotted key at the top"),
            ("mcp_servers = { other = { command = \"/y\", args = [\"a,b\"] }, \"agent-hud\" = { command = \"/x\" } }\n", true,
             "an inline table"),
            ("[mcp_servers.node_repl]\ncommand = \"node\"\n[mcp_servers.node_repl.env]\nagent-hud = \"1\"\n", false,
             "a key of that name in another server's table"),
            ("# [mcp_servers.agent-hud]\n[mcp_servers.other]\ncommand = \"/x\"\n", false, "a comment"),
            ("[mcp_servers.agent-hud-old]\ncommand = \"/x\"\n", false, "another name"),
            ("notes = \"\"\"\n[mcp_servers.agent-hud]\n\"\"\"\n[profiles.fast]\nmodel = \"x\"\n", false, "inside a multi-line string"),
            ("mcp_servers = { other = { command = \"/y\" } }\n", false, "an inline table without it"),
            ("[agent-hud]\ncommand = \"/x\"\n", false, "a table of that name elsewhere"),
            ("", false, "an empty file"),
        ]
        for (text, expected, why) in samples {
            try write(text, to: config)
            XCTAssertEqual(client.hasServer(home: home, environment: [:]), expected, why)
        }
        let moved = home.appendingPathComponent("codex-home", isDirectory: true)
        try write(samples[0].0, to: moved.appendingPathComponent("config.toml"))
        try write("", to: config)
        XCTAssertTrue(client.hasServer(home: home, environment: ["CODEX_HOME": moved.path]), "CODEX_HOME moves it")
    }

    /// A client is offered only where its command is: the CLI's install places, then PATH. Claude Code's desktop app
    /// carries an engine, which is no command a person runs.
    func testAClientIsFoundWhereItsCommandIsInstalled() throws {
        let home = try directory()
        let applications = home.appendingPathComponent("Applications", isDirectory: true)
        func place(_ path: String, executable: Bool = true) throws {
            let url = home.appendingPathComponent(path)
            try write("#!/bin/sh\n", to: url)
            try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
        }
        func found(_ client: MCPClient, path: String = "") -> String? {
            client.executable(home: home, applications: applications, path: path, registered: [])?.path
        }
        // Homebrew's and /usr/local's places are the system's own; where this Mac has a command there, it is found.
        let system = ["/opt/homebrew/bin", "/usr/local/bin"]
        let systemClaude = system.map { $0 + "/claude" }.first(where: FileManager.default.isExecutableFile(atPath:))
        let systemCodex = system.map { $0 + "/codex" }.first(where: FileManager.default.isExecutableFile(atPath:))
        XCTAssertEqual(found(.claudeCode), systemClaude)
        XCTAssertEqual(found(.codex), systemCodex)
        try place("Library/Application Support/Claude/claude-code/2.1.300/build/claude.app/Contents/MacOS/claude")
        XCTAssertEqual(found(.claudeCode), systemClaude, "the desktop app's engine is not offered")
        try place("bin/claude", executable: false)
        XCTAssertEqual(found(.claudeCode, path: home.appendingPathComponent("bin").path), systemClaude, "a file that cannot run")
        try place("tools/claude")
        XCTAssertEqual(found(.claudeCode, path: home.appendingPathComponent("tools").path),
                       systemClaude ?? home.appendingPathComponent("tools/claude").path, "on PATH")
        try place(".local/bin/claude")
        XCTAssertEqual(found(.claudeCode), home.appendingPathComponent(".local/bin/claude").path, "the installer's place first")
        try place(".bun/bin/codex")
        XCTAssertEqual(found(.codex), home.appendingPathComponent(".bun/bin/codex").path)
        try place("Applications/Codex.app/Contents/Resources/codex-cli/bin/codex")
        XCTAssertEqual(found(.codex), applications.appendingPathComponent("Codex.app/Contents/Resources/codex-cli/bin/codex").path,
                       "Codex's own app comes first")
    }

    /// The runner, tried on the shell rather than on any client: what a command wrote, its status, where it ran, and a
    /// command that takes too long or cannot start.
    func testACommandRunsFromTheHomeFolderAndIsStoppedWhenItTakesTooLong() async {
        let shell = URL(fileURLWithPath: "/bin/sh")
        let failed = await MCPClientCommand.run(shell, ["-c", "echo said; echo 'error: no such scope' >&2; exit 3"])
        XCTAssertEqual(failed.status, 3)
        XCTAssertEqual(failed.output, "error: no such scope\nsaid\n", "standard error first")
        XCTAssertEqual(failed.failureLine, "error: no such scope")
        let place = await MCPClientCommand.run(shell, ["-c", "pwd; case \":$PATH:\" in *:/opt/homebrew/bin:*) echo found;; esac"])
        XCTAssertTrue(place.succeeded)
        XCTAssertEqual(place.output, FileManager.default.homeDirectoryForCurrentUser.path + "\nfound\n",
                       "from the home folder, with the install places on PATH")
        let started = Date()
        let slow = await MCPClientCommand.run(URL(fileURLWithPath: "/bin/sleep"), ["30"], timeout: 0.3)
        XCTAssertNil(slow.status)
        XCTAssertEqual(slow.output, "")
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        let missing = await MCPClientCommand.run(URL(fileURLWithPath: "/nonexistent/claude"), ["mcp"])
        XCTAssertNil(missing.status)
        XCTAssertFalse(missing.output.isEmpty, "why it could not start")
    }

    func testAFailureIsOneLineForAPerson() {
        L10n.setLanguage(.en)
        defer { L10n.setLanguage(.system) }
        XCTAssertEqual(MCPCommandResult(status: 1, output: "\n  error: MCP server agent-hud already exists in user config  \nusage…").failureLine,
                       "error: MCP server agent-hud already exists in user config")
        XCTAssertEqual(MCPCommandResult(status: 2).failureLine, "Exit status 2")
        XCTAssertEqual(MCPCommandResult(status: nil).failureLine, "It did not finish in 15 seconds")
        XCTAssertEqual(MCPCommandResult(status: 1, output: String(repeating: "x", count: 400)).failureLine.count, 160)
        XCTAssertTrue(MCPCommandResult(status: 0).succeeded)
        XCTAssertFalse(MCPCommandResult(status: nil).succeeded)
    }
}
