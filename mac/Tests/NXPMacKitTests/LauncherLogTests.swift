import XCTest
@testable import NXPMacKit

final class LauncherLogTests: XCTestCase {
    private func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("launcher-log-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    /// A build that failed an hour ago left nothing to read: the window's log is in memory and forgets at quit.
    func testWhatTheWindowShowedIsOnDiskAfterwards() throws {
        let url = try scratch().appendingPathComponent("Logs/launcher.log")
        let log = LauncherLog(url: url)
        log.append("build: Mario Kart 8 Deluxe [0100152000022000] v1441792")
        log.append("Mario Kart 8 Deluxe: the package is damaged")
        let text = log.read()
        XCTAssertTrue(text.contains("build: Mario Kart 8 Deluxe [0100152000022000]"))
        XCTAssertTrue(text.contains("the package is damaged"))
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "build:")).lowerBound, try XCTUnwrap(text.range(of: "damaged")).lowerBound)
        // A second launcher reads the first one's lines.
        XCTAssertTrue(LauncherLog(url: url).read().contains("the package is damaged"))
    }

    func testItKeepsTheLastLinesInsteadOfGrowingForever() throws {
        let url = try scratch().appendingPathComponent("launcher.log")
        let log = LauncherLog(url: url, limit: 2048)
        for index in 0..<400 { log.append("engine: shader \(index) compiled, padding padding padding") }
        let text = log.read()
        XCTAssertTrue(text.contains("shader 399"), "the newest lines are kept")
        let current = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        XCTAssertLessThan(current, 4096)
    }
}
