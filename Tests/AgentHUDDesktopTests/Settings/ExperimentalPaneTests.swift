import AppKit
import SwiftUI
import XCTest
@testable import AgentHUDCore
@testable import AgentHUDDesktop

/// Settings → Experimental as drawn: its rendered controls dimmed while the switch is off, except Remove, and usable
/// once it is on; the switch writes the setting; and a host's rows below Agent HUD's own.
@MainActor
final class ExperimentalPaneTests: XCTestCase {
    override func tearDown() {
        L10n.setLanguage(.system)
        super.tearDown()
    }

    @MainActor
    private struct Page {
        let hosting: NSHostingView<AnyView>
        let window: NSWindow

        private func views(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap { views(in: $0) } }
        private var visible: [NSView] { views(in: hosting).filter { !$0.isHiddenOrHasHiddenAncestor } }

        var toggle: NSSwitch? { visible.compactMap { $0 as? NSSwitch }.first }
        var picker: NSPopUpButton? { visible.compactMap { $0 as? NSPopUpButton }.first }
    }

    private func page(_ settings: SettingsStore, _ setup: MCPClientSetup, sections: [DesktopSettingsSection] = []) throws -> Page {
        _ = NSApplication.shared
        let store = UsageStore(provider: DemoUsageProvider(), settings: settings)
        let size = SettingsWindowLayout.size
        let view = SettingsView(settings: settings, store: store, initialTab: .experimental, experimentalSections: sections,
                                clientSetup: setup).frame(width: size.width, height: size.height)
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -20000, y: -20000), size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        addTeardownBlock { @MainActor in window.orderOut(nil) }
        return Page(hosting: hosting, window: window)
    }

    /// SwiftUI applies a change on its own schedule, so wait for what it makes rather than for a fixed time.
    private func settle(_ page: Page, until reached: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            try? await Task.sleep(for: .milliseconds(50))
            page.hosting.layoutSubtreeIfNeeded()
        } while !reached() && Date() < deadline
    }

    private func settings() throws -> SettingsStore {
        let suite = "app.agenthud.tests.experimental.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)), defaultAgents: DemoData.agents)
        settings.update { $0.language = .en }
        L10n.setLanguage(.en)
        return settings
    }

    func testTheRowsAreDimmedWhileTheSwitchIsOffAndUsableOnceItIsOn() async throws {
        let settings = try settings()
        let mac = FakeClientMac(installed: [.claudeCode: URL(fileURLWithPath: "/usr/local/bin/claude")])
        let setup = MCPClientSetup(environment: mac.environment)
        let page = try page(settings, setup)
        await settle(page) { page.toggle != nil && page.picker != nil }
        let toggle = try XCTUnwrap(page.toggle, "the switch is drawn")
        let picker = try XCTUnwrap(page.picker, "the client picker is drawn")
        XCTAssertEqual(toggle.state, .off, "off until a person turns it on")
        XCTAssertFalse(picker.isEnabled)
        XCTAssertEqual(picker.itemTitles, ["Claude Code", "Other"])
        // SwiftUI draws the row's buttons itself, so the model says what they offer; the picker is AppKit's.
        XCTAssertEqual(setup.controls(toolsOn: false), .init(picker: false, action: false, copyCommand: false, hint: false))

        toggle.performClick(nil)
        await settle(page) { settings.settings.agentTools && page.picker?.isEnabled == true }
        XCTAssertTrue(settings.settings.agentTools, "the switch writes the setting")
        XCTAssertEqual(page.toggle?.state, .on)
        XCTAssertEqual(page.picker?.isEnabled, true)
        XCTAssertEqual(setup.controls(toolsOn: settings.settings.agentTools), .init(picker: true, action: true, copyCommand: true, hint: true))
        XCTAssertEqual(setup.action, .add)

        settings.update { $0.agentTools = false }
        await settle(page) { page.picker?.isEnabled == false }
        XCTAssertEqual(page.picker?.isEnabled, false, "dimmed again with the switch")
        XCTAssertTrue(mac.runs.isEmpty, "nothing ran on its own")
    }

    func testRemoveStaysAvailableWhileTheSwitchIsOff() async throws {
        let settings = try settings()
        let mac = FakeClientMac(installed: [.claudeCode: URL(fileURLWithPath: "/usr/local/bin/claude")], servers: [.claudeCode])
        let setup = MCPClientSetup(environment: mac.environment)
        let page = try page(settings, setup)
        await settle(page) { page.picker != nil }
        XCTAssertFalse(settings.settings.agentTools)
        XCTAssertEqual(page.picker?.isEnabled, true, "the picker Remove needs")
        XCTAssertEqual(setup.action, .remove)
        XCTAssertTrue(setup.controls(toolsOn: false).action, "Remove itself")
    }

    func testAHostsRowsFollowAgentHUDsOwnAndAHostPageOfTheSameNameJoinsThem() throws {
        let settings = try settings()
        let mac = FakeClientMac(installed: [:])
        let host = DesktopSettingsPage(id: "experimental", title: { "Experimental" }, subtitle: { "" }, symbol: "flask", color: .orange) {
            Text("Remote sessions")
        }
        let view = SettingsView(settings: settings, store: UsageStore(provider: DemoUsageProvider(), settings: settings),
                                initialTab: .experimental, additionalPages: [host],
                                experimentalSections: [DesktopSettingsSection(id: "phone") { Text("Phone approvals") }],
                                clientSetup: MCPClientSetup(environment: mac.environment))
        XCTAssertTrue(view.additionalPages.isEmpty, "no second Experimental page in the sidebar")
        XCTAssertEqual(view.experimentalSections.map(\.id), ["phone", "experimental"], "its rows go on the built-in page instead")
        XCTAssertEqual(SettingsTab.leading, [.general, .sources, .display])
        XCTAssertEqual(SettingsTab.allCases.last, .experimental, "Experimental comes after the host's pages")
    }
}
