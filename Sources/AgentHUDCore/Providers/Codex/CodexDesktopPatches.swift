import AgentHUDSupport
import Foundation

/// Desktop sends a followed thread's changes as the patches its state library (Immer) records: `op` is `replace`,
/// `add` or `remove`, and `path` names the place by object keys and array positions.
enum CodexDesktopPatches {
    /// A patch that names no place in the kept state: the state no longer matches the owner's and is asked for again.
    struct Unresolved: Error {}

    /// Applies a change's patches in order, as the library that wrote them does.
    static func apply(_ patches: [JSONValue], to state: inout JSONValue) throws {
        // A replacement of the whole state makes every patch before it moot.
        let whole = patches.lastIndex { $0["op"].stringValue == "replace" && $0["path"].arrayValue?.isEmpty == true }
        if let whole { state = patches[whole]["value"] }
        for patch in patches[(whole.map { $0 + 1 } ?? 0)...] {
            guard let op = patch["op"].stringValue, let path = patch["path"].arrayValue, !path.isEmpty else { throw Unresolved() }
            try state.change(at: path[...], op: op, value: patch["value"])
        }
    }
}

private extension JSONValue {
    mutating func change(at path: ArraySlice<JSONValue>, op: String, value: JSONValue) throws {
        let key = path[path.startIndex], rest = path.dropFirst()
        switch self {
        case .object(var members):
            guard let name = key.stringValue ?? key.position.map(String.init) else { throw CodexDesktopPatches.Unresolved() }
            // The members are held here alone while they change, so they change in place.
            self = .null
            defer { self = .object(members) }
            guard rest.isEmpty else {
                guard members[name] != nil else { throw CodexDesktopPatches.Unresolved() }
                return try members[name]!.change(at: rest, op: op, value: value)
            }
            switch op {
            case "replace", "add": members[name] = value
            case "remove": members.removeValue(forKey: name)
            default: throw CodexDesktopPatches.Unresolved()
            }
        case .array(var elements):
            self = .null
            defer { self = .array(elements) }
            guard rest.isEmpty else {
                guard let index = key.position, elements.indices.contains(index) else { throw CodexDesktopPatches.Unresolved() }
                return try elements[index].change(at: rest, op: op, value: value)
            }
            switch (op, key.position, key.stringValue) {
            case ("add", nil, "-"?): elements.append(value)
            case ("add", let index?, _) where index <= elements.count: elements.insert(value, at: index)
            case ("replace", let index?, _) where index < elements.count: elements[index] = value
            case ("replace", let index?, _) where index == elements.count: elements.append(value)
            // A shortened array can be written as its new length.
            case ("replace", nil, "length"?):
                guard let count = value.position, count <= elements.count else { throw CodexDesktopPatches.Unresolved() }
                elements.removeLast(elements.count - count)
            case ("remove", let index?, _) where index < elements.count: elements.remove(at: index)
            default: throw CodexDesktopPatches.Unresolved()
            }
        default:
            throw CodexDesktopPatches.Unresolved()
        }
    }

    /// An array position, as a number or as the digits a key can carry it in.
    var position: Int? {
        switch self {
        case .integer(let value) where value >= 0: return Int(exactly: value)
        case .string(let text) where !text.isEmpty && text.allSatisfy(\.isASCII) && text.allSatisfy(\.isNumber): return Int(text)
        default: return nil
        }
    }
}
