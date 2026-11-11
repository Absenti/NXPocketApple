import Foundation
import XCTest

@testable import NXPocketKit

// Fixtures are built here rather than committed: no binary ever enters the repository, and every byte a test
// asserts on is one the test wrote.

final class TestWorkspace {
    let root: URL

    init(_ name: String = "nxpocket") throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func url(_ path: String) -> URL { root.appendingPathComponent(path) }

    @discardableResult
    func write(_ path: String, _ data: Data) throws -> URL {
        let url = url(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    @discardableResult
    func write(_ path: String, _ text: String) throws -> URL {
        try write(path, Data(text.utf8))
    }

    @discardableResult
    func write(_ path: String, bytes: Int, seed: UInt8 = 0) throws -> URL {
        var data = Data(count: bytes)
        for index in 0..<bytes { data[index] = seed &+ UInt8(index % 251) }
        return try write(path, data)
    }
}

// MARK: - A synthetic Mach-O

/// Emits the load commands under test, so a parser test does not need a compiler.
struct MachOBuilder {
    var cpuType: Int32 = MachOFile.cpuTypeARM64
    var cpuSubtype: Int32 = 0
    var fileType: UInt32 = MachOFile.fileTypeDylib
    var platform: UInt32 = MachOFile.BuildVersion.platformIOS
    var minimumOS = OSVersion(major: 26, minor: 0)
    var sdkVersion = OSVersion(major: 27, minor: 2)
    var includeBuildVersion = true
    var legacyMinimumOS: OSVersion?
    var dependencies: [String] = []
    /// Dependencies written with another load command than LC_LOAD_DYLIB, by command.
    var otherDependencies: [(command: UInt32, name: String)] = []
    var rpaths: [String] = []
    var section: (segment: String, name: String, address: UInt64, size: UInt64)?
    /// The superblob appended at `offset`, as LC_CODE_SIGNATURE points at it.
    var codeSignature: Data?

    static let headerSize = 32

    func build() -> Data {
        var list: [Data] = []

        for name in dependencies { list.append(dylibCommand(0x0C, name)) }
        for other in otherDependencies { list.append(dylibCommand(other.command, other.name)) }
        if includeBuildVersion {
            var command = Data()
            command.append(u32(0x32)); command.append(u32(24))
            command.append(u32(platform))
            command.append(u32(MachOFile.encodeVersion(minimumOS)))
            command.append(u32(MachOFile.encodeVersion(sdkVersion)))
            command.append(u32(0))
            list.append(command)
        }
        if let legacyMinimumOS {
            var command = Data()
            command.append(u32(0x25)); command.append(u32(16))
            command.append(u32(MachOFile.encodeVersion(legacyMinimumOS)))
            command.append(u32(0))
            list.append(command)
        }
        for path in rpaths {
            let body = 12 + path.utf8.count + 1
            let size = round8(body)
            var command = Data()
            command.append(u32(0x8000_001C)); command.append(u32(UInt32(size)))
            command.append(u32(12))
            command.append(contentsOf: Array(path.utf8) + [0])
            command.append(contentsOf: [UInt8](repeating: 0, count: size - body))
            list.append(command)
        }
        if let section {
            var command = Data()
            let sectionCount: UInt32 = 1
            command.append(u32(0x19)); command.append(u32(UInt32(72 + 80 * Int(sectionCount))))
            command.append(fixed(section.segment, 16))
            command.append(u64(0)); command.append(u64(0x4000))
            command.append(u64(0)); command.append(u64(0x4000))
            command.append(u32(5)); command.append(u32(5))
            command.append(u32(sectionCount)); command.append(u32(0))
            command.append(fixed(section.name, 16))
            command.append(fixed(section.segment, 16))
            command.append(u64(section.address)); command.append(u64(section.size))
            command.append(u32(0)); command.append(u32(14))
            command.append(u32(0)); command.append(u32(0)); command.append(u32(0x8000_0400))
            command.append(u32(0)); command.append(u32(0)); command.append(u32(0))
            list.append(command)
        }

        var commands = Data()
        for command in list { commands.append(command) }
        if let codeSignature {
            let signatureOffset = Self.headerSize + commands.count + 16
            var command = Data()
            command.append(u32(0x1D)); command.append(u32(16))
            command.append(u32(UInt32(signatureOffset)))
            command.append(u32(UInt32(codeSignature.count)))
            commands.append(command)
            list.append(command)
        }

        var header = Data()
        header.append(u32(MachOFile.magic64))
        header.append(i32(cpuType))
        header.append(i32(cpuSubtype))
        header.append(u32(fileType))
        header.append(u32(UInt32(list.count)))
        header.append(u32(UInt32(commands.count)))
        header.append(u32(0x0020_0085))
        header.append(u32(0))

        var image = header
        image.append(commands)
        if let codeSignature { image.append(codeSignature) }
        return image
    }

    private func dylibCommand(_ cmd: UInt32, _ name: String) -> Data {
        let body = 24 + name.utf8.count + 1
        let size = round8(body)
        var command = Data()
        command.append(u32(cmd)); command.append(u32(UInt32(size)))
        command.append(u32(24))
        command.append(u32(0)); command.append(u32(0x10000)); command.append(u32(0x10000))
        command.append(contentsOf: Array(name.utf8) + [0])
        command.append(contentsOf: [UInt8](repeating: 0, count: size - body))
        return command
    }

    private func round8(_ count: Int) -> Int { (count + 7) / 8 * 8 }
    private func fixed(_ text: String, _ length: Int) -> Data {
        var bytes = Array(text.utf8.prefix(length))
        bytes.append(contentsOf: [UInt8](repeating: 0, count: length - bytes.count))
        return Data(bytes)
    }
    private func u32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private func i32(_ value: Int32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private func u64(_ value: UInt64) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
}

/// A synthetic `CS_SuperBlob`, big-endian like the real thing.
struct CodeSignatureBuilder {
    var identifier = "dev.nxpocket.app"
    var teamID: String? = "ABCDE12345"
    var flags: UInt32 = 0
    var certificate: String? = "Apple Development: Example (ABCDE12345)"
    var codeDirectoryVersion: UInt32 = 0x20400

    func build() -> Data {
        var codeDirectory = Data()
        let identifierOffset: UInt32 = 88
        var body = Data()
        body.append(contentsOf: Array(identifier.utf8) + [0])
        let teamOffset = teamID.map { _ in identifierOffset + UInt32(body.count) }
        if let teamID { body.append(contentsOf: Array(teamID.utf8) + [0]) }

        codeDirectory.append(be32(CodeSignatureInfo.codeDirectoryMagic))
        codeDirectory.append(be32(UInt32(88 + body.count)))
        codeDirectory.append(be32(codeDirectoryVersion))
        codeDirectory.append(be32(flags))
        codeDirectory.append(be32(0))
        codeDirectory.append(be32(identifierOffset))
        codeDirectory.append(be32(0))
        codeDirectory.append(be32(0))
        codeDirectory.append(be32(0))
        codeDirectory.append(contentsOf: [32, 2, 0, 12])
        codeDirectory.append(be32(0))
        codeDirectory.append(be32(0))
        codeDirectory.append(be32(teamOffset ?? 0))
        codeDirectory.append(be32(0))
        codeDirectory.append(be64(0))
        codeDirectory.append(be64(0))
        codeDirectory.append(be64(0))
        codeDirectory.append(be64(0))
        codeDirectory.append(body)

        var blobs = [(UInt32(0), codeDirectory)]
        if let certificate {
            var cms = Data(certificate.utf8)
            cms.append(contentsOf: [UInt8](repeating: 0, count: 4))
            var wrapper = Data()
            wrapper.append(be32(CodeSignatureInfo.cmsWrapperMagic))
            wrapper.append(be32(UInt32(8 + cms.count)))
            wrapper.append(cms)
            blobs.append((1, wrapper))
        }

        var index = Data()
        var offset = UInt32(12 + blobs.count * 8)
        for (type, blob) in blobs {
            index.append(be32(type)); index.append(be32(offset))
            offset += UInt32(blob.count)
        }
        var superBlob = Data()
        superBlob.append(be32(CodeSignatureInfo.superBlobMagic))
        superBlob.append(be32(offset))
        superBlob.append(be32(UInt32(blobs.count)))
        superBlob.append(index)
        for (_, blob) in blobs { superBlob.append(blob) }
        return superBlob
    }

    private func be32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    private func be64(_ value: UInt64) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
}

// MARK: - A synthetic RomFS image

enum RomfsFixture {
    /// A complete `DMROMFS1` image: 32-byte header, data, then the index the identity is computed over.
    @discardableResult
    static func writeImage(at url: URL, dataBytes: Int = 4096, indexBytes: Int = 512, seed: UInt8 = 7) throws -> RomfsIdentity {
        var data = Data(count: dataBytes)
        for index in 0..<dataBytes { data[index] = seed &+ UInt8(index % 97) }
        var index = Data(count: indexBytes)
        for offset in 0..<indexBytes { index[offset] = seed &* 3 &+ UInt8(offset % 61) }

        var image = Data()
        image.append(contentsOf: Array("DMROMFS1".utf8))
        let offset = UInt64(32 + dataBytes)
        withUnsafeBytes(of: offset.littleEndian) { image.append(contentsOf: $0) }
        let size = UInt64(indexBytes)
        withUnsafeBytes(of: size.littleEndian) { image.append(contentsOf: $0) }
        image.append(contentsOf: [UInt8](repeating: 0, count: 8))
        image.append(data)
        image.append(index)
        try image.write(to: url)
        return RomfsIdentity.ofImage(at: url)!
    }
}

// MARK: - A full package

/// Writes a `.nxgame` folder whose framework executable is a synthetic arm64 dylib. Returns the paths a test needs.
struct PackageFixture {
    var titleID = "0100111000200000"
    var name = "Fixture Game"
    var version = "1.0.0"
    var chain = "b-3f9a2c"
    var minimumOS = "26.0"
    var withRomfs = true
    var withSignature = true
    var extraFrameworkFile = false
    var hiddenMachO = false
    var brokenHash = false
    var brokenSize = false
    var executableImage: Data?
    var listedPathOverride: String?
    /// The executable Info.plist names; the manifest always names "DmGame".
    var bundleExecutable = "DmGame"
    /// Files written under `aoc/`, by name and size.
    var addOnFiles: [String: Int] = [:]
    /// The `aoc_size` package.json states; nil states what `addOnFiles` add up to.
    var addOnSizeOverride: Int64?

    static func frameworkName(_ titleID: String) -> String { "DmGame\(titleID).framework" }

    @discardableResult
    func write(into workspace: TestWorkspace, at folder: String = "game") throws -> URL {
        let root = workspace.url(folder)
        let framework = Self.frameworkName(titleID)
        let image = executableImage ?? MachOBuilder(codeSignature: withSignature ? CodeSignatureBuilder().build() : nil).build()
        try workspace.write("\(folder)/\(framework)/DmGame", image)

        let manifest: [String: Any] = [
            "schema": 1,
            "title_id": titleID,
            "name": name,
            "display_version": version,
            "package_version": "65536",
            "modules": ["main"],
            "nro_count": 0,
            "chain": chain,
            "loader": "FR",
            "framework": framework,
            "framework_executable": "DmGame",
            "image_marker": "dmgame_image_marker",
            "profile": "profile.tsv",
            "shader_map": "dm/shader_map.tsv",
            "launcher": "dm/launcher.json",
            "romfs_marker": "fixture.marker",
            "romfs_identity": "DMROMFSID1 fixture",
            "min_os": minimumOS
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try workspace.write("\(folder)/\(framework)/\(GameManifest.fileName)", manifestData)

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleExecutable</key><string>\(bundleExecutable)</string>
        <key>CFBundleIdentifier</key><string>dev.nxpocket.game.\(titleID)</string>
        <key>CFBundlePackageType</key><string>FMWK</string>
        </dict></plist>
        """
        try workspace.write("\(folder)/\(framework)/Info.plist", plist)
        if extraFrameworkFile {
            try workspace.write("\(folder)/\(framework)/extra.bin", bytes: 128)
        }
        if hiddenMachO {
            try workspace.write("\(folder)/\(framework)/sneaky", MachOBuilder().build())
        }

        var files = try PackageScanner.files(in: root.appendingPathComponent(framework)).map { item -> GamePackage.FileEntry in
            var entry = GamePackage.FileEntry(path: item.relativePath, size: item.size,
                                              sha256: try FileDigest.sha256(ofFileAt: item.url))
            if brokenHash, item.relativePath == "DmGame" { entry.sha256 = String(repeating: "0", count: 64) }
            if brokenSize, item.relativePath == "Info.plist" { entry.size += 1 }
            if let listedPathOverride, item.relativePath == "DmGame" { entry.path = listedPathOverride }
            return entry
        }
        files.sort { $0.path < $1.path }

        var romfsID = ""
        var romfsSize: Int64 = 0
        if withRomfs {
            let identity = try RomfsFixture.writeImage(at: workspace.url("\(folder)/romfs.img"))
            romfsID = identity.description
            romfsSize = Int64(identity.size)
        }

        for (file, size) in addOnFiles.sorted(by: { $0.key < $1.key }) {
            try workspace.write("\(folder)/aoc/\(file)", bytes: size)
        }
        let aocSize = addOnSizeOverride ?? Int64(addOnFiles.values.reduce(0, +))

        let package = GamePackage(titleID: TitleID(titleID)!,
                                  name: name, version: version, packageVersion: "65536",
                                  framework: framework, chain: chain, minOS: minimumOS,
                                  romfsID: romfsID, romfsSize: romfsSize, aocSize: aocSize,
                                  files: files, createdBy: "nxpocket-tests")
        try workspace.write("\(folder)/\(GamePackage.fileName)", try package.data())
        return root
    }
}

// MARK: - A signer that only records what it was asked to sign

struct RecordingSigner: FrameworkSigner {
    let identifier: String
    let teamID: String?
    let hasCertificate: Bool

    init(identifier: String, teamID: String? = nil, hasCertificate: Bool = true) {
        self.identifier = identifier
        self.teamID = teamID
        self.hasCertificate = hasCertificate
    }

    func sign(framework: URL, identity: SigningIdentity) throws -> CodeSignatureInfo {
        CodeSignatureInfo(identifier: identifier, teamID: teamID, flags: hasCertificate ? 0 : CodeSignatureInfo.adHocFlag,
                          hasCertificate: hasCertificate, signerName: identity.subject,
                          codeDirectoryVersion: 0x20400, hashType: 2)
    }
}

extension XCTestCase {
    func identity(identifier: String = "dev.nxpocket.app", team: String = "ABCDE12345",
                  expiresIn days: Double = 5) -> SigningIdentity {
        SigningIdentity(identifier: identifier, teamID: team, certificateSHA256: String(repeating: "a", count: 64),
                        subject: "Apple Development: Example (\(team))", expires: Date().addingTimeInterval(days * 86400))
    }
}
