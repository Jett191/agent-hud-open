import XCTest
@testable import AgentHUDCore

/// The Harness desktop app keeps its packages in its `app.asar` and runs them in its Electron as Node. A stand-in app
/// here has a plain `app.asar` folder and an executable that runs Node only when asked to run as Node.
final class DeepSeekDesktopTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agenthud-dsh-desktop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func write(_ text: String, to path: String, executable: Bool = false) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
    }

    private func desktopApp(node: URL) throws -> URL {
        try write("#!/bin/sh\n[ \"$ELECTRON_RUN_AS_NODE\" = 1 ] || exit 7\nexec '\(node.path)' \"$@\"\n",
                  to: "Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness", executable: true)
        let modules = "Applications/DeepSeek Harness.app/Contents/Resources/app.asar/dsh/node_modules/"
        try write(#"{"name":"@deepseek-ai/dsh-credentials-local","type":"module","main":"lib/index.js"}"#,
                  to: modules + "@deepseek-ai/dsh-credentials-local/package.json")
        try write("export function parseCredentialsDocument() { return {refs: new Map([['DEEPSEEK_API_KEY', 'fixture-key']])} }\n",
                  to: modules + "@deepseek-ai/dsh-credentials-local/lib/index.js")
        try write(#"{"name":"yaml","main":"index.js"}"#, to: modules + "yaml/package.json")
        // A custom endpoint ends the helper before any request, once the key was read.
        try write("exports.parse = () => ({'llm-deepseek': {baseURL: 'https://example.invalid'}})\n", to: modules + "yaml/index.js")
        return root.appendingPathComponent("Applications/DeepSeek Harness.app")
    }

    func testTheDesktopAppIsFoundByNameAndRunAsNode() throws {
        let applications = root.appendingPathComponent("Applications")
        XCTAssertNil(DeepSeekScriptRuntime.desktopApplication(in: [applications]))
        let app = try desktopApp(node: URL(fileURLWithPath: "/usr/bin/false"))
        XCTAssertEqual(DeepSeekScriptRuntime.desktopApplication(in: [applications]), app)
        XCTAssertEqual(DeepSeekScriptRuntime.desktop(app),
                       DeepSeekScriptRuntime(executable: app.appendingPathComponent("Contents/MacOS/DeepSeek Harness"),
                                             environment: ["ELECTRON_RUN_AS_NODE": "1"]))
    }

    func testWithoutACLIInstallTheDesktopAppSuppliesThePackageAndItsRuntime() throws {
        let app = try desktopApp(node: URL(fileURLWithPath: "/usr/bin/false"))
        let harness = DeepSeekCredentialLocator.locate(home: root, path: "", applications: [root.appendingPathComponent("Applications")])
        try XCTSkipIf(harness.module?.path.hasPrefix(app.path) != true, "a CLI install outside this test's home comes first")
        XCTAssertEqual(harness.module, app.appendingPathComponent(
            "Contents/Resources/app.asar/dsh/node_modules/@deepseek-ai/dsh-credentials-local/lib/index.js"))
        XCTAssertEqual(harness.runtime, .desktop(app), "only the app's Electron loads what is inside app.asar")
    }

    /// The reported failure: Harness's credentials file is there, and the package that reads it comes from the app.
    func testTheBalanceHelperReadsTheCredentialThroughTheDesktopApp() async throws {
        guard let node = DeepSeekLocator.nodeExecutable() else { throw XCTSkip("the stand-in Electron hands over to Node") }
        let app = try desktopApp(node: node)
        let home = root.appendingPathComponent("dsh")
        try write("llm-deepseek:\n  baseURL: https://example.invalid\n", to: "dsh/settings.yaml")
        try write("fixture: credentials\n", to: "dsh/.credentials.yaml")
        let harness = DeepSeekCredentialLocator.Harness(
            module: app.appendingPathComponent("Contents/Resources/app.asar/dsh/node_modules/@deepseek-ai/dsh-credentials-local/lib/index.js"),
            runtime: .desktop(app))

        do {
            _ = try await DeepSeekBalanceClient(directory: home) { harness }.fetch()
            XCTFail("a custom endpoint has no official balance")
        } catch {
            XCTAssertEqual(error.localizedDescription,
                           L10n.text("自定义 API 地址不支持官方余额查询", "Official balance is unavailable for a custom API endpoint"))
        }
    }

    /// The desktop app's Host holds `profiles/desktop/cordis.yml` while it runs, as a command-line Harness's Node does, and
    /// is the app's own executable in Node mode; its helpers never hold the profile.
    func testTheDesktopHostIsAHarnessProcess() {
        XCTAssertTrue(DeepSeekRuntime.isHarness(executable: "/Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness"))
        XCTAssertTrue(DeepSeekRuntime.isHarness(executable: "/opt/homebrew/Cellar/node@24/24.19.0/bin/node"))
        XCTAssertFalse(DeepSeekRuntime.isHarness(executable: "/Applications/DeepSeek Harness.app/Contents/Frameworks/"
            + "DeepSeek Harness Helper.app/Contents/MacOS/DeepSeek Harness Helper"))
        XCTAssertFalse(DeepSeekRuntime.isHarness(executable: "/usr/bin/vim"))
    }

    func testNoRuntimeAtAllNamesBothWaysToGetOne() async {
        do {
            _ = try await DeepSeekNode.run(script: "", arguments: [], runtime: nil)
            XCTFail("nothing can run the helper")
        } catch {
            XCTAssertEqual(error.localizedDescription, L10n.text("读取 Harness 数据需要 Node.js 或 Harness 桌面版",
                                                                 "Reading Harness data needs Node.js or the Harness desktop app"))
        }
    }
}
