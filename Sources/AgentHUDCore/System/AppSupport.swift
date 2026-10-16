import Foundation

/// Application-owned caches and local usage history.
public enum AppSupport {
    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(directoryName(of: .main), isDirectory: true)
    }

    /// The name of the data directory the application in `bundle` keeps: its `AgentHUDDataDirectory`, else
    /// `Agent HUD Open`, as for an executable outside a bundle.
    static func directoryName(of bundle: Bundle?) -> String {
        bundle?.object(forInfoDictionaryKey: "AgentHUDDataDirectory") as? String ?? "Agent HUD Open"
    }
}
