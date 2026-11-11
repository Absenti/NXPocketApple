import XCTest

@testable import NXShellHost

final class UpdateChannelTests: XCTestCase {
    /// A source as AltStore and SideStore read it, iPorterNX among other apps, its versions out of order.
    private let source = Data("""
    {"name": "iPorterNX", "identifier": "dev.nxpocket.source", "apps": [
      {"name": "Other", "bundleIdentifier": "com.example.other", "versions": [{"version": "9.9.9"}]},
      {"name": "iPorterNX", "bundleIdentifier": "dev.nxpocket.app", "developerName": "iPorterNX",
       "versions": [
         {"version": "0.2.0", "buildVersion": "7", "date": "2026-11-11T20:00:00Z", "size": 20000000,
          "downloadURL": "https://github.com/Absenti/iPorterNX/releases/download/v0.2.0/iPorterNX-iPhone.ipa"},
         {"version": "0.10.0", "buildVersion": "12", "date": "2026-12-01", "size": 21000000,
          "downloadURL": "https://github.com/Absenti/iPorterNX/releases/download/v0.10.0/iPorterNX-iPhone.ipa"},
         {"version": "not a version"}
       ]}
    ]}
    """.utf8)

    func testTheNewestNXPocketReleaseIsReadFromItsOwnEntry() throws {
        let release = try XCTUnwrap(UpdateChannel.newestRelease(in: source))
        XCTAssertEqual(release.version, "0.10.0", "0.10.0 is newer than 0.2.0: versions compare as numbers")
        XCTAssertEqual(release.build, "12")
        XCTAssertEqual(release.size, 21_000_000)
        XCTAssertEqual(release.downloadURL?.lastPathComponent, "iPorterNX-iPhone.ipa")
        XCTAssertNotNil(release.date, "a date alone, without a time, reads too")
    }

    func testAnOlderSourceWithTheVersionOnTheAppReads() throws {
        let legacy = Data("""
        {"apps": [{"bundleIdentifier": "dev.nxpocket.app", "version": "0.3.1", "versionDate": "2026-12-24",
                   "downloadURL": "https://example.invalid/iPorterNX-iPhone.ipa", "size": 5}]}
        """.utf8)
        XCTAssertEqual(UpdateChannel.newestRelease(in: legacy)?.version, "0.3.1")
        XCTAssertNil(UpdateChannel.newestRelease(in: Data(#"{"apps": []}"#.utf8)))
        XCTAssertNil(UpdateChannel.newestRelease(in: Data("<html>404</html>".utf8)))
    }

    func testVersionsCompareAsNumbersAndTheBuildBreaksATie() {
        XCTAssertEqual(UpdateChannel.compare("0.10.0", "0.9.9"), .orderedDescending)
        XCTAssertEqual(UpdateChannel.compare("1.0", "1.0.0"), .orderedSame)
        XCTAssertEqual(UpdateChannel.compare("0.2.0", "0.2.1"), .orderedAscending)
        let release = UpdateChannel.Release(version: "0.2.0", build: "8", date: nil, size: nil, downloadURL: nil)
        XCTAssertTrue(UpdateChannel.isNewer(release, thanVersion: "0.2.0", build: "7"))
        XCTAssertFalse(UpdateChannel.isNewer(release, thanVersion: "0.2.0", build: "8"))
        XCTAssertFalse(UpdateChannel.isNewer(release, thanVersion: "0.2.0", build: nil), "no build to compare: same version")
        XCTAssertFalse(UpdateChannel.isNewer(release, thanVersion: "0.3.0", build: "1"))
    }

    func testTheSideStoreLinkCarriesTheSourceAddressEncoded() {
        XCTAssertEqual(UpdateChannel.addSourceURL.absoluteString,
                       "sidestore://source?url=https%3A%2F%2Fgithub.com%2FAbsenti%2FiPorterNX%2Freleases%2Flatest%2Fdownload%2Fsource.json")
    }

    func testTheCheckIsOneGetThatSendsNothingAndAPrivateRepositoryIsNoError() async {
        var requests: [URLRequest] = []
        let outcome = await UpdateChannel.check(version: "0.2.0", build: "7") { request in
            requests.append(request)
            return (Data("Not Found".utf8), 404)
        }
        XCTAssertEqual(outcome, .noPublicChannel)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url, UpdateChannel.sourceURL)
        XCTAssertEqual(requests.first?.httpMethod ?? "GET", "GET")
        XCTAssertNil(requests.first?.httpBody)
        XCTAssertEqual(requests.first?.timeoutInterval, 10)
        XCTAssertEqual(requests.first?.httpShouldHandleCookies, false)

        let newer = await UpdateChannel.check(version: "0.2.0", build: "7") { _ in (self.source, 200) }
        guard case .newer(let release) = newer else { return XCTFail("\(newer)") }
        XCTAssertEqual(release.version, "0.10.0")
        let current = await UpdateChannel.check(version: "0.10.0", build: "12") { _ in (self.source, 200) }
        guard case .upToDate = current else { return XCTFail("\(current)") }
        let offline = await UpdateChannel.check(version: "0.2.0", build: "7") { _ in throw URLError(.notConnectedToInternet) }
        guard case .failed = offline else { return XCTFail("\(offline)") }
    }

    @MainActor
    func testTheAutomaticCheckRunsAtMostOnceADayAndNotWhenTurnedOff() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "nxpocket-updates-\(UUID().uuidString)"))
        var calls = 0
        let checker = UpdateChecker(defaults: defaults, version: "0.2.0", build: "7") { _ in
            calls += 1
            return (self.source, 200)
        }
        XCTAssertTrue(checker.automatic, "on by default")
        let now = Date()
        await checker.checkIfDue(now: now)?.value
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(checker.newerRelease?.version, "0.10.0")
        XCTAssertNil(checker.checkIfDue(now: now.addingTimeInterval(3600)), "not twice in a day")
        checker.dismiss(try XCTUnwrap(checker.newerRelease))
        XCTAssertNil(checker.newerRelease, "put off: the library stops mentioning it")
        checker.automatic = false
        XCTAssertNil(checker.checkIfDue(now: now.addingTimeInterval(2 * 86400)))
        XCTAssertEqual(defaults.object(forKey: "updates.automatic") as? Bool, false, "the choice is kept")
        await checker.check(now: now.addingTimeInterval(2 * 86400))
        XCTAssertEqual(calls, 2, "a check asked for by hand still runs")
    }
}
