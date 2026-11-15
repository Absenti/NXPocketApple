import Foundation
import XCTest

@testable import NXPMacKit

/// The iPhone app screen: its IPA, the script that builds it, and the helper that turns on the larger memory limit.
final class PhoneAppTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("nxpocket-phoneapp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testReadsTheVersionOfAnIPAWithoutUnpackingIt() throws {
        let app = folder.appendingPathComponent("pkg/Payload/NXPocket.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleShortVersionString": "0.1", "CFBundleVersion": "7", "CFBundleIdentifier": "dev.nxpocketapple.app"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        let ipa = folder.appendingPathComponent("NXPocketApple.ipa")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = folder.appendingPathComponent("pkg")
        zip.arguments = ["-qry", ipa.path, "Payload"]
        try zip.run()
        zip.waitUntilExit()
        let found = try XCTUnwrap(PhoneAppBuild.inspect(ipa))
        XCTAssertEqual(found.versionText, "0.1 (7)")
        XCTAssertEqual(found.bundleID, "dev.nxpocketapple.app")
        XCTAssertNil(PhoneAppBuild.inspect(folder.appendingPathComponent("none.ipa")))
    }

    func testFindsTheRepositoryAboveTheLauncher() throws {
        let repository = folder.appendingPathComponent("NXPocketApple")
        let executable = repository.appendingPathComponent("mac/.build/release/NXPocket")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repository.appendingPathComponent("tools"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repository.appendingPathComponent("app/Sources"), withIntermediateDirectories: true)
        try Data().write(to: repository.appendingPathComponent("tools/build_app.sh"))
        try Data().write(to: repository.appendingPathComponent("app/project.yml"))
        try Data().write(to: executable)
        XCTAssertEqual(PhoneAppBuild.repository(from: executable)?.resolvingSymlinksInPath().path, repository.resolvingSymlinksInPath().path)
        XCTAssertNil(PhoneAppBuild.repository(from: folder.appendingPathComponent("elsewhere/NXPocketApple")))

        let source = repository.appendingPathComponent("app/Sources/A.swift")
        try Data("x".utf8).write(to: source)
        let date = Date(timeIntervalSince1970: 1_900_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: source.path)
        XCTAssertEqual(PhoneAppBuild.newestSourceChange(in: repository), date)
    }

    func testFollowsTheScriptsStagesAndItsFailure() {
        XCTAssertEqual(PhoneAppBuild.progress(after: "\u{1B}[1mgenerating the project\u{1B}[0m")?.fraction, 0.05)
        XCTAssertEqual(PhoneAppBuild.progress(after: "\u{1B}[1mpacking the IPA\u{1B}[0m")?.fraction, 0.92)
        XCTAssertNil(PhoneAppBuild.progress(after: "** BUILD SUCCEEDED **"))
        XCTAssertEqual(PhoneAppBuild.failure(in: "\u{1B}[31mFAIL: xcodegen is missing (brew install xcodegen)\u{1B}[0m"),
                       "xcodegen is missing (brew install xcodegen)")
        let environment = PhoneAppBuild.environment(output: URL(fileURLWithPath: "/out"), xcode: URL(fileURLWithPath: "/Applications/Xcode.app"))
        XCTAssertEqual(environment["NXPOCKET_OUTPUT"], "/out", "the IPA lands where the screen looks")
        XCTAssertTrue(environment["PATH"]?.hasPrefix("/opt/homebrew/bin:") ?? false, "a Finder-started launcher has no shell PATH")
        XCTAssertEqual(environment["DEVELOPER_DIR"], "/Applications/Xcode.app/Contents/Developer")
    }

    // MARK: - Increased Memory Limit

    func testTheTeamIsTheSuffixSideStoreAppends() {
        XCTAssertEqual(MemoryLimitHelper.target(installed: "dev.nxpocketapple.app.ABCDE12345", base: "dev.nxpocketapple.app"),
                       MemoryLimitHelper.Target(bundleID: "dev.nxpocketapple.app.ABCDE12345", team: "ABCDE12345"))
        XCTAssertNil(MemoryLimitHelper.target(installed: "dev.nxpocketapple.app", base: "dev.nxpocketapple.app"), "installed by Xcode: no team in it")
        XCTAssertNil(MemoryLimitHelper.target(installed: "dev.nxpocketapple.app.beta", base: "dev.nxpocketapple.app"))
        XCTAssertNil(MemoryLimitHelper.target(installed: "com.other.ABCDE12345", base: "dev.nxpocketapple.app"))
    }

    /// FlareStore (and Sideloadly, TrollStore, Xcode) install the app under its plain ID: a normal installation, which
    /// the launcher used to report as "App ID not found" because it only knew SideStore's suffixed one.
    func testAnAppInstalledUnderItsPlainIDIsAnInstallationNotAnError() {
        let base = "dev.nxpocketapple.app"
        XCTAssertEqual(MemoryLimitHelper.installation(installed: "dev.nxpocketapple.app.ABCDE12345", base: base),
                       .teamSigned(MemoryLimitHelper.Target(bundleID: "dev.nxpocketapple.app.ABCDE12345", team: "ABCDE12345")))
        XCTAssertEqual(MemoryLimitHelper.installation(installed: base, base: base), .other(bundleID: base))
        XCTAssertEqual(MemoryLimitHelper.installation(installed: base, base: base).bundleID, base)
        XCTAssertEqual(MemoryLimitHelper.installation(installed: "dev.nxpocketapple.app.beta", base: base),
                       .other(bundleID: "dev.nxpocketapple.app.beta"), "a suffix that is not a team is not SideStore's")
    }

    func testReadsXcodesTeamsFromItsPreferences() {
        let accounts: [String: Any] = ["account-1": [["teamID": "ABCDE12345", "teamType": "Personal Team"], ["teamID": "ABCDE12345"]]]
        XCTAssertEqual(MemoryLimitHelper.teams(inProvisioningTeams: accounts), ["ABCDE12345", "ABCDE12345"])
        XCTAssertEqual(MemoryLimitHelper.teams(inProvisioningTeams: [:]), [])
    }

    func testTheAppIDsToPrepareBeforeTheFirstInstallAreTheBundleIDWithEachTeam() {
        let targets = MemoryLimitHelper.plannedTargets(base: "dev.nxpocketapple.app", teams: ["ZZZZZ99999", "ABCDE12345"])
        XCTAssertEqual(targets, [MemoryLimitHelper.Target(bundleID: "dev.nxpocketapple.app.ABCDE12345", team: "ABCDE12345"),
                                 MemoryLimitHelper.Target(bundleID: "dev.nxpocketapple.app.ZZZZZ99999", team: "ZZZZZ99999")])
        XCTAssertEqual(MemoryLimitHelper.target(installed: targets[0].bundleID, base: "dev.nxpocketapple.app"), targets[0],
                       "the ID prepared is the one SideStore later installs under")
        XCTAssertTrue(MemoryLimitHelper.plannedTargets(base: "dev.nxpocketapple.app", teams: []).isEmpty)
    }

    func testTheHelperAsksForTheEntitlementUnderTheAppIDWithAutomaticSigning() throws {
        let target = MemoryLimitHelper.Target(bundleID: "dev.nxpocketapple.app.ABCDE12345", team: "ABCDE12345")
        let yaml = MemoryLimitHelper.projectYAML(target)
        for line in ["PRODUCT_BUNDLE_IDENTIFIER: dev.nxpocketapple.app.ABCDE12345", "DEVELOPMENT_TEAM: ABCDE12345",
                     "CODE_SIGN_STYLE: Automatic", "CODE_SIGN_ENTITLEMENTS: EnableMemoryLimit.entitlements"] {
            XCTAssertTrue(yaml.contains(line), line)
        }
        let entitlements = try XCTUnwrap(try PropertyListSerialization.propertyList(
            from: Data(MemoryLimitHelper.entitlementsPlist.utf8), format: nil) as? [String: Any])
        XCTAssertEqual(entitlements[MemoryLimitHelper.entitlement] as? Bool, true)
        let arguments = MemoryLimitHelper.buildArguments(project: URL(fileURLWithPath: "/tmp/h/EnableMemoryLimit.xcodeproj"),
                                                         derivedData: URL(fileURLWithPath: "/tmp/h/dd"))
        XCTAssertTrue(arguments.contains("-allowProvisioningUpdates"))
        XCTAssertEqual(arguments[arguments.firstIndex(of: "-destination")! + 1], "generic/platform=iOS")
    }

    func testTellsASuccessFromAMissingAccount() {
        XCTAssertEqual(MemoryLimitHelper.interpret(status: 0, lines: ["CodeSign …", "** BUILD SUCCEEDED **"]), .enabled)
        let noAccount = ["/tmp/h/EnableMemoryLimit.xcodeproj: error: No Accounts: Add a new account in Accounts settings. (in target 'EnableMemoryLimit')",
                         "** BUILD FAILED **"]
        guard case .needsAccount = MemoryLimitHelper.interpret(status: 65, lines: noAccount) else { return XCTFail("not an account problem") }
        guard case .failed(let reason) = MemoryLimitHelper.interpret(status: 65, lines: ["error: Provisioning profile doesn't include the device", "** BUILD FAILED **"]) else {
            return XCTFail("not a failure")
        }
        XCTAssertTrue(reason.contains("Provisioning profile"))
    }
}
