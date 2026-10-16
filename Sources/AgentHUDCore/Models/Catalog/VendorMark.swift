import Foundation

/// The mark a vendor is drawn with, as a key. Vendors that share one piece of artwork share one key, and the HUD shows
/// one mark for them: Codex and ChatGPT share OpenAI's, Grok CLI is Grok's, and the OpenCode and Qoder builds share
/// their product's. The HUD's marks, the Simple panel's items, an agent's own panel and a layout's list of agents all
/// match vendors by this key.
public enum VendorMark {
    public static func key(_ vendor: String) -> String {
        switch vendor {
        case "Codex": "ChatGPT"
        case "Grok CLI": "Grok"
        case "OpenCode Go", "OpenCode-dark": "OpenCode"
        case "Qoder CN", "QoderWork", "Qoder-dark": "Qoder"
        default: vendor
        }
    }

    /// The vendors in order with one per mark: the first of the vendors that share one.
    public static func merged(_ vendors: [String]) -> [String] {
        var seen = Set<String>()
        return vendors.filter { seen.insert(key($0)).inserted }
    }
}
