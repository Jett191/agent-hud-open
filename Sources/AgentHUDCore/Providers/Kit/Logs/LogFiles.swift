import Foundation

/// The log files under a set of roots with their modification times and sizes. With a directory watch, a poll looks
/// only at the paths reported changed, and lists only the subtree of a reported directory; without one, or every five
/// minutes and whenever events were dropped, it lists every file again. A listing that stops at its limit keeps the
/// files it did not reach that are still there.
final class LogFiles {
    struct File: Equatable {
        let modified: Date
        let size: Int
    }

    /// What a listing could not cover, for a notice: entries it could not read, and whether it stopped at its limit.
    /// Until the next full listing, a poll reports the last one's gaps along with those of the subtrees it listed.
    struct Gaps {
        var unreadable = 0
        var truncated = false
    }

    /// The names of one root. Files are keyed under `listed`, the path the enumerator names them by; a change event can
    /// name the root by any of `aliases`.
    private struct RootNames {
        let listed: String
        let aliases: [String]
        /// The root did not exist when these names were taken, so its real path may still change.
        let missing: Bool
    }

    static let fullScanInterval: TimeInterval = 300

    private let roots: [URL]
    private var names: [RootNames]
    private let limit: Int
    private let skips: (URL) -> Bool
    private let accepts: (URL) -> Bool
    private var monitor: FileChangeMonitor?
    private(set) var files: [String: File] = [:]
    /// The directories that have held a known file since the last full listing, so a gone path that never held one is
    /// passed over without a walk of the known files.
    private var holders: Set<String> = []
    private var scannedAt: Date?
    private var scanGaps = Gaps()
    /// The outer collector's event paths. Once it supplies them, it owns the watch for this listing; its paths must
    /// reach the index even when this listing's independent FSEvents stream has not delivered the same event yet.
    private var usesExternalChanges = false
    private var reportedPaths: Set<String>? = []

    /// - limit: entries a full listing visits before it stops.
    /// - skips: an entry the listing neither accepts nor descends into.
    init(roots: [URL], watchesChanges: Bool, limit: Int = .max, skips: @escaping (URL) -> Bool = { _ in false },
         accepts: @escaping (URL) -> Bool) {
        self.roots = roots
        names = roots.map(Self.names)
        self.limit = limit
        self.skips = skips
        self.accepts = accepts
        monitor = watchesChanges ? FileChangeMonitor(directories: roots) : nil
    }

    /// Called before a collection read with paths from the collector's watch. Nil means events were dropped and a full
    /// listing is required. Repeated signals accumulate until the next read.
    func noteChanges(_ paths: Set<String>?) {
        usesExternalChanges = true
        monitor = nil
        if let paths, reportedPaths != nil { reportedPaths?.formUnion(paths.filter { canonical($0) != nil }) }
        else { reportedPaths = nil }
    }

    /// Brings `files` up to date.
    @discardableResult
    func refresh(now: Date) -> Gaps {
        let changed: Set<String>?
        if usesExternalChanges {
            changed = reportedPaths
            reportedPaths = []
        } else {
            monitor?.update()
            changed = monitor?.consumePaths()
        }
        guard let changed, let scannedAt, now.timeIntervalSince(scannedAt) < Self.fullScanInterval else { return scan(now: now) }
        // A root created since its names were taken can now be named by its real path.
        for index in names.indices where names[index].missing { names[index] = Self.names(roots[index]) }
        // FSEvents can name a directory when it is created or removed, and its children cannot be inferred from that
        // one path, so a directory is listed as a subtree. A path that is gone is one only if known files were under it.
        var directories: Set<String> = [], paths: [String] = []
        for path in Set(changed.compactMap(canonical)) {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            let isSubtree = exists ? isDirectory.boolValue : holders.contains(path)
            if isSubtree { directories.insert(path) } else { paths.append(path) }
        }
        // A directory inside another reported one is covered by that one's listing, and so is a file.
        let outermost = directories.filter { !Self.ancestors($0).contains(where: directories.contains) }
        var gaps = scanGaps
        for directory in outermost.sorted() { relist(directory, gaps: &gaps) }
        for path in paths where !Self.ancestors(path).contains(where: outermost.contains) { recheck(path) }
        return gaps
    }

    private func scan(now: Date) -> Gaps {
        names = roots.map(Self.names)
        var walk = Walk(limit: limit, skips: skips, accepts: accepts)
        for root in names { guard walk.add(URL(fileURLWithPath: root.listed)) else { break } }
        // Files past the limit were not seen, which does not mean they are gone.
        if walk.gaps.truncated {
            for (path, file) in files where walk.files[path] == nil && FileManager.default.fileExists(atPath: path) { walk.files[path] = file }
        }
        files = walk.files
        holders = []
        for path in files.keys { noteHolders(of: path) }
        scannedAt = now
        scanGaps = walk.gaps
        return walk.gaps
    }

    /// Lists one reported directory as a full listing would reach it, and drops the known files under it that the
    /// listing did not find. A directory that is gone, or that the full listing skips, adds nothing.
    private func relist(_ directory: String, gaps: inout Gaps) {
        var walk = Walk(limit: limit, skips: skips, accepts: accepts)
        if let url = reachable(directory) { walk.add(url) }
        if holders.contains(directory) {
            let prefix = directory + "/"
            let gone = files.keys.filter { path in
                path.hasPrefix(prefix) && walk.files[path] == nil
                    && !(walk.gaps.truncated && FileManager.default.fileExists(atPath: path))
            }
            for path in gone { files.removeValue(forKey: path) }
        }
        for (path, file) in walk.files { add(path, file) }
        gaps.unreadable += walk.gaps.unreadable
        gaps.truncated = gaps.truncated || walk.gaps.truncated
    }

    /// Looks at one reported file again. It is kept only where the full listing would find it: accepted, not skipped,
    /// not hidden and in a directory the listing descends into, or a root that is one file.
    private func recheck(_ path: String) {
        let url = URL(fileURLWithPath: path)
        guard accepts(url) else { return }
        let listed = names.contains { $0.listed == path }
            || (!skips(url) && !url.lastPathComponent.hasPrefix(".") && reachable(url.deletingLastPathComponent().path) != nil)
        if listed, let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
           values.isRegularFile == true, let modified = values.contentModificationDate, let size = values.fileSize {
            add(path, File(modified: modified, size: size))
        } else if !listed || !FileManager.default.fileExists(atPath: path) {
            files.removeValue(forKey: path)
        }
    }

    private func add(_ path: String, _ file: File) {
        if files.updateValue(file, forKey: path) == nil { noteHolders(of: path) }
    }

    /// Adds the directories that contain a known file, stopping at one already noted, whose own are noted too.
    private func noteHolders(of path: String) {
        var end = path.endIndex
        while let slash = path[..<end].lastIndex(of: "/"), slash > path.startIndex,
              holders.insert(String(path[..<slash])).inserted {
            end = slash
        }
    }

    /// The directory's URL when the full listing would descend into it: under a root, with no hidden or skipped
    /// directory on the way, and still there. Its files come back keyed by their real path, as the full listing's are.
    private func reachable(_ path: String) -> URL? {
        guard let root = names.first(where: { path == $0.listed || path.hasPrefix($0.listed + "/") }) else { return nil }
        var url = URL(fileURLWithPath: root.listed, isDirectory: true)
        for component in path.dropFirst(root.listed.count).split(separator: "/") {
            guard !component.hasPrefix(".") else { return nil }
            url.appendPathComponent(String(component))
            guard !skips(url) else { return nil }
        }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue ? url : nil
    }

    /// The directories that contain a path, nearest first.
    private static func ancestors(_ path: String) -> UnfoldFirstSequence<String> {
        sequence(first: (path as NSString).deletingLastPathComponent) { parent in
            parent.count > 1 ? (parent as NSString).deletingLastPathComponent : nil
        }
    }

    /// The path as the listing names it, or nil outside every root.
    private func canonical(_ path: String) -> String? {
        for root in names {
            for alias in root.aliases where path == alias || path.hasPrefix(alias + "/") {
                return root.listed + path.dropFirst(alias.count)
            }
        }
        return nil
    }

    /// The enumerator names a directory's files under its real path, `/private` included, which neither the root's own
    /// path nor `resolvingSymlinksInPath()` gives, and so do file events; a root that is one file is listed by its own
    /// path. A root that does not exist yet is taken to be a directory.
    private static func names(_ root: URL) -> RootNames {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory)
        let real = realPath(root.path)
        let listed = exists && !isDirectory.boolValue ? root.path : real
        var aliases: [String] = []
        for alias in [listed, root.path, root.resolvingSymlinksInPath().path, real] where !aliases.contains(alias) { aliases.append(alias) }
        return RootNames(listed: listed, aliases: aliases, missing: !exists)
    }

    /// The real path of `path`, or for a path that does not exist, its nearest existing directory's real path followed by
    /// the missing names: the path the root will have once it is created.
    private static func realPath(_ path: String) -> String {
        var existing = path, missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing), existing.count > 1 {
            missing.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        guard let real = realpath(existing, nil) else { return path }
        defer { free(real) }
        return missing.reduce(String(cString: real)) { ($0 as NSString).appendingPathComponent($1) }
    }

    /// One listing of roots or reported directories: the accepted files it found and what it could not cover. Its
    /// entries count against the limit together.
    private struct Walk {
        private static let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]

        let limit: Int
        let skips: (URL) -> Bool
        let accepts: (URL) -> Bool
        var files: [String: File] = [:]
        var gaps = Gaps()
        private var visited = 0

        init(limit: Int, skips: @escaping (URL) -> Bool, accepts: @escaping (URL) -> Bool) {
            self.limit = limit
            self.skips = skips
            self.accepts = accepts
        }

        /// Adds the accepted files at or under `url`; false once the limit stopped the listing.
        @discardableResult
        mutating func add(_ url: URL) -> Bool {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return true }
            guard isDirectory.boolValue else {
                // A root can name one file; a new URL does not answer from values cached by an earlier listing.
                let file = URL(fileURLWithPath: url.path)
                if accepts(file) { list(file) }
                return true
            }
            var unreadable = 0
            defer { gaps.unreadable += unreadable }
            guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Self.keys, options: [.skipsHiddenFiles], errorHandler: { _, _ in
                unreadable += 1
                return true
            }) else {
                unreadable += 1
                return true
            }
            for case let url as URL in enumerator {
                visited += 1
                guard visited <= limit else { gaps.truncated = true; return false }
                if skips(url) { enumerator.skipDescendants(); continue }
                if accepts(url) { list(url) }
            }
            return true
        }

        private mutating func list(_ url: URL) {
            guard let values = try? url.resourceValues(forKeys: Set(Self.keys)), let modified = values.contentModificationDate,
                  let size = values.fileSize, values.isRegularFile != nil else { gaps.unreadable += 1; return }
            if values.isRegularFile == true { files[url.path] = File(modified: modified, size: size) }
        }
    }
}
