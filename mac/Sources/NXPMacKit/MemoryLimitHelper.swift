import Foundation
import NXPocketKit

/// Turns on "Increased Memory Limit" for the App ID SideStore registered for NXPocket, the way it was done by hand on
/// 2026-11-10 (GetMoreRam did not work for this user): a one-off app whose bundle ID is exactly that App ID, with
/// the entitlement, built once for a device with Xcode's automatic signing. Xcode then turns the capability on for
/// the App ID on Apple's side; nothing it builds is installed. SideStore's next install or refresh of NXPocket
/// carries the entitlement, since it signs with what the App ID allows.
public enum MemoryLimitHelper {
    public static let entitlement = "com.apple.developer.kernel.increased-memory-limit"
    public static let scheme = "EnableMemoryLimit"

    /// The App ID and the team, read from the bundle ID SideStore installed NXPocket under: SideStore appends the
    /// team to it (`dev.nxpocket.app.ABCDE12345`).
    public struct Target: Equatable, Sendable {
        public var bundleID: String
        public var team: String
    }

    /// Nil when `installed` does not end in a team ID: the app was installed under its plain ID, by Xcode or
    /// another tool, and the team cannot be told from it.
    public static func target(installed: String, base: String) -> Target? {
        guard installed.hasPrefix(base + ".") else { return nil }
        let team = String(installed.dropFirst(base.count + 1))
        guard team.count == 10, team.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else { return nil }
        return Target(bundleID: installed, team: team)
    }

    /// The teams Xcode is signed in with (Xcode → Settings → Accounts), from its preferences: the build signs with
    /// the team only if Xcode has the Apple ID that SideStore uses.
    public static func xcodeTeams() -> Set<String> {
        guard let value = CFPreferencesCopyAppValue("IDEProvisioningTeamByIdentifier" as CFString, "com.apple.dt.Xcode" as CFString),
              let accounts = value as? [String: Any] else { return [] }
        return teams(inProvisioningTeams: accounts)
    }

    static func teams(inProvisioningTeams accounts: [String: Any]) -> Set<String> {
        var found = Set<String>()
        for case let teams as [[String: Any]] in accounts.values {
            for team in teams { if let id = team["teamID"] as? String { found.insert(id) } }
        }
        return found
    }

    // MARK: - The project

    public static func projectYAML(_ target: Target) -> String {
        """
        # One-off helper made by the NXPocket launcher: asks Apple, through Xcode's automatic signing, to enable
        # "Increased Memory Limit" on the App ID SideStore registered for NXPocket. Nothing it builds is installed.
        name: \(scheme)
        options:
          deploymentTarget:
            iOS: '26.0'
        targets:
          \(scheme):
            type: application
            platform: iOS
            sources: [Sources]
            settings:
              base:
                PRODUCT_BUNDLE_IDENTIFIER: \(target.bundleID)
                DEVELOPMENT_TEAM: \(target.team)
                CODE_SIGN_STYLE: Automatic
                CODE_SIGN_ENTITLEMENTS: \(scheme).entitlements
                GENERATE_INFOPLIST_FILE: YES
                TARGETED_DEVICE_FAMILY: '1'
                SWIFT_VERSION: '5.0'

        """
    }

    public static let entitlementsPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>\(entitlement)</key>
        \t<true/>
        </dict>
        </plist>

        """

    public static let appSource = """
        import SwiftUI

        @main
        struct EnableMemoryLimitApp: App {
            var body: some Scene { WindowGroup { Text("Nothing to see: this target only exists to update an App ID.") } }
        }

        """

    /// Writes the helper's sources into `folder` and generates its Xcode project. Returns the project.
    public static func generate(_ target: Target, in folder: URL, xcodegen: URL) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: folder.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try projectYAML(target).write(to: folder.appendingPathComponent("project.yml"), atomically: true, encoding: .utf8)
        try entitlementsPlist.write(to: folder.appendingPathComponent("\(scheme).entitlements"), atomically: true, encoding: .utf8)
        try appSource.write(to: folder.appendingPathComponent("Sources/App.swift"), atomically: true, encoding: .utf8)
        let runner = ProcessRunner(executable: xcodegen, arguments: ["generate", "--spec", "project.yml"], currentDirectory: folder)
        try runner.start()
        let result = runner.waitUntilExit()
        let project = folder.appendingPathComponent("\(scheme).xcodeproj")
        guard result.status == 0, manager.fileExists(atPath: project.path) else {
            throw NXPocketError(.engineFailed, "XcodeGen could not make the helper's project: \(result.lines.suffix(2).joined(separator: " "))")
        }
        return project
    }

    /// `xcodebuild` for any iOS device, allowed to update the provisioning on Apple's side: that is the point.
    public static func buildArguments(project: URL, derivedData: URL) -> [String] {
        ["-project", project.path, "-scheme", scheme, "-configuration", "Debug",
         "-destination", "generic/platform=iOS", "-derivedDataPath", derivedData.path,
         "-allowProvisioningUpdates", "build"]
    }

    public enum Outcome: Equatable, Sendable {
        /// Xcode signed the helper with the entitlement: the App ID has the capability.
        case enabled
        /// Xcode has no account for the team: sign in with SideStore's Apple ID in Xcode → Settings → Accounts.
        case needsAccount(String)
        case failed(String)
    }

    /// What Xcode's answer means. Its error lines are kept as they are: they are what to search for when it fails.
    public static func interpret(status: Int32, lines: [String]) -> Outcome {
        let errors = lines.filter { $0.contains("error:") }.map { $0.trimmingCharacters(in: .whitespaces) }
        if status == 0, lines.contains(where: { $0.contains("** BUILD SUCCEEDED **") }) { return .enabled }
        let accountHints = ["No Accounts", "No account for team", "no account", "requires a development team",
                            "Sign in to your Apple Account", "There are no accounts registered"]
        if let line = (errors.isEmpty ? lines : errors).first(where: { line in accountHints.contains { line.localizedCaseInsensitiveContains($0) } }) {
            return .needsAccount(line)
        }
        if !errors.isEmpty { return .failed(Array(errors.prefix(4)).joined(separator: "\n")) }
        return .failed(lines.suffix(4).joined(separator: "\n"))
    }
}
