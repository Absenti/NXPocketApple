import XCTest

@testable import NXPocketKit

final class MachOParserTests: XCTestCase {
    func testReadsASyntheticDylib() throws {
        let image = try MachOFile.parse(MachOBuilder(dependencies: ["/usr/lib/libSystem.B.dylib"]).build())
        XCTAssertTrue(image.header.isARM64)
        XCTAssertTrue(image.header.isDylib)
        XCTAssertEqual(image.header.commandCount, 2)
        XCTAssertEqual(image.minimumOS, OSVersion(major: 26, minor: 0))
        XCTAssertEqual(image.buildVersion?.sdkVersion, OSVersion(major: 27, minor: 2))
        XCTAssertEqual(image.dependencies.map(\.name), ["/usr/lib/libSystem.B.dylib"])
    }

    func testReadsTheRealCompilerOutput() throws {
        let workspace = try TestWorkspace("macho")
        let source = workspace.url("answer.c")
        try "#include <stdint.h>\nint32_t nxpocket_fixture(void) { return 44; }\n".write(to: source, atomically: true, encoding: .utf8)
        let output = workspace.url("Fixture.dylib")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["-sdk", "iphoneos", "clang", "-arch", "arm64", "-target", "arm64-apple-ios26.0",
                             "-dynamiclib", "-install_name", "@rpath/Fixture.dylib", "-Oz", "-Wl,-adhoc_codesign",
                             source.path, "-o", output.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw XCTSkip("no clang available") }
        process.waitUntilExit()
        try XCTSkipUnless(process.terminationStatus == 0 && FileManager.default.fileExists(atPath: output.path),
                          "the iOS SDK is not installed")

        let image = try MachOFile.parse(contentsOf: output)
        XCTAssertTrue(image.header.isARM64)
        XCTAssertTrue(image.header.isDylib)
        XCTAssertEqual(image.buildVersion?.platform, MachOFile.BuildVersion.platformIOS)
        XCTAssertLessThanOrEqual(image.minimumOS ?? OSVersion(major: 99), OSVersion(major: 27, minor: 2))
        XCTAssertTrue(image.dependencies.contains { $0.name.contains("libSystem") })
        XCTAssertNotNil(image.codeSignature, "codesign --sign - output carries a signature")
    }

    func testRefusesAFatBinary() throws {
        var data = Data([0xCA, 0xFE, 0xBA, 0xBE])
        data.append(contentsOf: [UInt8](repeating: 0, count: 64))
        XCTAssertTrue(MachOFile.isFat(data))
        XCTAssertThrowsError(try MachOFile.parse(data)) { error in
            XCTAssertEqual((error as? NXPocketError)?.code, .fatBinary)
        }
    }

    func testRefusesSomethingThatIsNotMachO() {
        XCTAssertThrowsError(try MachOFile.parse(Data("#!/bin/sh\n".utf8))) { error in
            XCTAssertEqual((error as? NXPocketError)?.code, .notAMachO)
        }
    }

    func testReadsTheLegacyIphoneOSMinimum() throws {
        var builder = MachOBuilder()
        builder.includeBuildVersion = false
        builder.legacyMinimumOS = OSVersion(major: 26, minor: 0)
        XCTAssertEqual(try MachOFile.parse(builder.build()).minimumOS, OSVersion(major: 26, minor: 0))
    }

    func testReadsSections() throws {
        let builder = MachOBuilder(section: (segment: "__TEXT", name: "__dmx0", address: 0x4000, size: 0x4000))
        let image = try MachOFile.parse(builder.build())
        let section = image.section(segment: "__TEXT", name: "__dmx0")
        XCTAssertEqual(section?.address, 0x4000)
        XCTAssertEqual(section?.size, 0x4000)
        XCTAssertEqual((section?.address ?? 1) % 0x4000, 0, "the engine's code page is 16K aligned")
    }
}

final class MachOInspectorTests: XCTestCase {
    private func inspect(_ image: Data, policy: MachOInspector.Policy = .default) throws -> MachOInspector.Report {
        let workspace = try TestWorkspace("inspect")
        let framework = workspace.url("DmGame.framework")
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        try image.write(to: framework.appendingPathComponent("DmGame"))
        return try MachOInspector.inspectExecutable(at: framework.appendingPathComponent("DmGame"),
                                                    frameworkRoot: framework, policy: policy)
    }

    func testLazyAndUpwardDependenciesGoThroughThePolicy() throws {
        for command: UInt32 in [0x20, 0x8000_0023] {   // LC_LAZY_LOAD_DYLIB, LC_LOAD_UPWARD_DYLIB
            let image = MachOBuilder(otherDependencies: [(command, "/private/var/mobile/evil.dylib")]).build()
            XCTAssertThrowsError(try inspect(image)) { error in
                XCTAssertEqual((error as? NXPocketError)?.code, .forbiddenDependency)
            }
        }
    }

    func testAcceptsASystemOnlyDylib() throws {
        let report = try inspect(MachOBuilder(dependencies: ["/usr/lib/libSystem.B.dylib"]).build())
        XCTAssertEqual(report.architecture, "arm64")
        XCTAssertTrue(report.warnings.isEmpty)
    }

    func testAcceptsRpathDependenciesInsideTheFramework() throws {
        let workspace = try TestWorkspace("rpath")
        let framework = workspace.url("DmGame.framework")
        try FileManager.default.createDirectory(at: framework.appendingPathComponent("Inner.framework"),
                                                withIntermediateDirectories: true)
        try Data().write(to: framework.appendingPathComponent("Inner.framework/Inner"))
        let image = MachOBuilder(dependencies: ["@rpath/Inner.framework/Inner"]).build()
        try image.write(to: framework.appendingPathComponent("DmGame"))
        let report = try MachOInspector.inspectExecutable(at: framework.appendingPathComponent("DmGame"),
                                                          frameworkRoot: framework)
        XCTAssertEqual(report.dependencies.first?.name, "@rpath/Inner.framework/Inner")
        XCTAssertTrue(report.warnings.isEmpty)
    }

    func testRefusesAnAbsoluteDependencyOutsideTheSystem() {
        XCTAssertThrowsError(try inspect(MachOBuilder(dependencies: ["/opt/homebrew/lib/libevil.dylib"]).build())) { error in
            XCTAssertEqual((error as? NXPocketError)?.code, .forbiddenDependency)
        }
    }

    func testRefusesARelativeDependencyThatEscapes() {
        XCTAssertThrowsError(try inspect(MachOBuilder(dependencies: ["@loader_path/../../lib/libevil.dylib"]).build())) { error in
            XCTAssertEqual((error as? NXPocketError)?.code, .unsafePath)
        }
    }

    func testRefusesTheWrongArchitecture() {
        XCTAssertThrowsError(try inspect(MachOBuilder(cpuType: 0x0100_0007).build())) { error in
            XCTAssertEqual((error as? NXPocketError)?.code, .wrongArchitecture)
        }
    }

    func testRefusesAnExecutableInsteadOfADylib() {
        XCTAssertThrowsError(try inspect(MachOBuilder(fileType: 2).build())) { error in
            XCTAssertEqual((error as? NXPocketError)?.code, .wrongMachOType)
        }
    }

    func testRefusesAMacOSPlatform() {
        XCTAssertThrowsError(try inspect(MachOBuilder(platform: MachOFile.BuildVersion.platformMacOS).build())) { error in
            XCTAssertEqual((error as? NXPocketError)?.code, .wrongArchitecture)
        }
    }

    func testRefusesADeploymentTargetNewerThanTheDevice() {
        XCTAssertThrowsError(try inspect(MachOBuilder(minimumOS: OSVersion(major: 99)).build(),
                                         policy: MachOInspector.Policy(maximumMinimumOS: OSVersion(major: 27)))) { error in
            XCTAssertEqual((error as? NXPocketError)?.code, .minimumOSNewer)
        }
    }

    func testRefusesAMissingDeploymentTarget() {
        XCTAssertThrowsError(try inspect(MachOBuilder(includeBuildVersion: false).build())) { error in
            XCTAssertEqual((error as? NXPocketError)?.code, .minimumOSNewer)
        }
    }

    func testRefusesADylibWithOnlyTheLegacyMinimum() {
        var builder = MachOBuilder()
        builder.includeBuildVersion = false
        builder.legacyMinimumOS = OSVersion(major: 26, minor: 0)
        XCTAssertThrowsError(try inspect(builder.build())) { error in
            XCTAssertEqual((error as? NXPocketError)?.code, .minimumOSNewer)
        }
    }
}

final class CodeSignatureTests: XCTestCase {
    func testReadsIdentifierTeamAndCertificate() throws {
        let builder = CodeSignatureBuilder(identifier: "com.kdt.livecontainer.ABCDE12345", teamID: "ABCDE12345")
        let image = try MachOFile.parse(MachOBuilder(codeSignature: builder.build()).build())
        let signature = try XCTUnwrap(try CodeSignatureInfo.read(image))
        XCTAssertEqual(signature.identifier, "com.kdt.livecontainer.ABCDE12345")
        XCTAssertEqual(signature.teamID, "ABCDE12345")
        XCTAssertTrue(signature.hasCertificate)
        XCTAssertFalse(signature.isAdHoc)
        XCTAssertEqual(signature.signerName, "Apple Development: Example (ABCDE12345)")
        XCTAssertEqual(signature.hashType, 2)
    }

    func testReportsAnAdHocSignature() throws {
        var builder = CodeSignatureBuilder()
        builder.certificate = nil
        builder.flags = CodeSignatureInfo.adHocFlag
        let image = try MachOFile.parse(MachOBuilder(codeSignature: builder.build()).build())
        let signature = try XCTUnwrap(try CodeSignatureInfo.read(image))
        XCTAssertTrue(signature.isAdHoc)
        XCTAssertFalse(signature.hasCertificate)
        XCTAssertNil(signature.signerName)
    }

    func testNoSignatureAtAll() throws {
        let image = try MachOFile.parse(MachOBuilder().build())
        XCTAssertNil(try CodeSignatureInfo.read(image))
    }
}
