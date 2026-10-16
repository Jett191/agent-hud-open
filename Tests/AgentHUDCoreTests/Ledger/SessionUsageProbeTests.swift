import XCTest
import AgentHUDCore

/// A probe on a copy of a real usage ledger: the breakdown of every session a retained usage report lists, written as
/// canonical JSON so two builds can be compared byte for byte, and how long reading them takes. It prints only counts and
/// timings; the breakdowns go to the output file alone.
final class SessionUsageProbeTests: XCTestCase {
    func testReportedSessionsUsageProbe() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["AGENT_HUD_PROBE_SESSION_USAGE"] == "1", let ledgerPath = environment["AGENT_HUD_PROBE_LEDGER"],
              let reportPath = environment["AGENT_HUD_PROBE_REPORT"], let outputPath = environment["AGENT_HUD_PROBE_OUTPUT"] else {
            throw XCTSkip("Set AGENT_HUD_PROBE_SESSION_USAGE=1 and AGENT_HUD_PROBE_LEDGER, AGENT_HUD_PROBE_REPORT and AGENT_HUD_PROBE_OUTPUT for a probe on a copy of a ledger")
        }
        // Opening a ledger may migrate it, so the probe reads a copy, and keeps rows of any age.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("session-usage-probe-\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("usage-ledger.sqlite")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: ledgerPath), to: copy)
        let ledger = try UsageLedger(url: copy, expires: false)
        let report = try JSONDecoder().decode(UsageReport.self, from: Data(contentsOf: URL(fileURLWithPath: reportPath)))
        let requests = report.sessions.map(SessionUsageRequest.init)

        let usage = try await ledger.sessionUsage(requests)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(usage).write(to: URL(fileURLWithPath: outputPath))

        let clock = ContinuousClock()
        var all: [Duration] = []
        for _ in 0..<7 { all.append(try await clock.measure { _ = try await ledger.sessionUsage(requests) }) }
        let largest = try XCTUnwrap(usage.max { $0.value.calls < $1.value.calls })
        let request = try XCTUnwrap(requests.first { $0.sessionID == largest.key })
        var one: [Duration] = []
        for _ in 0..<21 { one.append(try await clock.measure { _ = try await ledger.sessionUsage([request]) }) }
        print("Probe session usage: \(requests.count) sessions reported, \(usage.count) with usage, \(usage.values.reduce(0) { $0 + $1.calls }) calls; "
              + "all: \(Self.summary(all)); largest (\(largest.value.calls) calls): \(Self.summary(one))")
    }

    /// "min 1.23 ms, median 1.45 ms".
    private static func summary(_ durations: [Duration]) -> String {
        let milliseconds = durations.map { Double($0.components.seconds) * 1000 + Double($0.components.attoseconds) / 1e15 }.sorted()
        return String(format: "min %.2f ms, median %.2f ms", milliseconds[0], milliseconds[milliseconds.count / 2])
    }
}
