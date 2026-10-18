import AgentHUDCore
import AppKit
import SwiftUI
import XCTest
@testable import AgentHUDDesktop

/// A light HUD: text colours that read on its near-white surface, agents' colours that stand on it, and bots and marks in
/// dark ink; while the dark HUD keeps every colour it drew with.
@MainActor
final class LightLookTests: XCTestCase {
    private let agent = AgentDescriptor(id: "claude-session", vendor: "Claude", model: "Session", source: "", enabled: true)

    private var alerts: [IslandAlert] {
        [.completion(SessionCompletion(sessionID: "s", vendor: "Claude", turnID: "t", task: "Task", model: "Model",
                                       startedAt: nil, completedAt: Date(timeIntervalSince1970: 0))),
         .quota(.preview(.exhaustion, agent: agent)), .quota(.preview(.reset, agent: agent)),
         .resetCredits(.preview())]
    }

    /// Text, thin glyphs and agents' colours on the dark HUD are the very colours it drew them in before it had text
    /// colours of their own, so the standard look draws as it did.
    func testTheDarkHUDsTextColoursAreTheColoursItDrewWith() {
        let island = Theme.island
        for level in StatusLevel.allCases {
            XCTAssertEqual(island.statusText(level), island.status(level), "\(level)")
        }
        XCTAssertEqual(island.idle, Color(StatusPalette.idle))
        XCTAssertEqual(island.idleText, Color(StatusPalette.idle))
        XCTAssertEqual(island.insetSurface, island.rowBackground)
        for index in 0..<12 {
            XCTAssertEqual(island.agent(index), AgentPalette.swiftUIColor(index: index), "\(index)")
        }
        for alert in alerts {
            XCTAssertEqual(alert.accentText(island), Color(alert.accent), alert.id)
            XCTAssertEqual(alert.accentFill(island), Color(alert.accent), alert.id)
        }
        XCTAssertEqual(island.onAlertFill, island.onAccent)
        for opacity in [0.4, 0.42, 0.45, 0.5, 0.58, 0.65, 0.92] {
            XCTAssertEqual(island.alertInk(opacity), island.alertText.opacity(opacity), "\(opacity)")
        }
        let color = PermissionColor(island)
        XCTAssertEqual(color.signalText, color.signal)
        XCTAssertEqual(color.allowText, color.allow)
        XCTAssertEqual(color.denyText, color.deny)
        XCTAssertEqual(color.inset, Theme.island.rowBackground)
    }

    /// On the light HUD's surface the text colours read at about 4.5:1, where the tints made for fills read at 2 to 3:1.
    func testTheLightHUDsTextReadsOnItsSurface() throws {
        let surface = try rgb(Theme.lightIsland.islandFill)
        for level in StatusLevel.allCases {
            XCTAssertGreaterThanOrEqual(try contrast(rgb(Theme.lightIsland.statusText(level)), surface), 4.4, "\(level)")
        }
        XCTAssertGreaterThanOrEqual(contrast(rgb(StatusPalette.idleTextColor(light: true)), surface), 4.4)
        for alert in alerts {
            XCTAssertGreaterThanOrEqual(try contrast(rgb(alert.accentText(.light)), surface), 4.4, alert.id)
            XCTAssertLessThan(contrast(rgb(alert.accent), surface), 3, "the accent itself is a fill's colour")
        }
        for token in [Theme.light.text, Theme.light.secondary, Theme.light.alertText] {
            XCTAssertGreaterThanOrEqual(try contrast(rgb(token), surface), 4.5)
        }
        XCTAssertLessThan(contrast(rgb(StatusPalette.okLight), surface), 3, "the light tints are not text")
    }

    /// The light HUD's levels stand at least 3:1 on its surface as a fill, a ring, a bar or a dot, where the system's tints
    /// for fills, yellow and green above all, all but vanish.
    func testTheLightHUDsLevelsStandOnItsSurface() throws {
        let surface = try rgb(Theme.lightIsland.islandFill)
        for level in StatusLevel.allCases {
            XCTAssertGreaterThanOrEqual(try contrast(rgb(Theme.lightIsland.status(level)), surface), 3, "\(level)")
        }
        XCTAssertLessThan(contrast(rgb(StatusPalette.warningLight), surface), 1.5, "the tint itself")
    }

    /// The light window keeps the levels it drew with: its menu bar, Settings and statistics are no part of the HUD.
    func testTheLightWindowKeepsItsLevels() {
        for level in StatusLevel.allCases {
            XCTAssertEqual(Theme.light.status(level), Color(StatusPalette.color(for: level, light: true)), "\(level)")
        }
        XCTAssertEqual(Theme.light.statusText(.warning), Color(StatusPalette.warningTextLight))
        XCTAssertEqual(StatusPalette.warningTextLight.hexString, "#c7a100")
        XCTAssertEqual(Theme.light.statusText(.ok), Color(StatusPalette.okLight))
        XCTAssertEqual(Theme.light.statusText(.critical), Color(StatusPalette.criticalLight))
        XCTAssertEqual(Theme.light.cardBorder, Color.black.opacity(0.06))
    }

    /// On the light HUD the alerts' buttons are filled with the accents' deep shades under white ink, which reads as a
    /// button that can be pressed, and their captions are graded up to stay legible on the near-white surface.
    func testTheLightHUDsAlertsReadOnItsSurface() throws {
        let theme = Theme.lightIsland
        let surface = try rgb(theme.islandFill), ink = try rgb(theme.onAlertFill)
        for alert in alerts {
            let fill = try rgb(alert.accentFill(theme))
            XCTAssertGreaterThanOrEqual(contrast(ink, fill), 4.5, alert.id)
            XCTAssertGreaterThanOrEqual(contrast(fill, surface), 3, alert.id)
        }
        // The faintest caption, the alert ink at 0.4, laid over the surface as it is drawn.
        let caption = try over(theme.alertInk(0.4), surface)
        XCTAssertGreaterThanOrEqual(contrast(caption, surface), 4.3)
        XCTAssertEqual(theme.alertInk(0.9), theme.alertText.opacity(1), "a grade near full strength stops at full")
    }

    /// The light HUD's agents' colours stand at least 3:1 on its surface, as a dot or a bar must; the dark HUD's are the
    /// statistics window's own.
    func testTheLightHUDsAgentColoursStandOnItsSurface() throws {
        let surface = try rgb(Theme.light.islandFill)
        XCTAssertEqual(AgentPalette.lightColors.count, AgentPalette.colors.count)
        for (index, color) in AgentPalette.lightColors.enumerated() {
            XCTAssertGreaterThanOrEqual(contrast(rgb(color), surface), 3, "\(index)")
        }
        for index in [-1, 0, 5, 6, 13] {
            XCTAssertEqual(AgentPalette.color(index: index, light: false), AgentPalette.color(index: index), "\(index)")
        }
        XCTAssertEqual(Theme.light.agent(7), Color(AgentPalette.lightColors[1]))
    }

    /// A bot in light ink wears dark ink on a light ground, and a body that turned dark has its eyes cut in the ground's
    /// colour. A coloured mark's bot is the same on either ground.
    func testABotInLightInkWearsDarkInkOnALightGround() throws {
        let dark = try XCTUnwrap(BotSpec.spec(for: "Grok Bot", ground: .dark))
        let light = try XCTUnwrap(BotSpec.spec(for: "Grok Bot", ground: .light))
        guard case .solid(let white) = dark.paint, case .solid(let black) = light.paint else {
            return XCTFail("Grok Bot is one flat colour")
        }
        XCTAssertEqual(white, RGBA(hex: 0xffffff))
        XCTAssertEqual(black, RGBA(hex: 0x000000))
        XCTAssertNil(dark.eyeColor)
        XCTAssertEqual(light.eyeColor, BotSpec.lightCut)

        // A single-colour mark's bot is its own stencil, dark on a light ground.
        XCTAssertNil(BotSpec.spec(for: "Cursor", ground: .dark)?.eyeColor)
        XCTAssertEqual(BotSpec.spec(for: "Cursor", ground: .light)?.eyeColor, BotSpec.lightCut)
        // The cats keep their white eyes on their coloured faces; Claude keeps its colours and its dark eyes.
        XCTAssertEqual(BotSpec.spec(for: "CodeBuddy", ground: .light)?.eyeColor, RGBA(hex: 0xffffff))
        XCTAssertNil(BotSpec.spec(for: "Claude", ground: .light)?.eyeColor)
        guard case .artwork? = BotSpec.spec(for: "Claude", ground: .light)?.paint else {
            return XCTFail("Claude's bot keeps its artwork's colours")
        }
    }

    /// Devin's pale tile stays visible on either ground after it morphs into a bot.
    func testDevinDrawsItsTileBotInReadableInkOnBothGrounds() throws {
        for ground in [HUDLook.Appearance.dark, .light] {
            let form = try XCTUnwrap(BotForm.form(for: "Devin", ground: ground))
            var motion = BotMotion(seed: 3)
            motion.fit(form.spec)
            motion.set(.working, at: 0)
            for frame in 0...30 { motion.step(to: Double(frame) / 30) }
            XCTAssertEqual(motion.morph, 1)
            let image = try XCTUnwrap(BotRenderer.image(form, motion: motion, side: 40))
            let brightness = Self.brightness(of: image)
            if ground == .dark { XCTAssertGreaterThan(brightness, 0.9, "light tile and dark eyes on the dark HUD") }
            else { XCTAssertLessThan(brightness, 0.2, "dark tile and light eyes on the light HUD") }
        }
    }

    /// A form is read once for each mark and ground, and a single-colour mark's is a stencil in that ground's ink.
    func testABotsFormIsReadOncePerMarkAndGround() throws {
        let dark = try XCTUnwrap(BotForm.form(for: "Cursor", ground: .dark))
        let light = try XCTUnwrap(BotForm.form(for: "Cursor", ground: .light))
        XCTAssertFalse(dark === light)
        XCTAssertTrue(light === BotForm.form(for: "Cursor", ground: .light))
        XCTAssertEqual(dark.ground, .dark)
        XCTAssertEqual(light.ground, .light)
        XCTAssertGreaterThan(Self.brightness(of: dark.artwork), 0.9, "a white stencil on a dark ground")
        XCTAssertLessThan(Self.brightness(of: light.artwork), 0.2, "a dark stencil on a light ground")
        // Every frame of a bot in dark ink can be drawn, outlined or not.
        let image = try XCTUnwrap(BotRenderer.image(light, motion: BotMotion(seed: 3), side: 40, outline: 1))
        XCTAssertGreaterThan(image.width, 40)
    }

    /// A dock's single-colour mark is drawn in the ink of the ground its look gives it.
    func testADocksSingleColourMarkTakesTheInkOfItsGround() throws {
        let dark = try XCTUnwrap(LogoImages.image(.init(vendor: "Cursor", side: 40, outline: 1, light: false)))
        let light = try XCTUnwrap(LogoImages.image(.init(vendor: "Cursor", side: 40, outline: 1, light: true)))
        XCTAssertGreaterThan(Self.brightness(of: dark), 0.9)
        XCTAssertLessThan(Self.brightness(of: light), 0.2)
    }

    /// A bot on a reminder or the Simple panel is built again, in the other ink, when its HUD's look changes ground, and
    /// kept while it does not.
    func testABotOnStageIsBuiltAgainForAnotherGround() throws {
        let stage = BotStageView()
        defer { BotClock.shared.drop(stage) }
        stage.show(vendor: "Claude", size: 17, scale: 2, phase: .idle, ground: .dark)
        let first = try XCTUnwrap(stage.layer?.sublayers?.first)
        XCTAssertNil(stage.layer?.animation(forKey: kCATransition), "a bot's first showing is no change of look")
        stage.show(vendor: "Claude", size: 17, scale: 2, phase: .idle, ground: .dark)
        XCTAssertTrue(stage.layer?.sublayers?.first === first)
        stage.show(vendor: "Claude", size: 17, scale: 2, phase: .idle, ground: .light)
        XCTAssertFalse(stage.layer?.sublayers?.contains { $0 === first } ?? true)
        XCTAssertNotNil(stage.layer?.sublayers?.first)
        XCTAssertNotNil(stage.layer?.animation(forKey: kCATransition), "the bot in the new ink fades in over the old one")
    }

    /// A change of look alone fades a dock's marks into the new ground's ink, as the surface behind them moves to its new
    /// colours. A dock that changes otherwise is laid out again at once, and so is every change under Reduce Motion.
    func testAChangeOfGroundAloneFadesADocksMarks() {
        let placement = ScreenPlacement(edge: .top, logoSize: 24, logoEdgeDistance: 0)
        func config(_ vendors: [String]) -> LogoQueueConfig {
            LogoQueueConfig(items: vendors.map { LogoQueueItem(vendor: $0, isWorking: false) }, placement: placement,
                            settings: AgentHUDCore.Settings())
        }
        let one = config(["Cursor"]), two = config(["Cursor", "Claude"])

        let view = LogoQueueLayerView()
        view.apply(config: one, light: false, scale: 2, animates: true)
        XCTAssertNil(view.layer?.animation(forKey: kCATransition), "the first marks are no change of look")
        view.apply(config: one, light: true, scale: 2, animates: true)
        XCTAssertNotNil(view.layer?.animation(forKey: kCATransition))

        let reshaped = LogoQueueLayerView()
        reshaped.apply(config: one, light: false, scale: 2, animates: true)
        reshaped.apply(config: two, light: true, scale: 2, animates: true)
        XCTAssertNil(reshaped.layer?.animation(forKey: kCATransition), "another agent is another queue")
        XCTAssertEqual(reshaped.marks.count, 2)

        let still = LogoQueueLayerView()
        still.apply(config: one, light: false, scale: 2, animates: false)
        still.apply(config: one, light: true, scale: 2, animates: false)
        XCTAssertNil(still.layer?.animation(forKey: kCATransition), "Reduce Motion")
    }

    // MARK: Helpers

    private func rgb(_ color: RGBA) -> (Double, Double, Double) { (color.red, color.green, color.blue) }

    private func rgb(_ color: Color) throws -> (Double, Double, Double) {
        let srgb = try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB))
        return (Double(srgb.redComponent), Double(srgb.greenComponent), Double(srgb.blueComponent))
    }

    /// `color`, which may be translucent, laid over the opaque `ground`.
    private func over(_ color: Color, _ ground: (Double, Double, Double)) throws -> (Double, Double, Double) {
        let srgb = try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB))
        let alpha = Double(srgb.alphaComponent)
        func mix(_ channel: CGFloat, _ under: Double) -> Double { Double(channel) * alpha + under * (1 - alpha) }
        return (mix(srgb.redComponent, ground.0), mix(srgb.greenComponent, ground.1), mix(srgb.blueComponent, ground.2))
    }

    /// WCAG's contrast ratio of two opaque colours.
    private func contrast(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        func channel(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        func luminance(_ c: (Double, Double, Double)) -> Double {
            0.2126 * channel(c.0) + 0.7152 * channel(c.1) + 0.0722 * channel(c.2)
        }
        let one = luminance(a), other = luminance(b)
        return (max(one, other) + 0.05) / (min(one, other) + 0.05)
    }

    /// The mean brightness of an image's opaque pixels, 0 to 1.
    private static func brightness(of image: CGImage) -> Double {
        guard let context = BotForm.bitmap(image.width) else { return -1 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.width))
        guard let data = context.data else { return -1 }
        let bytes = data.assumingMemoryBound(to: UInt8.self), count = image.width * image.width
        var sum = 0.0, seen = 0
        for index in 0..<count where bytes[index * 4 + 3] > 250 {
            sum += (Double(bytes[index * 4]) + Double(bytes[index * 4 + 1]) + Double(bytes[index * 4 + 2])) / (3 * 255)
            seen += 1
        }
        return seen == 0 ? -1 : sum / Double(seen)
    }
}
