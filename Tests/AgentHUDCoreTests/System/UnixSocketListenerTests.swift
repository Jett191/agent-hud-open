import Darwin
import Foundation
import XCTest
@testable import AgentHUDCore

/// The file mode mask a listener tightens while its socket is made. A process has one mask, so it has to come back
/// however many listeners start together and however each of them ends.
@MainActor
final class UnixSocketListenerTests: XCTestCase {
    /// A short path, so a socket in it and the lock beside the socket fit a socket address. The mask is set to the
    /// usual one for the test, whatever the shell that runs it has.
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("usl-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let found = umask(0o022)
        addTeardownBlock {
            umask(found)
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func listener(at path: String) -> UnixSocketListener {
        XCTAssertTrue(UnixSocket.fits(path + ".lock"))
        return UnixSocketListener(path: path, requestLimit: 1024, category: "test") { _, connection in connection.cancel() }
    }

    /// The process's file mode mask, read without changing it.
    private func mask() -> mode_t {
        let current = umask(0)
        umask(current)
        return current
    }

    /// Whether something accepts on the socket at `path`.
    private func accepts(_ path: String) -> Bool {
        guard let descriptor = UnixSocket.connect(to: path) else { return false }
        close(descriptor)
        return true
    }

    /// The permission bits of the file at `path`; nil when there is none.
    private func mode(of path: String) -> mode_t? {
        var info = stat()
        return stat(path, &info) == 0 ? info.st_mode & 0o777 : nil
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), what)
    }

    func testTwoListenersStartedInOneTurnGiveTheMaskBack() async throws {
        let directory = try directory()
        let first = listener(at: directory.appendingPathComponent("a.sock").path)
        let second = listener(at: directory.appendingPathComponent("b.sock").path)
        XCTAssertTrue(first.start())
        XCTAssertTrue(second.start())
        addTeardownBlock {
            await first.stop()
            await second.stop()
        }
        XCTAssertEqual(mask(), 0o077, "tight until the sockets are made")
        await waitUntil("both listen") { self.accepts(first.path) && self.accepts(second.path) }
        await waitUntil("the mask is what it was before either started") { self.mask() == 0o022 }
        XCTAssertEqual(mode(of: first.path), 0o700, "only the user reaches a socket")
        XCTAssertEqual(mode(of: second.path), 0o700)

        // A file the application writes afterwards has the permissions it always had.
        let file = directory.appendingPathComponent("written").path
        close(open(file, O_CREAT | O_WRONLY, 0o666))
        XCTAssertEqual(mode(of: file), 0o644)
    }

    func testAListenerStoppedBeforeItsSocketIsMadeGivesTheMaskBack() async throws {
        let directory = try directory()
        let stopped = listener(at: directory.appendingPathComponent("a.sock").path)
        XCTAssertTrue(stopped.start())
        XCTAssertEqual(mask(), 0o077)
        stopped.stop()
        XCTAssertEqual(mask(), 0o022, "nothing is coming up any more")

        // One of two that goes away leaves the mask tight for the other, and the other gives it back.
        let kept = listener(at: directory.appendingPathComponent("b.sock").path)
        XCTAssertTrue(stopped.start())
        XCTAssertTrue(kept.start())
        addTeardownBlock { await kept.stop() }
        stopped.stop()
        stopped.stop()
        XCTAssertEqual(mask(), 0o077, "the other socket is not made yet")
        await waitUntil("the other listens") { self.accepts(kept.path) }
        await waitUntil("the mask is back") { self.mask() == 0o022 }
        XCTAssertEqual(mode(of: kept.path), 0o700)
    }

    func testAListenerThatDoesNotStartLeavesTheMaskAlone() async throws {
        let directory = try directory()
        let path = directory.appendingPathComponent("a.sock").path
        let serving = listener(at: path)
        XCTAssertTrue(serving.start())
        addTeardownBlock { await serving.stop() }
        await waitUntil("the first listens") { self.accepts(path) }
        await waitUntil("the mask is back") { self.mask() == 0o022 }

        XCTAssertFalse(listener(at: path).start(), "another process's copy would find the path served")
        XCTAssertEqual(mask(), 0o022)
        let long = directory.appendingPathComponent(String(repeating: "x", count: 120)).path
        let unfit = UnixSocketListener(path: long, requestLimit: 1024, category: "test") { _, connection in connection.cancel() }
        XCTAssertFalse(unfit.start(), "a path no socket address holds")
        XCTAssertEqual(mask(), 0o022)
        XCTAssertTrue(accepts(path), "the first one still serves")
    }
}
