import Foundation
import NXPocketKit

/// The iPhone app's IPA as `tools/build_app.sh --device-unsigned` leaves it: its date, its version, and whether the
/// app's sources changed after it was built.
public struct PhoneAppIPA: Equatable, Sendable {
    public var url: URL
    public var date: Date
    public var bytes: Int64
    /// `CFBundleShortVersionString` and `CFBundleVersion` of `Payload/NXPocket.app/Info.plist`.
    public var version: String?
    public var build: String?
    public var bundleID: String?

    public var versionText: String {
        switch (version, build) {
        case let (version?, build?): return "\(version) (\(build))"
        case let (version?, nil): return version
        default: return "unknown version"
        }
    }
}

/// Finds the repository the launcher runs from, reads the IPA, and builds it with the repository's own script.
public enum PhoneAppBuild {
    public static let ipaName = "NXPocketApple.ipa"

    /// The repository holding the launcher that runs: `mac/.build/release/NXPocket` sits three folders below it.
    /// A launcher copied elsewhere has none, and cannot build the app.
    public static func repository(from executable: URL? = Bundle.main.executableURL) -> URL? {
        var folder = executable?.resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            guard let current = folder else { return nil }
            if isRepository(current) { return current }
            folder = current.deletingLastPathComponent()
        }
        return nil
    }

    static func isRepository(_ folder: URL) -> Bool {
        let manager = FileManager.default
        return manager.fileExists(atPath: folder.appendingPathComponent("tools/build_app.sh").path)
            && manager.fileExists(atPath: folder.appendingPathComponent("app/project.yml").path)
    }

    /// The IPA the script writes into `output` (`NXPOCKET_OUTPUT`), read in place; nil when there is none.
    public static func inspect(_ ipa: URL) -> PhoneAppIPA? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: ipa.path),
              let date = attributes[.modificationDate] as? Date else { return nil }
        var found = PhoneAppIPA(url: ipa, date: date, bytes: (attributes[.size] as? Int64) ?? 0)
        if let plist = infoPlist(of: ipa) {
            found.version = plist["CFBundleShortVersionString"] as? String
            found.build = plist["CFBundleVersion"] as? String
            found.bundleID = plist["CFBundleIdentifier"] as? String
        }
        return found
    }

    /// `Payload/<app>/Info.plist`, out of the zip with `unzip -p`, which reads only that entry.
    static func infoPlist(of ipa: URL) -> [String: Any]? {
        guard let result = try? ProcessRunner.captureData(URL(fileURLWithPath: "/usr/bin/unzip"),
                                                          ["-p", ipa.path, "Payload/*.app/Info.plist"]),
              result.status == 0, !result.data.isEmpty else { return nil }
        return (try? PropertyListSerialization.propertyList(from: result.data, format: nil)) as? [String: Any]
    }

    /// The newest change to what goes into the app: its sources, its project, and `core`, which it links.
    public static func newestSourceChange(in repository: URL) -> Date? {
        let roots = ["app/Sources", "app/project.yml", "app/Package.swift", "core/Sources", "core/Package.swift"]
            .map { repository.appendingPathComponent($0) }
        var newest: Date?
        for root in roots {
            let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
            var files: [URL] = []
            if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
                for case let url as URL in walker { files.append(url) }
            }
            if files.isEmpty { files = [root] }
            for file in files {
                guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true, let date = values.contentModificationDate else { continue }
                if newest == nil || date > newest! { newest = date }
            }
        }
        return newest
    }

    /// What the build needs and lacks, in words: XcodeGen, Xcode, and the signing libraries the repository builds
    /// once (`app/Signing`, from tools/build_zsign.sh).
    public static func missing(in repository: URL, xcode: URL?) -> [String] {
        var missing: [String] = []
        if xcodegen() == nil { missing.append("XcodeGen (Setup → XcodeGen → Install)") }
        if xcode == nil { missing.append("Xcode") }
        let signing = repository.appendingPathComponent("app/Signing")
        for name in ["libnxzsign.xcframework", "OpenSSL.xcframework"]
        where !FileManager.default.fileExists(atPath: signing.appendingPathComponent(name).path) {
            missing.append("app/Signing/\(name) (run tools/build_zsign.sh)")
        }
        return missing
    }

    /// The places XcodeGen is installed: a launcher started from the Finder gets no shell PATH.
    /// Homebrew's, then the launcher's own XcodeGen from the setup screen (`FirstRunSetup.installXcodeGen`).
    public static var toolFolders: [String] { ["/opt/homebrew/bin", "/usr/local/bin", SetupPaths.standard.xcodegenBin.path] }

    public static func xcodegen() -> URL? {
        let candidates = toolFolders + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return candidates.lazy.map { URL(fileURLWithPath: $0).appendingPathComponent("xcodegen") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// The environment the script runs in: Homebrew's tools first on PATH, the chosen Xcode, and the launcher's
    /// output folder as the IPA's, so the screen finds what the script wrote.
    public static func environment(output: URL, xcode: URL?) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (toolFolders + [environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        environment["NXPOCKET_OUTPUT"] = output.path
        if let xcode { environment["DEVELOPER_DIR"] = xcode.appendingPathComponent("Contents/Developer").path }
        return environment
    }

    /// The script's stages, from its bold `say` lines, in order: how far a build is.
    static let stages = ["the shared-font stand-ins", "generating the project", "building an unsigned app",
                         "ad-hoc signing", "packing the IPA", "IPA: "]

    /// The share of the build done once `line` is printed, or nil for a line that starts no stage. The compile is
    /// most of the time and prints nothing until it ends (the script keeps only its last lines).
    public static func progress(after line: String) -> (fraction: Double, stage: String)? {
        let text = plain(line)
        let weights = [0.02, 0.05, 0.10, 0.85, 0.92, 1.0]
        for (index, stage) in stages.enumerated() where text.hasPrefix(stage) {
            return (weights[index], text)
        }
        return nil
    }

    /// The reason of a `FAIL: …` line.
    public static func failure(in line: String) -> String? {
        let text = plain(line)
        guard text.hasPrefix("FAIL: ") else { return nil }
        return String(text.dropFirst("FAIL: ".count))
    }

    /// A line without the script's colour codes.
    static func plain(_ line: String) -> String {
        line.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}

extension ProcessRunner {
    /// A short command whose standard output is wanted as bytes (`unzip -p` of a binary plist). It reads to the end of
    /// the output, so it is for commands that finish by themselves on a local file.
    static func captureData(_ executable: URL, _ arguments: [String]) throws -> (status: Int32, data: Data) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }
}
