import XCTest
@testable import AgentHUDCore

/// What changed since the last read is named until something makes it unnameable, and a read that does not finish
/// leaves it to the next one.
final class ChangedPathsTests: XCTestCase {
    func testChangesAreNamedFromTheFirstReadOnUntilTheyCannotBe() {
        var changed = ChangedPaths()
        changed.add(["/a"])
        XCTAssertNil(changed.take(), "before the first read nothing can be named")
        changed.add(["/a"])
        changed.add(["/b"])
        XCTAssertEqual(changed.take(), ["/a", "/b"])
        XCTAssertEqual(changed.take(), [], "a read covers what it took")
        changed.add(["/c"])
        changed.unnamed()
        changed.add(["/d"])
        XCTAssertNil(changed.take(), "dropped events leave the next read unable to say what changed")
        XCTAssertEqual(changed.take(), [])
    }

    func testAReadThatDoesNotFinishLeavesWhatItTookToTheNext() {
        var changed = ChangedPaths()
        _ = changed.take()
        changed.add(["/a"])
        let taken = changed.take()
        changed.add(["/b"])
        changed.putBack(taken)
        XCTAssertEqual(changed.take(), ["/a", "/b"])
        changed.add(["/c"])
        changed.putBack(nil)
        XCTAssertNil(changed.take(), "what could not be named stays unnamed")
        changed.unnamed()
        changed.putBack(["/e"])
        XCTAssertNil(changed.take())
    }
}
