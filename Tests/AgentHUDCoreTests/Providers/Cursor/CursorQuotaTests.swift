import Foundation
import XCTest
@testable import AgentHUDCore

/// `usage-summary` reports zero usage for the unified plans; `GetCurrentPeriodUsage` is the dashboard's
/// authoritative read. The quota windows take the RPC's percentages and cycle bounds where it answers.
final class CursorQuotaTests: XCTestCase {

    private func summary(_ plan: String = #"{"enabled":true,"used":0,"limit":4615,"autoPercentUsed":0,"apiPercentUsed":0,"totalPercentUsed":0}"#) throws -> ProviderJSON {
        try ProviderJSON.read(Data(#"{"billingCycleStart":"2026-10-01T00:00:00.000Z","billingCycleEnd":"2026-11-01T00:00:00.000Z","membershipType":"premium","individualUsage":{"plan":\#(plan),"onDemand":{"enabled":false}},"teamUsage":{}}"#.utf8))
    }

    func testTheDashboardsOwnReadOverridesTheSummaryZeros() throws {
        let period = try ProviderJSON.read(Data(#"{"billingCycleStart":"1792227193362","billingCycleEnd":"1792831993362","planUsage":{"autoPercentUsed":100,"apiPercentUsed":0,"totalPercentUsed":100},"spendLimitUsage":{"limitType":"user"},"enabled":true}"#.utf8))
        let quota = try CursorClient.parseQuota(summary(), period: period)
        XCTAssertEqual(quota.windows.map(\.id), ["cursor", "cursor:models", "cursor:third-party"])
        XCTAssertEqual(quota.windows.map(\.remaining), [0, 0, 100])
        // The cycle bounds come from the RPC's epoch-millisecond strings, not the summary's dates.
        XCTAssertEqual(quota.windows[0].reset?.timeIntervalSince1970 ?? 0, 1_792_831_993.362, accuracy: 0.001)
    }

    /// A failed or absent period read leaves the summary's own figures standing.
    func testTheSummaryStandsWithoutThePeriodRead() throws {
        let quota = try CursorClient.parseQuota(summary(#"{"enabled":true,"used":50,"limit":100,"autoPercentUsed":50,"apiPercentUsed":10,"totalPercentUsed":30}"#))
        XCTAssertEqual(quota.windows.map(\.id), ["cursor", "cursor:models", "cursor:third-party"])
        XCTAssertEqual(quota.windows.map(\.remaining), [70, 50, 90])
        XCTAssertEqual(quota.windows[0].reset, DateParsing.internet("2026-11-01T00:00:00.000Z"))
    }
}
