import XCTest

@testable import NXShellUI

final class ShellStringsTests: XCTestCase {
    func testEveryKeyHasAnEnglishLine() {
        for key in ShellStrings.Key.allCases {
            XCTAssertFalse(ShellStrings.text(key).isEmpty, "\(key) has no text")
        }
    }

    func testNoKeyFallsBackToItsName() {
        for key in ShellStrings.Key.allCases { XCTAssertNotNil(ShellStrings.english[key], "\(key) is not in the dictionary") }
    }
}
