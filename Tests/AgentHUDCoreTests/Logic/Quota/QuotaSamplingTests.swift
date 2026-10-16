import XCTest
@testable import AgentHUDCore

final class QuotaSamplingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func tearDown() {
        L10n.setLanguage(.system)
        super.tearDown()
    }

    func testInitialSamplingUsesActualReadingSpanInBothLanguages() throws {
        let snapshot = weeklySnapshot()
        let insights = QuotaMath.insights(snapshot: snapshot, samples: [sample(-180, 100), sample(0, 99)], now: now)
        let sampling = try XCTUnwrap(insights.sampling)
        XCTAssertEqual(sampling.elapsed, 180)
        XCTAssertEqual(sampling.required, 3600)
        XCTAssertFalse(sampling.afterReset)
        L10n.setLanguage(.zhHans)
        XCTAssertEqual(QuotaForecast.hint(snapshot: snapshot, insights: insights, now: now),
                       "首次采样，正在积累预测数据\n已采样 3分，预测至少需要1小时的有效记录")
        L10n.setLanguage(.en)
        XCTAssertEqual(QuotaForecast.hint(snapshot: snapshot, insights: insights, now: now),
                       "Collecting initial readings for a forecast\nSampled 3m; at least 1h of readings needed")
    }

    func testScheduledResetDoesNotReuseThePreviousCyclesDuration() throws {
        let snapshot = weeklySnapshot(startedAgo: 300)
        let insights = QuotaMath.insights(snapshot: snapshot,
            samples: [sample(-7200, 30), sample(-600, 23), sample(-180, 100), sample(0, 100)], now: now)
        XCTAssertEqual(insights.sampling, QuotaSampling(elapsed: 180, required: 3600, afterReset: true))
        L10n.setLanguage(.zhHans)
        XCTAssertEqual(QuotaForecast.hint(snapshot: snapshot, insights: insights, now: now),
                       "额度已重置，正在重新采样\n已采样 3分，预测至少需要1小时的有效记录")
        L10n.setLanguage(.en)
        XCTAssertTrue(try XCTUnwrap(QuotaForecast.hint(snapshot: snapshot, insights: insights, now: now))
            .hasPrefix("Quota reset; collecting new readings\n"))
    }

    func testAnEarlyResetAndRepeatedResetsUseOnlyTheLatestSeries() {
        let snapshot = weeklySnapshot()
        let samples = [sample(-7200, 20), sample(-6000, 100), sample(-3600, 20), sample(-180, 100), sample(0, 99)]
        let insights = QuotaMath.insights(snapshot: snapshot, samples: Array(samples.reversed()), now: now)
        XCTAssertEqual(insights.sampling, QuotaSampling(elapsed: 180, required: 3600, afterReset: true))
        XCTAssertNil(insights.burnRatePctPerHour)
    }

    func testSmallReadingWobbleDoesNotRestartSampling() {
        let insights = QuotaMath.insights(snapshot: weeklySnapshot(),
            samples: [sample(-1800, 80), sample(-600, 82), sample(0, 79)], now: now)
        XCTAssertEqual(insights.sampling, QuotaSampling(elapsed: 1800, required: 3600, afterReset: false))
    }

    func testIdleTimeWithoutNewReadingsDoesNotAdvanceProgress() throws {
        let snapshot = weeklySnapshot()
        let insights = QuotaMath.insights(snapshot: snapshot, samples: [sample(-7200, 99)], now: now)
        XCTAssertEqual(insights.sampling?.elapsed, 0)
        L10n.setLanguage(.en)
        XCTAssertTrue(try XCTUnwrap(QuotaForecast.hint(snapshot: snapshot, insights: insights, now: now))
            .contains("Sampled less than 1m"))
    }

    func testRequiredSpanRestoresForecastOrNoUsageAndFiveHourWindowsNeedFifteenMinutes() {
        L10n.setLanguage(.en)
        for (remaining, expected) in [(99.0, "Exhausts ~99h"), (100.0, "No usage")] {
            let snapshot = weeklySnapshot()
            let insights = QuotaMath.insights(snapshot: snapshot, samples: [sample(-3600, 100), sample(0, remaining)], now: now)
            XCTAssertEqual(QuotaForecast.hint(snapshot: snapshot, insights: insights, now: now), expected)
            // A series long enough for a burn rate keeps no sampling progress.
            XCTAssertNil(insights.sampling)
        }
        let snapshot = UsageSnapshot(agentId: "window", remainingPct: 99, resetAt: now.addingTimeInterval(3600),
                                     windowDuration: 5 * 3600, updatedAt: now)
        let insights = QuotaMath.insights(snapshot: snapshot, samples: [sample(-899, 100), sample(0, 99)], now: now)
        XCTAssertEqual(insights.sampling?.required, 900)
        XCTAssertTrue(QuotaForecast.hint(snapshot: snapshot, insights: insights, now: now)?.contains("at least 15m") == true)
    }

    func testOlderReportsDecodeWithoutSamplingAndNewReportsRoundTrip() throws {
        let old = #"{"burnRatePctPerHour":null,"timeToExhaust":null,"weeklyCapHits":0,"weeklyWaitTotal":0,"weeklyWaitLongest":0}"#
        XCTAssertNil(try JSONDecoder().decode(UsageInsights.self, from: Data(old.utf8)).sampling)
        let insights = QuotaMath.insights(snapshot: weeklySnapshot(), samples: [sample(0, 99)], now: now)
        XCTAssertEqual(try JSONDecoder().decode(UsageInsights.self, from: JSONEncoder().encode(insights)), insights)
    }

    func testUnknownOrExpiredCyclesKeepTheExistingFallback() {
        XCTAssertNil(UsageAnalytics.sampling(samples: [sample(0, 99)], cycle: nil, now: now))
        let expired = QuotaCycle(resetAt: now, duration: 7 * 86400)
        XCTAssertNil(UsageAnalytics.sampling(samples: [sample(-60, 99)], cycle: expired, now: now))
    }

    private func sample(_ offset: TimeInterval, _ remaining: Double) -> QuotaSample {
        QuotaSample(agentId: "window", timestamp: now.addingTimeInterval(offset), remainingPct: remaining)
    }

    private func weeklySnapshot(startedAgo: TimeInterval = 86400) -> UsageSnapshot {
        UsageSnapshot(agentId: "window", remainingPct: 99, resetAt: now.addingTimeInterval(7 * 86400 - startedAgo),
                      windowDuration: 7 * 86400, updatedAt: now)
    }
}
