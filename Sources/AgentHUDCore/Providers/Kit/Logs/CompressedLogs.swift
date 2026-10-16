import Foundation

/// Logs that their client compresses where they lie once they go cold, each into one Zstandard frame named after the log
/// with a suffix added. Codex turns a `rollout-….jsonl` it has not written for a week into `rollout-….jsonl.zst`, keeping
/// its modification time and stating the text's size in the frame's header, and turns it back into the plain log before
/// it writes to that session again. The text is the same in either form, so a store treats the two names as one log: the
/// compressed form is listed by the size of its text and hidden while the plain form is listed, which the client reads
/// first, and a log that changes form takes its state and its contribution to the new name (`handovers`). A compressed
/// log's text is decoded from the frame's start, so it is read forward only.
struct CompressedLogs {
    let suffix: String
    /// Text sizes read from frame headers, for the size and modification time each file had when its header was read.
    private var sizes: [String: (file: LogFiles.File, text: Int?)] = [:]
    /// A reader that a time budget stopped mid-text, with the start of a line it had not finished; the next read of the
    /// same log from the same place goes on with it instead of decoding the text up to there again.
    private var held: (path: String, file: LogFiles.File, reader: ZstandardReader, carry: Data)?

    init(suffix: String) {
        self.suffix = suffix
    }

    func isCompressed(_ path: String) -> Bool { path.hasSuffix(suffix) }

    /// The log's other form: the plain log of a compressed one, the compressed log of a plain one.
    func counterpart(_ path: String) -> String {
        isCompressed(path) ? String(path.dropLast(suffix.count)) : path + suffix
    }

    /// The listing as a store compares it. A compressed log is left out while its plain form is listed, and is listed
    /// by the size of its text where its header states it, so either form of a log has the same size.
    mutating func listing(_ files: [String: LogFiles.File]) -> [String: LogFiles.File] {
        var result: [String: LogFiles.File] = [:]
        for (path, file) in files {
            guard isCompressed(path) else {
                result[path] = file
                continue
            }
            guard files[counterpart(path)] == nil else { continue }
            result[path] = LogFiles.File(modified: file.modified, size: textSize(path, file: file) ?? file.size)
        }
        if sizes.keys.contains(where: { files[$0] == nil }) { sizes = sizes.filter { files[$0.key] != nil } }
        if let held, result[held.path] != held.file { self.held = nil }
        return result
    }

    /// The stored logs that left the listing while their other form is listed without a stored state of its own, each
    /// with the name it moves to. A store's rules for a changed log then decide what to read: nothing when the new form
    /// holds the same text, what was added when it holds more, and the whole log when it holds less.
    func handovers(stored: Set<String>, listing: [String: LogFiles.File]) -> [(from: String, to: String)] {
        stored.compactMap { path -> (from: String, to: String)? in
            let other = counterpart(path)
            guard listing[path] == nil, listing[other] != nil, !stored.contains(other) else { return nil }
            return (path, other)
        }.sorted { $0.from < $1.from }
    }

    /// Hands the complete lines of a compressed log's text from `offset` to `ingest`, a chunk at a time with the offset
    /// each chunk starts at, until the text ends or `deadline` passes, and at least one chunk. Returns where the lines
    /// handed over end, whether text is left, and how much text was decoded, including any passed over to reach `offset`.
    mutating func read(_ path: String, file: LogFiles.File, from offset: Int, chunkSize: Int, deadline: Date,
                       ingest: (Data, Int) throws -> Void) throws -> (offset: Int, waiting: Bool, decoded: Int) {
        var reader: ZstandardReader, carry = Data(), offset = offset, decoded = 0
        if let held, held.path == path, held.file == file, held.reader.position - held.carry.count == offset {
            (reader, carry) = (held.reader, held.carry)
        } else {
            reader = try ZstandardReader(url: URL(fileURLWithPath: path))
            decoded = try reader.skip(offset)
            guard decoded == offset else { throw ZstandardError.corrupt }
        }
        held = nil
        repeat {
            let chunk = try reader.read(upToCount: chunkSize)
            guard !chunk.isEmpty else { return (offset, false, decoded) }
            decoded += chunk.count
            carry.append(chunk)
            guard let newline = carry.lastIndex(of: 0x0A) else { continue }
            try ingest(carry[...newline], offset)
            offset += newline + 1
            carry = Data(carry[(newline + 1)...])
        } while Date() < deadline
        held = (path, file, reader, carry)
        return (offset, true, decoded)
    }

    /// Hands a compressed log's first `headLength` bytes of complete lines to `head`, then its complete lines before
    /// `end`, from its start, to `ingest` as `read` does: its history, which cannot be read backward a page at a time.
    func readHistory(_ path: String, before end: Int, headLength: Int, chunkSize: Int, head: (Data) -> Void,
                     ingest: (Data, Int) throws -> Void) throws -> Int {
        let reader = try ZstandardReader(url: URL(fileURLWithPath: path))
        var carry = try reader.read(upToCount: headLength), offset = 0
        head(carry.lastIndex(of: 0x0A).map { Data(carry[...$0]) } ?? Data())
        carry = Data(carry.prefix(end))
        while true {
            if let newline = carry.lastIndex(of: 0x0A) {
                try ingest(carry[...newline], offset)
                offset += newline + 1
                carry = Data(carry[(newline + 1)...])
            }
            guard offset + carry.count < end else { break }
            let chunk = try reader.read(upToCount: min(chunkSize, end - offset - carry.count))
            guard !chunk.isEmpty else { break }
            carry.append(chunk)
        }
        return reader.position
    }

    private mutating func textSize(_ path: String, file: LogFiles.File) -> Int? {
        if let known = sizes[path], known.file == file { return known.text }
        let text = (try? ZstandardReader.contentSize(of: URL(fileURLWithPath: path))) ?? nil
        sizes[path] = (file, text)
        return text
    }
}
