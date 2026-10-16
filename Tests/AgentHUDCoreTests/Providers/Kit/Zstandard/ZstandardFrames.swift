import Foundation

/// Zstandard frames written by hand (RFC 8878), for tests that need a compressed file without an encoder.
enum ZstandardFrames {
    static let magic: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]

    /// One frame holding `text` in raw blocks of at most 128 KB, stating the text's size in its header as Codex does, with
    /// a 2 MB window. Codex compresses its blocks; for a store, a frame of raw blocks is the same file.
    static func rollout(_ text: Data) -> Data {
        var frame = Data(magic + [0xC0, 0x58]) + littleEndian(text.count, bytes: 8)
        var start = 0
        repeat {
            let end = min(text.count, start + 128 << 10)
            frame += blockHeader(size: end - start, type: 0, last: end == text.count) + text[start..<end]
            start = end
        } while start < text.count
        return frame
    }

    /// A frame header: a window of `windowLog` bits unless the frame is one segment, the content size in `sizeBytes`
    /// bytes when given, and a checksum flag.
    static func header(contentSize: Int?, sizeBytes: Int = 8, windowLog: Int? = 21, checksum: Bool = false) -> Data {
        let sizeFlag: UInt8 = contentSize == nil ? 0 : [1: 0, 2: 1, 4: 2, 8: 3][sizeBytes]!
        let single = windowLog == nil
        var data = Data(magic + [sizeFlag << 6 | (single ? 0x20 : 0) | (checksum ? 0x04 : 0)])
        if let windowLog { data.append(UInt8((windowLog - 10) << 3)) }
        if let contentSize { data += littleEndian(sizeBytes == 2 ? contentSize - 256 : contentSize, bytes: sizeBytes) }
        return data
    }

    /// A block header: its size, its type (0 raw, 1 RLE, 2 compressed) and whether it ends the frame.
    static func blockHeader(size: Int, type: Int, last: Bool) -> Data {
        littleEndian(size << 3 | type << 1 | (last ? 1 : 0), bytes: 3)
    }

    /// A skippable frame holding `data`.
    static func skippable(_ data: Data) -> Data {
        Data([0x53, 0x2A, 0x4D, 0x18]) + littleEndian(data.count, bytes: 4) + data
    }

    static func littleEndian(_ value: Int, bytes: Int) -> Data {
        Data((0..<bytes).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
    }
}
