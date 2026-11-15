import XCTest

@testable import NXPocketKit

final class TransferSpeedTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testSpeedIsTheRecentAverageAndStartsAtAnyOffset() {
        var speed = TransferSpeed()
        XCTAssertEqual(speed.bytesPerSecond, 0)
        // A resume starts at 5 GB: only what arrived since counts.
        speed.add(bytes: 5_000_000_000, at: start)
        XCTAssertEqual(speed.bytesPerSecond, 0, "not a second of data yet")
        speed.add(bytes: 5_010_000_000, at: start.addingTimeInterval(2))
        XCTAssertEqual(speed.bytesPerSecond, 5_000_000, accuracy: 1)
    }

    func testOldSamplesLeaveTheWindow() {
        var speed = TransferSpeed()
        speed.add(bytes: 0, at: start)
        speed.add(bytes: 100_000_000, at: start.addingTimeInterval(10))
        // The network slowed down: the fast start no longer counts.
        for second in 11...30 { speed.add(bytes: 100_000_000 + Int64(second - 10) * 1_000_000, at: start.addingTimeInterval(Double(second))) }
        XCTAssertEqual(speed.bytesPerSecond, 1_000_000, accuracy: 1_000)
    }

    func testACountThatGoesDownStartsOver() {
        var speed = TransferSpeed()
        speed.add(bytes: 9_000, at: start)
        speed.add(bytes: 10_000, at: start.addingTimeInterval(2))
        speed.add(bytes: 100, at: start.addingTimeInterval(3))
        XCTAssertEqual(speed.bytesPerSecond, 0)
    }

    func testTimeLeftAndItsWords() {
        var speed = TransferSpeed()
        speed.add(bytes: 0, at: start)
        speed.add(bytes: 20_000_000, at: start.addingTimeInterval(2))
        XCTAssertEqual(try XCTUnwrap(speed.secondsLeft(bytesLeft: 600_000_000)), 60, accuracy: 0.01)
        XCTAssertNil(TransferSpeed().secondsLeft(bytesLeft: 1))
        XCTAssertEqual(TransferSpeed.leftText(0.2), "1 s left")
        XCTAssertEqual(TransferSpeed.leftText(45), "45 s left")
        XCTAssertEqual(TransferSpeed.leftText(360), "6 min left")
        XCTAssertEqual(TransferSpeed.leftText(3600), "1 h left")
        XCTAssertEqual(TransferSpeed.leftText(4320), "1 h 12 min left")
    }
}
