import XCTest
@testable import AgentHUDCore

/// A host's request for a pass falls due at the earliest time asked for its path, and the pass at or after that time
/// takes it once.
final class PassRequestsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testAPassTakesTheRequestsDueOnceAndAPathKeepsTheEarliestTimeAskedForIt() {
        var requests = PassRequests()
        XCTAssertNil(requests.next)
        requests.request(["/a", "/b"], at: start.addingTimeInterval(20))
        requests.request(["/a"], at: start.addingTimeInterval(5))
        requests.request(["/a"], at: start.addingTimeInterval(30))
        XCTAssertEqual(requests.next, start.addingTimeInterval(5), "a later request does not put off an earlier one")
        XCTAssertEqual(requests.take(at: start), [], "nothing is due before its time")
        XCTAssertEqual(requests.take(at: start.addingTimeInterval(5)), ["/a"])
        XCTAssertEqual(requests.next, start.addingTimeInterval(20))
        XCTAssertEqual(requests.take(at: start.addingTimeInterval(60)), ["/b"])
        XCTAssertNil(requests.next, "a request is taken once")
        XCTAssertEqual(requests.take(at: start.addingTimeInterval(60)), [])
    }
}
