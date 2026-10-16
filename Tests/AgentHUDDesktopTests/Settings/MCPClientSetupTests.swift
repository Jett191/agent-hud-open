import Foundation
import XCTest
@testable import AgentHUDCore
@testable import AgentHUDDesktop

/// A Mac a test makes up: which clients' commands it has, which configurations hold the server, and every command
/// run and text copied. A command run changes the configuration as the real client would, unless told to fail.
final class FakeClientMac: @unchecked Sendable {
    private let lock = NSLock()
    private var _servers: Set<MCPClient>
    private var _runs: [(URL, [String])] = []
    private var _copied: [String] = []
    var installed: [MCPClient: URL]
    var executable: URL?
    /// What the next command reports; it changes nothing unless it succeeds.
    var result = MCPCommandResult(status: 0)
    /// Whether a successful command changes the configuration.
    var takesEffect = true
    /// A command waits while this is true.
    var holding = false

    init(installed: [MCPClient: URL], servers: Set<MCPClient> = [],
         executable: URL? = URL(fileURLWithPath: "/Applications/Agent HUD Open.app/Contents/MacOS/Agent HUD Open")) {
        self.installed = installed
        _servers = servers
        self.executable = executable
    }

    var servers: Set<MCPClient> { lock.withLock { _servers } }
    var runs: [(URL, [String])] { lock.withLock { _runs } }
    var copied: [String] { lock.withLock { _copied } }

    @MainActor
    var environment: MCPClientSetup.Environment {
        MCPClientSetup.Environment(
            executable: executable,
            locate: { [self] in installed[$0] },
            hasServer: { [self] in servers.contains($0) },
            run: { [self] url, arguments in
                while lock.withLock({ holding }) { try? await Task.sleep(for: .milliseconds(5)) }
                return lock.withLock {
                    _runs.append((url, arguments))
                    guard result.succeeded, takesEffect,
                          let client = installed.first(where: { $0.value == url })?.key else { return result }
                    if arguments.contains("add") { _servers.insert(client) } else { _servers.remove(client) }
                    return result
                }
            },
            copy: { [self] text in lock.withLock { _copied.append(text) } })
    }

    func release() { lock.withLock { holding = false } }

    /// What a person's own run of a command in a terminal leaves in the configurations.
    func setServers(_ servers: Set<MCPClient>) { lock.withLock { _servers = servers } }
}

/// The install row on Settings → Experimental: what it offers, the command each button runs, and what it says after.
@MainActor
final class MCPClientSetupTests: XCTestCase {
    private let claude = URL(fileURLWithPath: "/Users/me/.local/bin/claude")
    private let codex = URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex")
    private let executable = "/Applications/Agent HUD Open.app/Contents/MacOS/Agent HUD Open"

    override func setUp() {
        super.setUp()
        L10n.setLanguage(.en)
    }

    override func tearDown() {
        L10n.setLanguage(.system)
        super.tearDown()
    }

    private func setup(_ mac: FakeClientMac) -> MCPClientSetup {
        let setup = MCPClientSetup(environment: mac.environment)
        setup.refresh()
        return setup
    }

    func testTheClientsOfThisMacThenOther() {
        let both = setup(FakeClientMac(installed: [.codex: codex, .claudeCode: claude]))
        XCTAssertEqual(both.choices, [.client(.claudeCode), .client(.codex), .other])
        XCTAssertEqual(both.choice, .client(.claudeCode), "the first client, where none has the server")
        XCTAssertEqual(both.choices.map(MCPClientSetup.label), ["Claude Code", "Codex", "Other"])

        let codexHasIt = setup(FakeClientMac(installed: [.codex: codex, .claudeCode: claude], servers: [.codex]))
        XCTAssertEqual(codexHasIt.choice, .client(.codex), "the first client that has the server, so Remove is at hand")

        let none = setup(FakeClientMac(installed: [:]))
        XCTAssertEqual(none.choices, [.other])
        XCTAssertEqual(none.choice, .other)

        let mac = FakeClientMac(installed: [.claudeCode: claude, .codex: codex])
        let chosen = setup(mac)
        chosen.choice = .client(.codex)
        chosen.refresh()
        XCTAssertEqual(chosen.choice, .client(.codex), "a look again keeps what a person chose")
        mac.installed = [.claudeCode: claude]
        chosen.refresh()
        XCTAssertEqual(chosen.choice, .client(.claudeCode), "a client that is gone is chosen no more")
    }

    func testAddAndRemoveRunTheClientsOwnCommandAndTheStatusReadsItsConfigurationAfter() async {
        let mac = FakeClientMac(installed: [.claudeCode: claude, .codex: codex])
        let setup = setup(mac)
        XCTAssertEqual(setup.status, "Not added yet")
        XCTAssertEqual(setup.action, .add)
        XCTAssertEqual(setup.buttonTitle, "Add")
        XCTAssertEqual(setup.hint, "Then start a new Claude Code session and ask it to rearrange the HUD.")

        await setup.perform()
        XCTAssertEqual(mac.runs.map(\.0), [claude])
        XCTAssertEqual(mac.runs.last?.1, ["mcp", "add", "--scope", "user", "agent-hud", "--", executable, "--mcp"])
        XCTAssertEqual(setup.status, "Added to Claude Code")
        XCTAssertEqual(setup.action, .remove)
        XCTAssertEqual(setup.buttonTitle, "Remove")

        await setup.perform()
        XCTAssertEqual(mac.runs.last?.1, ["mcp", "remove", "--scope", "user", "agent-hud"])
        XCTAssertEqual(setup.status, "Not added yet")

        setup.choice = .client(.codex)
        await setup.perform()
        XCTAssertEqual(mac.runs.last?.0, codex)
        XCTAssertEqual(mac.runs.last?.1, ["mcp", "add", "agent-hud", "--", executable, "--mcp"])
        XCTAssertEqual(setup.status, "Added to Codex")
        await setup.perform()
        XCTAssertEqual(mac.runs.last?.1, ["mcp", "remove", "agent-hud"])
        XCTAssertEqual(mac.runs.count, 4, "one command a press, nothing on its own")
        XCTAssertTrue(mac.copied.isEmpty)
    }

    func testAFailureIsShownInOneLineUntilTheChoiceChanges() async {
        let mac = FakeClientMac(installed: [.claudeCode: claude, .codex: codex])
        let setup = setup(mac)
        mac.result = MCPCommandResult(status: 1, output: "\nerror: user config is locked\n    at write (cli.js:1:1)\n")
        await setup.perform()
        XCTAssertEqual(setup.status, "Couldn't add: error: user config is locked")
        XCTAssertEqual(setup.action, .add, "nothing was added")

        mac.result = MCPCommandResult(status: nil)
        await setup.perform()
        XCTAssertEqual(setup.status, "Couldn't add: It did not finish in 15 seconds")

        mac.result = MCPCommandResult(status: 0)
        mac.takesEffect = false
        await setup.perform()
        XCTAssertEqual(setup.status, "Couldn't add: Claude Code's settings did not change",
                       "a command that says it worked is held to the configuration")

        setup.choice = .client(.codex)
        XCTAssertEqual(setup.status, "Not added yet", "another choice starts afresh")
    }

    func testWhileACommandRunsTheRowWaitsForIt() async {
        let mac = FakeClientMac(installed: [.claudeCode: claude])
        mac.holding = true
        let setup = setup(mac)
        let pressed = Task { await setup.perform() }
        for _ in 0..<500 where setup.running == nil { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(setup.running, .add)
        XCTAssertEqual(setup.status, "Adding to Claude Code…")
        XCTAssertEqual(setup.controls(toolsOn: true), .init(picker: false, action: false, copyCommand: false, hint: true))
        await setup.perform()
        mac.release()
        await pressed.value
        XCTAssertEqual(mac.runs.count, 1, "a second press while one runs does nothing")
        XCTAssertEqual(setup.status, "Added to Claude Code")
    }

    func testOtherCopiesTheServersSettingsAsJSON() async throws {
        let mac = FakeClientMac(installed: [.claudeCode: claude])
        let setup = setup(mac)
        setup.choice = .other
        XCTAssertEqual(setup.action, .copySettings)
        XCTAssertEqual(setup.buttonTitle, "Copy settings")
        XCTAssertNil(setup.commandLine, "Other has no command")
        XCTAssertEqual(setup.status, "Copy the settings into any client that runs MCP servers.")
        XCTAssertEqual(setup.hint, "Then start a new session in your client and ask it to rearrange the HUD.")
        await setup.perform()
        XCTAssertEqual(mac.copied, [MCPClient.settingsJSON(executable: executable)])
        let copied = try JSONSerialization.jsonObject(with: Data(mac.copied[0].utf8)) as? [String: [String: [String: Any]]]
        XCTAssertEqual(copied?["mcpServers"]?["agent-hud"]?["command"] as? String, executable)
        XCTAssertEqual(copied?["mcpServers"]?["agent-hud"]?["args"] as? [String], ["--mcp"])
        XCTAssertEqual(setup.status, "Settings copied. Paste them into your client's MCP settings.")
        XCTAssertTrue(mac.runs.isEmpty)
    }

    func testCopyCommandCopiesWhatTheButtonWouldRun() async {
        let mac = FakeClientMac(installed: [.claudeCode: claude, .codex: codex], servers: [.codex])
        let setup = setup(mac)
        setup.choice = .client(.claudeCode)
        setup.copyCommand()
        XCTAssertEqual(mac.copied.last, "claude mcp add --scope user agent-hud -- '\(executable)' --mcp")
        XCTAssertEqual(setup.status, "Command copied. Paste it into Terminal.")
        setup.choice = .client(.codex)
        setup.copyCommand()
        XCTAssertEqual(mac.copied.last, "codex mcp remove agent-hud")
        XCTAssertTrue(mac.runs.isEmpty, "copying runs nothing")

        // The person runs it in a terminal and comes back: the row reads the configuration again.
        setup.refresh()
        XCTAssertEqual(setup.status, "Command copied. Paste it into Terminal.", "nothing changed yet")
        mac.setServers([])
        setup.refresh()
        XCTAssertEqual(setup.choice, .client(.codex), "the choice stays")
        XCTAssertEqual(setup.status, "Not added yet")
        XCTAssertEqual(setup.action, .add)
        XCTAssertTrue(mac.runs.isEmpty)
    }

    func testAnApplicationRunningFromATemporaryPlaceIsNotAdded() async {
        for path in ["/private/var/folders/x1/abc/T/AppTranslocation/0F1E/d/Agent HUD Open.app/Contents/MacOS/Agent HUD Open",
                     "/Volumes/Agent HUD Open/Agent HUD Open.app/Contents/MacOS/Agent HUD Open"] {
            let mac = FakeClientMac(installed: [.claudeCode: claude, .codex: codex], servers: [.codex],
                                    executable: URL(fileURLWithPath: path))
            let setup = setup(mac)
            setup.choice = .client(.claudeCode)
            XCTAssertNil(setup.action, path)
            XCTAssertEqual(setup.status, "Move Agent HUD to Applications first.")
            XCTAssertNil(setup.commandLine)
            XCTAssertFalse(setup.controls(toolsOn: true).action)
            XCTAssertFalse(setup.controls(toolsOn: true).copyCommand)
            await setup.perform()
            setup.copyCommand()
            setup.choice = .other
            XCTAssertNil(setup.action, "nor are its settings copied")
            XCTAssertEqual(setup.status, "Move Agent HUD to Applications first.")
            await setup.perform()
            XCTAssertTrue(mac.runs.isEmpty, path)
            XCTAssertTrue(mac.copied.isEmpty, path)

            setup.choice = .client(.codex)
            XCTAssertEqual(setup.action, .remove, "what was added before can still be removed")
            await setup.perform()
            XCTAssertEqual(mac.runs.map(\.1), [["mcp", "remove", "agent-hud"]])
        }
    }

    /// While the switch is off the rows are dimmed and only Remove, with the picker it needs, stays available.
    func testTheRowsFollowTheSwitchExceptRemove() {
        let mac = FakeClientMac(installed: [.claudeCode: claude, .codex: codex])
        let setup = setup(mac)
        XCTAssertEqual(setup.controls(toolsOn: true), .init(picker: true, action: true, copyCommand: true, hint: true))
        XCTAssertEqual(setup.controls(toolsOn: false), .init(picker: false, action: false, copyCommand: false, hint: false))
        setup.choice = .other
        XCTAssertEqual(setup.controls(toolsOn: true), .init(picker: true, action: true, copyCommand: false, hint: true))
        XCTAssertEqual(setup.controls(toolsOn: false), .init(picker: false, action: false, copyCommand: false, hint: false))

        let added = self.setup(FakeClientMac(installed: [.claudeCode: claude, .codex: codex], servers: [.codex]))
        XCTAssertEqual(added.choice, .client(.codex))
        XCTAssertEqual(added.controls(toolsOn: false), .init(picker: true, action: true, copyCommand: true, hint: false))
        added.choice = .client(.claudeCode)
        XCTAssertEqual(added.controls(toolsOn: false), .init(picker: true, action: false, copyCommand: false, hint: false),
                       "the picker stays so Codex can be chosen again; Add waits for the switch")
    }
}
