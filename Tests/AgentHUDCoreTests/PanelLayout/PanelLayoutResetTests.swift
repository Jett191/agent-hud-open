import AgentHUDSupport
import XCTest
@testable import AgentHUDCore

/// A screen's two resets: Reset to Default of its panel layout gives it the default view and leaves its HUD style, and
/// Reset to Default of its HUD style gives it the default placement and glow and leaves its layout. Each keeps what it
/// replaces as the previous version, so Revert to Previous undoes either. An agent proposes each apart, as a draft.
@MainActor
final class PanelLayoutResetTests: XCTestCase {
    private let screen = "SCREEN-A"
    private var changes = 0
    private let own = PanelLayout(blocks: ["Claude": PanelLayout.Block(widget: .ring)], hiddenSections: [.tokens])

    private func makeDefaults() -> UserDefaults {
        let suite = "AgentHUDTests.PanelLayoutReset.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    /// Settings of their own, whose changes the test counts, where the screen keeps a Dynamic dock with 28 pt logos and a
    /// glow of 30 pt reach, and a layout of its own saved over the shared one.
    private func makeSettings(_ defaults: UserDefaults? = nil) -> SettingsStore {
        let settings = SettingsStore(defaults: defaults ?? makeDefaults())
        settings.update {
            $0.screens[screen] = ScreenPlacement(mode: .logos, logoSize: 28)
            var glow = GlowSettings()
            glow.range = 30
            $0.screenGlow[screen] = glow
        }
        settings.panelLayout.propose(.own(own), for: screen)
        settings.panelLayout.save(.screen(screen))
        settings.onChange = { [weak self] _ in self?.changes += 1 }
        return settings
    }

    private func stored(_ defaults: UserDefaults) -> JSONValue? {
        defaults.data(forKey: SettingsStore.Keys.panelLayout).flatMap { try? JSONValue.parse($0) }
    }

    // MARK: The layout's reset

    /// The layout's Reset to Default gives the screen the default view as its own layout and never touches its style:
    /// the settings are not written, the previous version is the layout it replaced with the same style, and a waiting
    /// draft, a style draft included, is dropped. Revert to Previous brings the layout back, the style as it was.
    func testResettingTheLayoutLeavesTheStyle() throws {
        let defaults = makeDefaults()
        let settings = makeSettings(defaults)
        let layout = settings.panelLayout
        let saved = settings.settings
        layout.propose(.own(PanelLayout(hiddenSections: [.sessions])), for: screen)
        layout.proposeStyle(HUDStyle(logoSize: 36), for: screen, hasNotch: false)
        let revision = layout.revision

        layout.reset(.screen(screen))
        XCTAssertEqual(layout.ownLayout(of: screen), PanelLayout())
        XCTAssertNil(layout.draft(of: screen), "a layout draft is dropped")
        XCTAssertNil(layout.styleDraft(of: screen), "and a style draft")
        XCTAssertEqual(layout.revision, revision + 1, "one change")
        XCTAssertEqual(settings.settings, saved, "the style is left as saved")
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(layout.previous(of: screen), .own(own))
        let side = try XCTUnwrap(stored(defaults)?["screens"][screen].objectValue)
        XCTAssertNil(side["previousStyle"], "the version before had the style the screen has now")

        layout.revert(.screen(screen))
        XCTAssertEqual(layout.ownLayout(of: screen), own)
        XCTAssertEqual(settings.settings, saved, "Revert brings the layout back and the style stays")
        XCTAssertEqual(changes, 0)
        layout.revert(.screen(screen))
        XCTAssertEqual(layout.ownLayout(of: screen), PanelLayout(), "reverting again undoes it")

        // Resetting the default view changes nothing and keeps the version before.
        let again = layout.revision
        layout.reset(.screen(screen))
        XCTAssertEqual(layout.revision, again)
        XCTAssertEqual(layout.previous(of: screen), .own(own))
    }

    // MARK: The style's reset

    /// The HUD style's Reset to Default drops a style draft first, writes the default placement and glow in one change
    /// of the settings and leaves the layout, saved and as a draft. The style it replaces is kept with the previous
    /// version, beside the same layout and across a relaunch, so Revert to Previous brings it back.
    func testResettingTheStyleLeavesTheLayout() throws {
        let defaults = makeDefaults()
        let settings = makeSettings(defaults)
        let layout = settings.panelLayout
        let saved = settings.settings
        let waiting = PanelLayout(hiddenSections: [.sessions])
        layout.propose(.own(waiting), for: screen)
        layout.proposeStyle(HUDStyle(logoSize: 36), for: screen, hasNotch: false)
        let revision = layout.revision

        layout.resetLook(screen)
        XCTAssertNil(layout.styleDraft(of: screen), "a style draft is dropped first")
        XCTAssertNil(settings.settings.screens[screen])
        XCTAssertNil(settings.settings.screenGlow[screen])
        XCTAssertEqual(settings.effectivePlacement(on: screen, hasNotch: false), .default(hasNotch: false))
        XCTAssertEqual(settings.effectiveGlow(on: screen), settings.settings.glow)
        XCTAssertEqual(changes, 1, "one settings change")
        XCTAssertEqual(layout.revision, revision + 1, "one change to the documents")
        XCTAssertEqual(layout.ownLayout(of: screen), own, "the layout stays")
        XCTAssertEqual(layout.draft(of: screen), .own(waiting), "and so does its draft")
        XCTAssertEqual(layout.previous(of: screen), .own(own), "the version before is the same layout")
        let side = try XCTUnwrap(stored(defaults)?["screens"][screen].objectValue)
        XCTAssertEqual(side["previousStyle"]?["placement"]["logoSize"], .integer(28))
        XCTAssertEqual(side["previousStyle"]?["glow"]["range"], .integer(30))

        let relaunched = SettingsStore(defaults: defaults)
        XCTAssertTrue(relaunched.panelLayout.canRevert(.screen(screen)))
        relaunched.panelLayout.revert(.screen(screen))
        XCTAssertEqual(relaunched.settings.screens[screen], saved.screens[screen], "Revert brings the style back")
        XCTAssertEqual(relaunched.settings.screenGlow[screen], saved.screenGlow[screen])
        XCTAssertEqual(relaunched.panelLayout.ownLayout(of: screen), own, "the layout as it was")
        relaunched.panelLayout.revert(.screen(screen))
        XCTAssertNil(relaunched.settings.screens[screen], "reverting again undoes it")
        XCTAssertNil(relaunched.settings.screenGlow[screen])
    }

    /// On a screen that uses the shared layout, the style's reset keeps it on the shared layout, and Revert to
    /// Previous gives the style back and leaves it there.
    func testResettingTheStyleOfAScreenOnTheSharedLayout() {
        let settings = makeSettings()
        let layout = settings.panelLayout
        layout.useShared(screen)
        let saved = settings.settings
        layout.resetLook(screen)
        XCTAssertTrue(layout.usesShared(screen))
        XCTAssertNil(settings.settings.screens[screen])
        XCTAssertEqual(layout.previous(of: screen), .shared)
        layout.revert(.screen(screen))
        XCTAssertTrue(layout.usesShared(screen))
        XCTAssertEqual(settings.settings, saved)
    }

    /// A screen that already draws the defaults has no style to reset: the reset drops a waiting style draft and keeps
    /// the versions as they are, and writes nothing. A store without settings has none to reset either.
    func testResettingTheDefaultStyleChangesNothingButADraft() {
        let settings = makeSettings()
        let layout = settings.panelLayout
        layout.resetLook(screen)
        let previous = layout.previous(of: screen), count = changes, revision = layout.revision
        layout.resetLook(screen)
        XCTAssertEqual(layout.revision, revision)
        XCTAssertEqual(layout.previous(of: screen), previous)
        XCTAssertEqual(changes, count)

        layout.proposeStyle(HUDStyle(logoSize: 30), for: screen, hasNotch: false)
        layout.resetLook(screen)
        XCTAssertNil(layout.styleDraft(of: screen))
        XCTAssertEqual(layout.revision, revision + 2, "the draft and its drop")
        XCTAssertEqual(layout.previous(of: screen), previous)
        XCTAssertEqual(changes, count)

        let bare = PanelLayoutStore(defaults: makeDefaults())
        bare.proposeStyle(HUDStyle(logoSize: 30), for: screen, hasNotch: false)
        bare.resetLook(screen)
        XCTAssertNil(bare.styleDraft(of: screen))
        XCTAssertFalse(bare.canRevert(.screen(screen)))
    }

    // MARK: In turn

    /// The two resets one after the other, on a screen that uses the shared layout: each keeps the layout and the style
    /// the screen had just before it as the previous version, so Revert to Previous after a relaunch undoes the last
    /// one, in either order.
    func testEachResetInTurnKeepsWhatWasJustBefore() {
        let defaults = makeDefaults()
        let first = makeSettings(defaults)
        first.panelLayout.useShared(screen)
        let placement = first.settings.screens[screen], glow = first.settings.screenGlow[screen]

        first.panelLayout.reset(.screen(screen))
        first.panelLayout.resetLook(screen)
        let second = SettingsStore(defaults: defaults)
        XCTAssertEqual(second.panelLayout.ownLayout(of: screen), PanelLayout())
        XCTAssertNil(second.settings.screens[screen])
        second.panelLayout.revert(.screen(screen))
        XCTAssertEqual(second.settings.screens[screen], placement, "the style the style's reset replaced")
        XCTAssertEqual(second.settings.screenGlow[screen], glow)
        XCTAssertEqual(second.panelLayout.ownLayout(of: screen), PanelLayout(), "beside the layout it had then")

        second.panelLayout.useShared(screen)
        second.panelLayout.resetLook(screen)
        second.panelLayout.reset(.screen(screen))
        let third = SettingsStore(defaults: defaults)
        third.panelLayout.revert(.screen(screen))
        XCTAssertTrue(third.panelLayout.usesShared(screen), "the shared layout the layout's reset replaced")
        XCTAssertNil(third.settings.screens[screen], "beside the style it had then")
        XCTAssertNil(third.settings.screenGlow[screen])
    }

    // MARK: An agent's proposals

    /// The default layout proposed for a screen is its layout alone: a waiting style draft stays and the style as
    /// saved is drawn.
    func testTheDefaultLayoutIsProposedWithoutTheStyle() {
        let settings = makeSettings()
        let layout = settings.panelLayout
        layout.proposeStyle(HUDStyle(logoSize: 36), for: screen, hasNotch: false)
        XCTAssertTrue(layout.proposeDefault(.screen(screen)))
        XCTAssertEqual(layout.draft(of: screen), .own(PanelLayout()))
        XCTAssertEqual(layout.styleDraft(of: screen), HUDStyle(logoSize: 36))
        layout.discardStyle(screen)
        XCTAssertEqual(settings.effectivePlacement(on: screen, hasNotch: false).logoSize, 28)
        XCTAssertEqual(changes, 0)
    }

    /// The default style proposed for a screen is a style draft drawn as the defaults, listed by the fields that
    /// differ, beside the layout draft it leaves; Save writes it as the reset writes it, keeping the style before with
    /// the previous version. A screen that draws the defaults gets no draft.
    func testTheDefaultStyleIsProposedAsADraftAndSavedAsTheResetWritesIt() {
        let settings = makeSettings()
        let layout = settings.panelLayout
        let saved = settings.settings
        layout.propose(.own(PanelLayout(hiddenSections: [.sessions])), for: screen)
        XCTAssertTrue(layout.proposeDefaultLook(for: screen, hasNotch: false))
        XCTAssertEqual(layout.styleDraft(of: screen), HUDStyle(logoSize: ScreenPlacement().logoSize,
                                                               glow: HUDStyle.Glow(range: GlowSettings().range)))
        XCTAssertEqual(settings.effectivePlacement(on: screen, hasNotch: false), .default(hasNotch: false))
        XCTAssertEqual(settings.effectiveGlow(on: screen), settings.settings.glow)
        XCTAssertNotNil(layout.draft(of: screen), "the layout draft stays")
        XCTAssertEqual(changes, 0, "a proposal writes nothing")

        layout.save(.screen(screen))
        XCTAssertNil(settings.settings.screens[screen])
        XCTAssertNil(settings.settings.screenGlow[screen])
        XCTAssertEqual(changes, 1)
        layout.revert(.screen(screen))
        XCTAssertEqual(settings.settings, saved, "Revert brings the style back")
        XCTAssertEqual(layout.ownLayout(of: screen), own)

        layout.resetLook(screen)
        XCTAssertFalse(layout.proposeDefaultLook(for: screen, hasNotch: false), "already the defaults")
        XCTAssertNil(layout.styleDraft(of: screen))
    }
}
