import Foundation

/// `game.manifest.json` inside a game framework, schema 1. The engine writes it and the shell reads it. Keys this
/// app does not know are ignored.
public struct GameManifest: Codable, Equatable, Sendable {
    public static let supportedSchema = 1
    public static let fileName = "game.manifest.json"

    public var schema: Int
    public var titleID: String
    public var name: String
    public var displayVersion: String
    public var packageVersion: String
    public var modules: [String]
    public var nroCount: Int
    public var chain: String
    public var loader: String
    public var framework: String
    public var frameworkExecutable: String
    public var launcher: String
    public var profile: String
    public var shaderMap: String
    public var imageMarker: String
    public var romfsMarker: String
    public var romfsIdentity: String
    public var minOS: String
    public var icon: String?
    public var console: String?
    public var builtBy: String?
    public var builtAt: String?
    public var bytes: Int64?

    enum CodingKeys: String, CodingKey {
        case schema, name, modules, chain, loader, framework, launcher, profile, icon, console, bytes
        case titleID = "title_id"
        case displayVersion = "display_version"
        case packageVersion = "package_version"
        case nroCount = "nro_count"
        case frameworkExecutable = "framework_executable"
        case shaderMap = "shader_map"
        case imageMarker = "image_marker"
        case romfsMarker = "romfs_marker"
        case romfsIdentity = "romfs_identity"
        case minOS = "min_os"
        case builtBy = "built_by"
        case builtAt = "built_at"
    }

    public static func decode(_ data: Data) throws -> GameManifest {
        let manifest: GameManifest
        do { manifest = try JSONDecoder().decode(GameManifest.self, from: data) }
        catch { throw NXPocketError(.packageDamaged, "\(fileName) could not be read: \(error.localizedDescription)") }
        guard manifest.schema == supportedSchema else {
            throw NXPocketError(.packageUnsupported, "\(fileName) has schema \(manifest.schema), this app reads schema \(supportedSchema).")
        }
        guard TitleID.isGame(manifest.titleID) else {
            throw NXPocketError(.packageDamaged, "title_id \"\(manifest.titleID)\" is not 16 hex digits starting with 0100.")
        }
        guard manifest.framework.hasSuffix(".framework"), !manifest.framework.contains("/") else {
            throw NXPocketError(.packageDamaged, "framework \"\(manifest.framework)\" is not a .framework name.")
        }
        guard isChain(manifest.chain) else {
            throw NXPocketError(.packageDamaged, "chain \"\(manifest.chain)\" is not of the form b-<hex>.")
        }
        guard manifest.loader == "FR" || manifest.loader == "FH" else {
            throw NXPocketError(.packageDamaged, "loader \"\(manifest.loader)\" is neither FR nor FH.")
        }
        guard !manifest.modules.isEmpty else {
            throw NXPocketError(.packageDamaged, "\(fileName) lists no modules.")
        }
        // Paths the launch opens inside the framework. They are checked here, where every reader of the manifest goes
        // through, rather than only at import: the library folder can be changed from Files after the import.
        var paths = [("framework_executable", manifest.frameworkExecutable), ("profile", manifest.profile),
                     ("shader_map", manifest.shaderMap)]
        if let icon = manifest.icon { paths.append(("icon", icon)) }
        for (key, path) in paths where !SafePath.isSafeRelative(path) {
            throw NXPocketError(.unsafePath, "\(key) \"\(path)\" is not a relative path inside the framework.")
        }
        return manifest
    }

    public static func isChain(_ text: String) -> Bool {
        text.count > 2 && text.hasPrefix("b-") && text.dropFirst(2).allSatisfy(\.isHexDigit)
    }

    public var minOSVersion: OSVersion? { OSVersion(minOS) }
}

/// A `major.minor[.patch]` version, comparable across platforms.
public struct OSVersion: Hashable, Comparable, Sendable, CustomStringConvertible {
    public var major: Int, minor: Int, patch: Int

    public init(major: Int, minor: Int = 0, patch: Int = 0) {
        self.major = major; self.minor = minor; self.patch = patch
    }

    public init?(_ text: String) {
        let parts = text.split(separator: ".").compactMap { Int($0) }
        guard !parts.isEmpty, parts.count <= 3, parts.count == text.split(separator: ".").count else { return nil }
        self.init(major: parts[0], minor: parts.count > 1 ? parts[1] : 0, patch: parts.count > 2 ? parts[2] : 0)
    }

    public var description: String { patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)" }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    /// The running OS, without an extra call into UIKit.
    public static var current: OSVersion {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return OSVersion(major: v.majorVersion, minor: v.minorVersion, patch: v.patchVersion)
    }
}
