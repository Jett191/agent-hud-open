import Foundation

enum DeepSeekCredentialLocator {
    /// Harness's credentials package and a runtime that can load it.
    struct Harness: Sendable, Equatable {
        let module: URL?
        let runtime: DeepSeekScriptRuntime?
    }

    static let package = "@deepseek-ai/dsh-credentials-local/lib/index.js"

    /// A CLI install's package, run by Node or else by the desktop app; otherwise the desktop app's own, which sits in
    /// its `app.asar` with every other package its runtime ships, side by side, and loads only in its Electron.
    static func locate(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                       path: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
                       applications: [URL] = DeepSeekScriptRuntime.applicationFolders) -> Harness {
        let desktop = DeepSeekScriptRuntime.desktopApplication(in: applications)
        if let module = module(home: home) {
            return Harness(module: module, runtime: DeepSeekScriptRuntime.node(path: path) ?? desktop.map(DeepSeekScriptRuntime.desktop))
        }
        if let desktop {
            return Harness(module: desktop.appendingPathComponent("Contents/Resources/app.asar/dsh/node_modules").appendingPathComponent(package),
                           runtime: .desktop(desktop))
        }
        return Harness(module: nil, runtime: DeepSeekScriptRuntime.node(path: path))
    }

    static func module(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        var roots = ["/opt/homebrew/lib/node_modules", "/usr/local/lib/node_modules"].map { URL(fileURLWithPath: $0) }
        roots.append(home.appendingPathComponent(".bun/install/global/node_modules"))
        let cache = home.appendingPathComponent(".npm/_npx")
        if let installs = try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.contentModificationDateKey]) {
            roots += installs.sorted { a, b in
                ((try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                    > ((try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }.map { $0.appendingPathComponent("node_modules") }
        }
        // A global `dsh` install keeps the package in its own node_modules, not beside itself.
        let candidates = roots.map { $0.appendingPathComponent(package) }
            + roots.map { $0.appendingPathComponent("@deepseek-ai/dsh/node_modules").appendingPathComponent(package) }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
