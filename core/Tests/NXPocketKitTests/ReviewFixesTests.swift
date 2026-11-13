import XCTest

@testable import NXPocketKit

/// Each test here covers a gap the review found (the verifier, importer and bounds ones were run against the code as it
/// was, and fail on it): a package that declares no hash, an image
/// whose identity cannot be read, a framework that is a link, an executable swapped before it is signed, a certificate
/// with nothing to sign with, a hash of half a file, and files of any size read at every launch.
final class PackageVerifierGapTests: XCTestCase {
    func testRefusesAFileListedWithoutAHash() throws {
        let workspace = try TestWorkspace()
        let root = try PackageFixture(emptyHashes: true).write(into: workspace)
        XCTAssertThrowsError(try PackageVerifier.verify(root)) { error in
            XCTAssertEqual((error as? NXPocketError)?.code, .packageDamaged)
        }
        // The listing is checked even where hashing is not asked for: an entry with no hash is never valid.
        XCTAssertThrowsError(try PackageVerifier.verify(root, options: .shallow)) { error in
            XCTAssertEqual((error as? NXPocketError)?.code, .packageDamaged)
        }
    }

    func testRefusesAnIdentityItCannotRead() throws {
        for unreadable in ["garbage", "", "DMROMFSID1 size=abc"] {
            let workspace = try TestWorkspace()
            let root = try PackageFixture(romfsIDOverride: unreadable).write(into: workspace)
            XCTAssertThrowsError(try PackageVerifier.verify(root), "romfs_id \"\(unreadable)\"") { error in
                XCTAssertEqual((error as? NXPocketError)?.code, .packageDamaged)
            }
        }
    }

    /// The attack the empty identity allowed: another content's image of the same size, never compared.
    func testRefusesAnotherImageUnderAnUnreadableIdentity() throws {
        let workspace = try TestWorkspace()
        let root = try PackageFixture(romfsIDOverride: "").write(into: workspace)
        try RomfsFixture.writeImage(at: root.appendingPathComponent("romfs.img"), seed: 99)
        XCTAssertThrowsError(try PackageVerifier.verify(root)) { error in
            XCTAssertEqual((error as? NXPocketError)?.code, .packageDamaged)
        }
    }

    func testAListingThatDoesNotLookAtTheImageDoesNotNeedItsIdentity() throws {
        let workspace = try TestWorkspace()
        let root = try PackageFixture(romfsIDOverride: "garbage").write(into: workspace)
        XCTAssertNoThrow(try PackageVerifier.verify(root, options: .shallow))
    }

    func testRefusesAFrameworkThatIsASymbolicLink() throws {
        let workspace = try TestWorkspace()
        let root = try PackageFixture().write(into: workspace)
        let framework = PackageFixture.frameworkName("0100111000200000")
        let elsewhere = workspace.url("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: root.appendingPathComponent(framework), to: elsewhere.appendingPathComponent(framework))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(framework),
                                                   withDestinationURL: elsewhere.appendingPathComponent(framework))
        XCTAssertThrowsError(try PackageVerifier.verify(root)) { error in
            XCTAssertEqual((error as? NXPocketError)?.code, .symbolicLink)
        }
    }

    func testRefusesAPackageFolderThatIsASymbolicLink() throws {
        let workspace = try TestWorkspace()
        let real = try PackageFixture().write(into: workspace, at: "real")
        let link = workspace.url("link.nxgame")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertThrowsError(try PackageVerifier.verify(link)) { error in
            XCTAssertEqual((error as? NXPocketError)?.code, .symbolicLink)
        }
    }

    func testRefusesARomfsImageThatIsASymbolicLink() throws {
        let workspace = try TestWorkspace()
        let root = try PackageFixture().write(into: workspace)
        let image = root.appendingPathComponent("romfs.img")
        let elsewhere = workspace.url("elsewhere.img")
        try FileManager.default.moveItem(at: image, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: image, withDestinationURL: elsewhere)
        XCTAssertThrowsError(try PackageVerifier.verify(root)) { error in
            XCTAssertEqual((error as? NXPocketError)?.code, .symbolicLink)
        }
    }
}

final class ImporterGapTests: XCTestCase {
    private func importer(_ workspace: TestWorkspace) throws -> GameImporter {
        let importer = GameImporter(documents: workspace.url("Documents"), log: nil)
        try importer.prepareDirectories()
        return importer
    }

    private final class CountingSigner: FrameworkSigner, @unchecked Sendable {
        var calls = 0
        func sign(framework: URL, identity: SigningIdentity) throws -> CodeSignatureInfo {
            calls += 1
            return CodeSignatureInfo(identifier: identity.identifier, teamID: identity.teamID, flags: 0, hasCertificate: true,
                                     signerName: identity.subject, codeDirectoryVersion: 0x20400, hashType: 2)
        }
    }

    /// The window the review proved: the executable replaced between the check and the signature. The progress call
    /// of the signing stage is the last thing the importer does before it signs, so a test can act in that gap.
    func testRefusesAnExecutableSwappedBeforeItIsSigned() throws {
        let workspace = try TestWorkspace()
        let importer = try importer(workspace)
        let source = try PackageFixture().write(into: workspace, at: ".incoming/transfer")
        let executable = source.appendingPathComponent(PackageFixture.frameworkName("0100111000200000")).appendingPathComponent("DmGame")
        let signer = CountingSigner()
        var swapped = false
        XCTAssertThrowsError(try importer.install(source, identity: identity(), signer: signer) { progress in
            if progress.stage == .signing, !swapped {
                swapped = true
                try? Data("not the code that was checked".utf8).write(to: executable)
            }
        }) { error in
            XCTAssertEqual((error as? NXPocketError)?.code, .hashMismatch)
        }
        XCTAssertTrue(swapped)
        XCTAssertEqual(signer.calls, 0, "nothing is signed once the executable is not the one that was checked")
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.url("Documents/games/0100111000200000").path))
    }

    func testRefusesACertificateWithNothingToSignWith() throws {
        let workspace = try TestWorkspace()
        let importer = try importer(workspace)
        let source = try PackageFixture().write(into: workspace, at: ".incoming/transfer")
        XCTAssertThrowsError(try importer.install(source, identity: identity(), signer: nil)) { error in
            XCTAssertEqual((error as? NXPocketError)?.code, .signingFailed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.url("Documents/games/0100111000200000").path),
                       "an unsigned framework never reaches the library")
    }

    func testTheSigningRecordKeepsWhichEntitlementsWereUsed() throws {
        let workspace = try TestWorkspace()
        let importer = try importer(workspace)
        let source = try PackageFixture().write(into: workspace, at: ".incoming/transfer")
        var identity = identity()
        identity.entitlementsTag = "app"
        _ = try importer.install(source, identity: identity, signer: CountingSigner())
        let record = try XCTUnwrap(GameLibrary.readSigning(workspace.url("Documents/games/0100111000200000")))
        XCTAssertEqual(record.entitlements, "app")
        XCTAssertFalse(record.needsResign(against: identity))
        identity.entitlementsTag = "profile"
        XCTAssertTrue(record.needsResign(against: identity), "the other choice is signed again")
    }
}

final class DigestAndBoundsTests: XCTestCase {
    func testAHashIsNeverTheHashOfWhatWasReadBeforeAnError() throws {
        let workspace = try TestWorkspace()
        let folder = workspace.url("a-folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Opening a folder for reading works and reading it fails: that used to return the hash of nothing.
        XCTAssertThrowsError(try FileDigest.sha256(ofFileAt: folder))
        let file = try workspace.write("data", bytes: 10_000)
        XCTAssertEqual(try FileDigest.sha256(ofFileAt: file), FileDigest.sha256(of: try Data(contentsOf: file)))
    }

    func testAnOversizedLaunchMarkerIsNotReadAtAll() throws {
        let workspace = try TestWorkspace()
        let documents = workspace.url("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        // A sparse file: 6 MB by its size, nothing on disk. Read whole, it would be allocated at every launch.
        let marker = LaunchMarker.url(in: documents)
        FileManager.default.createFile(atPath: marker.path, contents: nil)
        let handle = try FileHandle(forWritingTo: marker)
        try handle.truncate(atOffset: 6 << 20)
        try handle.close()
        XCTAssertNil(LaunchMarker.read(in: documents))
    }

    func testAnOversizedImportLogIsNotReadAtAll() throws {
        let workspace = try TestWorkspace()
        let url = workspace.url("import-log.txt")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 8 << 20)
        try handle.close()
        XCTAssertEqual(ImportLog(url: url).read(), "")
        // Writing to it still works: the oversized file is moved aside rather than appended to.
        ImportLog(url: url).append("after")
        XCTAssertTrue(ImportLog(url: url).read().contains("after"))
    }

    func testTheLogKeepsItsLastHoursWhenItRotates() throws {
        let workspace = try TestWorkspace()
        let url = workspace.url("import-log.txt")
        let log = ImportLog(url: url, limits: 512)
        for index in 0..<40 { log.append("line \(index) padding padding padding") }
        let archive = try String(contentsOf: log.archive, encoding: .utf8)
        XCTAssertEqual(log.archive.lastPathComponent, "import-log.1.txt")
        XCTAssertTrue(archive.contains("line "), "the full log was moved aside, not thrown away")
        let current = log.read()
        XCTAssertTrue(current.contains("earlier lines in import-log.1.txt"))
        XCTAssertTrue(current.contains("line 39"))
    }
}
