import Foundation
import NXPocketKit

@testable import NXPMacKit

/// A built game, written by the launcher's own `PackageWriter`, so what the server shares is what a real build produces.
enum ShareFixture {
    static let titleID = "0100111000200000"

    @discardableResult
    static func build(titleID: String = ShareFixture.titleID, name: String = "Shared Game", version: String = "1.0.0",
                      romfsBytes: Int = 8192, in outputFolder: URL, scratch: URL, aoc: [String: Int] = [:]) throws -> URL {
        let work = scratch.appendingPathComponent("work-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let frameworkName = "DmGame\(titleID).framework"
        let framework = work.appendingPathComponent(frameworkName, isDirectory: true)
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        try dylib().write(to: framework.appendingPathComponent("DmGame"))
        let manifest: [String: Any] = [
            "schema": 1, "title_id": titleID, "name": name, "display_version": version, "package_version": "65536",
            "modules": ["main"], "nro_count": 0, "chain": "b-3f9a2c", "loader": "FR", "framework": frameworkName,
            "framework_executable": "DmGame", "image_marker": "dmgame_image_marker", "profile": "profile.tsv",
            "shader_map": "dm/shader_map.tsv", "launcher": "dm/launcher.json", "romfs_marker": "fixture.marker",
            "romfs_identity": "DMROMFSID1 fixture", "min_os": "26.0"
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: framework.appendingPathComponent("game.manifest.json"))
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>CFBundleExecutable</key><string>DmGame</string>
        <key>CFBundleIdentifier</key><string>dev.nxpocket.game.\(titleID)</string>
        <key>CFBundlePackageType</key><string>FMWK</string></dict></plist>
        """.utf8).write(to: framework.appendingPathComponent("Info.plist"))
        try Data(base64Encoded: onePixelPNG)!.write(to: framework.appendingPathComponent("icon.png"))

        let romfs = work.appendingPathComponent("RomFS.img")
        try image(dataBytes: romfsBytes).write(to: romfs)
        var aocFolder: URL?
        if !aoc.isEmpty {
            let folder = work.appendingPathComponent("aoc", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (file, size) in aoc { try Data(repeating: 7, count: size).write(to: folder.appendingPathComponent(file)) }
            aocFolder = folder
        }
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        let destination = LocalLibrary.destination(for: TitleID(titleID)!, in: outputFolder)
        try PackageWriter.write(framework: framework, romfsImage: romfs, aocFolder: aocFolder, into: destination)
        return destination
    }

    static func image(dataBytes: Int, indexBytes: Int = 1024) -> Data {
        var data = Data(count: dataBytes)
        data.withUnsafeMutableBytes { raw in for index in 0..<raw.count { raw[index] = UInt8(truncatingIfNeeded: index % 251) } }
        var index = Data(count: indexBytes)
        for offset in 0..<indexBytes { index[offset] = UInt8((offset * 7) % 253) }
        var image = Data("DMROMFS1".utf8)
        for word in [UInt64(32 + dataBytes), UInt64(indexBytes)] { withUnsafeBytes(of: word.littleEndian) { image.append(contentsOf: $0) } }
        image.append(contentsOf: [UInt8](repeating: 0, count: 8))
        image.append(data)
        image.append(index)
        return image
    }

    static func dylib() -> Data {
        func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        let install = "@rpath/DmGame"
        let body = 24 + install.utf8.count + 1
        let size = (body + 7) / 8 * 8
        var commands = Data()
        commands.append(le32(0x0C)); commands.append(le32(UInt32(size)))
        commands.append(le32(24)); commands.append(le32(0))
        commands.append(le32(0x10000)); commands.append(le32(0x10000))
        commands.append(contentsOf: Array(install.utf8) + [0])
        commands.append(contentsOf: [UInt8](repeating: 0, count: size - body))
        var build = Data()
        build.append(le32(0x32)); build.append(le32(24))
        build.append(le32(MachOFile.BuildVersion.platformIOS))
        build.append(le32(UInt32(26) << 16))
        build.append(le32(UInt32(27) << 16 | 2))
        build.append(le32(0))
        commands.append(build)
        var header = Data()
        header.append(le32(MachOFile.magic64))
        header.append(le32(UInt32(bitPattern: MachOFile.cpuTypeARM64)))
        header.append(le32(0))
        header.append(le32(MachOFile.fileTypeDylib))
        header.append(le32(2)); header.append(le32(UInt32(commands.count)))
        header.append(le32(0x0020_0085)); header.append(le32(0))
        return header + commands
    }

    static let onePixelPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
}
