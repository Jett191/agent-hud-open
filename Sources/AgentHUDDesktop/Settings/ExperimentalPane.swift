import AppKit
import SwiftUI
import AgentHUDCore

/// Settings → Experimental: what is still being tested. Agent HUD's own rows let agents arrange the HUD over MCP, in
/// three rows: the switch, off by default, the client to add the server to, and what to ask once it is in. A host's
/// rows follow below.
struct ExperimentalPane: View {
    let settings: SettingsStore
    let theme: Theme
    var additions: [DesktopSettingsSection] = []
    @State private var setup: MCPClientSetup

    init(settings: SettingsStore, theme: Theme, additions: [DesktopSettingsSection] = [], setup: MCPClientSetup? = nil) {
        self.settings = settings
        self.theme = theme
        self.additions = additions
        _setup = State(initialValue: setup ?? MCPClientSetup())
    }

    var body: some View {
        let toolsOn = settings.settings.agentTools
        let controls = setup.controls(toolsOn: toolsOn)
        VStack(alignment: .leading, spacing: 28) {
            SettingsSection(title: L10n.text("Agent 工具", "Agent tools"), theme: theme) {
                SettingRow(label: L10n.text("允许 agent 调整 HUD", "Let agents arrange the HUD"),
                           subtitle: L10n.text("agent 通过 MCP 读取面板和 HUD，起草新布局，由你保存。",
                                               "Agents read the panel and HUD over MCP and draft new layouts for you to save.")) {
                    Toggle(L10n.text("允许 agent 调整 HUD", "Let agents arrange the HUD"), isOn: settings.binding(\.agentTools))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .accessibilityIdentifier("experimental-agent-tools")
                }
                SettingsDivider(theme: theme)
                installRow(controls, toolsOn: toolsOn)
                SettingsDivider(theme: theme)
                Text(setup.hint)
                    .font(.ui(12))
                    .foregroundStyle(controls.hint ? theme.secondary : theme.secondary.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .accessibilityIdentifier("experimental-agent-tools-hint")
            }
            ForEach(additions) { $0.content() }
        }
        .onAppear { setup.refresh() }
        // A command copied and run in a terminal shows here when the person comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in setup.refresh() }
    }

    private func installRow(_ controls: MCPClientSetup.Controls, toolsOn: Bool) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("客户端", "Client"))
                    .foregroundStyle(toolsOn ? theme.text : theme.secondary)
                HStack(spacing: 8) {
                    Text(setup.status)
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .help(setup.status)
                        .accessibilityIdentifier("experimental-agent-tools-status")
                    // The command the button runs, for a person who would rather run it in a terminal.
                    if setup.commandLine != nil {
                        Button(L10n.text("拷贝命令", "Copy command")) { setup.copyCommand() }
                            .buttonStyle(.plain)
                            .foregroundStyle(controls.copyCommand ? Color.accentColor : theme.secondary.opacity(0.5))
                            .disabled(!controls.copyCommand)
                            .help(setup.commandLine ?? "")
                            .accessibilityIdentifier("experimental-agent-tools-copy")
                    }
                }
                .font(.ui(11))
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Picker(L10n.text("客户端", "Client"), selection: $setup.choice) {
                    ForEach(setup.choices, id: \.self) { choice in
                        Text(MCPClientSetup.label(choice)).tag(choice)
                    }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
                .disabled(!controls.picker)
                .accessibilityIdentifier("experimental-agent-tools-client")
                Button(setup.buttonTitle) { Task { await setup.perform() } }
                    .disabled(!controls.action)
                    .accessibilityIdentifier("experimental-agent-tools-action")
            }
            .fixedSize()
        }
        .frame(minHeight: 30)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}
