import Foundation
import NXPocketKit
import XCTest

@testable import NXPMacKit

/// `PackageWriter` had no test at all: it was the one component of the launcher nothing exercised. Worse, its output
/// had never been fed to `PackageVerifier`, the code the iPhone runs before it signs or moves anything. These tests
/// are that round trip, so the two halves cannot drift apart unnoticed.
final class PackageRoundTripTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("nxpocket-roundtrip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - A framework the engine could plausibly have produced

    private static let titleID = "0100111000200000"
    private static let frameworkName = "DmGame0100111000200000.framework"

    private func makeFramework(in folder: URL, name: String = frameworkName,
                               marker: String = "dmgame_image_marker",
                               withSignature: Bool = true) throws -> URL {
        let framework = folder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        try syntheticDylib().write(to: framework.appendingPathComponent("DmGame"))

        let manifest: [String: Any] = [
            "schema": 1, "title_id": Self.titleID, "name": "Round Trip", "display_version": "1.2.1",
            "package_version": "65536", "modules": ["main"], "nro_count": 0, "chain": "b-3f9a2c", "loader": "FR",
            "framework": name, "framework_executable": "DmGame", "image_marker": marker,
            "profile": "profile.tsv", "shader_map": "dm/shader_map.tsv", "launcher": "dm/launcher.json",
            "romfs_marker": "roundtrip.marker", "romfs_identity": "DMROMFSID1 fixture", "min_os": "26.0"
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: framework.appendingPathComponent("game.manifest.json"))
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>CFBundleExecutable</key><string>DmGame</string>
        <key>CFBundleIdentifier</key><string>dev.nxpocket.game.\(Self.titleID)</string>
        <key>CFBundlePackageType</key><string>FMWK</string></dict></plist>
        """.utf8).write(to: framework.appendingPathComponent("Info.plist"))

        if withSignature {
            // The engine's output carries a placeholder signature; the shell must never see one, because a game is
            // signed again on the device.
            let signature = framework.appendingPathComponent("_CodeSignature", isDirectory: true)
            try FileManager.default.createDirectory(at: signature, withIntermediateDirectories: true)
            try Data("<plist/>".utf8).write(to: signature.appendingPathComponent("CodeResources"))
        }
        return framework
    }

    private func syntheticRomfs(at url: URL, dataBytes: Int = 8192, indexBytes: Int = 1024) throws -> RomfsIdentity {
        var data = Data(count: dataBytes)
        for index in 0..<dataBytes { data[index] = UInt8(index % 251) }
        var index = Data(count: indexBytes)
        for offset in 0..<indexBytes { index[offset] = UInt8((offset * 7) % 253) }
        var image = Data("DMROMFS1".utf8)
        // magic, index offset, index size, then padding: 32 bytes of header, the data, then the index.
        for word in [UInt64(32 + dataBytes), UInt64(indexBytes)] {
            withUnsafeBytes(of: word.littleEndian) { image.append(contentsOf: $0) }
        }
        image.append(contentsOf: [UInt8](repeating: 0, count: 8))
        image.append(data)
        image.append(index)
        try image.write(to: url)
        return RomfsIdentity.ofImage(at: url)!
    }

    /// A thin arm64 iOS dylib built here: the repository holds no binary.
    private func syntheticDylib() -> Data {
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

    // MARK: - Tests

    func testWhatTheLauncherWritesTheShellAccepts() throws {
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let framework = try makeFramework(in: staging)
        let romfs = root.appendingPathComponent("RomFS.img")
        let identity = try syntheticRomfs(at: romfs)
        let destination = LocalLibrary.destination(for: TitleID(Self.titleID)!, in: root.appendingPathComponent("out"))

        let packaged = try PackageWriter.write(framework: framework, romfsImage: romfs, aocFolder: nil, into: destination)

        XCTAssertEqual(packaged.package.titleID, Self.titleID)
        XCTAssertEqual(packaged.package.name, "Round Trip")
        XCTAssertEqual(packaged.package.chain, "b-3f9a2c")
        XCTAssertEqual(packaged.package.romfsID, identity.description)

        // The shell's own code path, on the launcher's output.
        let verified = try PackageVerifier.verify(destination)
        XCTAssertEqual(verified.titleID, TitleID(Self.titleID)!)
        XCTAssertEqual(verified.manifest.frameworkExecutable, "DmGame")
        XCTAssertNotNil(verified.romfsURL)
        XCTAssertFalse(packaged.package.files.isEmpty)
        XCTAssertEqual(packaged.package.files.map(\.path).sorted(), packaged.package.files.map(\.path),
                       "the file list is sorted, so two builds of one game produce the same manifest")
    }

    func testThePackageCarriesNoSignature() throws {
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let framework = try makeFramework(in: staging, withSignature: true)
        let destination = LocalLibrary.destination(for: TitleID(Self.titleID)!, in: root.appendingPathComponent("out"))

        XCTAssertTrue(FileManager.default.fileExists(atPath: framework.appendingPathComponent("_CodeSignature/CodeResources").path),
                      "the fixture starts with a placeholder signature")

        let packaged = try PackageWriter.write(framework: framework, romfsImage: nil, aocFolder: nil, into: destination)

        // A signature of the Mac's making would be refused on the device, and an unlisted file would fail verification.
        XCTAssertFalse(FileManager.default.fileExists(atPath: packaged.root.appendingPathComponent(Self.frameworkName)
            .appendingPathComponent("_CodeSignature").path))
        XCTAssertFalse(packaged.package.files.contains { $0.path.hasPrefix("_CodeSignature") })
        XCTAssertNoThrow(try PackageVerifier.verify(packaged.root, options: .shallow))
    }

    func testTheFrameworkIsRenamedAfterItsTitleID() throws {
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        // The engine names it one way; the package must impose the name the shell looks for.
        let framework = try makeFramework(in: staging, name: "DmGame.framework")
        let destination = LocalLibrary.destination(for: TitleID(Self.titleID)!, in: root.appendingPathComponent("out"))

        let packaged = try PackageWriter.write(framework: framework, romfsImage: nil, aocFolder: nil, into: destination)

        XCTAssertEqual(packaged.package.framework, Self.frameworkName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent(Self.frameworkName).path))
        XCTAssertNoThrow(try PackageVerifier.verify(packaged.root, options: .shallow))
    }

    func testAddOnContentIsCarriedAndCounted() throws {
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let framework = try makeFramework(in: staging)
        let aoc = root.appendingPathComponent("aoc", isDirectory: true)
        try FileManager.default.createDirectory(at: aoc, withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 4096).write(to: aoc.appendingPathComponent("1.img"))
        let destination = LocalLibrary.destination(for: TitleID(Self.titleID)!, in: root.appendingPathComponent("out"))

        let packaged = try PackageWriter.write(framework: framework, romfsImage: nil, aocFolder: aoc, into: destination)

        XCTAssertEqual(packaged.package.aocSize, 4096)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("aoc/1.img").path))
        XCTAssertNoThrow(try PackageVerifier.verify(packaged.root, options: .shallow))
    }

    func testTheRomfsSizeIsTheFileOnDisk() throws {
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let framework = try makeFramework(in: staging)
        let romfs = root.appendingPathComponent("RomFS.img")
        let identity = try syntheticRomfs(at: romfs, dataBytes: 4096, indexBytes: 512)
        let destination = LocalLibrary.destination(for: TitleID(Self.titleID)!, in: root.appendingPathComponent("out"))

        let packaged = try PackageWriter.write(framework: framework, romfsImage: romfs, aocFolder: nil, into: destination)

        let onDisk = try FileManager.default.attributesOfItem(atPath: destination.appendingPathComponent("romfs.img").path)[.size] as? Int64
        XCTAssertEqual(packaged.package.romfsSize, onDisk)
        XCTAssertEqual(packaged.package.romfsSize, Int64(identity.size))
    }

    func testAnImageThatIsNotRomfsIsRefusedRatherThanPacked() throws {
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let framework = try makeFramework(in: staging)
        let romfs = try { () throws -> URL in
            let url = root.appendingPathComponent("bad.img")
            try Data("this is not a RomFS image at all".utf8).write(to: url)
            return url
        }()
        let destination = LocalLibrary.destination(for: TitleID(Self.titleID)!, in: root.appendingPathComponent("out"))

        XCTAssertThrowsError(try PackageWriter.write(framework: framework, romfsImage: romfs, aocFolder: nil, into: destination)) { error in
            XCTAssertEqual((error as? NXPocketError)?.code, .packageDamaged)
        }
    }

    func testTheEngineStampWinsOverRecomputingTheIdentity() throws {
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let framework = try makeFramework(in: staging)
        let romfs = root.appendingPathComponent("RomFS.img")
        let identity = try syntheticRomfs(at: romfs)
        // The engine writes RomFS.img.id beside the image; its identity is authoritative.
        let stamp: [String: Any] = ["identity": identity.description, "bytes": identity.size, "sha256": "unused"]
        try JSONSerialization.data(withJSONObject: stamp, options: [.sortedKeys])
            .write(to: romfs.appendingPathExtension("id"))
        let destination = LocalLibrary.destination(for: TitleID(Self.titleID)!, in: root.appendingPathComponent("out"))

        let packaged = try PackageWriter.write(framework: framework, romfsImage: romfs, aocFolder: nil, into: destination)

        XCTAssertEqual(packaged.package.romfsID, identity.description)
        XCTAssertNoThrow(try PackageVerifier.verify(packaged.root))
    }

    // MARK: - Writing beside, then swapping

    /// A rebuild that fails leaves the package that was there whole, and nothing half written beside it. It used to be
    /// written over the old one entry by entry, and a failure left the old package.json beside new content.
    func testARebuildThatFailsLeavesThePreviousPackageWhole() throws {
        let framework = try makeFramework(in: root.appendingPathComponent("staging", isDirectory: true))
        let romfs = root.appendingPathComponent("RomFS.img")
        _ = try syntheticRomfs(at: romfs)
        let destination = LocalLibrary.destination(for: TitleID(Self.titleID)!, in: root.appendingPathComponent("out"))
        let first = try PackageWriter.write(framework: framework, romfsImage: romfs, aocFolder: nil, into: destination)

        let broken = root.appendingPathComponent("broken.img")
        try Data(repeating: 7, count: 100).write(to: broken)
        XCTAssertThrowsError(try PackageWriter.write(framework: framework, romfsImage: broken, aocFolder: nil, into: destination))
        let still = try PackageVerifier.verify(destination)
        XCTAssertEqual(still.package.romfsID, first.package.romfsID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: PackageWriter.partialFolder(for: destination).path))
        XCTAssertEqual(LocalLibrary.scan(outputFolder: root.appendingPathComponent("out")).count, 1, "a partial folder is never listed")
    }

    /// Unticking the DLC and building again gives a package without them: the old aoc/ does not stay behind.
    func testARebuildWithoutDLCDropsTheOldAddOnContent() throws {
        let framework = try makeFramework(in: root.appendingPathComponent("staging", isDirectory: true))
        let aoc = root.appendingPathComponent("aoc", isDirectory: true)
        try FileManager.default.createDirectory(at: aoc, withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 4096).write(to: aoc.appendingPathComponent("1.img"))
        try Data(repeating: 0, count: 6148).write(to: aoc.appendingPathComponent(".DS_Store"))
        let destination = LocalLibrary.destination(for: TitleID(Self.titleID)!, in: root.appendingPathComponent("out"))

        let with = try PackageWriter.write(framework: framework, romfsImage: nil, aocFolder: aoc, into: destination)
        XCTAssertEqual(with.package.aocSize, 4096, "counted as the phone counts it, the Finder's file aside")
        XCTAssertNoThrow(try PackageVerifier.verify(destination, options: PackageWriter.macVerification))

        let without = try PackageWriter.write(framework: framework, romfsImage: nil, aocFolder: nil, into: destination)
        XCTAssertEqual(without.package.aocSize, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("aoc").path))
        XCTAssertNoThrow(try PackageVerifier.verify(destination, options: PackageWriter.macVerification))
    }

    /// A package that lost its RomFS image after it was built is not shown as ready to send.
    func testTheLibraryFlagsAPackageThatLostItsImage() throws {
        let framework = try makeFramework(in: root.appendingPathComponent("staging", isDirectory: true))
        let romfs = root.appendingPathComponent("RomFS.img")
        _ = try syntheticRomfs(at: romfs)
        let out = root.appendingPathComponent("out")
        let destination = LocalLibrary.destination(for: TitleID(Self.titleID)!, in: out)
        let packaged = try PackageWriter.write(framework: framework, romfsImage: romfs, aocFolder: nil, into: destination)
        XCTAssertTrue(LocalLibrary.scan(outputFolder: out).first?.isReady ?? false)
        XCTAssertEqual(LocalLibrary.scan(outputFolder: out).first?.byteCount, packaged.package.totalSize, "the size package.json gives")
        try FileManager.default.removeItem(at: destination.appendingPathComponent(GameLayout.romfsFile))
        XCTAssertFalse(LocalLibrary.scan(outputFolder: out).first?.isReady ?? true)
    }

    // MARK: - Renaming

    /// A renamed package must pass every check the phone runs: the name is in package.json and in the framework's
    /// manifest, which the phone compares, and the manifest's hash in the file list must follow.
    func testARenamedPackageStillPassesThePhonesChecks() throws {
        let framework = try makeFramework(in: root.appendingPathComponent("staging", isDirectory: true))
        let romfs = root.appendingPathComponent("RomFS.img")
        _ = try syntheticRomfs(at: romfs)
        let destination = LocalLibrary.destination(for: TitleID(Self.titleID)!, in: root.appendingPathComponent("out"))
        let before = try PackageWriter.write(framework: framework, romfsImage: romfs, aocFolder: nil, into: destination)

        let renamed = try PackageRenamer.rename(destination, to: "  Mon jeu — Été\n2  ")
        XCTAssertEqual(renamed.name, "Mon jeu — Été 2", "trimmed, on one line")
        let verified = try PackageVerifier.verify(destination)
        XCTAssertEqual(verified.package.name, "Mon jeu — Été 2")
        XCTAssertEqual(verified.manifest.name, "Mon jeu — Été 2")
        XCTAssertEqual(verified.manifest.chain, before.manifest.chain, "the engine's other fields stay")
        XCTAssertEqual(verified.manifest.frameworkExecutable, before.manifest.frameworkExecutable)
        XCTAssertEqual(verified.package.romfsID, before.package.romfsID)
        let executable = { (package: GamePackage) in package.files.first { $0.path == "DmGame" } }
        XCTAssertEqual(executable(verified.package), executable(before.package), "the executable is not touched")
        XCTAssertNotEqual(verified.package.files.first { $0.path == GameManifest.fileName }?.sha256,
                          before.package.files.first { $0.path == GameManifest.fileName }?.sha256)
    }

    func testANameMustHoldSomething() {
        XCTAssertThrowsError(try PackageRenamer.clean("  \n "))
        XCTAssertThrowsError(try PackageRenamer.clean(String(repeating: "a", count: PackageRenamer.maximumLength + 1)))
        XCTAssertEqual(try PackageRenamer.clean("South Park"), "South Park")
    }
}
