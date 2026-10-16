import AppKit
import CryptoKit
import XCTest
@testable import AgentHUDDesktop

/// The bundled artwork is read for what is made from it and then let go; what is made from a fresh read is the same,
/// pixel for pixel, as what was made from one kept.
///
/// `AGENT_HUD_PROBE_ARTWORK_OUTPUT` also writes the hash of every baked mark, bot artwork and accent, so two builds
/// can be compared by the file's hash.
@MainActor
final class ArtworkMemoryTests: XCTestCase {
    private func bytes(_ image: CGImage?) -> Data? {
        guard let image, let data = image.dataProvider?.data else { return nil }
        return Data(bytes: CFDataGetBytePtr(data), count: CFDataGetLength(data))
    }

    private func hash(_ image: CGImage?) -> String {
        guard let image, let data = bytes(image) else { return "none" }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "\(image.width)x\(image.height)/\(image.bitsPerPixel)/\(digest)"
    }

    func testAnOriginalIsReadAfreshAndKeptByNoOne() throws {
        weak var read: NSImage?
        try autoreleasepool {
            let image = try XCTUnwrap(AgentArtwork.original(for: "ChatGPT"))
            var rect = CGRect(origin: .zero, size: image.size)
            XCTAssertNotNil(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
            XCTAssertFalse(image === AgentArtwork.original(for: "ChatGPT"))
            read = image
        }
        XCTAssertNil(read, "nothing keeps the artwork, or its 12.5 MB of drawn pixels, once its caller is done")
    }

    func testAMarkBakedFromAFreshReadIsTheSameAsTheFirst() throws {
        for vendor in AgentArtwork.allVendors {
            for (side, outline, light) in [(30, 1, false), (88, 1, false), (44, 0, true)] {
                let key = LogoImages.Key(vendor: vendor, side: side, outline: outline, light: light)
                LogoImages.invalidate()
                let first = bytes(LogoImages.image(key)), bounds = LogoImages.visibleBounds(key)
                LogoImages.invalidate()
                XCTAssertEqual(bytes(LogoImages.image(key)), first, "\(vendor) \(side)")
                XCTAssertEqual(LogoImages.visibleBounds(key), bounds, "\(vendor) \(side)")
            }
            let form = BotForm.read(vendor), again = BotForm.read(vendor)
            XCTAssertEqual(bytes(again?.artwork), bytes(form?.artwork), vendor)
            XCTAssertEqual(bytes(again?.field), bytes(form?.field), vendor)
            XCTAssertEqual(again?.logoReach, form?.logoReach, vendor)
        }
    }

    /// Explicit local probe: `AGENT_HUD_PROBE_ARTWORK_OUTPUT=<file>` runs it.
    func testProbeWritesEveryBakedMarkBotAndAccent() throws {
        guard let path = ProcessInfo.processInfo.environment["AGENT_HUD_PROBE_ARTWORK_OUTPUT"] else {
            throw XCTSkip("Set AGENT_HUD_PROBE_ARTWORK_OUTPUT for a local probe")
        }
        var output: [String: String] = [:]
        for vendor in AgentArtwork.allVendors + ["Codex", "Claude Code"] {
            for side in [16, 30, 44, 60, 88, 128] {
                for outline in [0, 1] {
                    for light in [false, true] {
                        let key = LogoImages.Key(vendor: vendor, side: side, outline: outline, light: light)
                        // The second read is the one the change touches: before it, a kept artwork; after it, a fresh one.
                        _ = LogoImages.image(key); LogoImages.invalidate()
                        output["mark/\(vendor)/\(side)/\(outline)/\(light)"] = hash(LogoImages.image(key)) + "|\(LogoImages.visibleBounds(key))"
                    }
                }
            }
            let form = BotForm.read(vendor)
            output["bot/\(vendor)"] = [hash(form?.artwork), hash(form?.field), hash(form?.stripped),
                                       "\(form?.logoReach.reduce(0, +) ?? -1)", "\(form?.bodyReach.reduce(0, +) ?? -1)"].joined(separator: "|")
            output["accent/\(vendor)"] = AgentArtwork.accent(for: vendor).map { "\($0.redComponent),\($0.greenComponent),\($0.blueComponent)" } ?? "none"
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(output).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
