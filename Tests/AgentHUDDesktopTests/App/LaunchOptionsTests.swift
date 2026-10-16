import XCTest
@testable import AgentHUDDesktop

/// The launch switches that decide whether this copy answers the MCP tools.
final class LaunchOptionsTests: XCTestCase {
    func testTheDemoToolsSwitchIsParsed() {
        XCTAssertTrue(DesktopLaunchOptions.parse(["app", "--demo", "--demo-tools"]).demoTools)
        XCTAssertTrue(DesktopLaunchOptions.parse(["app", "--demo-tools", "--demo"]).demoTools, "in either order")
        XCTAssertFalse(DesktopLaunchOptions.parse(["app", "--demo"]).demoTools)
        XCTAssertFalse(DesktopLaunchOptions.parse(["app", "--demo-tools"]).demo, "it does not turn the demo on by itself")
    }

    /// One process serves the socket. Every launch but a demo serves it while Settings → Experimental's switch is on,
    /// and a demo only when asked, and then whatever the switch says.
    func testWhoServesTheToolChannel() {
        XCTAssertEqual(DesktopLaunchOptions.parse(["app"]).toolChannel, .whileSwitchedOn)
        XCTAssertEqual(DesktopLaunchOptions.parse(["app", "--show-settings"]).toolChannel, .whileSwitchedOn)
        XCTAssertEqual(DesktopLaunchOptions.parse(["app", "--demo"]).toolChannel, .never, "a demo leaves the socket to the real copy")
        XCTAssertEqual(DesktopLaunchOptions.parse(["app", "--demo-script", "showcase"]).toolChannel, .never)
        XCTAssertEqual(DesktopLaunchOptions.parse(["app", "--demo-clock", "2026-10-12T09:41"]).toolChannel, .never)
        XCTAssertEqual(DesktopLaunchOptions.parse(["app", "--demo", "--demo-tools"]).toolChannel, .always)
        XCTAssertEqual(DesktopLaunchOptions.parse(["app", "--demo-script", "showcase", "--demo-tools"]).toolChannel, .always)
        XCTAssertEqual(DesktopLaunchOptions.parse(["app", "--demo-tools"]).toolChannel, .whileSwitchedOn,
                       "without a demo the switch on the command line changes nothing")
    }
}
