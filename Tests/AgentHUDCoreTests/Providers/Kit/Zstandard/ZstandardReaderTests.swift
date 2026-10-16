import CryptoKit
import XCTest
@testable import AgentHUDCore

/// The decoder reads what the reference encoder writes, a piece at a time, and reports a broken frame instead of decoding
/// it wrong. Every Codex rollout compressed on this Mac on 2026-10-15, 2,670 files and 14.3 GB of text, decoded to the
/// same bytes as `zstd -dc`; these fixtures keep the decoder's paths covered without them.
final class ZstandardReaderTests: XCTestCase, @unchecked Sendable {
    /// Written by `zstd` 1.5.7. Their texts, about which the tests know only the length and SHA-256 that `zstd -dc` gave:
    /// - lines-stream-19: 150 KB of JSON lines piped through `zstd -19`, so the frame states no size and carries a
    ///   checksum: six blocks, Huffman literals in one and four streams, the previous block's Huffman and sequence tables.
    /// - runs-19 and runs-9: a 200-byte random pattern repeated with runs of `a` between, to 270 KB, at levels 19 and 9:
    ///   raw literals, sequence tables predefined, of one symbol and repeated, and offsets one less than the last.
    /// - short-runs-19: 6.6 KB of `x` and `y` runs, at level 19: a single Huffman stream.
    /// - small-alphabet-19: 4,000 bytes below 21, at level 19: Huffman weights written directly.
    private static let fixtures: [(name: String, length: Int, sha256: String)] = [
        ("lines-stream-19", 150_000, "5a5ae630ad96a7e34bd06c4443aad60ca5e28903745c07ab1404c4ea96fd0349"),
        ("runs-19", 270_107, "ce0e43c8f6a10c509ec28cae6f68b85fb139a2008752c91247cb05f43aaed225"),
        ("runs-9", 270_107, "ce0e43c8f6a10c509ec28cae6f68b85fb139a2008752c91247cb05f43aaed225"),
        ("short-runs-19", 6_643, "c00d5210270b2b231d295a8a05d71f83b5c02c90a2b5177808470032aab36a13"),
        ("small-alphabet-19", 4_000, "1ba503504142f7cd77782107c6368f78498f7cc2a80275d1121f149e9d1ccb14"),
    ]

    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "zst"))
    }

    private func file(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zst")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func decode(_ url: URL, pieces: Int = 1 << 20) throws -> Data {
        let reader = try ZstandardReader(url: url)
        var text = Data()
        while true {
            let piece = try reader.read(upToCount: pieces)
            if piece.isEmpty { break }
            XCTAssertLessThanOrEqual(piece.count, pieces)
            text += piece
        }
        XCTAssertEqual(reader.position, text.count)
        return text
    }

    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    func testEncoderOutputDecodesToItsTextInPiecesOfAnySize() throws {
        for (name, length, sha256) in Self.fixtures {
            let url = try fixture(name)
            let text = try decode(url)
            XCTAssertEqual(text.count, length, name)
            XCTAssertEqual(digest(text), sha256, name)
            XCTAssertEqual(try decode(url, pieces: 1_000), text, "\(name) in small pieces")
            let reader = try ZstandardReader(url: url)
            XCTAssertEqual(try reader.skip(length / 3), length / 3)
            XCTAssertEqual(try reader.read(upToCount: .max), text.suffix(from: length / 3), "\(name) after passing over a third")
        }
        XCTAssertNil(try ZstandardReader.contentSize(of: fixture("lines-stream-19")), "a piped frame states no size")
        XCTAssertEqual(try ZstandardReader.contentSize(of: fixture("runs-19")), 270_107)
    }

    /// Raw, RLE and compressed blocks of hand-built literals across two frames, with a checksum and a skippable frame.
    func testEveryBlockKindAcrossFrames() throws {
        let raw = Data("hello ".utf8), end = Data("end\n".utf8)
        // A compressed block of 20 `q` as RLE literals, then one of raw literals; neither has sequences.
        let rleLiterals = Data([20 << 3 | 1, UInt8(ascii: "q"), 0]), rawLiterals = Data([UInt8(end.count) << 3]) + end + Data([0])
        var first = ZstandardFrames.header(contentSize: 6 + 5 + 20 + 4, sizeBytes: 4, checksum: true)
        first += ZstandardFrames.blockHeader(size: raw.count, type: 0, last: false) + raw
        first += ZstandardFrames.blockHeader(size: 5, type: 1, last: false) + Data([UInt8(ascii: "z")])
        first += ZstandardFrames.blockHeader(size: rleLiterals.count, type: 2, last: false) + rleLiterals
        first += ZstandardFrames.blockHeader(size: rawLiterals.count, type: 2, last: true) + rawLiterals
        first += Data([1, 2, 3, 4])
        let again = Data("again".utf8)
        let second = ZstandardFrames.header(contentSize: again.count, sizeBytes: 1, windowLog: nil)
            + ZstandardFrames.blockHeader(size: again.count, type: 0, last: true) + again
        let url = try file(first + ZstandardFrames.skippable(Data("metadata".utf8)) + second)
        XCTAssertEqual(String(decoding: try decode(url), as: UTF8.self), "hello zzzzz" + String(repeating: "q", count: 20) + "end\nagain")
        XCTAssertEqual(try ZstandardReader.contentSize(of: url), 35, "the first frame's size")
        XCTAssertNil(try ZstandardReader.contentSize(of: file(ZstandardFrames.skippable(Data()) + second)))
        XCTAssertThrowsError(try ZstandardReader.contentSize(of: file(Data("{\"type\":\"session_meta\"}\n".utf8)))) {
            XCTAssertEqual($0 as? ZstandardError, .notZstandard)
        }
    }

    func testABrokenFrameIsReportedRatherThanDecodedWrong() throws {
        let text = try decode(fixture("runs-19"))
        let compressed = try Data(contentsOf: fixture("runs-19"))
        XCTAssertThrowsError(try decode(file(compressed.dropLast(100)))) { XCTAssertEqual($0 as? ZstandardError, .corrupt, "cut short") }
        // A frame that states more text than its blocks hold.
        let short = ZstandardFrames.header(contentSize: 10, sizeBytes: 4) + ZstandardFrames.blockHeader(size: 3, type: 0, last: true) + Data("abc".utf8)
        XCTAssertThrowsError(try decode(file(short))) { XCTAssertEqual($0 as? ZstandardError, .corrupt) }
        XCTAssertThrowsError(try decode(file(ZstandardFrames.header(contentSize: nil, windowLog: 40)))) {
            XCTAssertEqual($0 as? ZstandardError, .unsupported, "a window past the reference decoder's limit")
        }
        XCTAssertEqual(text.count, 270_107)
    }
}
