import AgentHUDCore
import AppKit
import QuartzCore
import XCTest
@testable import AgentHUDDesktop

/// A bot's frames are drawn from kept parts wherever they can be. These hold every such frame to the one drawn
/// whole, the outline and the hairline to the ones drawn before they were made cheaper, byte for byte, and measure
/// what a frame costs.
@MainActor
final class BotFrameTests: XCTestCase {
    /// A pointer that keeps moving, so the eyes keep following it.
    private static func aim(at now: TimeInterval) -> CGPoint {
        CGPoint(x: 0.6 * cos(now * 0.7), y: 0.4 * sin(now * 1.1))
    }

    /// The motions a bot would draw a frame for, at 30 frames a second, through `phases` from the given times.
    private static func motions(of form: BotForm, seed: UInt64, until end: TimeInterval,
                                phases: [(TimeInterval, BotPhase)]) -> [BotMotion] {
        var motion = BotMotion(seed: seed)
        motion.spin = form.spec.spin
        var drawn: [BotMotion] = [], shown: BotRenderer.Look?, next = 0, frame = 0
        while Double(frame) / 30 < end {
            let now = Double(frame) / 30
            while next < phases.count, phases[next].0 <= now {
                motion.set(phases[next].1, at: now)
                next += 1
            }
            motion.step(to: now, aim: aim(at: now))
            let look = BotRenderer.look(of: motion)
            if look != shown {
                shown = look
                drawn.append(motion)
            }
            frame += 1
        }
        return drawn
    }

    private static let phases: [(TimeInterval, BotPhase)] = [(0, .working), (4, .opened), (5, .asking), (6, .done), (7.5, .idle)]

    private static func bytes(_ image: CGImage?) -> Data {
        (image?.dataProvider?.data as Data?) ?? Data()
    }

    /// The ways a queue draws a bot: its size, its hairline and its display's colours.
    private struct Setting {
        var side: CGFloat
        var outline: Int
        var space: CGColorSpace?
    }

    /// The settings the app draws in, side by side: a 20 pt mark at 2x with its hairline on a P3 display, the
    /// stand-alone mark without one, a mark at 1x, sizes that are not even, colours that are not the usual ones,
    /// and the main display's own.
    private static let settings: [Setting] = {
        var settings = [Setting(side: 40, outline: 1, space: CGColorSpace(name: CGColorSpace.displayP3)),
                        Setting(side: 40, outline: 0, space: nil),
                        Setting(side: 20, outline: 1, space: CGColorSpace(name: CGColorSpace.sRGB)),
                        Setting(side: 37, outline: 0, space: CGColorSpace(name: CGColorSpace.adobeRGB1998))]
        let display = CGDisplayCopyColorSpace(CGMainDisplayID())
        if display.model == .rgb { settings.append(Setting(side: 44, outline: 1, space: display)) }
        return settings
    }()

    private static func draw(_ form: BotForm, _ motion: BotMotion, _ setting: Setting) -> CGImage? {
        BotRenderer.image(form, motion: motion, side: setting.side, outline: setting.outline, space: setting.space)
    }

    /// The same frame with nothing kept from any earlier one.
    private static func drawnWhole(_ form: BotForm, _ motion: BotMotion, _ setting: Setting) -> Data {
        BotCanvas.forget()
        BotStill.forget()
        return bytes(draw(form, motion, setting))
    }

    /// Every bot through a morph, its acts, an alert and back, drawn as two queues would draw it in every setting
    /// in turn, and each frame drawn again whole in a new bitmap.
    func testAFrameFromKeptPartsIsTheFrameDrawnWhole() throws {
        var frames = 0, differing: [String] = []
        for vendor in AgentArtwork.allVendors {
            let form = try XCTUnwrap(BotForm.form(for: vendor))
            let screens = (0..<2).map { Self.motions(of: form, seed: UInt64($0 + 1), until: 9, phases: Self.phases) }
            // Both screens' frames, in every setting, in turn the way the clock draws them, from whatever is kept.
            var kept: [[[Data]]] = Array(repeating: Array(repeating: [], count: Self.settings.count), count: 2)
            for index in 0..<screens.map(\.count).max()! {
                for (screen, motions) in screens.enumerated() where index < motions.count {
                    for (place, setting) in Self.settings.enumerated() {
                        kept[screen][place].append(Self.bytes(Self.draw(form, motions[index], setting)))
                    }
                }
            }
            // Then each frame again with nothing kept.
            for (screen, motions) in screens.enumerated() {
                for (index, motion) in motions.enumerated() {
                    for (place, setting) in Self.settings.enumerated() {
                        frames += 1
                        if kept[screen][place][index] != Self.drawnWhole(form, motion, setting) {
                            differing.append("\(vendor) screen \(screen) setting \(place) frame \(index)")
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(frames, 25000)
        XCTAssertEqual(differing.prefix(20), [], "\(differing.count) of \(frames) frames differ")
    }

    /// Every bot at once, frame by frame, in more settings than there is room to keep, so kept parts are shared,
    /// passed between bots and let go.
    func testFramesOfManyBotsInTurnAreTheFramesDrawnWhole() throws {
        let bots = try AgentArtwork.allVendors.map { vendor in
            let form = try XCTUnwrap(BotForm.form(for: vendor))
            return (vendor, form, Self.motions(of: form, seed: 5, until: 9, phases: Self.phases))
        }
        let settings = Array(Self.settings.prefix(3))
        var kept: [[[Data]]] = bots.map { _ in settings.map { _ in [] } }
        for index in 0..<bots.map(\.2.count).max()! {
            for (bot, (_, form, motions)) in bots.enumerated() where index < motions.count {
                for (place, setting) in settings.enumerated() {
                    kept[bot][place].append(Self.bytes(Self.draw(form, motions[index], setting)))
                }
            }
        }
        var frames = 0, differing: [String] = []
        for (bot, (vendor, form, motions)) in bots.enumerated() {
            for (index, motion) in motions.enumerated() {
                for (place, setting) in settings.enumerated() {
                    frames += 1
                    if kept[bot][place][index] != Self.drawnWhole(form, motion, setting) {
                        differing.append("\(vendor) setting \(place) frame \(index)")
                    }
                }
            }
        }
        XCTAssertGreaterThan(frames, 10000)
        XCTAssertEqual(differing.prefix(20), [], "\(differing.count) of \(frames) frames differ")
    }

    /// The outline built from kept directions, and handed back when it is asked for again, is the one built a
    /// point at a time, at every moment of every bot's morph and turn.
    func testTheOutlineIsTheOneBuiltBefore() throws {
        var outlines = 0, differing: [String] = []
        for vendor in AgentArtwork.allVendors {
            let form = try XCTUnwrap(BotForm.form(for: vendor))
            var moments = Self.motions(of: form, seed: 3, until: 9, phases: Self.phases)
                .map { (BotMotion.easeInOut($0.morph), $0.turn) }
            moments += [(0, 0), (1, 0), (0.5, 359.75), (1, -12.5), (0.25, 721.5), (1, 0)]
            for (eased, turn) in moments {
                outlines += 1
                if BotFramesAsBefore.elements(of: form.outline(eased: eased, turn: turn))
                    != BotFramesAsBefore.elements(of: BotFramesAsBefore.outline(form, eased: eased, turn: turn)) {
                    differing.append("\(vendor) at \(eased), turned \(turn)")
                }
            }
        }
        XCTAssertGreaterThan(outlines, 3000)
        XCTAssertEqual(differing.prefix(20), [], "\(differing.count) of \(outlines) outlines differ")
    }

    /// Whole frames with their hairline, from every bot in every setting that has one, are the same frames drawn
    /// without it with the hairline then laid as it was before.
    func testTheHairlineIsTheOneLaidBefore() throws {
        for space in [CGColorSpace(name: CGColorSpace.sRGB)!, CGColorSpace(name: CGColorSpace.displayP3)!] {
            let probe = try XCTUnwrap(BotCanvas.clear(66, space: space))
            XCTAssertNotNil(BotHairline.strengths(for: probe), "\(space): Accelerate lays the hairline as Core Graphics does")
        }
        var frames = 0, differing: [String] = []
        for vendor in AgentArtwork.allVendors {
            let form = try XCTUnwrap(BotForm.form(for: vendor))
            let motions = Self.motions(of: form, seed: 3, until: 9, phases: Self.phases)
            for (index, motion) in motions.enumerated() where index % 3 == 0 {
                for setting in Self.settings where setting.outline > 0 {
                    let laid = Self.bytes(Self.draw(form, motion, setting))
                    let bare = try XCTUnwrap(BotRenderer.bare(form, motion: motion, side: setting.side,
                                                              outline: setting.outline, space: setting.space))
                    frames += 1
                    if laid != Self.bytes(BotFramesAsBefore.hairlined(bare, reach: setting.outline)) {
                        differing.append("\(vendor) frame \(index) at \(setting.side)")
                    }
                }
            }
        }
        XCTAssertGreaterThan(frames, 2000)
        XCTAssertEqual(differing.prefix(20), [], "\(differing.count) of \(frames) frames differ")
    }

    /// Not a benchmark unless asked for: `AGENT_HUD_BENCH_BOTS=1 swift test --filter BotFrameTests`, in a debug or
    /// a release build. A typical Dynamic-mode queue on two displays, timed in thread CPU time: a minute of its
    /// drawing alone, then two minutes of the clock ticking 30 times a second as `BotClock` runs it.
    func testFrameCost() throws {
        guard ProcessInfo.processInfo.environment["AGENT_HUD_BENCH_BOTS"] == "1" else {
            throw XCTSkip("Set AGENT_HUD_BENCH_BOTS=1 to time a bot's frames")
        }
        func cpu() -> TimeInterval {
            var time = timespec()
            clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
            return TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1e9
        }
        let rows: [(String, BotPhase)] = [("Claude", .working), ("Codex", .working), ("Cursor", .idle),
                                          ("Grok", .working), ("OpenCode", .idle), ("DeepSeek", .idle)]
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let minute: [(TimeInterval, BotPhase)] = [(0, .working), (20, .asking), (26, .done), (30, .opened), (40, .idle), (45, .working)]

        // The drawing alone: every frame a working bot draws in that minute, best of five rounds.
        var drawn: [(BotForm, BotMotion)] = []
        for (index, row) in rows.enumerated() {
            let form = try XCTUnwrap(BotForm.form(for: row.0))
            drawn += Self.motions(of: form, seed: UInt64(index + 1), until: 60, phases: minute).map { (form, $0) }
        }
        var best = TimeInterval.infinity
        for _ in 0..<5 {
            let began = cpu()
            for (form, motion) in drawn { autoreleasepool { _ = BotRenderer.image(form, motion: motion, side: 40, outline: 1, space: space) } }
            best = min(best, cpu() - began)
        }
        print(String(format: "bot frame: %.1f µs each, %d frames over %d bot-minutes",
                     best / Double(drawn.count) * 1e6, drawn.count, rows.count))

        // The clock: two queues of those six marks, stepped as their actors ask, frames committed every tick.
        let root = CALayer()
        var actors: [BotActor] = []
        for screen in 0..<2 {
            for (index, row) in rows.enumerated() {
                let actor = BotActor(form: try XCTUnwrap(BotForm.form(for: row.0)), staysBot: false, period: 3,
                                     seed: UInt64(screen * 100 + index + 1))
                actor.resize(side: 20, scale: 2, outline: 1)
                actor.show(in: space)
                actor.set(row.1, at: 0)
                root.addSublayer(actor.layer)
                actors.append(actor)
            }
        }
        var now: TimeInterval = 0, busy: TimeInterval = 0, ticks = 0
        while now < 120 {
            let began = cpu()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for actor in actors { _ = actor.step(to: now, yRunsDown: true) { Self.aim(at: now) } }
            CATransaction.commit()
            busy += cpu() - began
            ticks += 1
            now += BotPace.lively
        }
        print(String(format: "bot clock: %.1f µs a tick, %.2f ms a second at 30 ticks a second",
                     busy / Double(ticks) * 1e6, busy / now * 1000))
    }
}
