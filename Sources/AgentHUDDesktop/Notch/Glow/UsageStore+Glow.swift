import AgentHUDCore

@MainActor
public extension UsageStore {
    /// The glow of every agent: each glow part's level, at the working pace while any session is in flight.
    /// - screen: which display's glow to resolve; nothing asks for the default one.
    func glowAppearance(light: Bool, on screen: String? = nil) -> GlowAppearance {
        glowAppearance(light: light, on: screen, levels: levels, anyAgentActive: hasLiveSession)
    }

    /// A glow drawn from the given parts' levels and pace, as a screen whose layout lists its agents draws it
    /// (`ScreenAgents`), under that screen's glow settings with its style draft drawn over them.
    internal func glowAppearance(light: Bool, on screen: String?, levels: [StatusLevel], anyAgentActive: Bool) -> GlowAppearance {
        let appearance = GlowAppearance.resolve(
            levels: levels,
            paused: isPaused || !isAccessAllowed,
            anyAgentActive: anyAgentActive,
            glow: settings.effectiveGlow(on: screen),
            light: light
        )
        guard glowHidden else { return appearance }
        return GlowAppearance(
            stops: appearance.stops, peakOpacity: appearance.peakOpacity, troughOpacity: appearance.troughOpacity,
            breathing: appearance.breathing, breathSeconds: appearance.breathSeconds, hidden: true
        )
    }
}
