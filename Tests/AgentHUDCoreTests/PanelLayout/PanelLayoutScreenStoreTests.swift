import Observation
import XCTest
@testable import AgentHUDCore

/// A layout per screen: a screen without one draws the shared layout, a screen with one draws it whole, and each
/// document has its own saved layout, previous layout and draft under one revision.
@MainActor
final class PanelLayoutScreenStoreTests: XCTestCase {
    private let rings = PanelLayout(blocks: ["Claude": PanelLayout.Block(widget: .ring)], order: ["Codex"])
    private let quiet = PanelLayout(blocks: ["Codex": PanelLayout.Block(hidden: true)], hiddenSections: [.sessions],
                                    style: PanelStyle(spacing: .compact))
    private let dock = PanelLayout(hud: PanelLayout.HUD(agents: ["Codex", "Claude"]))

    private func makeDefaults() -> UserDefaults {
        let suite = "AgentHUDTests.PanelLayoutScreens.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func stored(_ defaults: UserDefaults) -> String? {
        defaults.data(forKey: SettingsStore.Keys.panelLayout).map { String(decoding: $0, as: UTF8.self) }
    }

    /// A store whose shared layout is `quiet` and whose screen "A" keeps `rings` of its own, both saved.
    private func makeStore(in defaults: UserDefaults) -> PanelLayoutStore {
        let store = PanelLayoutStore(defaults: defaults)
        store.propose(quiet)
        store.save()
        store.propose(.own(rings), for: "A")
        store.save(.screen("A"))
        return store
    }

    // MARK: Reading a screen

    func testAScreenWithoutALayoutOfItsOwnDrawsTheSharedOne() {
        let store = PanelLayoutStore(defaults: makeDefaults())
        XCTAssertEqual(store.effective(for: "A"), PanelLayout())
        XCTAssertEqual(store.effective(for: nil), store.effective)
        XCTAssertTrue(store.usesShared("A"))
        XCTAssertNil(store.ownLayout(of: "A"))
        XCTAssertNil(store.draftScope(on: "A"))
        XCTAssertTrue(store.screenKeys.isEmpty)

        store.propose(quiet)
        XCTAssertEqual(store.effective(for: "A"), quiet, "the shared draft shows on every screen that uses it")
        XCTAssertEqual(store.effective(for: "B"), quiet)
        XCTAssertEqual(store.draftScope(on: "A"), .shared, "and its bar acts on the shared layout")
        XCTAssertTrue(store.hasDraft(on: "B"))
        XCTAssertFalse(store.hasDraft(.screen("A")))
    }

    /// A screen with a layout of its own draws that whole: nothing of the shared layout mixes in, not even what its own
    /// leaves at the default.
    func testAScreensOwnLayoutIsDrawnWholeWithoutTheSharedOne() {
        let store = makeStore(in: makeDefaults())
        XCTAssertEqual(store.effective(for: "A"), rings)
        XCTAssertEqual(store.effective(for: "A").style, PanelStyle(), "the shared layout's compact spacing does not reach it")
        XCTAssertEqual(store.effective(for: "B"), quiet)
        XCTAssertFalse(store.usesShared("A"))
        XCTAssertEqual(store.ownLayout(of: "A"), rings)
        XCTAssertEqual(store.previous(of: "A"), .shared, "before its own layout, the screen used the shared one")
        XCTAssertEqual(store.screenKeys, ["A"])

        store.propose(PanelLayout(order: ["Cursor"]))
        XCTAssertEqual(store.effective(for: "A"), rings, "a shared draft does not reach a screen with its own layout")
        XCTAssertNil(store.draftScope(on: "A"))
        XCTAssertEqual(store.draftScope(on: "B"), .shared)
    }

    // MARK: An agent's change to a screen

    func testAScreensProposalIsItsOwnDraftAndLeavesTheSharedLayoutAndTheDefaults() {
        let defaults = makeDefaults()
        let store = PanelLayoutStore(defaults: defaults)
        XCTAssertTrue(store.propose(.own(dock), for: "A"))
        XCTAssertEqual(store.effective(for: "A"), dock, "drawn at once")
        XCTAssertEqual(store.draft(of: "A"), .own(dock))
        XCTAssertEqual(store.draftScope(on: "A"), .screen("A"))
        XCTAssertFalse(store.hasDraft, "the shared layout has none")
        XCTAssertEqual(store.effective(for: "B"), PanelLayout())
        XCTAssertNil(stored(defaults), "a draft is never written")
        XCTAssertNil(PanelLayoutStore(defaults: defaults).draft(of: "A"), "a relaunch drops it")

        XCTAssertFalse(store.propose(.shared, for: "A"), "using the shared layout is what the screen already does")
        XCTAssertNil(store.draft(of: "A"))
        XCTAssertTrue(store.screenKeys.isEmpty, "a screen left with nothing to keep has no document")
    }

    func testAScreenCanBeProposedTheDefaultItsPreviousOrTheSharedLayout() {
        let store = makeStore(in: makeDefaults())
        XCTAssertTrue(store.proposeDefault(.screen("A")))
        XCTAssertEqual(store.draft(of: "A"), .own(PanelLayout()), "its own default view, not the shared layout")
        XCTAssertEqual(store.effective(for: "A"), PanelLayout())
        XCTAssertTrue(store.proposePrevious(.screen("A")))
        XCTAssertEqual(store.draft(of: "A"), .shared)
        XCTAssertEqual(store.effective(for: "A"), quiet, "its previous choice was the shared layout")
        XCTAssertFalse(store.proposePrevious(.screen("B")), "a screen with nothing saved before has no previous")
        XCTAssertNil(store.draft(of: "B"))
    }

    // MARK: A person's choice

    /// Saving a draft to use the shared layout removes the screen's own layout, which becomes its previous one; a
    /// revert brings it back.
    func testSavingADraftToUseTheSharedLayoutRemovesTheScreensOwnAndRevertBringsItBack() {
        let defaults = makeDefaults()
        let store = makeStore(in: defaults)
        store.propose(.shared, for: "A")
        XCTAssertEqual(store.effective(for: "A"), quiet, "the shared layout, drawn as the screen's draft")
        XCTAssertEqual(store.draftScope(on: "A"), .screen("A"), "the screen's bar saves the screen's choice")
        store.savePanel(on: "A")
        XCTAssertNil(store.ownLayout(of: "A"))
        XCTAssertTrue(store.usesShared("A"))
        XCTAssertEqual(store.previous(of: "A"), .own(rings))
        XCTAssertEqual(store.current, quiet, "the shared layout is as it was")
        XCTAssertEqual(PanelLayoutStore(defaults: defaults).previous(of: "A"), .own(rings), "kept across a relaunch")

        store.revert(.screen("A"))
        XCTAssertEqual(store.ownLayout(of: "A"), rings)
        XCTAssertEqual(store.previous(of: "A"), .shared)
        store.revert(.screen("A"))
        XCTAssertTrue(store.usesShared("A"), "reverting again undoes it")
    }

    func testSavingDiscardingResettingAndUsingSharedActOnTheScreenAlone() {
        let defaults = makeDefaults()
        let store = makeStore(in: defaults)
        store.propose(dock)
        store.propose(.own(dock), for: "A")
        store.discard(.screen("A"))
        XCTAssertNil(store.draft(of: "A"))
        XCTAssertEqual(store.draft, dock, "the shared draft stays")
        XCTAssertEqual(store.effective(for: "A"), rings)

        store.propose(.own(dock), for: "A")
        store.save(.screen("A"))
        XCTAssertEqual(store.ownLayout(of: "A"), dock)
        XCTAssertEqual(store.previous(of: "A"), .own(rings))
        XCTAssertEqual(store.draft, dock, "and saving the screen's leaves it too")
        XCTAssertEqual(store.current, quiet)

        store.reset(.screen("A"))
        XCTAssertEqual(store.ownLayout(of: "A"), PanelLayout(), "the default view, as the screen's own")
        XCTAssertEqual(store.previous(of: "A"), .own(dock))
        let revision = store.revision
        store.reset(.screen("A"))
        XCTAssertEqual(store.revision, revision, "already the default")

        store.propose(.own(rings), for: "A")
        store.useShared("A")
        XCTAssertTrue(store.usesShared("A"), "a person's click takes effect at once")
        XCTAssertNil(store.draft(of: "A"), "and drops the screen's draft")
        XCTAssertEqual(store.previous(of: "A"), .own(PanelLayout()))
        XCTAssertEqual(store.effective(for: "A"), dock, "the shared draft now shows here too")
        XCTAssertEqual(store.draftScope(on: "A"), .shared)
        store.savePanel(on: "A")
        XCTAssertEqual(store.current, dock, "and the screen's bar now saves the shared layout")
        XCTAssertNil(store.draftScope(on: "A"))
    }

    func testDiscardingThePanelsDraftDropsTheOneItShows() {
        let store = makeStore(in: makeDefaults())
        store.propose(dock)
        store.propose(.own(dock), for: "A")
        store.discardPanel(on: "A")
        XCTAssertNil(store.draft(of: "A"))
        XCTAssertEqual(store.draft, dock, "the screen's own draft, not the shared one")
        store.discardPanel(on: "A")
        XCTAssertEqual(store.draft, dock, "a screen with its own layout shows no shared draft to drop")
        store.discardPanel(on: "B")
        XCTAssertNil(store.draft)
    }

    // MARK: Revision

    func testOneRevisionCountsEveryDocumentsChangesOnce() {
        let store = PanelLayoutStore(defaults: makeDefaults())
        var expected = 0
        func step(_ what: String, changes: Bool, _ change: () -> Void) {
            change()
            if changes { expected += 1 }
            XCTAssertEqual(store.revision, expected, what)
        }
        step("a screen's proposal", changes: true) { store.propose(.own(rings), for: "A") }
        step("the same again", changes: false) { store.propose(.own(rings), for: "A") }
        step("a shared proposal", changes: true) { store.propose(quiet) }
        step("another screen's proposal", changes: true) { store.propose(.own(dock), for: "B") }
        step("a save of one screen", changes: true) { store.save(.screen("A")) }
        step("a save of a screen without a draft", changes: false) { store.save(.screen("A")) }
        step("a discard of a screen without a document", changes: false) { store.discard(.screen("C")) }
        step("using the shared layout where it is used", changes: false) { store.useShared("C") }
        step("a revert of a screen", changes: true) { store.revert(.screen("A")) }
        step("a revert of a screen with nothing before", changes: false) { store.revert(.screen("C")) }
        step("a discard of the shared draft", changes: true) { store.discard() }
        step("a reset of a screen, which also drops its draft", changes: true) { store.reset(.screen("B")) }
        XCTAssertEqual(store.revision, 7)
    }

    func testAScreensDocumentIsObserved() {
        let store = PanelLayoutStore(defaults: makeDefaults())
        let changed = expectation(description: "a screen's draft changes what its panel draws")
        withObservationTracking { _ = store.effective(for: "A") } onChange: { changed.fulfill() }
        store.propose(.own(rings), for: "A")
        wait(for: [changed], timeout: 1)
    }

    // MARK: Kept across launches

    func testEveryScreensLayoutIsKeptBesideTheSharedOne() throws {
        let defaults = makeDefaults()
        let store = makeStore(in: defaults)
        store.propose(.own(dock), for: "B")
        store.save(.screen("B"))
        store.useShared("B")
        let expected = [
            #"{"screens":{"A":{"current":{"blocks":{"Claude":{"widget":"ring"}},"order":["Codex"]},"previous":"shared"},"#,
            #""B":{"previous":{"hud":{"agents":["Codex","Claude"]}}}},"#,
            #""shared":{"current":{"blocks":{"Codex":{"hidden":true}},"hiddenSections":["sessions"],"style":{"spacing":"compact"}},"#,
            #""previous":{}}}"#,
        ].joined()
        XCTAssertEqual(stored(defaults), expected, "keys sorted; a screen using the shared layout keeps only its previous one")

        let reloaded = PanelLayoutStore(defaults: defaults)
        XCTAssertEqual(reloaded.current, quiet)
        XCTAssertEqual(reloaded.ownLayout(of: "A"), rings)
        XCTAssertEqual(reloaded.previous(of: "A"), .shared)
        XCTAssertTrue(reloaded.usesShared("B"))
        XCTAssertEqual(reloaded.previous(of: "B"), .own(dock))
        XCTAssertEqual(reloaded.screenKeys, ["A", "B"], "a screen that is away keeps its layout for when it returns")
        XCTAssertEqual(reloaded.revision, 0)
    }

    func testOneUnreadableScreenOrSideKeepsTheRest() {
        let defaults = makeDefaults()
        defaults.set(Data("""
            {"shared": {"current": {"order": ["Codex"]}},
             "screens": {"A": {"current": {"hud": {"agents": ["Claude"]}}, "previous": 4},
                         "B": "rings",
                         "C": {"current": [1], "previous": {"order": ["Cursor"]}},
                         "D": {"current": "shared"},
                         "": {"current": {}}}}
            """.utf8), forKey: SettingsStore.Keys.panelLayout)
        let store = PanelLayoutStore(defaults: defaults)
        XCTAssertEqual(store.current, PanelLayout(order: ["Codex"]))
        XCTAssertEqual(store.ownLayout(of: "A"), PanelLayout(hud: PanelLayout.HUD(agents: ["Claude"])))
        XCTAssertNil(store.previous(of: "A"), "an unreadable previous is none")
        XCTAssertTrue(store.usesShared("B"), "a screen that is not an object is left out")
        XCTAssertTrue(store.usesShared("C"), "an unreadable current is the shared layout")
        XCTAssertEqual(store.previous(of: "C"), .own(PanelLayout(order: ["Cursor"])))
        XCTAssertEqual(store.screenKeys, ["A", "C"], "nothing to keep for D, and no screen without a key")

        let broken = makeDefaults()
        broken.set(Data(#"{"shared": [], "screens": {"A": {"current": {"order": ["Codex"]}}}}"#.utf8), forKey: SettingsStore.Keys.panelLayout)
        let kept = PanelLayoutStore(defaults: broken)
        XCTAssertEqual(kept.current, PanelLayout(), "an unreadable shared side is the default")
        XCTAssertEqual(kept.ownLayout(of: "A"), PanelLayout(order: ["Codex"]), "and keeps the screens")
    }

    /// The first format was never released: a value under its key is not read, and nothing is written there.
    func testTheFirstFormatIsNotRead() {
        let defaults = makeDefaults()
        defaults.set(Data(#"{"current": {"order": ["Codex"]}}"#.utf8), forKey: "panelLayout.v1")
        let store = PanelLayoutStore(defaults: defaults)
        XCTAssertEqual(store.current, PanelLayout())
        store.propose(rings)
        store.save()
        XCTAssertEqual(defaults.data(forKey: "panelLayout.v1"), Data(#"{"current": {"order": ["Codex"]}}"#.utf8))
        XCTAssertNotNil(stored(defaults))
    }
}
