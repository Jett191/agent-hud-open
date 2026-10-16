import XCTest
@testable import AgentHUDCore

final class AntigravityCLITests: XCTestCase {
    /// `agy -p /usage --output-format json` as agy 1.3.1 prints it, with the long descriptions shortened.
    private static let printed = #"""
    {"conversation_id":"","status":"SUCCESS","response":"Gemini Models\tWeekly Limit Remaining\t75%\t2026-10-20T04:42:34Z","num_turns":0,
     "usage":{"input_tokens":0,"output_tokens":0,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":0},
     "command":{"name":"usage","data":{"description":"Within each group, models share a weekly limit and a 5-hour limit.","groups":[
      {"name":"Gemini Models","description":"Models within this group: Gemini Flash, Gemini Pro","buckets":[
       {"id":"gemini-weekly","name":"Weekly Limit Remaining","description":"It will fully refresh in 5 days.","window":"weekly","remaining_fraction":0.75,"reset_time":"2026-10-20T04:42:34Z"},
       {"id":"gemini-5h","name":"Five Hour Limit Remaining","description":null,"window":"5h","remaining_fraction":1,"reset_time":"2026-10-15T07:05:34Z"}]},
      {"name":"Claude and GPT models","description":"Models within this group: Claude Opus, Claude Sonnet, GPT-OSS","buckets":[
       {"id":"3p-weekly","name":"Weekly Limit Remaining","description":null,"window":"weekly","remaining_fraction":0.5,"reset_time":"2026-10-19T15:09:23Z"},
       {"id":"3p-5h","name":"Five Hour Limit Remaining","description":null,"window":"5h","remaining_fraction":0,"reset_time":"2026-10-15T07:05:34Z"}]}]}}}
    """#

    /// The rows match the language server's own summary, so a reading from either keeps the same windows.
    func testPrintedUsageReadsAsTheLanguageServerSummary() throws {
        let quota = try AntigravityCLI.usage(.read(Data(Self.printed.utf8)))
        XCTAssertEqual(quota.windows.map(\.id), ["antigravity:gemini-weekly", "antigravity:gemini-5h",
                                                 "antigravity:3p-weekly", "antigravity:3p-5h"])
        XCTAssertEqual(quota.windows.map(\.label), ["Gemini Models · Weekly Limit Remaining", "Gemini Models · Five Hour Limit Remaining",
                                                    "Claude and GPT models · Weekly Limit Remaining", "Claude and GPT models · Five Hour Limit Remaining"])
        XCTAssertEqual(quota.windows.map(\.remaining), [75, 100, 50, 0])
        XCTAssertEqual(quota.windows.map(\.duration), [604800, 18000, 604800, 18000])
        XCTAssertEqual(quota.windows.first?.reset, DateParsing.internet("2026-10-20T04:42:34Z"))
        XCTAssertEqual(quota.quotaWindowIDs, ["antigravity:gemini-weekly", "antigravity:gemini-5h", "antigravity:3p-weekly", "antigravity:3p-5h"])
        XCTAssertNil(quota.account, "agy's print mode names no account")
    }

    func testAnotherCommandOrAFailedRunIsNotAReading() throws {
        for text in [#"{"status":"SUCCESS","command":{"name":"credits","data":{"remaining_credits":5}}}"#,
                     #"{"status":"ERROR","command":{"name":"usage","data":{"groups":[]}}}"#, #"{"status":"SUCCESS"}"#] {
            XCTAssertThrowsError(try AntigravityCLI.usage(.read(Data(text.utf8))), text)
        }
    }

    func testTheRunningAgyIsAskedForItsUsageInPrintMode() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agenthud-agy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let printed = directory.appendingPathComponent("usage.json")
        try Data(Self.printed.utf8).write(to: printed)
        let agy = directory.appendingPathComponent("agy")
        try "#!/bin/sh\n[ \"$*\" = \"-p /usage --output-format json\" ] || exit 3\ncat '\(printed.path)'\n"
            .write(to: agy, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agy.path)

        let quota = try await AntigravityCLI().quota(executable: agy)
        XCTAssertEqual(quota.windows.count, 4)
    }

    /// The program is the running process's own; a process of another name is not agy, whatever its command line says.
    func testOnlyARunningAgyProgramIsAsked() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agenthud-agy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let agy = directory.appendingPathComponent("agy")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: agy)
        let process = Process()
        process.executableURL = agy
        process.arguments = ["30"]
        try process.run()
        defer { process.terminate() }

        func candidate(_ pid: Int32) -> AntigravityService.Candidate {
            .init(pid: Int(pid), token: "", extensionPort: nil, extensionToken: nil, priority: 1)
        }
        let own = ProcessInfo.processInfo.processIdentifier
        XCTAssertNil(AntigravityCLI.executable(of: [candidate(own)]))
        XCTAssertEqual(AntigravityCLI.executable(of: [candidate(own), candidate(process.processIdentifier)])?.resolvingSymlinksInPath(),
                       agy.resolvingSymlinksInPath())
    }
}
