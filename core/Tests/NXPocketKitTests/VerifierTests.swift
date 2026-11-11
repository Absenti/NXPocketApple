import XCTest

@testable import NXPocketKit

final class PackageVerifierTests: XCTestCase {
    func testAcceptsAWellFormedPackage() throws {
        let workspace = try TestWorkspace()
        let root = try PackageFixture().write(into: workspace)
        let verified = try PackageVerifier.verify(root)
        XCTAssertEqual(verified.titleID, TitleID("0100111000200000"))
        XCTAssertEqual(verified.manifest.frameworkExecutable, "DmGame")
        XCTAssertNotNil(verified.romfsURL)
        XCTAssertNil(verified.aocURL)
    }

    func testRefusesAMissingPackageJson() throws {
        let workspace = try TestWorkspace()
        try workspace.write("game/framework/File", "x")
        XCTAssertThrowsError(try PackageVerifier.verify(workspace.url("game"))) { error in
            XCTAssertEqual((error as? NXPocketError)?.code, .packageMissing)
        }
    }

    func testRefusesAnotherSchema() throws {
        let workspace = try TestWorkspace()
        let root = try PackageFixture().write(into: workspace)
        var package = try PackageVerifier.loadPackage(root)
        package.schema = 2
        try workspace.write("game/\(GamePackage.fileName)", try package.data())
        XCTAssertThrowsError(try PackageVerifier.verify(root)) { error in
            XCTAssertEqual((error as? NXPocketError)?.code, .packageUnsupported)
        }
    }

    func testRefusesAWrongSha256() throws {
        let workspace = try TestWorkspace()
        let root = try PackageFixture(brokenHash: true).write(into: workspace)
        XCTAssertThrowsError(try PackageVerifier.verify(root)) { error in
            XCTAssertEqual((error as? NXPocketError)?.code, .hashMismatch)
        }
    }

    func testRefusesAWrongSize() throws {
        let workspace = try TestWorkspace()
        let root = try PackageFixture(brokenSize: true).write(into: workspace)
        XCTAssertThrowsError(try PackageVerifier.verify(root)) { error in
            XCTAssertEqual((error as? NXPocketError)?.code, .sizeMismatch)
        }
    }

    func testRefusesAPathThatEscapesTheFramework() throws {
        let workspace = try TestWorkspace()
        let root = try PackageFixture(listedPathOverride: "../../escape").write(into: workspace)
        XCTAssertThrowsError(try PackageVerifier.verify(root)) { error in
            XCTAssertEqual((error as? NXPocketError)?.code, .unsafePath)
        }
    }

    func testRefusesAnAbsoluteListedPath() throws {
        let workspace = try TestWorkspace()
        let root = try PackageFixture(listedPathOverride: "/etc/passwd").write(into: workspace)
        XCTAssertThrowsError(try PackageVerifier.verify(root)) { error in
            XCTAssertEqual((error as? NXPocketError)?.code, .unsafePath)
        }
    }

    func testRefusesASymbolicLinkInTheFramework() throws {
        let workspace = try TestWorkspace()
        let root = try PackageFixture().write(into: workspace)
        let framework = root.appendingPathComponent(PackageFixture.frameworkName("0100111000200000"))
        try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("link").path,
                                                   withDestinationPath: "/usr/lib/libSystem.B.dylib")
        XCTAssertThrowsError(try PackageVerifier.verify(root)) { error in
            XCTAssertEqual((error as? NXPocketError)?.code, .symbolicLink)
        }
    }

    func testRefusesAnUnlistedFileInTheFramework() throws {
        let workspace = try TestWorkspace()
        let root = try PackageFixture().write(into: workspace)
        let framework = root.appendingPathComponent(PackageFixture.frameworkName("0100111000200000"))
        try Data(repeating: 0, count: 32).write(to: framework.appendingPathComponent("surprise.bin"))
        XCTAssertThrowsError(try PackageVerifier.verify(root)) { error in
            XCTAssertEqual((error as? NXPocketError)?.code, .packageInconsistent)
        }
    }

    func testTheFindersFilesAreNotPartOfThePackage() throws {
        let workspace = try TestWorkspace()
        let root = try PackageFixture().write(into: workspace)
        let framework = root.appendingPathComponent(PackageFixture.frameworkName("0100111000200000"))
        try Data(repeating: 0, count: 6148).write(to: framework.appendingPathComponent(".DS_Store"))
        try Data(repeating: 0, count: 4096).write(to: framework.appendingPathComponent("._game.manifest.json"))
        XCTAssertFalse(try PackageScanner.files(in: framework).contains { PackageScanner.isFinderMetadata($0.url.lastPathComponent) },
                       "a package written next to a Finder window does not list them")

        XCTAssertEqual(PackageScanner.removeFinderMetadata(in: root),
                       ["\(framework.lastPathComponent)/.DS_Store", "\(framework.lastPathComponent)/._game.manifest.json"])
        XCTAssertNoThrow(try PackageVerifier.verify(root))
    }

    func testAMachONamedLikeTheFindersFileIsStillHidden() throws {
        let workspace = try TestWorkspace()
        let root = try PackageFixture().write(into: workspace)
        let framework = root.appendingPathComponent(PackageFixture.frameworkName("0100111000200000"))
        try MachOBuilder().build().write(to: framework.appendingPathComponent(".DS_Store"))
        // Foundation's listing does not show a `._` file at all: this one was invisible to the checks before.
        try MachOBuilder().build().write(to: framework.appendingPathComponent("._payload"))
        let hidden = try PackageScanner.nestedMachOs(in: framework, allowing: [])
        XCTAssertTrue(hidden.contains(".DS_Store"), "\(hidden)")
        XCTAssertTrue(hidden.contains("._payload"), "\(hidden)")
    }

    func testRefusesAHiddenMachO() throws {
        let workspace = try TestWorkspace()
        let root = try PackageFixture(hiddenMachO: true).write(into: workspace)
        XCTAssertThrowsError(try PackageVerifier.verify(root)) { error in
            XCTAssertEqual((error as? NXPocketError)?.code, .hiddenMachO)
        }
    }

    func testRefusesAnExecutableInfoPlistDoesNotName() throws {
        // zsign signs the executable Info.plist names; the launch loads the manifest's. They must be one file.
        let workspace = try TestWorkspace()
        let root = try PackageFixture(bundleExecutable: "Other").write(into: workspace)
        XCTAssertThrowsError(try PackageVerifier.verify(root)) { error in
            XCTAssertEqual((error as? NXPocketError)?.code, .packageInconsistent)
        }
    }

    func testRefusesAddOnContentThePackageDoesNotCount() throws {
        // A rebuild without the add-ons once left the previous ones in aoc/, with aoc_size 0.
        let workspace = try TestWorkspace()
        let root = try PackageFixture(addOnFiles: ["0100111000201001.img": 4096], addOnSizeOverride: 0).write(into: workspace)
        XCTAssertThrowsError(try PackageVerifier.verify(root)) { error in
            XCTAssertEqual((error as? NXPocketError)?.code, .packageInconsistent)
        }
    }

    func testRefusesAddOnContentOfAnotherSize() throws {
        let workspace = try TestWorkspace()
        let root = try PackageFixture(addOnFiles: ["0100111000201001.img": 4096], addOnSizeOverride: 9000).write(into: workspace)
        XCTAssertThrowsError(try PackageVerifier.verify(root)) { error in
            XCTAssertEqual((error as? NXPocketError)?.code, .sizeMismatch)
        }
    }

    func testAcceptsAddOnContentOfTheStatedSize() throws {
        let workspace = try TestWorkspace()
        let root = try PackageFixture(addOnFiles: ["0100111000201001.img": 4096, "0100111000201002.img": 100]).write(into: workspace)
        let verified = try PackageVerifier.verify(root)
        XCTAssertEqual(verified.aocURL?.lastPathComponent, "aoc")
    }

    func testRefusesAManifestPathOutsideTheFramework() throws {
        let workspace = try TestWorkspace()
        let root = try PackageFixture().write(into: workspace)
        let url = root.appendingPathComponent("DmGame0100111000200000.framework/\(GameManifest.fileName)")
        for key in ["framework_executable", "profile", "shader_map", "icon"] {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            json[key] = "../../../Documents/elsewhere"
            XCTAssertThrowsError(try GameManifest.decode(JSONSerialization.data(withJSONObject: json)), key) { error in
                XCTAssertEqual((error as? NXPocketError)?.code, .unsafePath, key)
            }
        }
    }

    func testRefusesAPackageListingThatIsTooLargeToBeOne() throws {
        let workspace = try TestWorkspace()
        let root = try PackageFixture().write(into: workspace)
        try workspace.write("game/\(GamePackage.fileName)", bytes: Int(BoundedRead.metadataLimit) + 1)
        XCTAssertThrowsError(try PackageVerifier.verify(root)) { error in
            XCTAssertEqual((error as? NXPocketError)?.code, .packageDamaged)
        }
    }

    func testRefusesAFrameworkNameThatLeavesThePackage() throws {
        let workspace = try TestWorkspace()
        let root = try PackageFixture().write(into: workspace)
        let url = root.appendingPathComponent(GamePackage.fileName)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["framework"] = "../other.framework"
        XCTAssertThrowsError(try GamePackage.decode(JSONSerialization.data(withJSONObject: json))) { error in
            XCTAssertEqual((error as? NXPocketError)?.code, .packageDamaged)
        }
    }

    func testRefusesAManifestThatDisagreesWithThePackage() throws {
        let workspace = try TestWorkspace()
        let root = try PackageFixture().write(into: workspace)
        let manifest = root.appendingPathComponent("DmGame0100111000200000.framework/\(GameManifest.fileName)")
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        json["title_id"] = "0100999999990000"
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: manifest)
        XCTAssertThrowsError(try PackageVerifier.verify(root, options: .shallow)) { error in
            XCTAssertEqual((error as? NXPocketError)?.code, .packageInconsistent)
        }
    }

    func testRefusesAGameThatNeedsANewerOS() throws {
        let workspace = try TestWorkspace()
        let root = try PackageFixture(minimumOS: "99.0").write(into: workspace)
        var options = VerifyOptions.default
        options.maximumMinimumOS = OSVersion(major: 27, minor: 2)
        XCTAssertThrowsError(try PackageVerifier.verify(root, options: options)) { error in
            XCTAssertEqual((error as? NXPocketError)?.code, .minimumOSNewer)
        }
    }

    func testRefusesARomfsImageTheFrameworkWasNotBuiltFor() throws {
        let workspace = try TestWorkspace()
        let root = try PackageFixture().write(into: workspace)
        var package = try PackageVerifier.loadPackage(root)
        package.romfsID = "DMROMFSID1 size=\(package.romfsSize) index=deadbeef"
        try workspace.write("game/\(GamePackage.fileName)", try package.data())
        XCTAssertThrowsError(try PackageVerifier.verify(root)) { error in
            XCTAssertEqual((error as? NXPocketError)?.code, .hashMismatch)
        }
    }

    func testRefusesATruncatedRomfsImage() throws {
        let workspace = try TestWorkspace()
        let root = try PackageFixture().write(into: workspace)
        var package = try PackageVerifier.loadPackage(root)
        let image = root.appendingPathComponent("romfs.img")
        let handle = try FileHandle(forWritingTo: image)
        try handle.truncate(atOffset: 64)
        try handle.close()
        package.romfsSize = 64
        try workspace.write("game/\(GamePackage.fileName)", try package.data())
        XCTAssertThrowsError(try PackageVerifier.verify(root)) { error in
            XCTAssertEqual((error as? NXPocketError)?.code, .packageDamaged)
        }
    }

    func testShallowOptionsSkipTheExpensiveChecks() throws {
        let workspace = try TestWorkspace()
        let root = try PackageFixture(brokenHash: true).write(into: workspace)
        XCTAssertNoThrow(try PackageVerifier.verify(root, options: .shallow))
    }
}

final class RomfsIdentityTests: XCTestCase {
    func testMatchesWhatItWrote() throws {
        let workspace = try TestWorkspace()
        let url = workspace.url("romfs.img")
        let written = try RomfsFixture.writeImage(at: url)
        XCTAssertEqual(RomfsIdentity.ofImage(at: url), written)
        XCTAssertEqual(RomfsIdentity.parse(written.description), written)
    }

    func testAnIndexByteChangesTheIdentity() throws {
        let workspace = try TestWorkspace()
        let url = workspace.url("romfs.img")
        let written = try RomfsFixture.writeImage(at: url)
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: UInt64(size - 1))
        try handle.write(contentsOf: Data([0xEE]))
        try handle.close()
        XCTAssertNotEqual(RomfsIdentity.ofImage(at: url), written)
    }

    /// The identity covers the header and the index only, never the game data: a 15 GB image is never read whole.
    func testAGameDataByteLeavesTheIdentityAlone() throws {
        let workspace = try TestWorkspace()
        let url = workspace.url("romfs.img")
        let written = try RomfsFixture.writeImage(at: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: 4096)
        try handle.write(contentsOf: Data([0xFF, 0xFF, 0xFF, 0xFF]))
        try handle.close()
        XCTAssertEqual(RomfsIdentity.ofImage(at: url), written)
    }

    func testRefusesSomethingThatIsNotAnImage() throws {
        let workspace = try TestWorkspace()
        let url = try workspace.write("romfs.img", Data("not an image at all, really not one".utf8))
        XCTAssertNil(RomfsIdentity.ofImage(at: url))
    }

    func testParsesTheEngineLine() {
        XCTAssertEqual(RomfsIdentity.parse("DMROMFSID1 title=0100111000200000 version=0 build=1 size=4096 index=1a2b")?.size, 4096)
        XCTAssertNil(RomfsIdentity.parse("DMROMFSID1 size=4096"))
        XCTAssertNil(RomfsIdentity.parse("something else"))
    }
}
