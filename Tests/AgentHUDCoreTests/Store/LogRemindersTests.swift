import XCTest
@testable import AgentHUDCore

/// A reminded log is read at the next pass, then looked at three more times, half a second apart, and read again only
/// when a look finds it changed.
final class LogRemindersTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func log() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agenthud-reminder-\(UUID().uuidString).jsonl")
        try Data("a\n".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Appends through a handle that stays open, as Codex writes its rollouts.
    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func testARemindedLogIsReadOnceAndAgainOnlyWhenALookFindsItChanged() throws {
        let file = try log(), path = file.path
        var reminders = LogReminders()
        XCTAssertNil(reminders.nextLook)
        reminders.remind([path])
        XCTAssertTrue(reminders.isPending)
        XCTAssertEqual(reminders.due(at: start), [path], "the pass after the reminder reads the log")
        XCTAssertFalse(reminders.isPending)
        XCTAssertEqual(reminders.nextLook, start.addingTimeInterval(0.5))
        XCTAssertEqual(reminders.due(at: start.addingTimeInterval(0.4)), [], "no look is due yet")
        XCTAssertEqual(reminders.due(at: start.addingTimeInterval(0.5)), [], "a look that finds the log as it was reads nothing")
        try append("b\n", to: file)
        XCTAssertEqual(reminders.due(at: start.addingTimeInterval(1)), [path], "what the client wrote after its hook is read")
        XCTAssertEqual(reminders.nextLook, start.addingTimeInterval(1.5))
        try append("c\n", to: file)
        XCTAssertEqual(reminders.due(at: start.addingTimeInterval(1.5)), [path])
        XCTAssertNil(reminders.nextLook, "three looks, and the file watch takes over")
        try append("d\n", to: file)
        XCTAssertEqual(reminders.due(at: start.addingTimeInterval(2)), [])
    }

    func testARemindAgainStartsItsLooksOverAndALogThatIsGoneIsReadOnce() throws {
        let path = try log().path
        var reminders = LogReminders()
        reminders.remind([path])
        _ = reminders.due(at: start)
        _ = reminders.due(at: start.addingTimeInterval(0.5))
        reminders.remind([path])
        XCTAssertEqual(reminders.due(at: start.addingTimeInterval(1)), [path], "a second hook reads it again whatever the look says")
        XCTAssertEqual(reminders.nextLook, start.addingTimeInterval(1.5))
        for offset in [1.5, 2.0, 2.5] { XCTAssertEqual(reminders.due(at: start.addingTimeInterval(offset)), []) }
        XCTAssertNil(reminders.nextLook)

        let gone = FileManager.default.temporaryDirectory.appendingPathComponent("agenthud-reminder-\(UUID().uuidString).jsonl").path
        reminders.remind([gone])
        XCTAssertEqual(reminders.due(at: start), [gone])
        XCTAssertEqual(reminders.due(at: start.addingTimeInterval(0.5)), [], "a log that cannot be looked at does not change")
    }
}
