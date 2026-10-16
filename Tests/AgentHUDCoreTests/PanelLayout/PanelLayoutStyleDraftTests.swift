import AgentHUDSupport
import XCTest
@testable import AgentHUDCore

/// A screen's style draft: an agent's change to its resting HUD, drawn over that screen's settings at once and written
/// into them only by a person's Save. A screen's versions cover its whole look, so Save and Revert to Previous take its
/// layout and its style together, and a person's own edit of the screen drops a waiting draft. The two resets are
/// `PanelLayoutResetTests`'.
@MainActor
final class PanelLayoutStyleDraftTests: XCTestCase {
    private let screen = "SCREEN-A", other = "SCREEN-B"
    private var changes = 0

    private func makeDefaults() -> UserDefaults {
        let suite = "AgentHUDTests.PanelLayoutStyle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    /// Settings of their own, whose changes the test counts.
    private func makeSettings(_ defaults: UserDefaults? = nil) -> SettingsStore {
        let settings = SettingsStore(defaults: defaults ?? makeDefaults())
        settings.onChange = { [weak self] _ in self?.changes += 1 }
        return settings
    }

    private func stored(_ defaults: UserDefaults) -> JSONValue? {
        defaults.data(forKey: SettingsStore.Keys.panelLayout).flatMap { try? JSONValue.parse($0) }
    }

    private let simple = HUDStyle(mode: .simple, simpleSize: 30, glow: HUDStyle.Glow(brightness: 0.5))

    // MARK: A draft

    /// A style draft is drawn over the screen's settings at once and writes nothing: not the settings, not the stored
    /// layouts. It is the screen's alone.
    func testADraftIsDrawnOverTheSettingsAndWritesNothing() throws {
        let defaults = makeDefaults()
        let settings = makeSettings(defaults)
        let layout = settings.panelLayout
        let before = settings.settings
        XCTAssertTrue(layout.proposeStyle(simple, for: screen, hasNotch: true))
        XCTAssertEqual(layout.styleDraft(of: screen), simple)
        XCTAssertTrue(layout.hasStyleDraft(screen))
        XCTAssertTrue(layout.hasDraft(on: screen), "the panel's bar shows for a style alone")
        XCTAssertNil(layout.draftScope(on: screen), "and no layout waits")
        XCTAssertEqual(layout.revision, 1)

        let drawn = settings.effectivePlacement(on: screen, hasNotch: true)
        XCTAssertEqual(drawn.mode, .simple)
        XCTAssertEqual(drawn.simpleSize, 30)
        XCTAssertEqual(settings.effectiveGlow(on: screen).brightness, 0.5)
        XCTAssertEqual(settings.effectivePlacement(on: other, hasNotch: true), .default(hasNotch: true), "the other screen")
        XCTAssertEqual(settings.effectiveGlow(on: other), settings.settings.glow)
        XCTAssertEqual(settings.effectiveGlow(on: nil), settings.settings.glow, "the default glow takes no draft")
        XCTAssertEqual(settings.settings, before)
        XCTAssertEqual(changes, 0)
        XCTAssertNil(stored(defaults), "a draft is not kept")

        XCTAssertFalse(layout.proposeStyle(HUDStyle(), for: screen, hasNotch: true), "an empty style is no draft")
        XCTAssertNil(layout.styleDraft(of: screen))
        XCTAssertFalse(layout.hasDraft(on: screen))
    }

    /// Discarding drops the style draft with the layout draft of the screen, and the settings never changed.
    func testDiscardDropsTheStyleWithTheLayoutDraft() {
        let settings = makeSettings()
        let layout = settings.panelLayout
        layout.proposeStyle(simple, for: screen, hasNotch: true)
        layout.propose(.own(PanelLayout(hiddenSections: [.tokens])), for: screen)
        layout.discardPanel(on: screen)
        XCTAssertNil(layout.styleDraft(of: screen))
        XCTAssertNil(layout.draft(of: screen))
        XCTAssertEqual(settings.effectivePlacement(on: screen, hasNotch: true), .default(hasNotch: true))
        XCTAssertEqual(changes, 0)

        layout.proposeStyle(simple, for: screen, hasNotch: true)
        layout.discard(.shared)
        XCTAssertNotNil(layout.styleDraft(of: screen), "the shared layout's discard leaves a screen's style")
        layout.discard(.screen(screen))
        XCTAssertNil(layout.styleDraft(of: screen))
    }

    /// A person always wins: an edit of the screen in Settings, or dragging its HUD, drops the draft first and makes the
    /// change to what is saved. An edit is no version.
    func testAPersonsEditDropsTheDraftFirst() {
        let settings = makeSettings()
        let layout = settings.panelLayout
        layout.proposeStyle(simple, for: screen, hasNotch: true)
        layout.proposeStyle(HUDStyle(logoSize: 30), for: other, hasNotch: false)
        settings.updateScreen(screen) {
            var next = $0.placement(on: screen, hasNotch: true)
            next.mode = .logos
            $0.screens[screen] = next
        }
        XCTAssertNil(layout.styleDraft(of: screen))
        XCTAssertEqual(settings.settings.screens[screen]?.mode, .logos)
        XCTAssertEqual(settings.settings.screens[screen]?.simpleSize, ScreenPlacement().simpleSize, "nothing of the draft is kept")
        XCTAssertNil(settings.settings.screenGlow[screen])
        XCTAssertEqual(changes, 1)
        XCTAssertNotNil(layout.styleDraft(of: other), "another screen's draft waits")
        XCTAssertFalse(layout.canRevert(.screen(screen)), "an edit is no version")
    }

    // MARK: Save

    /// Save writes the style into the settings with one change, and the screen's style before it is kept with the
    /// previous version; the draft is gone and the screen draws what was saved.
    func testSaveWritesTheStyleIntoTheSettingsOnce() throws {
        let defaults = makeDefaults()
        let settings = makeSettings(defaults)
        let layout = settings.panelLayout
        layout.proposeStyle(simple, for: screen, hasNotch: true)
        let drawn = settings.effectivePlacement(on: screen, hasNotch: true), glow = settings.effectiveGlow(on: screen)
        layout.savePanel(on: screen)
        XCTAssertEqual(changes, 1, "one settings change")
        XCTAssertNil(layout.styleDraft(of: screen))
        XCTAssertFalse(layout.hasDraft(on: screen))
        XCTAssertEqual(settings.settings.screens[screen], drawn)
        XCTAssertEqual(settings.settings.screenGlow[screen], glow)
        XCTAssertEqual(settings.effectivePlacement(on: screen, hasNotch: true), drawn)
        XCTAssertTrue(layout.canRevert(.screen(screen)), "the style before is the previous version")
        XCTAssertTrue(layout.usesShared(screen), "a style alone leaves the screen on the shared layout")

        let side = try XCTUnwrap(stored(defaults)?["screens"][screen].objectValue)
        XCTAssertEqual(side["previous"], .string("shared"))
        XCTAssertEqual(side["previousStyle"], .object([:]), "the screen had no style of its own before")
    }

    /// A style that changes only the placement leaves the screen drawing the default glow, and one that changes only
    /// the glow keeps the placement it draws by default: nothing the style leaves is written.
    func testSaveWritesOnlyThePartsTheStyleChanges() {
        let settings = makeSettings()
        let layout = settings.panelLayout
        layout.proposeStyle(HUDStyle(logoSize: 30), for: screen, hasNotch: false)
        layout.save(.screen(screen))
        XCTAssertEqual(settings.settings.screens[screen], ScreenPlacement(logoSize: 30))
        XCTAssertNil(settings.settings.screenGlow[screen], "the default glow stays the default")

        layout.proposeStyle(HUDStyle(glow: HUDStyle.Glow(style: .dots)), for: other, hasNotch: true)
        layout.save(.screen(other))
        XCTAssertNil(settings.settings.screens[other], "the placement the hardware is given stays")
        XCTAssertEqual(settings.settings.screenGlow[other]?.style, .dots)
    }

    /// A layout draft and a style draft of one screen are one version: Save keeps both, and the previous version is the
    /// layout and the style the screen had before.
    func testALayoutAndAStyleAreSavedAsOneVersion() {
        let settings = makeSettings()
        let layout = settings.panelLayout
        let own = PanelLayout(hiddenSections: [.tokens])
        settings.update { $0.screens[screen] = ScreenPlacement(mode: .logos, logoSize: 20) }
        changes = 0
        layout.propose(.own(own), for: screen)
        layout.proposeStyle(HUDStyle(logoSize: 32), for: screen, hasNotch: false)
        let revision = layout.revision
        layout.savePanel(on: screen)
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(layout.revision, revision + 1, "one change to the documents")
        XCTAssertEqual(layout.ownLayout(of: screen), own)
        XCTAssertEqual(settings.settings.screens[screen]?.logoSize, 32)

        layout.revert(.screen(screen))
        XCTAssertTrue(layout.usesShared(screen), "the layout before")
        XCTAssertEqual(settings.settings.screens[screen]?.logoSize, 20, "and the style before")
        XCTAssertEqual(changes, 2)
        layout.revert(.screen(screen))
        XCTAssertEqual(layout.ownLayout(of: screen), own, "reverting again undoes it")
        XCTAssertEqual(settings.settings.screens[screen]?.logoSize, 32)
    }

    /// The panel's bar on a screen that draws the shared layout saves the shared draft it shows and the screen's
    /// style: the shared layout's version and the screen's.
    func testTheBarSavesASharedDraftAndTheScreensStyle() {
        let settings = makeSettings()
        let layout = settings.panelLayout
        layout.propose(PanelLayout(style: PanelStyle(width: 600)))
        layout.proposeStyle(HUDStyle(mode: .simple), for: screen, hasNotch: false)
        XCTAssertEqual(layout.draftScope(on: screen), .shared)
        layout.savePanel(on: screen)
        XCTAssertEqual(layout.current.style.panelWidth, 600)
        XCTAssertEqual(settings.settings.screens[screen]?.mode, .simple)
        XCTAssertFalse(layout.hasDraft(on: screen))
    }

    // MARK: Revert

    /// Revert to Previous takes back the style a Save wrote, and an edit made since is no version: it is what reverting
    /// again returns to.
    func testRevertTakesTheStyleBack() {
        let settings = makeSettings()
        let layout = settings.panelLayout
        layout.proposeStyle(HUDStyle(glow: HUDStyle.Glow(style: .ascii)), for: screen, hasNotch: true)
        layout.save(.screen(screen))
        settings.updateScreen(screen) { $0.screenGlow[screen]?.brightness = 0.4 }
        changes = 0
        layout.revert(.screen(screen))
        XCTAssertNil(settings.settings.screenGlow[screen], "the screen draws the default glow again")
        XCTAssertEqual(changes, 1)
        layout.revert(.screen(screen))
        XCTAssertEqual(settings.settings.screenGlow[screen]?.style, .ascii)
        XCTAssertEqual(settings.settings.screenGlow[screen]?.brightness, 0.4, "the look it had when it was reverted from")
    }

    /// An agent's proposal of the previous version waits as a draft that draws that version's look whole, a glow's grid
    /// that no agent sets included, and lists what an agent can read of it; Save writes it back as it was kept.
    func testProposingThePreviousVersionDrawsAndSavesItsLookWhole() {
        let settings = makeSettings()
        let layout = settings.panelLayout
        var glow = GlowSettings()
        glow.style = .dots
        glow.gridPitch = 6
        settings.update { $0.screenGlow[screen] = glow }
        layout.proposeStyle(HUDStyle(glow: HUDStyle.Glow(style: .ascii)), for: screen, hasNotch: true)
        layout.save(.screen(screen))
        settings.updateScreen(screen) { $0.screenGlow[screen]?.gridPitch = 10 }
        changes = 0

        XCTAssertTrue(layout.proposePrevious(.screen(screen), hasNotch: true))
        XCTAssertEqual(layout.styleDraft(of: screen), HUDStyle(glow: HUDStyle.Glow(style: .dots)))
        XCTAssertEqual(settings.effectiveGlow(on: screen), glow, "drawn whole, the grid included")
        XCTAssertEqual(changes, 0)
        layout.save(.screen(screen))
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(settings.settings.screenGlow[screen], glow)
        XCTAssertNil(settings.settings.screens[screen], "no placement of its own, as in that version")
        layout.revert(.screen(screen))
        XCTAssertEqual(settings.settings.screenGlow[screen]?.gridPitch, 10, "the look it replaced is kept")

        // Without a screen to draw on, the version's style is left as saved and no style draft waits.
        XCTAssertFalse(layout.proposePrevious(.screen(screen), hasNotch: nil), "the same layout, and no style draft")
        XCTAssertNil(layout.styleDraft(of: screen))
    }

    /// Using the shared layout again drops a style draft and leaves the style as saved.
    func testUsingTheSharedLayoutLeavesTheStyle() {
        let settings = makeSettings()
        let layout = settings.panelLayout
        layout.propose(.own(PanelLayout(hiddenSections: [.sessions])), for: screen)
        layout.proposeStyle(HUDStyle(logoSize: 30), for: screen, hasNotch: false)
        layout.save(.screen(screen))
        layout.proposeStyle(HUDStyle(logoSize: 16), for: screen, hasNotch: false)
        layout.useShared(screen)
        XCTAssertNil(layout.styleDraft(of: screen))
        XCTAssertEqual(settings.settings.screens[screen]?.logoSize, 30)
        XCTAssertTrue(layout.usesShared(screen))
    }

    // MARK: Across a relaunch

    /// The previous style is kept beside the layout, so Revert to Previous works after a relaunch; a draft is not.
    func testThePreviousStyleOutlivesARelaunchAndADraftDoesNot() throws {
        let defaults = makeDefaults()
        let first = makeSettings(defaults)
        first.update { $0.screens[screen] = ScreenPlacement(mode: .simple, simpleSize: 20) }
        first.panelLayout.proposeStyle(HUDStyle(simpleSize: 34, showNumbers: false), for: screen, hasNotch: false)
        first.panelLayout.save(.screen(screen))
        first.panelLayout.proposeStyle(HUDStyle(simpleSize: 40), for: screen, hasNotch: false)

        let side = try XCTUnwrap(stored(defaults)?["screens"][screen]["previousStyle"]["placement"].objectValue)
        XCTAssertEqual(side["simpleSize"], .integer(20))

        let second = makeSettings(defaults)
        XCTAssertNil(second.panelLayout.styleDraft(of: screen), "a draft is dropped on relaunch")
        XCTAssertEqual(second.settings.screens[screen]?.simpleSize, 34)
        XCTAssertTrue(second.panelLayout.canRevert(.screen(screen)))
        second.panelLayout.revert(.screen(screen))
        XCTAssertEqual(second.settings.screens[screen]?.simpleSize, 20)
        XCTAssertEqual(second.settings.screens[screen]?.showsNumbers, true)
    }

    /// A previous style that cannot be read is none, and loses nothing else of the screen.
    func testAPreviousStyleThatCannotBeReadIsNone() {
        let defaults = makeDefaults()
        let json = #"{"screens":{"A":{"current":{"hiddenSections":["tokens"]},"previous":"shared","previousStyle":{"glow":7}}}}"#
        defaults.set(Data(json.utf8), forKey: SettingsStore.Keys.panelLayout)
        let store = PanelLayoutStore(defaults: defaults)
        XCTAssertEqual(store.ownLayout(of: "A"), PanelLayout(hiddenSections: [.tokens]))
        XCTAssertEqual(store.previous(of: "A"), .shared)
        XCTAssertNil(store.screens["A"]?.previousLook)
    }
}
