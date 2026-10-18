import Foundation
import XCTest
@testable import AgentHUDCore

final class DevinQuotaTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_240_190)

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ bytes: [UInt8], name: String = "user_status.abcdef0123456789.bin",
                       fetchedAt: Int, to directory: URL) throws {
        let envelope = "{\"version\":1,\"identity_digest\":\"abcdef0123456789\",\"fetched_at_secs\":\(fetchedAt),"
            + "\"payload\":\"\(Data(bytes).base64EncodedString())\"}"
        try envelope.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// The `GetUserStatus` protobuf the CLI caches: the subscription message under field 13, plan at `1.2`,
    /// shares used at `14` (weekly) and `15` (daily), resets at `17` (daily) and `18` (weekly), identity at
    /// the root's 3, 5 and 7. A zero share is omitted, as proto3 writes no defaults.
    private func status(dailyUsed: UInt64? = nil, weeklyUsed: UInt64 = 100,
                        dailyReset: UInt64 = 1_792_310_400, weeklyReset: UInt64 = 1_792_310_400) -> [UInt8] {
        var subscription = field(1, message: field(2, string: "Pro"))
            + field(14, int: weeklyUsed) + field(17, int: dailyReset) + field(18, int: weeklyReset)
        if let dailyUsed { subscription += field(15, int: dailyUsed) }
        return field(3, string: "Test User") + field(5, string: "team$account-abc123")
            + field(7, string: "user@example.com") + field(13, message: subscription)
    }

    private func varint(_ value: UInt64) -> [UInt8] {
        var value = value, bytes: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value > 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value > 0
        return bytes
    }

    private func field(_ number: Int, int value: UInt64) -> [UInt8] {
        varint(UInt64(number << 3)) + varint(value)
    }

    private func field(_ number: Int, message: [UInt8]) -> [UInt8] {
        varint(UInt64(number << 3 | 2)) + varint(UInt64(message.count)) + message
    }

    private func field(_ number: Int, string: String) -> [UInt8] {
        field(number, message: Array(string.utf8))
    }

    func testReadsPlanWindowsAndAccountFromCache() throws {
        let directory = try directory()
        try write(status(dailyUsed: 49), fetchedAt: 1_792_240_190, to: directory)
        let quota = try DevinQuota.quota(in: directory, now: now)
        XCTAssertEqual(quota.plan, "Pro")
        XCTAssertEqual(quota.client, "Devin CLI")
        XCTAssertEqual(quota.label, "user@example.com")
        XCTAssertEqual(quota.observedAt, Date(timeIntervalSince1970: 1_792_240_190))
        XCTAssertEqual(quota.account?.evidence, .account)
        XCTAssertEqual(quota.account?.provider, "Devin")
        XCTAssertFalse(quota.signedOut)
        XCTAssertNil(quota.notice)
        XCTAssertNotNil(quota.sourceInfo)
        XCTAssertEqual(quota.windows.count, 2)
        let daily = try XCTUnwrap(quota.windows.first { $0.id == "devin:daily" })
        XCTAssertEqual(try XCTUnwrap(daily.remaining), 51, accuracy: 0.000001)
        XCTAssertEqual(daily.reset, Date(timeIntervalSince1970: 1_792_310_400))
        XCTAssertEqual(daily.duration, 86400)
        let weekly = try XCTUnwrap(quota.windows.first { $0.id == "devin:weekly" })
        XCTAssertEqual(try XCTUnwrap(weekly.remaining), 0, accuracy: 0.000001)
        XCTAssertEqual(weekly.duration, 604800)
    }

    func testShareOver100LeavesTheWindowRemainingUnknown() throws {
        let directory = try directory()
        try write(status(weeklyUsed: 101), fetchedAt: 1_792_240_190, to: directory)
        let weekly = try XCTUnwrap(try DevinQuota.quota(in: directory, now: now).windows.first { $0.id == "devin:weekly" })
        XCTAssertNil(weekly.remaining, "a share past 100 is no percent and stays unknown")
        XCTAssertEqual(weekly.reset, Date(timeIntervalSince1970: 1_792_310_400))
    }

    func testAbsentDailyShareReadsAsZeroUsed() throws {
        let directory = try directory()
        try write(status(), fetchedAt: 1_792_240_190, to: directory)
        let daily = try XCTUnwrap(try DevinQuota.quota(in: directory, now: now).windows.first { $0.id == "devin:daily" })
        XCTAssertEqual(try XCTUnwrap(daily.remaining), 100, accuracy: 0.000001)
    }

    func testNewestParseableFileWins() throws {
        let directory = try directory()
        try write(status(), name: "user_status.1111111111111111.bin", fetchedAt: 100, to: directory)
        let old = directory.appendingPathComponent("user_status.1111111111111111.bin")
        try "not json".write(to: directory.appendingPathComponent("user_status.2222222222222222.bin"),
                            atomically: true, encoding: .utf8)
        let new = directory.appendingPathComponent("user_status.2222222222222222.bin")
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3600)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: new.path)
        let quota = try DevinQuota.quota(in: directory, now: now)
        XCTAssertEqual(quota.plan, "Pro")
        XCTAssertEqual(quota.observedAt, Date(timeIntervalSince1970: 100))
    }

    func testMissingCacheIsSignedOutAndMalformedIsNotice() throws {
        let directory = try directory()
        XCTAssertTrue(try DevinQuota.quota(in: directory, now: now).signedOut)
        try "not json".write(to: directory.appendingPathComponent("user_status.abcdef0123456789.bin"),
                            atomically: true, encoding: .utf8)
        let quota = try DevinQuota.quota(in: directory, now: now)
        XCTAssertFalse(quota.signedOut)
        XCTAssertNotNil(quota.notice)
        XCTAssertTrue(quota.windows.isEmpty)
    }
}
