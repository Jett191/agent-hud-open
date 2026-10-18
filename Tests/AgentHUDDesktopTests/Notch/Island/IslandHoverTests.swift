import AppKit
import SwiftUI
import XCTest
import AgentHUDCore
@testable import AgentHUDDesktop

/// Island rows and their native tracking anchors in a non-key panel.
final class IslandHoverTests: XCTestCase {
    @MainActor
    func testForecastAndResetPopupsFollowThePointerWithoutFocus() async throws {
        _ = NSApplication.shared
        let domain = "app.agenthud.tests.hover.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = SettingsStore(defaults: defaults, defaultAgents: DemoData.agents)
        let store = UsageStore(provider: DemoUsageProvider(), settings: settings)
        let now = Date()
        let agents = [
            AgentDescriptor(id: "session", vendor: "Claude", model: L10n.windowSession, source: "Test", enabled: true),
            AgentDescriptor(id: "weekly", vendor: "Claude", model: L10n.windowWeekly, source: "Test", enabled: true),
            AgentDescriptor(id: "fable", vendor: "Claude", model: L10n.windowWeeklyPrefix + "Fable", source: "Test", enabled: true),
            AgentDescriptor(id: "codex", vendor: "Codex", model: L10n.windowWeekly, source: "Test", enabled: true),
        ]
        settings.updateAgents { _ in agents }
        settings.panelLayout.setSwitches { $0.quotaDetails = true; $0.tokenUsage = false; $0.sessionList = false; $0.resetCountdown = true }
        let snapshots = agents.enumerated().map { index, agent in
            UsageSnapshot(agentId: agent.id, remainingPct: [67, 80, 60, 0][index],
                          resetAt: now.addingTimeInterval(index == 0 ? 5 * 3600 : 24 * 3600),
                          windowDuration: index == 0 ? 5 * 3600 : 7 * 86400, updatedAt: now)
        }
        func insights(rate: Double, remaining: Double) -> UsageInsights {
            UsageInsights(burnRatePctPerHour: rate, timeToExhaust: BurnRate(pctPerHour: rate).timeToExhaust(remainingPct: remaining),
                          weeklyCapHits: 0, weeklyWaitTotal: 0, weeklyWaitLongest: 0, weeklyWaitLongestAt: nil)
        }
        store.replace(report: UsageReport(generatedAt: now, snapshots: snapshots, sessions: [],
            insightsByAgent: ["session": insights(rate: 30, remaining: 67), "weekly": insights(rate: 1, remaining: 80)],
            codexResetCredits: DemoData.codexResetCredits(now: now)))

        func root(open: Bool) -> IslandRootView {
            IslandRootView(store: store, isOpen: open, collapsedSize: CGSize(width: 216, height: 32), collapsedTopRadius: 16,
                           collapsedBottomRadius: 12, look: .standard, lightBorder: false, onOpenStats: {})
        }
        let measured = NSHostingView(rootView: HoverPanelView(store: store, onOpenStats: {})
            .frame(width: IslandController.expandedWidth).fixedSize(horizontal: false, vertical: true))
        let size = CGSize(width: IslandController.expandedWidth + 2 * NotchGeometry.expandedTopRadius, height: measured.fittingSize.height)
        let window = OverlayPanel(frame: CGRect(origin: CGPoint(x: -20000, y: -20000), size: size), level: .statusBar, acceptsMouse: true)
        let hosting = NSHostingView(rootView: root(open: true))
        hosting.sizingOptions = []
        hosting.frame = CGRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        await settle(hosting)
        XCTAssertFalse(window.isKeyWindow || window.canBecomeKey, "Hover must work without keyboard focus")

        let anchors: [IslandHoverAnchorView<QuotaForecastDetails>] = descendants(in: hosting)
            .sorted { $0.convert($0.bounds, to: nil).midY > $1.convert($1.bounds, to: nil).midY }
        XCTAssertEqual(anchors.count, agents.count, "Every timed model row needs an island hover anchor")
        for (agent, anchor) in zip(agents, anchors) {
            let popup = try await enter(anchor, in: window)
            let details = try XCTUnwrap(popup.contentView as? NSHostingView<ModifiedContent<QuotaForecastDetails, HUDLookEnvironment>>)
            XCTAssertEqual(details.rootView.content.agent.id, agent.id, "The hovered row must use its own forecast")
            XCTAssertEqual(details.rootView.modifier.look, .standard, "The popup draws in the look of the island it opens from")
            XCTAssertEqual(popup.appearance?.name, HUDLook.standard.appearanceName)
            checkFollowsPointer(anchor, popup: popup, in: window)
            await leave(anchor, popup: popup, in: window)
        }

        let resets: [IslandHoverAnchorView<ResetCreditsDetails>] = descendants(in: hosting)
        XCTAssertEqual(resets.count, 1, "Reset credits keep the shared hover behaviour")
        let resetAnchor = try XCTUnwrap(resets.first)
        let resetPopup = try await enter(resetAnchor, in: window)
        await leave(resetAnchor, popup: resetPopup, in: window)

        let popup = try await enter(try XCTUnwrap(anchors.first), in: window)
        hosting.rootView = root(open: false)
        await settle(hosting)
        try await Task.sleep(for: .milliseconds(450))
        await settle(hosting)
        XCTAssertFalse(popup.isVisible || popup.parent != nil, "Collapsing the island must dismiss the forecast")
    }

    /// A row's hover details cast a shadow on an opaque island and none on one the desktop shows through, glass or a
    /// solid with a transparency, where a shadow under them would darken them, as the HUD keeps shadows from under its
    /// own see-through shells. The details take a change of look where they are, the shadow with it.
    @MainActor
    func testHoverDetailsCastAShadowOnlyOnAnOpaqueIsland() throws {
        _ = NSApplication.shared
        let size = CGSize(width: 240, height: 40)
        func shown(_ look: HUDLook) throws -> (anchor: IslandHoverAnchorView<Text>, popup: NSWindow, window: NSWindow) {
            let window = OverlayPanel(frame: CGRect(origin: CGPoint(x: -20000, y: -20000), size: size), level: .statusBar,
                                      acceptsMouse: true)
            let anchor = IslandHoverAnchorView(content: Text("Details"), look: look)
            anchor.frame = CGRect(origin: .zero, size: size)
            let container = NSView(frame: CGRect(origin: .zero, size: size))
            container.addSubview(anchor)
            window.contentView = container
            window.orderFrontRegardless()
            anchor.mouseLocation = { [weak window] in window?.convertPoint(toScreen: CGPoint(x: 20, y: 20)) ?? .zero }
            anchor.mouseEntered(with: try event(.mouseEntered, window: window, at: CGPoint(x: 20, y: 20)))
            anchor.update(content: Text("Details"), look: look, enabled: true, isHovered: true)
            let popup = try XCTUnwrap(window.childWindows?.first, "hovering a row shows its details")
            return (anchor, popup, window)
        }
        let looks: [(String, HUDLook)] = [
            ("the standard look", .standard),
            ("light and opaque", HUDLook(appearance: .light)),
            ("solid with a transparency", HUDLook(appearance: .dark, transparency: 0.3)),
            ("glass at 0", HUDLook(appearance: .light, material: .glass)),
            ("glass at 0.5", HUDLook(appearance: .dark, material: .glass, transparency: 0.5, glassStyle: .regular)),
        ]
        for (name, look) in looks {
            let (anchor, popup, window) = try shown(look)
            defer {
                anchor.dismiss()
                window.orderOut(nil)
            }
            XCTAssertEqual(popup.hasShadow, !look.seeThrough, "\(name): made in it")
            for (other, next) in looks {
                anchor.update(content: Text("Details"), look: next, enabled: true, isHovered: true)
                XCTAssertTrue(window.childWindows?.first === popup, "\(name) to \(other): the same details")
                XCTAssertEqual(popup.hasShadow, !next.seeThrough, "\(name) to \(other)")
            }
        }
        XCTAssertTrue(looks.contains { !$0.1.seeThrough } && looks.contains { $0.1.seeThrough }, "both kinds are tried")
    }

    @MainActor
    func testMovingTheWindowUnderAStillPointerDismissesAMissedExitAfterTheUpdate() async throws {
        _ = NSApplication.shared
        let size = CGSize(width: 240, height: 40)
        let window = OverlayPanel(frame: CGRect(origin: CGPoint(x: -20000, y: -20000), size: size), level: .statusBar,
                                  acceptsMouse: true)
        let anchor = IslandHoverAnchorView(content: Text("Details"), look: .standard)
        anchor.frame = CGRect(origin: .zero, size: size)
        window.contentView = anchor
        window.orderFrontRegardless()
        defer { anchor.dismiss(); window.orderOut(nil) }
        let point = CGPoint(x: 20, y: 20), screenPoint = window.convertPoint(toScreen: point)
        anchor.mouseLocation = { screenPoint }
        var hoverChanges: [Bool] = []
        anchor.onHover = { hoverChanges.append($0) }
        anchor.mouseEntered(with: try event(.mouseEntered, window: window, at: point))
        anchor.update(content: Text("Details"), look: .standard, enabled: true, isHovered: true)
        let popup = try XCTUnwrap(window.childWindows?.first)
        XCTAssertTrue(popup.isVisible)

        // No mouseExited arrives when the entire window moves away from an unmoved screen pointer.
        window.setFrameOrigin(window.frame.origin.applying(CGAffineTransform(translationX: 500, y: 0)))
        anchor.update(content: Text("Details"), look: .standard, enabled: true, isHovered: true)
        XCTAssertFalse(popup.isVisible || popup.parent != nil, "dismiss the stale popup in this update")
        XCTAssertEqual(hoverChanges, [true], "do not publish a SwiftUI state change during the native view update")
        await settle(anchor)
        XCTAssertEqual(hoverChanges, [true, false], "reconcile the binding after the view update")
    }

    @MainActor
    func testANewEnterWinsOverADeferredMissedExit() async throws {
        _ = NSApplication.shared
        let window = OverlayPanel(frame: CGRect(x: -20000, y: -20000, width: 240, height: 40), level: .statusBar,
                                  acceptsMouse: true)
        let anchor = IslandHoverAnchorView(content: Text("Details"), look: .standard)
        anchor.frame = CGRect(x: 0, y: 0, width: 240, height: 40)
        window.contentView = anchor
        window.orderFrontRegardless()
        defer { anchor.dismiss(); window.orderOut(nil) }
        var hoverChanges: [Bool] = []
        anchor.onHover = { hoverChanges.append($0) }
        let inside = CGPoint(x: 20, y: 20)
        anchor.mouseLocation = { [weak window] in window?.convertPoint(toScreen: CGPoint(x: 500, y: 20)) ?? .zero }
        anchor.mouseEntered(with: try event(.mouseEntered, window: window, at: inside))
        anchor.update(content: Text("Details"), look: .standard, enabled: true, isHovered: true)
        anchor.mouseEntered(with: try event(.mouseEntered, window: window, at: inside))
        await settle(anchor)
        XCTAssertEqual(hoverChanges, [true, true], "a newer enter must not be cleared by the deferred exit")
    }

    @MainActor
    private func enter<Content: View>(_ anchor: IslandHoverAnchorView<Content>, in window: NSWindow) async throws -> NSWindow {
        anchor.updateTrackingAreas()
        XCTAssertTrue(anchor.trackingAreas.contains { $0.options.contains([.activeAlways, .mouseMoved]) },
                      "Pointer tracking must stay active outside the key window")
        let originalSize = window.frame.size
        let point = anchor.convert(CGPoint(x: anchor.bounds.minX + 12, y: anchor.bounds.midY), to: nil)
        anchor.mouseLocation = { [weak window] in window?.convertPoint(toScreen: point) ?? .zero }
        anchor.mouseEntered(with: try event(.mouseEntered, window: window, at: point))
        await settle(try XCTUnwrap(window.contentView))
        let popup = try XCTUnwrap(window.childWindows?.first, "Entering a row must show an island popup")
        XCTAssertTrue(popup.isVisible, "Entering a row must show an island popup")
        XCTAssertTrue(window.frame.size == originalSize && !window.isKeyWindow, "Hover must not resize or focus the island")
        return popup
    }

    @MainActor
    private func checkFollowsPointer<Content: View>(_ anchor: IslandHoverAnchorView<Content>, popup: NSWindow, in window: NSWindow) {
        for x in [24.0, 120.0] {
            let point = anchor.convert(CGPoint(x: anchor.bounds.minX + x, y: anchor.bounds.midY), to: nil)
            guard let moved = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else {
                return XCTFail("Could not create a mouse event")
            }
            anchor.mouseMoved(with: moved)
            let screenPoint = window.convertPoint(toScreen: point)
            XCTAssertEqual(popup.frame.minX, screenPoint.x + 10, accuracy: 1, "The popup stays beside the pointer, not at the row's edge")
            XCTAssertEqual(popup.frame.maxY, screenPoint.y - 12, accuracy: 1)
        }
    }

    @MainActor
    private func leave<Content: View>(_ anchor: IslandHoverAnchorView<Content>, popup: NSWindow, in window: NSWindow) async {
        guard let exited = try? event(.mouseExited, window: window), let content = window.contentView else {
            return XCTFail("Could not leave the row")
        }
        anchor.mouseExited(with: exited)
        await settle(content)
        XCTAssertFalse(popup.isVisible || popup.parent != nil, "Leaving a row must dismiss its popup")
    }

    @MainActor
    private func event(_ type: NSEvent.EventType, window: NSWindow, at point: CGPoint = .zero) throws -> NSEvent {
        try XCTUnwrap(NSEvent.enterExitEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
    }

    @MainActor
    private func settle(_ view: NSView) async {
        view.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(100))
        view.window?.displayIfNeeded()
    }

    @MainActor
    private func descendants<T: NSView>(in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(in: $0) }
    }
}
