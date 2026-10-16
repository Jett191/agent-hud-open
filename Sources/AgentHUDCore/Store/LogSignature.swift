import Foundation

/// What tells a log that was written to since a look from the log as it was then: its modification time and size. A
/// client that keeps its log open and appends to it, as Codex does, moves both without the file watch always seeing it.
enum LogSignature {
    /// The log's signature now; nil when it cannot be looked at.
    static func of(_ path: String) -> String? {
        // A new URL does not answer from values cached by an earlier look.
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let modified = values.contentModificationDate, let size = values.fileSize else { return nil }
        return "\(modified.timeIntervalSince1970):\(size)"
    }
}
