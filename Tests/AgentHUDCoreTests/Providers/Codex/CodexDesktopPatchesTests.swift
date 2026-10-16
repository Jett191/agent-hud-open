import AgentHUDSupport
import XCTest
@testable import AgentHUDCore

final class CodexDesktopPatchesTests: XCTestCase {
    private func patch(_ op: String, _ path: [JSONValue], _ value: JSONValue? = nil) -> JSONValue {
        var patch: [String: JSONValue] = ["op": .string(op), "path": .array(path)]
        patch["value"] = value
        return .object(patch)
    }

    func testPatchesChangeObjectsAndArraysAsTheLibraryThatWroteThemDoes() throws {
        var state = try JSONValue.parse(Data(#"{"requests":[{"id":1},{"id":2}],"turns":{"a":{"items":["x"],"status":"inProgress"}},"title":"t"}"#.utf8))
        try CodexDesktopPatches.apply([
            patch("replace", [.string("title")], .string("renamed")),
            patch("add", [.string("turns"), .string("b")], .object(["items": .array([])])),
            patch("add", [.string("turns"), .string("a"), .string("items"), .integer(1)], .string("y")),
            patch("add", [.string("turns"), .string("a"), .string("items"), .string("-")], .string("z")),
            patch("add", [.string("turns"), .string("a"), .string("items"), .integer(0)], .string("first")),
            patch("replace", [.string("turns"), .string("a"), .string("status")], .string("completed")),
            patch("replace", [.string("requests"), .integer(1), .string("completed")], .bool(true)),
            patch("remove", [.string("requests"), .integer(0)]),
            patch("replace", [.string("requests"), .integer(1)], .object(["id": .integer(3)])),
            patch("remove", [.string("turns"), .string("b")]),
        ], to: &state)
        XCTAssertEqual(state, try JSONValue.parse(Data(#"""
        {"requests":[{"id":2,"completed":true},{"id":3}],"turns":{"a":{"items":["first","x","y","z"],"status":"completed"}},"title":"renamed"}
        """#.utf8)))
        // An array made shorter can come as its new length, and a position as the digits of a key.
        try CodexDesktopPatches.apply([patch("replace", [.string("turns"), .string("a"), .string("items"), .string("length")], .integer(1)),
                                       patch("replace", [.string("requests"), .string("0"), .string("id")], .integer(9))], to: &state)
        XCTAssertEqual(state["turns"]["a"]["items"], .array([.string("first")]))
        XCTAssertEqual(state["requests"].arrayValue?.first, .object(["id": .integer(9), "completed": .bool(true)]))
        // The whole state replaced makes what came before it in the same change moot.
        try CodexDesktopPatches.apply([patch("remove", [.string("nowhere"), .string("deep")]), patch("replace", [], .object(["fresh": .bool(true)])),
                                       patch("add", [.string("more")], .integer(1))], to: &state)
        XCTAssertEqual(state, .object(["fresh": .bool(true), "more": .integer(1)]))
    }

    func testAPatchThatNamesNoPlaceInTheKeptStateThrowsAndLeavesWhatItReached() throws {
        let original = try JSONValue.parse(Data(#"{"requests":[{"id":1}],"cwd":"/tmp"}"#.utf8))
        for bad in [
            patch("replace", [.string("turns"), .string("a"), .string("status")], .string("completed")),
            patch("replace", [.string("requests"), .integer(4), .string("completed")], .bool(true)),
            patch("remove", [.string("requests"), .integer(1)]),
            patch("add", [.string("requests"), .integer(3)], .null),
            patch("replace", [.string("cwd"), .string("inside")], .null),
            patch("move", [.string("cwd")], .null),
            patch("replace", [.string("requests"), .string("length")], .integer(5)),
            .object(["op": .string("replace")]),
        ] {
            var state = original
            XCTAssertThrowsError(try CodexDesktopPatches.apply([bad], to: &state), "\(bad)")
            XCTAssertEqual(state, original, "a refused patch leaves the place it was aimed at as it was")
        }
    }
}
