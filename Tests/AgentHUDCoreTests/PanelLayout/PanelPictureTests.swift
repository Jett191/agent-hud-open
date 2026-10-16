import Foundation
import XCTest
@testable import AgentHUDCore

/// The rules of the panel's picture that hold without drawing it: how an account's label is masked, what a session
/// row is called instead of its title, the scale a tall panel is drawn at, and when a panel scrolls.
final class PanelPictureTests: XCTestCase {
    override func tearDown() {
        L10n.setLanguage(.system)
        super.tearDown()
    }

    func testAnEmailKeepsTheEndsOfItsNameAndItsDomain() {
        XCTAssertEqual(IdentityMask.account("jazzenus@gmail.com"), "j***s@gmail.com")
        XCTAssertEqual(IdentityMask.account("w.k@example.com"), "w***k@example.com")
        XCTAssertEqual(IdentityMask.account("abc@example.com"), "a***c@example.com", "three characters keep both ends")
        XCTAssertEqual(IdentityMask.account("ab@example.com"), "***@example.com")
        XCTAssertEqual(IdentityMask.account("a@example.com"), "***@example.com")
        XCTAssertEqual(IdentityMask.account("@example.com"), "@example.com", "no name before the @ is nothing to hide")
        XCTAssertEqual(IdentityMask.account("team@work@example.com"), "t***m@work@example.com", "the name ends at the first @")
    }

    func testAPlainLabelKeepsItsFirstAndLastCharacter() {
        XCTAssertEqual(IdentityMask.account("Personal"), "P***l")
        XCTAssertEqual(IdentityMask.account("Account 15e866"), "A***6")
        XCTAssertEqual(IdentityMask.account("CN · PLAN · Account 15e866"), "C***6")
        XCTAssertEqual(IdentityMask.account("李小明"), "李***明", "characters as a person reads them")
        XCTAssertEqual(IdentityMask.account("👩‍💻dev👨‍👩‍👧"), "👩‍💻***👨‍👩‍👧")
    }

    func testAShortLabelIsAllAsterisksAndAnEmptyOneStaysEmpty() {
        XCTAssertEqual(IdentityMask.account("ab"), "***")
        XCTAssertEqual(IdentityMask.account("Q"), "***")
        XCTAssertEqual(IdentityMask.account("张三"), "***")
        XCTAssertEqual(IdentityMask.account(""), "")
        for label in ["ab", "Q", "Personal", "jazzenus@gmail.com"] {
            XCTAssertEqual(IdentityMask.account(label).filter { $0 == "*" }.count, 3, "the length of a name is not told: \(label)")
        }
    }

    func testASessionIsCalledByItsPlaceInTheList() {
        L10n.setLanguage(.en)
        XCTAssertEqual(IdentityMask.session(at: 1), "Session 1")
        XCTAssertEqual(IdentityMask.session(at: 5), "Session 5")
        L10n.setLanguage(.zhHans)
        XCTAssertEqual(IdentityMask.session(at: 2), "会话 2")
    }

    func testATallPanelIsDrawnAtTheScaleThatKeepsItWithinTheLimit() {
        XCTAssertEqual(PanelPicture.pointScale, 2)
        XCTAssertEqual(PanelPicture.pixelLimit, 2_400)
        XCTAssertEqual(PanelPicture.scale(forHeight: 741), 2)
        XCTAssertEqual(PanelPicture.scale(forHeight: 1_200), 2, "exactly at the limit")
        XCTAssertEqual(PanelPicture.scale(forHeight: 1_500), 1.6, accuracy: 0.000_001)
        XCTAssertEqual(PanelPicture.scale(forHeight: 1_500) * 1_500, 2_400, accuracy: 0.000_001)
        XCTAssertEqual(PanelPicture.scale(forHeight: 500, limit: 800), 1.6, accuracy: 0.000_001)
        XCTAssertEqual(PanelPicture.scale(forHeight: 0), 2)

        let drawn = PanelPicture(png: Data(), width: 540, fit: PanelFit(height: 1_500, maximumHeight: 1_360), scale: 1.6)
        XCTAssertTrue(drawn.isScaledDown)
        XCTAssertFalse(PanelPicture(png: Data(), width: 540, fit: PanelFit(height: 741, maximumHeight: 900), scale: 2).isScaledDown)
    }

    func testAPanelScrollsOnlyWhenItIsTallerThanTheDisplayLetsItOpen() {
        XCTAssertFalse(PanelFit(height: 741, maximumHeight: 902).scrolls)
        XCTAssertFalse(PanelFit(height: 902, maximumHeight: 902).scrolls, "a panel as tall as the room it has fits")
        XCTAssertTrue(PanelFit(height: 903, maximumHeight: 902).scrolls)
    }
}
