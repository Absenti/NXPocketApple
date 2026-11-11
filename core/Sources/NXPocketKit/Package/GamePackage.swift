import Foundation

/// `package.json`, schema 1: what the Mac app writes into a `.nxgame` folder and what the iPhone app verifies
/// before it imports anything.
public struct GamePackage: Codable, Equatable, Sendable {
    public static let currentSchema = 1
    public static let defaultMinimumOS = "26.0"
    public static let fileName = "package.json"

    public struct FileEntry: Codable, Equatable, Sendable {
        public var path: String
        public var size: Int64
        public var sha256: String

        public init(path: String, size: Int64, sha256: String) {
            self.path = path
            self.size = size
            self.sha256 = sha256
        }
    }

    public var schema: Int
    public var titleID: String
    public var name: String
    public var version: String
    public var packageVersion: String
    public var framework: String
    public var chain: String
    public var minOS: String
    public var romfsID: String
    public var romfsSize: Int64
    public var aocSize: Int64
    public var files: [FileEntry]
    public var createdBy: String

    enum CodingKeys: String, CodingKey {
        case schema, name, version, framework, chain, files
        case titleID = "title_id"
        case packageVersion = "package_version"
        case minOS = "min_os"
        case romfsID = "romfs_id"
        case romfsSize = "romfs_size"
        case aocSize = "aoc_size"
        case createdBy = "created_by"
    }

    public init(titleID: TitleID, name: String, version: String, packageVersion: String,
                framework: String, chain: String, minOS: String, romfsID: String,
                romfsSize: Int64, aocSize: Int64, files: [FileEntry],
                createdBy: String, schema: Int = currentSchema) {
        self.schema = schema
        self.titleID = titleID.description
        self.name = name
        self.version = version
        self.packageVersion = packageVersion
        self.framework = framework
        self.chain = chain
        self.minOS = minOS
        self.romfsID = romfsID
        self.romfsSize = romfsSize
        self.aocSize = aocSize
        self.files = files
        self.createdBy = createdBy
    }

    /// The framework's own manifest, next to the framework inside the package.
    public var frameworkName: String { framework }
    public var manifestPathInFramework: String { "\(framework)/\(GameManifest.fileName)" }
    public var romfsPath: String { GameLayout.romfsFile }
    public var aocPath: String { GameLayout.addOnFolder }

    /// Everything the package carries besides the game's data, in bytes.
    public var codeSize: Int64 { files.reduce(0) { $0 + $1.size } }
    public var dataSize: Int64 { romfsSize + aocSize }
    public var totalSize: Int64 { codeSize + dataSize }

    public func data(pretty: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> GamePackage {
        let package: GamePackage
        do {
            package = try JSONDecoder().decode(GamePackage.self, from: data)
        } catch let decoding as DecodingError {
            throw NXPocketError(.packageDamaged, Self.explain(decoding))
        } catch {
            throw NXPocketError(.packageDamaged, "package.json could not be read: \(error.localizedDescription)")
        }
        // The library builds the framework's path from this name, so it is checked wherever package.json is read.
        guard package.framework.hasSuffix(".framework"), !package.framework.contains("/"), !package.framework.hasPrefix(".") else {
            throw NXPocketError(.packageDamaged, "framework \"\(package.framework)\" is not a .framework name.")
        }
        return package
    }

    private static func explain(_ error: DecodingError) -> String {
        func key(_ path: [CodingKey]) -> String { path.map(\.stringValue).joined(separator: ".") }
        switch error {
        case .keyNotFound(let k, let c):
            return c.codingPath.isEmpty ? "package.json has no \"\(k.stringValue)\"."
                : "package.json has no \"\(k.stringValue)\" (in \(key(c.codingPath)))."
        case .typeMismatch(_, let c), .valueNotFound(_, let c):
            return "package.json has a wrong or missing value at \"\(key(c.codingPath))\"."
        case .dataCorrupted:
            return "package.json is not valid JSON."
        @unknown default:
            return "package.json could not be read."
        }
    }
}
