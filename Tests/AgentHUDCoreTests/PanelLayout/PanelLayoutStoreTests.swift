import Observation
import XCTest
@testable import AgentHUDCore

/// The layout's three states, as an agent's proposals and a person's choices move them.
@MainActor
final class PanelLayoutStoreTests: XCTestCase {
    private let rings = PanelLayout(blocks: ["Claude": PanelLayout.Block(widget: .ring)], order: ["Codex"])
    private let quiet = PanelLayout(blocks: ["Codex": PanelLayout.Block(hidden: true)], hiddenSections: [.sessions])

    private func makeDefaults() -> UserDefaults {
        let suite = "AgentHUDTests.PanelLayout.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func stored(_ defaults: UserDefaults) -> String? {
        defaults.data(forKey: SettingsStore.Keys.panelLayout).map { String(decoding: $0, as: UTF8.self) }
    }

    /// A store whose saved layout is `current`, saved over the default.
    private func makeStore(saved current: PanelLayout, in defaults: UserDefaults) -> PanelLayoutStore {
        let store = PanelLayoutStore(defaults: defaults)
        store.propose(current)
        store.save()
        return store
    }

    // MARK: An agent's change

    func testAFreshStoreIsTheDefaultLayoutWithNothingToSaveOrRevert() {
        let store = PanelLayoutStore(defaults: makeDefaults())
        XCTAssertEqual(store.current, PanelLayout())
        XCTAssertNil(store.previous)
        XCTAssertNil(store.draft)
        XCTAssertEqual(store.effective, PanelLayout())
        XCTAssertFalse(store.hasDraft)
        XCTAssertFalse(store.canRevert)
        XCTAssertEqual(store.revision, 0)
    }

    func testAProposalIsADraftShownAtOnceAndNotSaved() {
        let defaults = makeDefaults()
        let store = PanelLayoutStore(defaults: defaults)
        XCTAssertTrue(store.propose(rings))
        XCTAssertEqual(store.draft, rings)
        XCTAssertEqual(store.effective, rings, "the panel draws the draft")
        XCTAssertTrue(store.hasDraft)
        XCTAssertEqual(store.current, PanelLayout(), "the saved layout waits for a person")
        XCTAssertFalse(store.canRevert)
        XCTAssertNil(defaults.object(forKey: SettingsStore.Keys.panelLayout), "a draft is never written")

        let relaunched = PanelLayoutStore(defaults: defaults)
        XCTAssertNil(relaunched.draft, "a relaunch drops an unsaved draft")
        XCTAssertEqual(relaunched.effective, PanelLayout())
        XCTAssertEqual(relaunched.revision, 0)
    }

    func testAProposalIsKeptNormalizedAndOneThatIsTheSavedLayoutClearsTheDraft() {
        let store = makeStore(saved: rings, in: makeDefaults())
        let untidy = PanelLayout(blocks: ["Codex": PanelLayout.Block(hidden: true, hiddenRows: ["", "codex", "codex"]), "Cursor": PanelLayout.Block()],
                                 order: ["Claude", "", "Claude"], hiddenSections: [.sessions, .sessions])
        XCTAssertTrue(store.propose(untidy))
        XCTAssertEqual(store.draft, untidy.normalized())
        XCTAssertEqual(store.draft, PanelLayout(blocks: ["Codex": PanelLayout.Block(hidden: true, hiddenRows: ["codex"])], order: ["Claude"],
                                                hiddenSections: [.sessions]))

        var same = rings
        same.blocks["Cursor"] = PanelLayout.Block()
        same.order += ["Codex", ""]
        XCTAssertFalse(store.propose(same), "the saved layout written another way is no change")
        XCTAssertNil(store.draft)
        XCTAssertEqual(store.effective, rings)
        XCTAssertFalse(store.propose(rings))
    }

    func testProposingTheDefaultOrThePreviousLayout() {
        let defaults = makeDefaults()
        let store = PanelLayoutStore(defaults: defaults)
        XCTAssertFalse(store.proposePrevious(), "nothing was saved before")
        XCTAssertFalse(store.proposeDefault(), "the saved layout already is the default")
        XCTAssertNil(store.draft)
        XCTAssertEqual(store.revision, 0)

        store.propose(rings)
        XCTAssertFalse(store.proposePrevious())
        XCTAssertEqual(store.draft, rings, "without a previous layout the draft stays as it was")
        store.save()
        store.propose(quiet)
        store.save()

        XCTAssertTrue(store.proposePrevious())
        XCTAssertEqual(store.draft, rings)
        XCTAssertEqual(store.current, quiet)
        XCTAssertEqual(store.previous, rings, "proposing changes nothing saved")
        XCTAssertTrue(store.proposeDefault())
        XCTAssertEqual(store.draft, PanelLayout())
        XCTAssertEqual(store.effective, PanelLayout(), "the default view is shown as a draft too")
        XCTAssertEqual(PanelLayoutStore(defaults: defaults).current, quiet)

        store.save()
        XCTAssertEqual(store.current, PanelLayout())
        XCTAssertEqual(store.previous, quiet)
    }

    // MARK: A person's choice

    func testSavingKeepsTheDraftAndTheSavedLayoutBecomesThePreviousOne() {
        let defaults = makeDefaults()
        let store = PanelLayoutStore(defaults: defaults)
        store.save()
        XCTAssertEqual(store.revision, 0, "nothing to save without a draft")
        XCTAssertNil(stored(defaults))

        store.propose(rings)
        store.save()
        XCTAssertEqual(store.current, rings)
        XCTAssertEqual(store.previous, PanelLayout(), "the default view was the layout before")
        XCTAssertNil(store.draft)
        XCTAssertTrue(store.canRevert)
        XCTAssertEqual(stored(defaults), #"{"shared":{"current":{"blocks":{"Claude":{"widget":"ring"}},"order":["Codex"]},"previous":{}}}"#)

        store.propose(quiet)
        store.save()
        XCTAssertEqual(store.current, quiet)
        XCTAssertEqual(store.previous, rings)
        let both = [
            #"{"shared":{"current":{"blocks":{"Codex":{"hidden":true}},"hiddenSections":["sessions"]},"#,
            #""previous":{"blocks":{"Claude":{"widget":"ring"}},"order":["Codex"]}}}"#,
        ].joined()
        XCTAssertEqual(stored(defaults), both, "both sides in one value, keys sorted")
        store.save()
        XCTAssertEqual(store.previous, rings, "a second save without a draft keeps the previous layout")
    }

    func testDiscardingDropsTheDraft() {
        let defaults = makeDefaults()
        let store = makeStore(saved: rings, in: defaults)
        let saved = stored(defaults)
        store.propose(quiet)
        store.discard()
        XCTAssertNil(store.draft)
        XCTAssertEqual(store.effective, rings)
        XCTAssertEqual(store.previous, PanelLayout())
        XCTAssertEqual(stored(defaults), saved)
    }

    func testRevertingSwapsTheSavedAndThePreviousLayoutAndDropsAnyDraft() {
        let defaults = makeDefaults()
        let store = makeStore(saved: rings, in: defaults)
        store.propose(quiet)
        store.save()
        store.propose(PanelLayout(order: ["Cursor"]))

        store.revert()
        XCTAssertEqual(store.current, rings)
        XCTAssertEqual(store.previous, quiet)
        XCTAssertNil(store.draft)
        let reloaded = PanelLayoutStore(defaults: defaults)
        XCTAssertEqual(reloaded.current, rings)
        XCTAssertEqual(reloaded.previous, quiet)

        store.revert()
        XCTAssertEqual(store.current, quiet, "reverting again undoes it")
        XCTAssertEqual(store.previous, rings)
        XCTAssertEqual(PanelLayoutStore(defaults: defaults).current, quiet)
    }

    func testRevertingWithoutAPreviousLayoutKeepsTheSavedOne() {
        let defaults = makeDefaults()
        let store = PanelLayoutStore(defaults: defaults)
        store.revert()
        XCTAssertEqual(store.revision, 0)
        store.propose(rings)
        store.revert()
        XCTAssertEqual(store.current, PanelLayout())
        XCTAssertNil(store.previous)
        XCTAssertNil(store.draft, "any draft is dropped")
        XCTAssertNil(stored(defaults))
    }

    func testResettingGoesBackToTheDefaultAndKeepsTheSavedLayoutAsThePreviousOne() {
        let defaults = makeDefaults()
        let store = makeStore(saved: rings, in: defaults)
        store.propose(quiet)
        store.save()
        store.propose(PanelLayout(order: ["Cursor"]))

        store.reset()
        XCTAssertEqual(store.current, PanelLayout())
        XCTAssertEqual(store.previous, quiet)
        XCTAssertNil(store.draft)
        XCTAssertEqual(stored(defaults), #"{"shared":{"current":{},"previous":{"blocks":{"Codex":{"hidden":true}},"hiddenSections":["sessions"]}}}"#)
        XCTAssertEqual(PanelLayoutStore(defaults: defaults).previous, quiet)

        // Already the default: the previous layout stays, and a draft still goes.
        let revision = store.revision
        store.reset()
        XCTAssertEqual(store.previous, quiet)
        XCTAssertEqual(store.revision, revision)
        store.propose(rings)
        store.reset()
        XCTAssertNil(store.draft)
        XCTAssertEqual(store.current, PanelLayout())
        XCTAssertEqual(store.previous, quiet)

        store.revert()
        XCTAssertEqual(store.current, quiet, "the reset can be reverted")
        XCTAssertEqual(store.previous, PanelLayout())
    }

    // MARK: Revision

    func testTheRevisionCountsEachChangeOnce() {
        let store = PanelLayoutStore(defaults: makeDefaults())
        var expected = 0
        func step(_ what: String, changes: Bool, _ change: () -> Void) {
            change()
            if changes { expected += 1 }
            XCTAssertEqual(store.revision, expected, what)
        }
        step("a proposal", changes: true) { store.propose(rings) }
        step("the same proposal again", changes: false) { store.propose(rings) }
        step("another proposal", changes: true) { store.propose(quiet) }
        step("a discard", changes: true) { store.discard() }
        step("a discard without a draft", changes: false) { store.discard() }
        step("a save without a draft", changes: false) { store.save() }
        step("a revert without a previous layout", changes: false) { store.revert() }
        step("a reset of the default", changes: false) { store.reset() }
        step("a proposal of the saved layout", changes: false) { store.proposeDefault() }
        step("a proposal", changes: true) { store.propose(rings) }
        step("a save, which changes all three states", changes: true) { store.save() }
        step("a proposal of the saved layout over no draft", changes: false) { store.propose(rings) }
        step("a proposal", changes: true) { store.propose(quiet) }
        step("a proposal of the saved layout over a draft", changes: true) { store.propose(rings) }
        step("a proposal of the previous layout", changes: true) { store.proposePrevious() }
        step("a revert, which also drops the draft", changes: true) { store.revert() }
        step("a reset of the default that revert brought back", changes: false) { store.reset() }
        step("a revert back", changes: true) { store.revert() }
        step("a reset", changes: true) { store.reset() }
        step("a reset again", changes: false) { store.reset() }
        XCTAssertEqual(store.revision, 11)
    }

    func testEveryStateIsObserved() {
        let store = PanelLayoutStore(defaults: makeDefaults())
        func expectChange(_ what: String, reading read: () -> Void, when change: () -> Void) {
            let changed = expectation(description: what)
            withObservationTracking { read() } onChange: { changed.fulfill() }
            change()
            wait(for: [changed], timeout: 1)
        }
        expectChange("a proposal changes what the panel draws", reading: { _ = store.effective }) { store.propose(rings) }
        expectChange("a proposal counts a revision", reading: { _ = store.revision }) { store.propose(quiet) }
        expectChange("a save ends the draft", reading: { _ = store.hasDraft }) { store.save() }
        expectChange("a reset makes a previous layout", reading: { _ = store.previous }) { store.reset() }
        expectChange("a revert changes the saved layout", reading: { _ = store.current }) { store.revert() }
    }
}
