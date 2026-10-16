import Foundation

/// Reads a TOML file only as far as it takes to know whether it has a server under `mcp_servers`, which is all Agent
/// HUD asks of Codex's `config.toml`. Tables, dotted keys and inline tables are recognised however their keys are
/// quoted; comments and multi-line strings are passed over, so a server written there does not count.
enum MCPTOMLTables {
    /// Whether `text` has the server `server`: a `[mcp_servers.<server>]` table or one under it, a key `<server>`
    /// under `[mcp_servers]`, a dotted key `mcp_servers.<server>.…` at the top, or `<server>` in an inline table
    /// given as `mcp_servers`.
    static func names(server: String, in text: String) -> Bool {
        var table: [String] = []
        var openString: String?
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var line = Substring(raw)
            if let delimiter = openString {
                guard let end = line.range(of: delimiter) else { continue }
                line = line[end.upperBound...]
                openString = nil
            }
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("[") {
                let inside = trimmed.drop { $0 == "[" }
                guard let (path, _) = key(inside) else { continue }
                table = path
                if names(path, server) { return true }
                continue
            }
            guard let (path, rest) = key(trimmed), rest.first == "=" else { continue }
            let value = rest.dropFirst().drop { $0 == " " || $0 == "\t" }
            if names(table + path, server) { return true }
            if table + path == ["mcp_servers"], value.hasPrefix("{"), inline(value, names: server) { return true }
            for delimiter in ["\"\"\"", "'''"] where value.hasPrefix(delimiter) {
                if value.dropFirst(3).range(of: delimiter) == nil { openString = delimiter }
            }
        }
        return false
    }

    private static func names(_ path: [String], _ server: String) -> Bool {
        path.count >= 2 && path[0] == "mcp_servers" && path[1] == server
    }

    /// Whether an inline table's own keys include `server`.
    private static func inline(_ value: Substring, names server: String) -> Bool {
        var rest = value.dropFirst()
        while !rest.isEmpty {
            rest = rest.drop { $0 == " " || $0 == "\t" || $0 == "," }
            guard let (path, after) = key(rest), after.first == "=" else { return false }
            if path.first == server { return true }
            // Past the value: a nested table, a string or a bare value, to the comma that ends it.
            var depth = 0, quote: Character?
            var index = after.dropFirst().startIndex
            while index < rest.endIndex {
                let character = rest[index]
                if let open = quote {
                    if character == open { quote = nil }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if character == "{" || character == "[" {
                    depth += 1
                } else if character == "}" || character == "]" {
                    if depth == 0 { return false }
                    depth -= 1
                } else if character == ",", depth == 0 {
                    break
                }
                index = rest.index(after: index)
            }
            rest = rest[index...]
        }
        return false
    }

    /// A dotted key at the start of `text`, its parts unquoted, and what follows it with the space before it taken
    /// away; nil when `text` starts with no key.
    static func key(_ text: Substring) -> ([String], Substring)? {
        var parts: [String] = []
        var rest = text
        while true {
            rest = rest.drop { $0 == " " || $0 == "\t" }
            guard let first = rest.first else { return nil }
            var part = ""
            if first == "\"" || first == "'" {
                var index = rest.index(after: rest.startIndex)
                var closed = false
                while index < rest.endIndex {
                    let character = rest[index]
                    if character == first { closed = true; break }
                    if character == "\\", first == "\"" {
                        index = rest.index(after: index)
                        guard index < rest.endIndex else { break }
                    }
                    part.append(rest[index])
                    index = rest.index(after: index)
                }
                guard closed else { return nil }
                rest = rest[rest.index(after: index)...]
            } else {
                let bare = rest.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
                guard !bare.isEmpty else { return nil }
                part = String(bare)
                rest = rest.dropFirst(bare.count)
            }
            parts.append(part)
            rest = rest.drop { $0 == " " || $0 == "\t" }
            guard rest.first == "." else { return (parts, rest) }
            rest = rest.dropFirst()
        }
    }
}
