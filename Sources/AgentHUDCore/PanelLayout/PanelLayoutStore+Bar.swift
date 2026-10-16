import Foundation

/// What the bar a panel shows while a draft waits acts on: the layout draft that panel draws and its screen's style
/// draft, kept or dropped together.
public extension PanelLayoutStore {
    /// Saves what the panel on `screen` shows unsaved: the layout draft it draws (`draftScope(on:)`) and the screen's
    /// style draft.
    func savePanel(on screen: String?) {
        if draftScope(on: screen) == .shared { save(.shared) }
        if let screen, hasDraft(.screen(screen)) { save(.screen(screen)) }
    }

    /// Drops what the panel on `screen` shows unsaved: the layout draft it draws (`draftScope(on:)`) and the screen's
    /// style draft.
    func discardPanel(on screen: String?) {
        if draftScope(on: screen) == .shared { discard(.shared) }
        if let screen, hasDraft(.screen(screen)) { discard(.screen(screen)) }
    }
}
