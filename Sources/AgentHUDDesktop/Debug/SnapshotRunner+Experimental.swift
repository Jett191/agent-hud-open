import AppKit
import SwiftUI
import AgentHUDCore

#if DEBUG
/// The stills of Settings → Experimental, named `settings-experimental-…`.
extension SnapshotRunner {
    /// The Experimental page with the switch on and Claude Code chosen, which is not added yet; with Other chosen; in
    /// light; at the smallest window; and with the switch off and Codex chosen, which has the server, so Remove alone
    /// is available. A sample Mac stands in for this one: Claude Code and Codex installed, the application in
    /// Applications, and no command runs.
    static func saveExperimental(settings: SettingsStore, store: UsageStore, folder: URL) {
        if let prefix = ProcessInfo.processInfo.environment["AGENTHUD_SNAPSHOT_PREFIX"],
           !"settings-experimental".hasPrefix(prefix) && !prefix.hasPrefix("settings-experimental") { return }
        let saved = settings.settings.agentTools
        defer { settings.update { $0.agentTools = saved } }
        let setup = MCPClientSetup(environment: .sample)
        setup.refresh()
        func shoot(_ name: String, _ choice: MCPClientSetup.Choice, toolsOn: Bool, scheme: ColorScheme = .dark,
                   size: CGSize = SettingsWindowLayout.size) {
            settings.update { $0.agentTools = toolsOn }
            setup.choice = choice
            save(name, SettingsView(settings: settings, store: store, initialTab: .experimental, clientSetup: setup)
                .frame(width: size.width, height: size.height), folder: folder, scheme: scheme)
        }
        shoot("settings-experimental-dark", .client(.claudeCode), toolsOn: true)
        shoot("settings-experimental-other-dark", .other, toolsOn: true)
        shoot("settings-experimental-light", .client(.claudeCode), toolsOn: true, scheme: .light)
        shoot("settings-experimental-small-dark", .client(.claudeCode), toolsOn: true, size: SettingsWindowLayout.minimum)
        shoot("settings-experimental-off-dark", .client(.codex), toolsOn: false)
    }
}

extension MCPClientSetup.Environment {
    /// A Mac with Claude Code and Codex, Codex already given the server, and Agent HUD in Applications. Nothing runs
    /// and nothing is copied.
    static var sample: Self {
        Self(executable: URL(fileURLWithPath: "/Applications/Agent HUD Open.app/Contents/MacOS/Agent HUD Open"),
             locate: { URL(fileURLWithPath: "/usr/local/bin/\($0.command)") },
             hasServer: { $0 == .codex },
             run: { _, _ in MCPCommandResult(status: 0) },
             copy: { _ in })
    }
}
#endif
