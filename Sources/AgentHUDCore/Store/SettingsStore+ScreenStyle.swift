import Foundation

/// What one screen's resting HUD draws: its settings, with the style draft an agent proposed for that screen drawn over
/// them (`PanelLayoutStore.styleDraft(of:)`). Settings stay the saved truth, and a person's edit of a screen wins over a
/// draft.
@MainActor
public extension SettingsStore {
    /// The placement a screen's HUD draws: its own saved one, or the one its hardware is given, with the screen's style
    /// draft drawn over it.
    func effectivePlacement(on screen: String, hasNotch: Bool) -> ScreenPlacement {
        let saved = settings.placement(on: screen, hasNotch: hasNotch)
        return panelLayout.styles[screen]?.placement(over: saved, hasNotch: hasNotch) ?? saved
    }

    /// The glow a screen draws: its own saved one, or the default, with the screen's style draft drawn over it. Nil, for
    /// no screen, is the default glow, which no draft changes.
    func effectiveGlow(on screen: String?) -> GlowSettings {
        let saved = settings.glow(on: screen)
        guard let screen, let draft = panelLayout.styles[screen] else { return saved }
        return draft.glow(over: saved, defaultGlow: settings.glow)
    }

    /// A person's own edit of one screen's placement or glow: the screen's style draft is dropped first, so a person
    /// always wins over an agent, and the change is made to the settings as saved. An edit is no version of the
    /// screen: it leaves its previous version as it was.
    func updateScreen(_ screen: String, _ change: (inout Settings) -> Void) {
        panelLayout.discardStyle(screen)
        update(change)
    }
}
