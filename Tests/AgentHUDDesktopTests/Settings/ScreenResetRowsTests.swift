import XCTest
import AgentHUDCore
@testable import AgentHUDDesktop

/// A display's two Reset to Default buttons in Settings → Display → Screens: the Panel layout row's resets the layout
/// alone and the HUD style row's the placement and glow alone, each offered only while it has something to reset, and
/// the Panel layout row's Revert to Previous undoes either.
@MainActor
final class ScreenResetRowsTests: XCTestCase {
    private let screen = "SCREEN-A"
    private let own = PanelLayout(hiddenSections: [.tokens])

    private func makeSettings() -> SettingsStore {
        let suite = "app.agenthud.tests.screen-resets.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return SettingsStore(defaults: defaults)
    }

    /// The layout's Reset to Default is offered for a layout of the display's own that is not the default view, or a
    /// draft, and rests on the default view, whatever the style; a click resets the layout and leaves the style.
    func testTheLayoutsResetIsOfferedForALayoutToReset() {
        let settings = makeSettings()
        let layout = settings.panelLayout
        let row = ScreenLayoutRow(layout: layout, screen: screen)
        XCTAssertFalse(row.hasOwn, "on the shared layout the row offers no reset")

        layout.propose(.own(own), for: screen)
        XCTAssertTrue(row.hasOwn)
        XCTAssertTrue(row.canReset, "a draft of its own")
        layout.save(.screen(screen))
        XCTAssertTrue(row.canReset, "a layout of its own")

        settings.update { $0.screens[screen] = ScreenPlacement(mode: .simple, simpleSize: 30) }
        let saved = settings.settings
        row.reset()
        XCTAssertEqual(layout.ownLayout(of: screen), PanelLayout())
        XCTAssertEqual(settings.settings, saved, "the style stays")
        XCTAssertFalse(row.canReset, "the default view rests the button")
        layout.proposeStyle(HUDStyle(simpleSize: 34), for: screen, hasNotch: false)
        XCTAssertFalse(row.canReset, "a style draft is the style row's to reset")
        layout.discardStyle(screen)

        XCTAssertTrue(layout.canRevert(.screen(screen)))
        layout.revert(.screen(screen))
        XCTAssertEqual(layout.ownLayout(of: screen), own, "Revert to Previous undoes it")
        XCTAssertEqual(settings.settings, saved)
    }

    /// The HUD style's Reset to Default is offered while the display keeps a placement or a glow of its own, or an
    /// agent's unsaved style shows on it, and rests otherwise; a click gives it the defaults and leaves the layout.
    func testTheStylesResetIsOfferedForAStyleToReset() {
        let settings = makeSettings()
        let layout = settings.panelLayout
        let row = ScreenStyleRow(settings: settings, screen: screen)
        XCTAssertFalse(row.canReset, "the defaults")

        layout.proposeStyle(HUDStyle(mode: .simple), for: screen, hasNotch: false)
        XCTAssertTrue(row.canReset, "an agent's unsaved style")
        row.reset()
        XCTAssertNil(layout.styleDraft(of: screen), "dropped")
        XCTAssertFalse(row.canReset)
        XCTAssertFalse(layout.canRevert(.screen(screen)), "nothing saved changed, so no version")

        var glow = GlowSettings()
        glow.style = .dots
        settings.update { $0.screenGlow[screen] = glow }
        XCTAssertTrue(row.canReset, "a glow of its own")
        settings.update {
            $0.screenGlow[screen] = nil
            $0.screens[screen] = ScreenPlacement(mode: .simple)
        }
        XCTAssertTrue(row.canReset, "a placement of its own")

        layout.propose(.own(own), for: screen)
        layout.save(.screen(screen))
        settings.update { $0.screenGlow[screen] = glow }
        row.reset()
        XCTAssertNil(settings.settings.screens[screen])
        XCTAssertNil(settings.settings.screenGlow[screen])
        XCTAssertEqual(layout.ownLayout(of: screen), own, "the layout stays")
        XCTAssertFalse(row.canReset)

        layout.revert(.screen(screen))
        XCTAssertEqual(settings.settings.screens[screen], ScreenPlacement(mode: .simple), "Revert to Previous undoes it")
        XCTAssertEqual(settings.settings.screenGlow[screen], glow)
        XCTAssertEqual(layout.ownLayout(of: screen), own)
        XCTAssertTrue(row.canReset)
    }
}
