import Foundation
import XCTest

@testable import NXPMacKit

final class PhoneAppDownloadTests: XCTestCase {
    private func release(_ version: String, assets: [String]) -> LauncherRelease {
        var urls: [String: URL] = [:]
        for name in assets { urls[name] = URL(string: "https://example.invalid/\(name)")! }
        return LauncherRelease(tag: "v\(version)", version: SemanticVersion(version)!, title: version, notes: "",
                               page: URL(string: "https://example.invalid")!, isDraft: false, isPrerelease: false, assets: urls)
    }

    private func ipa(_ version: String?) -> PhoneAppIPA {
        PhoneAppIPA(url: URL(fileURLWithPath: "/tmp/NXPocketApple.ipa"), date: Date(), bytes: 1, version: version, build: nil,
                    bundleID: PhoneAppDownload.bundleID)
    }

    func testAReleaseWithoutTheIPAOrItsSumsOffersNothing() {
        XCTAssertFalse(PhoneAppDownload.hasIPA(release("0.3.0", assets: ["NXPocketApple-macOS.zip", "SHA256SUMS"])))
        XCTAssertFalse(PhoneAppDownload.hasIPA(release("0.3.0", assets: ["NXPocketApple-iPhone.ipa"])), "no sums to check it against")
        XCTAssertTrue(PhoneAppDownload.hasIPA(release("0.3.0", assets: ["NXPocketApple-iPhone.ipa", "SHA256SUMS"])))
    }

    func testTheIPAIsFetchedWhenMissingOrOlderAndNotOtherwise() {
        let latest = release("0.3.0", assets: ["NXPocketApple-iPhone.ipa", "SHA256SUMS"])
        XCTAssertTrue(PhoneAppDownload.needsDownload(have: nil, release: latest))
        XCTAssertTrue(PhoneAppDownload.needsDownload(have: ipa("0.2.1"), release: latest))
        XCTAssertTrue(PhoneAppDownload.needsDownload(have: ipa(nil), release: latest), "an IPA whose version cannot be read is replaced")
        XCTAssertFalse(PhoneAppDownload.needsDownload(have: ipa("0.3.0"), release: latest))
        XCTAssertFalse(PhoneAppDownload.needsDownload(have: ipa("0.4.0"), release: latest), "a newer one built here is kept")
        XCTAssertFalse(PhoneAppDownload.needsDownload(have: nil, release: release("0.3.0", assets: [])), "nothing to fetch")
    }
}

final class PhoneAppSeedTests: XCTestCase {
    /// A minimal IPA: a zip with `Payload/NXPocket.app/Info.plist`.
    private func makeIPA(at url: URL, bundleID: String, version: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("seed-\(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent("Payload/NXPocket.app", isDirectory: true)
        try fileManager.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleShortVersionString": version, "CFBundleVersion": "1"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = root
        zip.arguments = ["-qr", url.path, "Payload"]
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("seed-out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testTheBundledIPAIsPutInPlaceWhenNoneIsThere() throws {
        let dir = try folder()
        let bundled = dir.appendingPathComponent("bundled.ipa")
        try makeIPA(at: bundled, bundleID: PhoneAppDownload.bundleID, version: "0.2.1")
        let destination = dir.appendingPathComponent("out/NXPocketApple.ipa")
        XCTAssertEqual(PhoneAppDownload.seed(from: bundled, to: destination)?.version, "0.2.1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    func testAnOlderCopyIsReplacedAndANewerOrEqualOneKept() throws {
        let dir = try folder()
        let destination = dir.appendingPathComponent("NXPocketApple.ipa")
        let bundled = dir.appendingPathComponent("bundled.ipa")
        try makeIPA(at: bundled, bundleID: PhoneAppDownload.bundleID, version: "0.3.0")
        try makeIPA(at: destination, bundleID: PhoneAppDownload.bundleID, version: "0.2.0")
        XCTAssertEqual(PhoneAppDownload.seed(from: bundled, to: destination)?.version, "0.3.0")
        XCTAssertNil(PhoneAppDownload.seed(from: bundled, to: destination), "the same version is left alone")
        try makeIPA(at: bundled, bundleID: PhoneAppDownload.bundleID, version: "0.2.5")
        XCTAssertNil(PhoneAppDownload.seed(from: bundled, to: destination), "a newer copy already there is kept")
    }

    func testAnIPAOfAnotherAppIsNeverPutInPlace() throws {
        let dir = try folder()
        let bundled = dir.appendingPathComponent("old.ipa")
        try makeIPA(at: bundled, bundleID: "dev.nxpocket.app", version: "0.2.0")
        let destination = dir.appendingPathComponent("NXPocketApple.ipa")
        XCTAssertNil(PhoneAppDownload.seed(from: bundled, to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}
