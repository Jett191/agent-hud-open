import Foundation

/// Claude Code runs with no one to ask about a permission: print mode, or an SDK host that answers none itself.
///
/// Such a run denies a request the moment its hooks return, so holding one on the HUD only stalls the script that started
/// it: an eval of eight `claude -p` runs waited the whole approval wait on six cards nobody else could answer. The
/// permission hook lets these go at once and the HUD never hears of them; Claude Code then denies them exactly as it
/// would with no HUD installed. Two signals must agree, and a run either cannot place is held as before:
/// - Claude Code stamps `CLAUDE_CODE_SESSION_ATTENDED` on every hook it starts: 1 for a terminal session and the desktop
///   and IDE hosts, 0 for print mode and SDK hosts. A run started from another session's shell gets its own 0 but
///   inherits that session's entrypoint, so the entrypoint says nothing here.
/// - The engine's arguments: print mode (`-p`, or a stream-json host) with no `--permission-prompt-tool`, or with
///   `--permission-prompts none`. A host that names a prompt tool asks its own user while the hook waits and the first
///   answer wins, so its requests stay on the HUD.
/// Background sessions wait in their own terminal until their user attaches, so they stay too.
enum ClaudeHeadlessRuns {
    /// Whether the engine that started this hook process is such a run.
    static func current(environment: [String: String] = ProcessInfo.processInfo.environment,
                        home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        // Attended sessions, nearly every request, need no look at the process tree.
        guard environment["CLAUDE_CODE_SESSION_ATTENDED"] == "0" else { return false }
        let executables = Set(ClaudeEngineLocator.candidates(home: home, path: environment["PATH"] ?? "")
            .map { $0.resolvingSymlinksInPath().path })
        return headless(ancestors: HookProcessOrigins.ancestors(), environment: environment, executablePaths: executables)
    }

    static func headless(ancestors: [HookProcessOrigins.Ancestor], environment: [String: String],
                         executablePaths: Set<String>) -> Bool {
        guard environment["CLAUDE_CODE_SESSION_ATTENDED"] == "0", (environment["CLAUDE_CODE_SESSION_KIND"] ?? "").isEmpty,
              let arguments = ClaudeSessionOrigins.engineArguments(ancestors: ancestors, executablePaths: executablePaths)
        else { return false }
        return asksNoOne(arguments)
    }

    /// Whether an engine started with `arguments`, its executable first, denies whatever it would ask. Never interprets
    /// an option value or a prompt as a flag.
    static func asksNoOne(_ arguments: [String]) -> Bool {
        var printing = false, promptTool = false, noPrompts = false
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { break }
            let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
            let option = parts.first ?? argument, inline = parts.count == 2
            switch option {
            case "-p", "--print", "--input-format", "--output-format": printing = true
            case "--permission-prompt-tool": promptTool = true
            case "--permission-prompts":
                noPrompts = (inline ? parts[1] : index + 1 < arguments.count ? arguments[index + 1] : nil) == "none"
            default: break
            }
            index += ClaudeSessionOrigins.valueOptions.contains(option) && !inline ? 2 : 1
        }
        return printing && (noPrompts || !promptTool)
    }
}
