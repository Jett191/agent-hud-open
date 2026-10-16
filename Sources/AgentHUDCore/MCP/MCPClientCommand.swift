import Foundation

/// What one run of a client's command did.
package struct MCPCommandResult: Equatable, Sendable {
    /// The exit status; nil when the command could not start or did not finish in time.
    package var status: Int32?
    /// What it wrote, standard error first, or why it could not start.
    package var output: String

    /// A run that ended with `status`, having written `output`.
    package init(status: Int32?, output: String = "") {
        self.status = status
        self.output = output
    }

    /// Whether the command ran and exited 0.
    package var succeeded: Bool { status == 0 }

    /// Why it failed, in one line for a person: the first line it wrote, else what became of it.
    package var failureLine: String {
        let first = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        if let first { return first.count > 160 ? String(first.prefix(159)) + "…" : first }
        guard let status else {
            let seconds = Int(MCPClientCommand.timeout)
            return L10n.text("\(seconds) 秒内没有完成", "It did not finish in \(seconds) seconds")
        }
        return L10n.text("退出状态 \(status)", "Exit status \(status)")
    }
}

/// Runs a client's own command, such as `claude mcp add`, when a person asks for it: from the home folder, with the
/// install places of the clients' commands and of Node on `PATH`, which an application started from Finder lacks, and
/// stopped when it takes longer than `timeout`. Nothing runs one on its own.
package enum MCPClientCommand {
    /// How long a command may take before it is stopped, in seconds.
    package static let timeout: TimeInterval = 15

    /// Runs `executable` with `arguments` and says how it went; nil status when it could not start or ran out of
    /// `timeout`.
    package static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval = timeout) async -> MCPCommandResult {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(home.path)/.bun/bin:\(home.path)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:"
            + (environment["PATH"] ?? "")
        do {
            let child = try ChildProcess(executable, arguments, environment: environment, directory: home, stdoutLimit: 64 * 1024)
            defer { child.stop() }
            try await child.waitForExit(before: Date().addingTimeInterval(timeout))
            let output = child.output
            // One that ran out of time is said to have, whatever it wrote before.
            guard let status = output.status else { return MCPCommandResult(status: nil) }
            return MCPCommandResult(status: status, output: String(decoding: output.stderr + output.stdout, as: UTF8.self))
        } catch {
            return MCPCommandResult(status: nil, output: error.localizedDescription)
        }
    }
}
