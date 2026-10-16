import XCTest
@testable import AgentHUDCore

/// The process shapes were read from Claude Code 2.1.300 and the desktop app's 2.1.295 engine on 2026-10-15.
final class ClaudeHeadlessRunsTests: XCTestCase {
    private let native = "/Users/test/.local/share/claude/versions/2.1.300"
    private let shell = HookProcessOrigins.Ancestor(executable: "/bin/sh", arguments: ["sh", "-c", "hook"])
    private let unattended = ["CLAUDE_CODE_SESSION_ATTENDED": "0"]

    private func engine(_ arguments: [String]) -> HookProcessOrigins.Ancestor {
        HookProcessOrigins.Ancestor(executable: native, arguments: ["claude"] + arguments)
    }

    func testAPrintRunStartedFromADesktopSessionsShellIsLetGo() {
        // An eval script a desktop session ran: the run inherits the desktop's entrypoint and the app is further up.
        let run = engine(["-p", "Review this repository", "--allowedTools", "Read", "Grep", "--no-session-persistence"])
        let script = HookProcessOrigins.Ancestor(executable: "/bin/bash", arguments: ["bash", "run_evals.sh"])
        let desktop = HookProcessOrigins.Ancestor(executable: "/Applications/Claude.app/Contents/MacOS/Claude", arguments: ["Claude"],
                                                  bundleIdentifier: "com.anthropic.claudefordesktop")
        var environment = unattended
        environment["CLAUDE_CODE_ENTRYPOINT"] = "claude-desktop"
        XCTAssertTrue(ClaudeHeadlessRuns.headless(ancestors: [shell, run, script, desktop], environment: environment,
                                                  executablePaths: [native]))
        environment["CLAUDE_CODE_ENTRYPOINT"] = "sdk-cli"
        XCTAssertTrue(ClaudeHeadlessRuns.headless(ancestors: [run], environment: environment, executablePaths: [native]),
                      "the same from a plain shell")
    }

    func testRunsThatAskNoOneButTheHUD() {
        XCTAssertTrue(ClaudeHeadlessRuns.asksNoOne(["claude", "--print", "hi"]))
        XCTAssertTrue(ClaudeHeadlessRuns.asksNoOne(["claude", "--output-format", "stream-json", "--verbose", "--input-format", "stream-json"]),
                      "an SDK host that answers nothing itself")
        XCTAssertTrue(ClaudeHeadlessRuns.asksNoOne(["claude", "-p", "hi", "--permission-prompts", "none"]))
        XCTAssertTrue(ClaudeHeadlessRuns.asksNoOne(["claude", "-p", "hi", "--permission-prompt-tool", "stdio", "--permission-prompts=none"]),
                      "no prompts at all, whatever answers them")
    }

    func testRunsSomeoneElseCanAnswerStayOnTheHUD() {
        let desktop = engine(["--output-format", "stream-json", "--verbose", "--input-format", "stream-json",
                              "--permission-prompt-tool=stdio", "--permission-mode=default"])
        XCTAssertFalse(ClaudeHeadlessRuns.headless(ancestors: [desktop], environment: ["CLAUDE_CODE_SESSION_ATTENDED": "1"],
                                                   executablePaths: [native]), "the desktop app's engine")
        XCTAssertFalse(ClaudeHeadlessRuns.headless(ancestors: [desktop], environment: unattended, executablePaths: [native]),
                       "an SDK app asks its own user alongside the hook")
        XCTAssertFalse(ClaudeHeadlessRuns.asksNoOne(["claude", "-p", "hi", "--permission-prompt-tool", "mcp__approver__ask"]))
        XCTAssertFalse(ClaudeHeadlessRuns.asksNoOne(["claude", "-p", "hi", "--permission-prompts", "host", "--permission-prompt-tool", "stdio"]))
        XCTAssertFalse(ClaudeHeadlessRuns.asksNoOne(["claude"]), "a terminal session")
        XCTAssertFalse(ClaudeHeadlessRuns.asksNoOne(["claude", "--resume", "a-session"]), "an unattended session not in print mode")
    }

    func testEitherSignalAloneIsNotEnough() {
        let run = engine(["-p", "hi"])
        XCTAssertFalse(ClaudeHeadlessRuns.headless(ancestors: [run], environment: ["CLAUDE_CODE_SESSION_ATTENDED": "1"],
                                                   executablePaths: [native]))
        XCTAssertFalse(ClaudeHeadlessRuns.headless(ancestors: [run], environment: [:], executablePaths: [native]),
                       "an engine that does not say is held as before")
        var background = unattended
        background["CLAUDE_CODE_SESSION_KIND"] = "bg"
        XCTAssertFalse(ClaudeHeadlessRuns.headless(ancestors: [run], environment: background, executablePaths: [native]),
                       "a background session waits for its user to attach")
        XCTAssertFalse(ClaudeHeadlessRuns.headless(ancestors: [shell, run], environment: unattended, executablePaths: ["/other/claude"]),
                       "the nearest process must be an installed engine")
        let unrelated = HookProcessOrigins.Ancestor(executable: "/opt/homebrew/bin/node", arguments: ["node", "/tmp/sdk.js", "-p"])
        XCTAssertFalse(ClaudeHeadlessRuns.headless(ancestors: [unrelated, run], environment: unattended, executablePaths: [native]))
        XCTAssertFalse(ClaudeHeadlessRuns.current(environment: unattended), "this test process was not started by an engine")
    }

    func testOptionValuesAndPromptsNameNoMode() {
        XCTAssertFalse(ClaudeHeadlessRuns.asksNoOne(["claude", "--append-system-prompt", "-p", "--", "-p"]))
        XCTAssertTrue(ClaudeHeadlessRuns.asksNoOne(["claude", "-p", "hi", "--append-system-prompt", "--permission-prompt-tool"]),
                      "a value is not a prompt tool")
        XCTAssertFalse(ClaudeHeadlessRuns.asksNoOne(["claude", "-p", "hi", "--permission-prompt-tool", "stdio", "--model", "--permission-prompts=none"]))
        let npm = "/Users/test/npm/node_modules/@anthropic-ai/claude-code/cli.js"
        let node = HookProcessOrigins.Ancestor(executable: "/opt/homebrew/bin/node", arguments: ["node", npm, "-p", "hi"])
        XCTAssertTrue(ClaudeHeadlessRuns.headless(ancestors: [node], environment: unattended, executablePaths: [npm]),
                      "the npm install runs its script through Node")
    }
}
