import AgentHUDSupport
import Foundation

/// Which layout a screen draws: the shared one, or one of its own.
public enum PanelScreenLayout: Hashable, Sendable {
    case shared
    case own(PanelLayout)

    /// The screen's own layout; nil while it uses the shared one.
    public var layout: PanelLayout? {
        if case .own(let layout) = self { return layout }
        return nil
    }

    /// The choice with its layout normalized.
    func normalized() -> PanelScreenLayout {
        switch self {
        case .shared: .shared
        case .own(let layout): .own(layout.normalized())
        }
    }
}

/// One screen's own placement and glow as the settings keep them (`Settings.screens`, `Settings.screenGlow`), each nil
/// where the screen has none of its own and draws the default. `ScreenLook()` is a screen that draws the defaults.
struct ScreenLook: Hashable, Sendable {
    var placement: ScreenPlacement?
    var glow: GlowSettings?
}

/// One screen's own layout document: the saved choice, the one saved before it, and a choice an agent proposed that no
/// person has saved yet. A screen's versions cover its whole look, its layout and its style, so the version saved
/// before also keeps the screen's own placement and glow where that version's differ from the saved one's. A screen
/// without a document uses the shared layout.
struct PanelScreenDocument: Equatable, Sendable {
    var current: PanelScreenLayout = .shared
    var previous: PanelScreenLayout?
    var draft: PanelScreenLayout?
    /// The screen's own placement and glow in the version saved before; nil where that version had the style the
    /// screen has now, or there is none.
    var previousLook: ScreenLook?

    /// Whether the document says nothing a screen without one would not: the shared layout, nothing before it, no draft.
    var isEmpty: Bool { current == .shared && previous == nil && draft == nil && previousLook == nil }
    /// Whether the document has anything to keep across launches.
    var isSaved: Bool { current != .shared || previous != nil || previousLook != nil }
}

/// How the saved layouts are kept in the defaults: one value, `{"shared": {"current": …, "previous": …}, "screens":
/// {"<screen key>": {"current": …, "previous": …, "previousStyle": …}}}`. Each side is a layout's JSON; a screen's side
/// is that or the string `"shared"`, and a screen's `current` left out is the shared layout. A screen's `previousStyle`
/// is the screen's own placement and glow in the version saved before, as the settings keep them,
/// `{"placement": …, "glow": …}`, each left out where the screen had none of its own then; it is left out itself where
/// that version had the style the screen has now. `previous` is left out while there is none, the shared side while
/// it is the default layout with no previous one, a screen while it uses the shared layout with nothing before it, and
/// `screens` while no screen has a layout of its own.
///
/// Reading forgives side by side: a side that cannot be read is the default (`current` of the shared layout), the
/// shared layout (`current` of a screen) or none (`previous`, `previousStyle`), and a screen that is not an object is
/// left out, so what cannot be read never loses the rest.
enum PanelLayoutStorage {
    struct Saved: Equatable {
        var current = PanelLayout()
        var previous: PanelLayout?
        var screens: [String: PanelScreenDocument] = [:]
    }

    static func read(_ data: Data?) -> Saved {
        let root = data.flatMap { try? JSONValue.parse($0) }?.objectValue ?? [:]
        let shared = root["shared"]?.objectValue ?? [:]
        var saved = Saved(current: shared["current"].flatMap { PanelLayout(json: $0) }?.normalized() ?? PanelLayout(),
                          previous: shared["previous"].flatMap { PanelLayout(json: $0) }?.normalized())
        for (key, value) in root["screens"]?.objectValue ?? [:] where !key.isEmpty {
            guard let sides = value.objectValue else { continue }
            let document = PanelScreenDocument(current: sides["current"].flatMap(choice) ?? .shared,
                                               previous: sides["previous"].flatMap(choice),
                                               previousLook: sides["previousStyle"].flatMap(look))
            if document.isSaved { saved.screens[key] = document }
        }
        return saved
    }

    /// The value written for the saved layouts, sorted by key; nil when there is nothing to keep.
    static func write(_ saved: Saved) -> Data? {
        var root: [String: JSONValue] = [:]
        if saved.previous != nil || !saved.current.isDefault {
            var shared: [String: JSONValue] = ["current": json(saved.current)]
            if let previous = saved.previous { shared["previous"] = json(previous) }
            root["shared"] = .object(shared)
        }
        var screens: [String: JSONValue] = [:]
        for (key, document) in saved.screens where document.isSaved {
            var sides: [String: JSONValue] = [:]
            if let own = document.current.layout { sides["current"] = json(own) }
            if let previous = document.previous { sides["previous"] = json(previous) }
            if let look = document.previousLook { sides["previousStyle"] = json(look) }
            screens[key] = .object(sides)
        }
        if !screens.isEmpty { root["screens"] = .object(screens) }
        guard !root.isEmpty else { return nil }
        return try? RecordCoding.encoder().encode(JSONValue.object(root))
    }

    /// A screen's side: a layout's object, or "shared"; nil for anything else.
    private static func choice(_ value: JSONValue) -> PanelScreenLayout? {
        if value.stringValue == "shared" { return .shared }
        return PanelLayout(json: value).map { .own($0.normalized()) }
    }

    /// A screen's previous style: an object whose placement and glow are each read as the settings read them; nil
    /// where it is not an object, or a part of it cannot be read, which would restore a style that was never saved.
    private static func look(_ value: JSONValue) -> ScreenLook? {
        guard let parts = value.objectValue else { return nil }
        var look = ScreenLook()
        if let placement = parts["placement"], placement != .null {
            guard let read = try? placement.decode(ScreenPlacement.self) else { return nil }
            look.placement = read
        }
        if let glow = parts["glow"], glow != .null {
            guard let read = try? glow.decode(GlowSettings.self) else { return nil }
            look.glow = read
        }
        return look
    }

    private static func json(_ choice: PanelScreenLayout) -> JSONValue {
        switch choice {
        case .shared: .string("shared")
        case .own(let layout): json(layout)
        }
    }

    private static func json(_ layout: PanelLayout) -> JSONValue {
        (try? JSONValue.from(layout)) ?? .object([:])
    }

    private static func json(_ look: ScreenLook) -> JSONValue {
        var parts: [String: JSONValue] = [:]
        if let placement = look.placement { parts["placement"] = try? JSONValue.from(placement) }
        if let glow = look.glow { parts["glow"] = try? JSONValue.from(glow) }
        return .object(parts)
    }
}
