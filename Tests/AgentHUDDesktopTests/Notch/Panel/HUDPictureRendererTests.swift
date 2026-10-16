import AgentHUDSupport
import AppKit
import SwiftUI
import XCTest
@testable import AgentHUDCore
@testable import AgentHUDDesktop

/// A screen's resting HUD drawn off screen for an agent, as `get_panel_image` returns it with show "hud": the island
/// with its glow, a Dynamic dock's marks over their backdrop, a Simple panel, each as the screen draws it now with any
/// style draft, read back from its pixels.
@MainActor
final class HUDPictureRendererTests: XCTestCase {
    private let key = "screen:picture"

    /// The sample's store over settings of its own, made when a test first reaches for either.
    private lazy var store: UsageStore = {
        _ = NSApplication.shared
        let suite = "app.agenthud.tests.hud-picture.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!, defaultAgents: DemoData.agents)
        let store = UsageStore(provider: DemoUsageProvider(), settings: settings, clock: { DemoClock.now })
        store.replace(report: DemoUsageProvider.report(agents: settings.agents, historyHours: UsageStore.historyHours, now: DemoClock.now))
        return store
    }()

    private var layout: PanelLayoutStore { store.settings.panelLayout }
    private let notch = ScreenMetrics(menuBar: 37, notch: CGSize(width: 185, height: 32))

    private func renderer(hasNotch: Bool = true) -> HUDPictureRenderer {
        HUDPictureRenderer(store: store, screen: key, hasNotch: hasNotch, metrics: hasNotch ? notch : .fallback)
    }

    private func bitmap(_ picture: HUDPicture, file: StaticString = #filePath, line: UInt = #line) throws -> NSBitmapImageRep {
        try XCTUnwrap(NSBitmapImageRep(data: picture.png), "the picture is a PNG", file: file, line: line)
    }

    /// How far a pixel's colour is from a grey: a glow's colours are far, the backdrop and the black island are not.
    private func colourfulness(_ rep: NSBitmapImageRep, x: Int, y: Int) -> CGFloat {
        guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return 0 }
        let parts = [colour.redComponent, colour.greenComponent, colour.blueComponent]
        return (parts.max() ?? 0) - (parts.min() ?? 0)
    }

    /// Whether any pixel of a band of rows is far from grey.
    private func hasColour(_ rep: NSBitmapImageRep, rows: Range<Int>) -> Bool {
        for y in rows where y >= 0 && y < rep.pixelsHigh {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) where colourfulness(rep, x: x, y: y) > 0.25 { return true }
        }
        return false
    }

    // MARK: Beside the notch

    /// Beside the notch the picture is the island with its glow, drawn at twice its size; the glow is in it, read back
    /// from the colours under the island.
    func testTheNotchIsDrawnWithItsGlow() throws {
        let renderer = renderer()
        XCTAssertEqual(renderer.placement.mode, .notch, "a screen with a notch keeps its island")
        let picture = try XCTUnwrap(renderer.picture())
        XCTAssertTrue(picture.drawsGlow)
        XCTAssertEqual(picture.scale, 2)
        let rep = try bitmap(picture)
        XCTAssertEqual(rep.pixelsWide, Int((picture.width * 2).rounded()))
        XCTAssertEqual(rep.pixelsHigh, Int((picture.height * 2).rounded()))
        XCTAssertGreaterThan(picture.width, 185, "the glow reaches past the island")
        // The island hangs from the picture's top edge, 32 points tall; the glow's colours are just below its foot.
        XCTAssertTrue(hasColour(rep, rows: 64..<80), "the glow is drawn off screen")
        // The island itself is black in the middle, from the very top.
        for y in [0, 32] {
            let island = rep.colorAt(x: rep.pixelsWide / 2, y: y)?.usingColorSpace(.deviceRGB)
            XCTAssertLessThan(island?.brightnessComponent ?? 1, 0.1, "\(y)")
        }
    }

    /// A style draft's glow is in the picture: another style and a wider range make another, larger picture.
    func testAGlowDraftIsDrawn() throws {
        let saved = try XCTUnwrap(renderer().picture())
        XCTAssertTrue(layout.proposeStyle(HUDStyle(glow: HUDStyle.Glow(style: .blur, range: 30)), for: key, hasNotch: true))
        let wider = try XCTUnwrap(renderer().picture())
        XCTAssertGreaterThan(wider.width, saved.width, "a wider range reaches farther")
        XCTAssertTrue(layout.proposeStyle(HUDStyle(glow: HUDStyle.Glow(style: .dots)), for: key, hasNotch: true))
        let dots = try XCTUnwrap(renderer().picture())
        XCTAssertNotEqual(dots.png, saved.png)
        XCTAssertTrue(hasColour(try bitmap(dots), rows: 64..<Int(dots.height * 2)))
    }

    // MARK: Docks

    /// A Dynamic dock is its marks over their backdrop; a draft's larger logos make it longer and taller.
    func testADocksLogosFollowTheDraft() throws {
        let saved = try XCTUnwrap(renderer(hasNotch: false).picture())
        XCTAssertEqual(renderer(hasNotch: false).placement.mode, .logos, "a screen without a notch is a dock")
        XCTAssertTrue(saved.drawsGlow)
        XCTAssertTrue(hasColour(try bitmap(saved), rows: 0..<Int(saved.height * 2)), "the marks and the backdrop are drawn")
        layout.proposeStyle(HUDStyle(logoSize: 36), for: key, hasNotch: false)
        let larger = try XCTUnwrap(renderer(hasNotch: false).picture())
        XCTAssertGreaterThan(larger.width, saved.width)
        XCTAssertGreaterThanOrEqual(larger.height, saved.height)
    }

    /// A Simple panel draws no glow, and a draft that turns a notch into one is drawn as one, along a top edge
    /// whichever edge it is parked on.
    func testADraftThatTurnsTheScreenSimpleIsDrawnAsOne() throws {
        layout.proposeStyle(HUDStyle(mode: .simple, edge: .left), for: key, hasNotch: true)
        let renderer = renderer()
        XCTAssertEqual(renderer.placement.mode, .simple)
        let picture = try XCTUnwrap(renderer.picture())
        XCTAssertFalse(picture.drawsGlow)
        let items = ScreenAgents(store: store, listed: [], mode: .simple).meterItems
        var top = renderer.placement
        top.edge = .top
        let strip = SimpleMeterConfig(items: items, placement: top).stripSize
        XCTAssertEqual(picture.width, Double(strip.width + 2 * HUDPictureRenderer.margin), accuracy: 1, "laid along a top edge")
        XCTAssertEqual(picture.height, Double(strip.height + 2 * HUDPictureRenderer.margin), accuracy: 1)
    }

    // MARK: To the tools

    /// The tools hand the picture over with what it shows, for an attached screen only.
    func testTheToolsReturnTheRestingHUD() throws {
        let screen = PanelScreen(key: key, name: "Built-in display", mode: .notch, edge: .top, hasNotch: true,
                                 agents: ScreenAgents.available(store: store, mode: .notch))
        let renderer = renderer()
        let tools = PanelTools(store: store, screens: { [screen] }, hud: { _ in renderer.picture() })
        layout.proposeStyle(HUDStyle(glow: HUDStyle.Glow(effect: .ripple)), for: key, hasNotch: true)
        guard case .result(let said, let images) = tools.answer(MCPToolRequest(
            tool: MCPTools.getPanelImage, arguments: ["screen": .string(key), "show": .string("hud")])) else {
            return XCTFail("the resting HUD was refused")
        }
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images.first?.mimeType, "image/png")
        XCTAssertEqual(said["show"], .string("hud"))
        XCTAssertEqual(said["mode"], .string("notch"))
        XCTAssertEqual(said["unsaved"], .bool(true))
        XCTAssertEqual(said["glow"], .bool(true))
        let note = try XCTUnwrap(said["note"]?.stringValue)
        XCTAssertTrue(note.hasPrefix("The resting HUD of \"Built-in display\" as it looks now, with its unsaved style draft: "
                                     + "the island at its notch"), note)
        XCTAssertTrue(note.contains(", with its glow."), note)
        guard case .failure(let refusal) = tools.answer(MCPToolRequest(tool: MCPTools.getPanelImage,
                                                                       arguments: ["show": .string("hud")])) else {
            return XCTFail("the shared layout has no resting HUD")
        }
        XCTAssertTrue(refusal.hasPrefix("show \"hud\" draws one screen's resting HUD, so it needs that screen's key."), refusal)
    }
}
