import XCTest
@testable import AgentHUDCore

/// What is kept of the layout across launches, how it is read back, and where it sits beside the settings.
@MainActor
final class PanelLayoutPersistenceTests: XCTestCase {
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

    /// A store over a stored value written as `json`.
    private func load(_ json: String) -> PanelLayoutStore {
        let defaults = makeDefaults()
        defaults.set(Data(json.utf8), forKey: SettingsStore.Keys.panelLayout)
        return PanelLayoutStore(defaults: defaults)
    }

    func testTheSavedLayoutsAreReadByTheNextStoreOnTheSameDefaults() {
        let defaults = makeDefaults()
        let first = PanelLayoutStore(defaults: defaults)
        first.propose(rings)
        first.save()
        first.propose(quiet)
        first.save()
        first.propose(PanelLayout(order: ["Cursor"]))

        let second = PanelLayoutStore(defaults: defaults)
        XCTAssertEqual(second.current, quiet)
        XCTAssertEqual(second.previous, rings)
        XCTAssertNil(second.draft)
        XCTAssertTrue(second.canRevert)
        XCTAssertEqual(second.revision, 0, "the count starts again at launch")
        XCTAssertEqual(PanelLayoutStore(defaults: makeDefaults()).current, PanelLayout(), "another suite has its own layout")
    }

    func testOneUnreadableSideKeepsTheOther() {
        let lostCurrent = load(#"{"shared": {"current": "rings", "previous": {"order": ["Codex"]}}}"#)
        XCTAssertEqual(lostCurrent.current, PanelLayout())
        XCTAssertEqual(lostCurrent.previous, PanelLayout(order: ["Codex"]))
        XCTAssertTrue(lostCurrent.canRevert)

        let lostPrevious = load(#"{"shared": {"current": {"order": ["Codex"]}, "previous": [1, 2]}}"#)
        XCTAssertEqual(lostPrevious.current, PanelLayout(order: ["Codex"]))
        XCTAssertNil(lostPrevious.previous)

        let onlyCurrent = load(#"{"shared": {"current": {"hiddenSections": ["tokens"]}}}"#)
        XCTAssertEqual(onlyCurrent.current, PanelLayout(hiddenSections: [.tokens]))
        XCTAssertNil(onlyCurrent.previous)
        XCTAssertNil(load(#"{"shared": {"current": {}, "previous": null}}"#).previous)
        XCTAssertEqual(load(#"{"shared": {"current": {}, "previous": {}}}"#).previous, PanelLayout(), "the default view can be the previous layout")

        // A side written by a newer build loses only what this build does not know, and is read normalized.
        let newer = load("""
            {"shared": {"current": {"blocks": {"Claude": {"widget": "gauge", "measures": ["cost", "pace"], "columns": 8}, "Codex": {}},
                                    "order": ["a", "a"], "style": {"spacing": "airy", "separators": false}},
                        "previous": {"sections": ["weather", "sessions"]}, "next": {}},
             "elsewhere": {}}
            """)
        XCTAssertEqual(newer.current, PanelLayout(blocks: ["Claude": PanelLayout.Block(measures: [.cost])], order: ["a"],
                                                  style: PanelStyle(separators: false)))
        XCTAssertEqual(newer.previous, PanelLayout(sections: [.sessions, .blocks, .tokens]))

        for unreadable in ["", "not json", "[]", #""{}""#, "{", #"{"shared": 7}"#, #"{"shared": [{}]}"#] {
            let store = load(unreadable)
            XCTAssertEqual(store.current, PanelLayout(), unreadable)
            XCTAssertNil(store.previous, unreadable)
        }
        let defaults = makeDefaults()
        defaults.set(#"{"shared": {"current": {"order": ["Codex"]}}}"#, forKey: SettingsStore.Keys.panelLayout)
        XCTAssertEqual(PanelLayoutStore(defaults: defaults).current, PanelLayout(), "the stored value is data, as the settings are")
    }

    func testAnUnreadableValueIsReplacedByTheNextSave() {
        let defaults = makeDefaults()
        defaults.set(Data(#"{"shared": {"current": 7, "previous": {"order": ["Codex"]}}}"#.utf8), forKey: SettingsStore.Keys.panelLayout)
        let store = PanelLayoutStore(defaults: defaults)
        store.propose(rings)
        store.save()
        XCTAssertEqual(stored(defaults), #"{"shared":{"current":{"blocks":{"Claude":{"widget":"ring"}},"order":["Codex"]},"previous":{}}}"#)
    }

    // MARK: Beside the settings

    func testSettingsHoldALayoutStoreOnTheirOwnDefaults() {
        XCTAssertEqual(SettingsStore.Keys.panelLayout, "panelLayout.v2")
        let defaults = makeDefaults(), other = makeDefaults()
        let row = AgentDescriptor(id: "claude-session", vendor: "Claude", model: "5h", source: "", enabled: true)
        let settings = SettingsStore(defaults: defaults, defaultAgents: [row])
        settings.setAgent(id: "claude-session", enabled: false)
        let agents = defaults.data(forKey: SettingsStore.Keys.agents)
        var heard: [SettingsStore.Change] = []
        settings.onChange = { heard.append($0) }

        settings.panelLayout.propose(rings)
        settings.panelLayout.save()
        settings.panelLayout.propose(quiet)
        settings.panelLayout.reset()
        settings.panelLayout.revert()

        XCTAssertTrue(heard.isEmpty, "a layout change is no settings change, so it wakes no collection")
        XCTAssertEqual(defaults.data(forKey: SettingsStore.Keys.agents), agents, "and it never writes the agent list")
        XCTAssertNil(defaults.object(forKey: SettingsStore.Keys.settings))

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.panelLayout.current, rings)
        XCTAssertEqual(reloaded.panelLayout.previous, PanelLayout())
        XCTAssertFalse(reloaded.agents[0].enabled, "the settings beside it are as they were")
        XCTAssertEqual(SettingsStore(defaults: other).panelLayout.current, PanelLayout(), "another suite has its own layout")
        XCTAssertNil(other.object(forKey: SettingsStore.Keys.panelLayout))
    }
}
