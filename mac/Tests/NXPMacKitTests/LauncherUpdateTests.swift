import Foundation
import XCTest

@testable import NXPMacKit

/// The launcher's own updates: which release is newer, what GitHub's answer and SHA256SUMS say, and every case where
/// it must refuse to replace itself.
final class LauncherUpdateTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("nxpocket-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func v(_ text: String) -> SemanticVersion { SemanticVersion(text)! }

    // MARK: - Versions

    func testVersionsCompareByNumberNotByText() {
        XCTAssertLessThan(v("0.2.0"), v("0.10.0"))
        XCTAssertLessThan(v("0.9.9"), v("1.0.0"))
        XCTAssertLessThan(v("1.2.3"), v("1.2.4"))
        XCTAssertEqual(v("v0.2.0"), v("0.2.0"), "the tag's v is not part of the version")
        XCTAssertEqual(v("1.0.0+build.7"), v("1.0.0"), "build metadata does not count")
    }

    func testAPrereleaseComesBeforeItsRelease() {
        XCTAssertLessThan(v("1.0.0-beta"), v("1.0.0"))
        XCTAssertLessThan(v("1.0.0-alpha"), v("1.0.0-alpha.1"))
        XCTAssertLessThan(v("1.0.0-beta.2"), v("1.0.0-beta.11"))
        XCTAssertLessThan(v("1.0.0-1"), v("1.0.0-alpha"), "numbers sort below words")
        XCTAssertGreaterThan(v("1.0.1-beta"), v("1.0.0"))
    }

    func testWhatIsNotAVersionIsRefused() {
        for text in ["", "1.2", "1.2.3.4", "a.b.c", "1.2.x", "1.2.3-", "v", "１.2.3", "1..3"] {
            XCTAssertNil(SemanticVersion(text), text)
        }
    }

    // MARK: - GitHub's answer

    private func releaseJSON(tag: String = "v0.3.0", draft: Bool = false, prerelease: Bool = false) -> Data {
        let object: [String: Any] = [
            "tag_name": tag, "name": "NXPocketApple 0.3.0", "body": "- Saves are copied by themselves\n- Setup screen",
            "html_url": "https://github.com/Absenti/NXPocketApple/releases/tag/\(tag)", "draft": draft, "prerelease": prerelease,
            "assets": [
                ["name": "NXPocketApple-macOS.zip", "browser_download_url": "https://github.com/Absenti/NXPocketApple/releases/download/\(tag)/NXPocketApple-macOS.zip"],
                ["name": "SHA256SUMS", "browser_download_url": "https://github.com/Absenti/NXPocketApple/releases/download/\(tag)/SHA256SUMS"],
                ["name": "NXPocketApple-iPhone.ipa", "browser_download_url": "http://example.com/NXPocketApple-iPhone.ipa"],
                ["name": "broken"],
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    func testTheReleaseIsReadWithItsNotesAndHTTPSAssetsOnly() throws {
        let release = try LauncherUpdate.parse(releaseJSON())
        XCTAssertEqual(release.version, v("0.3.0"))
        XCTAssertEqual(release.tag, "v0.3.0")
        XCTAssertEqual(release.title, "NXPocketApple 0.3.0")
        XCTAssertTrue(release.notes.contains("Setup screen"))
        XCTAssertEqual(release.page.absoluteString, "https://github.com/Absenti/NXPocketApple/releases/tag/v0.3.0")
        XCTAssertEqual(Set(release.assets.keys), ["NXPocketApple-macOS.zip", "SHA256SUMS"], "a plain-http asset is not taken")
    }

    func testAReleaseWhoseTagIsNotAVersionOrThatIsNotJSONIsRefused() {
        XCTAssertThrowsError(try LauncherUpdate.parse(releaseJSON(tag: "latest")))
        XCTAssertThrowsError(try LauncherUpdate.parse(Data("<html>".utf8)))
    }

    func testAPrivateRepositoryIsNoChannelYetNotAnError() {
        XCTAssertEqual(LauncherUpdate.outcome(status: 404, data: Data(#"{"message":"Not Found"}"#.utf8), current: v("0.2.0")),
                       .noPublicChannel)
    }

    func testANewerReleaseIsOfferedAndTheSameOneIsNot() {
        guard case .available(let release) = LauncherUpdate.outcome(status: 200, data: releaseJSON(), current: v("0.2.0")) else {
            return XCTFail("0.3.0 is newer than 0.2.0")
        }
        XCTAssertEqual(release.version, v("0.3.0"))
        XCTAssertEqual(LauncherUpdate.outcome(status: 200, data: releaseJSON(), current: v("0.3.0")), .upToDate(v("0.3.0")))
        XCTAssertEqual(LauncherUpdate.outcome(status: 200, data: releaseJSON(), current: v("0.4.0")), .upToDate(v("0.3.0")))
    }

    func testDraftsAndPrereleasesAreIgnored() {
        XCTAssertEqual(LauncherUpdate.outcome(status: 200, data: releaseJSON(draft: true), current: v("0.2.0")), .noPublicChannel)
        XCTAssertEqual(LauncherUpdate.outcome(status: 200, data: releaseJSON(prerelease: true), current: v("0.2.0")), .noPublicChannel)
        XCTAssertEqual(LauncherUpdate.outcome(status: 200, data: releaseJSON(tag: "v0.3.0-beta.1"), current: v("0.2.0")),
                       .noPublicChannel)
    }

    func testADevelopmentBuildIsShownTheLatestRelease() {
        guard case .available = LauncherUpdate.outcome(status: 200, data: releaseJSON(), current: nil) else {
            return XCTFail("a build without a version is offered the release (its page)")
        }
    }

    func testGitHubsLimitIsAFailureToRetryLater() {
        guard case .failed(let text) = LauncherUpdate.outcome(status: 403, data: Data(), current: v("0.2.0")) else { return XCTFail() }
        XCTAssertTrue(text.contains("later"), text)
    }

    // MARK: - SHA256SUMS

    func testShasumLinesAreReadInTextAndBinaryMode() {
        let zip = String(repeating: "a", count: 64), ipa = String(repeating: "B", count: 64)
        let text = """
            \(zip)  NXPocketApple-macOS.zip
            \(ipa) *NXPocketApple-iPhone.ipa
            not a line
            1234  short.txt

            """
        let sums = LauncherUpdate.checksums(in: text)
        XCTAssertEqual(sums["NXPocketApple-macOS.zip"], zip)
        XCTAssertEqual(sums["NXPocketApple-iPhone.ipa"], ipa.lowercased())
        XCTAssertEqual(sums.count, 2)
    }

    // MARK: - Refusals

    func testOnlyAWritableAppOutsideTheBuildFolderCanReplaceItself() throws {
        XCTAssertNotNil(LauncherUpdate.refusal(for: URL(fileURLWithPath: "/x/mac/.build/release/NXPocket")), "a plain executable")
        XCTAssertNotNil(LauncherUpdate.refusal(for: URL(fileURLWithPath: "/x/mac/.build/NXPocketApple.app")), "the --app build")
        XCTAssertNotNil(LauncherUpdate.refusal(for: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/Y/d/NXPocketApple.app")))

        let app = root.appendingPathComponent("Applications/NXPocketApple.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        XCTAssertNil(LauncherUpdate.refusal(for: app))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: app.deletingLastPathComponent().path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: app.deletingLastPathComponent().path) }
        XCTAssertNotNil(LauncherUpdate.refusal(for: app), "a folder the user cannot write")
    }

    /// An app bundle with a shell script for executable, ad hoc signed unless asked not to.
    private func fakeApp(_ name: String = "NXPocketApple.app", bundleID: String = LauncherUpdate.bundleID, version: String = "0.3.0",
                         signed: Bool = true) throws -> URL {
        let app = root.appendingPathComponent(UUID().uuidString).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleShortVersionString": version,
                                   "CFBundleExecutable": "NXPocket", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let executable = app.appendingPathComponent("Contents/MacOS/NXPocket")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        if signed {
            let result = try ProcessRunner.capture(URL(fileURLWithPath: "/usr/bin/codesign"), ["--force", "--sign", "-", app.path])
            XCTAssertEqual(result.status, 0, result.lines.joined(separator: "\n"))
        }
        return app
    }

    func testTheDownloadedAppMustBeTheLauncherAtTheReleasesVersionNewerAndSigned() throws {
        XCTAssertNoThrow(try LauncherUpdate.check(try fakeApp(), release: v("0.3.0"), current: v("0.2.0")))
        XCTAssertThrowsError(try LauncherUpdate.check(try fakeApp(bundleID: "com.example.other"), release: v("0.3.0"), current: v("0.2.0")))
        XCTAssertThrowsError(try LauncherUpdate.check(try fakeApp(version: "0.2.9"), release: v("0.3.0"), current: v("0.2.0")),
                             "the zip holds another version than the tag")
        XCTAssertThrowsError(try LauncherUpdate.check(try fakeApp(version: "0.2.0"), release: v("0.2.0"), current: v("0.2.0")),
                             "not newer")
        XCTAssertThrowsError(try LauncherUpdate.check(try fakeApp(signed: false), release: v("0.3.0"), current: v("0.2.0")))
        let tampered = try fakeApp()
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: tampered.appendingPathComponent("Contents/MacOS/NXPocket"))
        XCTAssertThrowsError(try LauncherUpdate.check(tampered, release: v("0.3.0"), current: v("0.2.0")), "changed after signing")
    }

    func testAReleaseWithoutTheLauncherOrItsSumsIsRefusedBeforeAnyDownload() throws {
        var release = try LauncherUpdate.parse(releaseJSON())
        release.assets[LauncherUpdate.sumsName] = nil
        XCTAssertThrowsError(try LauncherUpdate.prepare(release, current: v("0.2.0"), replacing: try fakeApp()) { _, _ in }) { error in
            XCTAssertTrue("\(error)".contains("SHA256SUMS"), "\(error)")
        }
    }

    func testTheSwapRefusesANewAppItDidNotUnpack() throws {
        XCTAssertThrowsError(try LauncherUpdate.startSwap(app: try fakeApp(), newApp: try fakeApp(), version: v("0.2.0")),
                             "its folder would be removed by the script")
    }

    /// The whole download path against a local server holding a real `--app` build zipped as a release is:
    /// NXPOCKET_UPDATE_LIVE=http://127.0.0.1:<port> with NXPocketApple-macOS.zip, SHA256SUMS and BAD_SUMS (wrong hash).
    func testLivePrepareFromALocalServer() throws {
        guard let base = ProcessInfo.processInfo.environment["NXPOCKET_UPDATE_LIVE"].flatMap(URL.init(string:)) else {
            throw XCTSkip("set NXPOCKET_UPDATE_LIVE to a local server holding a release's files")
        }
        let target = try fakeApp(version: "0.1.0")
        func release(sums: String) -> LauncherRelease {
            LauncherRelease(tag: "v0.2.0", version: v("0.2.0"), title: "test", notes: "", page: base, isDraft: false,
                            isPrerelease: false,
                            assets: [LauncherUpdate.zipName: base.appendingPathComponent(LauncherUpdate.zipName),
                                     LauncherUpdate.sumsName: base.appendingPathComponent(sums)])
        }
        let last = LastFraction()
        let newApp = try LauncherUpdate.prepare(release(sums: "SHA256SUMS"), current: v("0.1.0"), replacing: target) { written, expected in
            if expected > 0 { last.set(Double(written) / Double(expected)) }
        }
        XCTAssertEqual(newApp.lastPathComponent, "NXPocketApple.app")
        XCTAssertEqual(newApp.deletingLastPathComponent().lastPathComponent, "unpacked")
        XCTAssertEqual(last.value, 1)
        print("live update: unpacked \(newApp.path)")
        try? FileManager.default.removeItem(at: newApp.deletingLastPathComponent().deletingLastPathComponent())
        XCTAssertThrowsError(try LauncherUpdate.prepare(release(sums: "BAD_SUMS"), current: v("0.1.0"), replacing: target) { _, _ in }) {
            XCTAssertTrue("\($0)".contains("does not match"), "\($0)")
        }
        XCTAssertThrowsError(try LauncherUpdate.prepare(release(sums: "SHA256SUMS"), current: v("0.2.0"), replacing: target) { _, _ in },
                             "not newer than the running one")
    }

    // MARK: - The swap script

    private func runSwap(newAppPresent: Bool) throws -> (old: URL, trashed: URL, staging: URL) {
        let old = root.appendingPathComponent("Apps/NXPocketApple's.app", isDirectory: true)   // a quote in the path
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: old.appendingPathComponent("which"))
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let newApp = staging.appendingPathComponent("unpacked/NXPocketApple.app", isDirectory: true)
        if newAppPresent {
            try FileManager.default.createDirectory(at: newApp, withIntermediateDirectories: true)
            try Data("new".utf8).write(to: newApp.appendingPathComponent("which"))
        }
        let trashed = root.appendingPathComponent("Trash/NXPocketApple 0.2.0 1.app", isDirectory: true)
        try FileManager.default.createDirectory(at: trashed.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A process that has already exited stands for the launcher.
        let gone = Process()
        gone.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try gone.run()
        gone.waitUntilExit()
        let script = root.appendingPathComponent("swap.sh")
        try Data(LauncherUpdate.swapScript(app: old, newApp: newApp, trashed: trashed, staging: staging,
                                           pid: gone.processIdentifier, opener: "/usr/bin/true").utf8).write(to: script)
        _ = try ProcessRunner.capture(URL(fileURLWithPath: "/bin/sh"), [script.path])
        return (old, trashed, staging)
    }

    func testTheSwapPutsTheOldAppInTheTrashAndTheNewOneInItsPlace() throws {
        let (old, trashed, staging) = try runSwap(newAppPresent: true)
        XCTAssertEqual(try String(contentsOf: old.appendingPathComponent("which"), encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: trashed.appendingPathComponent("which"), encoding: .utf8), "old",
                       "the old app is in the Trash, not deleted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testAFailedSwapPutsTheOldAppBack() throws {
        let (old, trashed, _) = try runSwap(newAppPresent: false)
        XCTAssertEqual(try String(contentsOf: old.appendingPathComponent("which"), encoding: .utf8), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashed.path))
    }
}

private final class LastFraction: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Double?
    func set(_ value: Double) { lock.lock(); stored = value; lock.unlock() }
    var value: Double? { lock.lock(); defer { lock.unlock() }; return stored }
}
