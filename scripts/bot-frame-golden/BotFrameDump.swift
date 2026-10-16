import AppKit
import CryptoKit
import XCTest
@testable import AgentHUDDesktop

/// Dropped into a copy of the package by `scripts/bot-frame-golden.sh`; not part of the test target. Draws every
/// bot through a scripted 48 seconds in several settings, the way queues on two displays would interleave them,
/// and writes one line per frame with a hash of its bytes to the file named by `BOT_FRAME_DUMP`.
///
/// It only uses what the renderer has offered since origin/main 376e9d6, so the same file runs on both sides.
@MainActor
final class BotFrameDumpTests: XCTestCase {
    private static func aim(_ now: TimeInterval) -> CGPoint { CGPoint(x: 0.6 * cos(now * 0.7), y: 0.4 * sin(now * 1.1)) }

    /// The frames a bot draws, at 30 a second, through working, an alert, done, opened, idle and back.
    private static func motions(_ form: BotForm, seed: UInt64) -> [BotMotion] {
        var motion = BotMotion(seed: seed)
        motion.spin = form.spec.spin
        motion.period = 3
        let script: [(TimeInterval, BotPhase)] = [(0, .working), (12, .asking), (16, .done), (19, .opened), (22, .idle),
                                                  (34, .working), (40, .done)]
        var shown: BotRenderer.Look?, next = 0, frame = 0, drawn: [BotMotion] = []
        while Double(frame) / 30 < 48 {
            let now = Double(frame) / 30
            while next < script.count, script[next].0 <= now {
                motion.set(script[next].1, at: now)
                next += 1
            }
            motion.step(to: now, aim: aim(now))
            let look = BotRenderer.look(of: motion)
            if look != shown {
                shown = look
                drawn.append(motion)
            }
            frame += 1
        }
        return drawn
    }

    func testDump() throws {
        guard let path = ProcessInfo.processInfo.environment["BOT_FRAME_DUMP"] else {
            throw XCTSkip("Run by scripts/bot-frame-golden.sh")
        }
        var settings: [(side: CGFloat, outline: Int, space: CGColorSpace?)] = [
            (40, 1, CGColorSpace(name: CGColorSpace.displayP3)),
            (40, 0, nil),
            (20, 1, CGColorSpace(name: CGColorSpace.sRGB)),
            (37, 0, CGColorSpace(name: CGColorSpace.adobeRGB1998)),
            (44, 1, CGColorSpace(name: CGColorSpace.displayP3)),
        ]
        let display = CGDisplayCopyColorSpace(CGMainDisplayID())
        if display.model == .rgb { settings.append((40, 1, display)) }
        func hash(_ image: CGImage?) -> String {
            guard let image, let data = image.dataProvider?.data as Data? else { return "none" }
            return "\(image.width)x\(image.height) " + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        var bots: [(vendor: String, form: BotForm, seed: UInt64, motions: [BotMotion])] = []
        for vendor in AgentArtwork.allVendors {
            let form = try XCTUnwrap(BotForm.form(for: vendor))
            for seed: UInt64 in [1, 7] { bots.append((vendor, form, seed, Self.motions(form, seed: seed))) }
        }
        var lines: [String] = []
        // One bot at a time, its settings in turn frame by frame.
        for bot in bots {
            for (index, motion) in bot.motions.enumerated() {
                for (place, setting) in settings.enumerated() {
                    let image = BotRenderer.image(bot.form, motion: motion, side: setting.side, outline: setting.outline,
                                                  space: setting.space)
                    lines.append("one \(bot.vendor) seed \(bot.seed) setting \(place) frame \(index) " + hash(image))
                }
            }
        }
        // Every bot in turn, frame by frame, in two settings.
        for index in 0..<bots.map(\.motions.count).max()! {
            for bot in bots where index < bot.motions.count {
                for place in 0..<2 {
                    let setting = settings[place]
                    let image = BotRenderer.image(bot.form, motion: bot.motions[index], side: setting.side,
                                                  outline: setting.outline, space: setting.space)
                    lines.append("all \(bot.vendor) seed \(bot.seed) setting \(place) frame \(index) " + hash(image))
                }
            }
        }
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        print("bot frames dumped: \(lines.count)")
    }
}
