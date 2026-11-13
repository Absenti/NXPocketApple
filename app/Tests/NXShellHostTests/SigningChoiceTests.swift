import NXPocketKit
import XCTest
@testable import NXShellHost

/// Which entitlements a game is signed with, when to try the others, and what the app can say about a game iOS
/// refused. The first real FlareStore install showed why: the game's signature copied a profile granting 40-odd
/// entitlements, dyld answered only "file system sandbox blocked mmap()", and nothing said which difference mattered.
final class SigningChoiceTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let suite = "nxpocket.tests.signing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    // MARK: - The two sources

    func testOnlyAnInstallationWhoseProfileAndSignatureDisagreeHasASecondChoice() {
        let profile: [String: Any] = ["application-identifier": "TEAM.*", "get-task-allow": false, "aps-environment": "production"]
        let trimmed: [String: Any] = ["application-identifier": "TEAM.dev.nxpocketapple.app", "get-task-allow": false]
        XCTAssertEqual(SigningPreference.alternative(to: .profile, signed: trimmed, profile: profile), .app)
        XCTAssertEqual(SigningPreference.alternative(to: .app, signed: trimmed, profile: profile), .profile)
        XCTAssertNil(SigningPreference.alternative(to: .profile, signed: profile, profile: profile),
                     "the same entitlements twice: signing again changes nothing")
        XCTAssertNil(SigningPreference.alternative(to: .profile, signed: nil, profile: profile), "no entitlements in the app's signature")
        XCTAssertNil(SigningPreference.alternative(to: .profile, signed: trimmed, profile: nil))
    }

    func testBothChoicesRefusedStopsTheRetries() {
        let profile: [String: Any] = ["a": true]
        let signed: [String: Any] = ["b": true]
        XCTAssertNil(SigningPreference.alternative(to: .profile, signed: signed, profile: profile, exhausted: true))
    }

    // MARK: - What is remembered

    func testTheProfileIsTheDefaultAndAChoiceOnlyHoldsForTheSignatureItWasMadeUnder() {
        let defaults = defaults()
        let here = SigningPreference.fingerprint(identifier: "dev.nxpocketapple.app", team: "AAAAAAAAAA", signedXML: Data("x".utf8))
        let elsewhere = SigningPreference.fingerprint(identifier: "dev.nxpocketapple.app", team: "BBBBBBBBBB", signedXML: Data("x".utf8))
        XCTAssertNotEqual(here, elsewhere, "another team is another installation")
        XCTAssertEqual(SigningPreference.choice(signedAvailable: true, fingerprint: here, defaults: defaults), .profile)

        SigningPreference.remember(.app, fingerprint: here, defaults: defaults)
        XCTAssertEqual(SigningPreference.choice(signedAvailable: true, fingerprint: here, defaults: defaults), .app)
        XCTAssertEqual(SigningPreference.choice(signedAvailable: true, fingerprint: elsewhere, defaults: defaults), .profile,
                       "reinstalled by another store: the choice is forgotten")
        XCTAssertEqual(SigningPreference.choice(signedAvailable: false, fingerprint: here, defaults: defaults), .profile,
                       "the app's own entitlements cannot be copied when there are none")

        SigningPreference.forget(defaults: defaults)
        XCTAssertEqual(SigningPreference.choice(signedAvailable: true, fingerprint: here, defaults: defaults), .profile)
    }

    func testExhaustionIsPerInstallation() {
        let defaults = defaults()
        let here = SigningPreference.fingerprint(identifier: "x", team: "T", signedXML: nil)
        XCTAssertFalse(SigningPreference.isExhausted(fingerprint: here, defaults: defaults))
        SigningPreference.remember(.profile, fingerprint: here, exhausted: true, defaults: defaults)
        XCTAssertTrue(SigningPreference.isExhausted(fingerprint: here, defaults: defaults))
        XCTAssertFalse(SigningPreference.isExhausted(fingerprint: "other", defaults: defaults))
    }

    func testTheSignerReadsItsChoiceFromTheIdentity() {
        XCTAssertEqual(DeviceSigner.Entitlements(tag: "profile"), .appProfile)
        XCTAssertEqual(DeviceSigner.Entitlements(tag: "app"), .appSigned)
        XCTAssertNil(DeviceSigner.Entitlements(tag: nil))
        XCTAssertNil(DeviceSigner.Entitlements(tag: "nonsense"))
    }

    // MARK: - The diagnosis

    /// A development signature, the kind that loads games (SideStore): with this one, agreement leaves nothing to blame.
    private let appSigned: [String: Any] = ["application-identifier": "ABCDE12345.dev.nxpocketapple.app", "get-task-allow": true]

    private func game(identifier: String = "dev.nxpocketapple.app", team: String? = "ABCDE12345",
                      applicationIdentifier: String? = "ABCDE12345.dev.nxpocketapple.app",
                      keys: [String]? = ["application-identifier", "get-task-allow"]) -> GameSignatureFacts {
        GameSignatureFacts(identifier: identifier, teamID: team, hasCertificate: true, signerName: nil,
                           applicationIdentifier: applicationIdentifier, entitlementKeys: keys)
    }

    private func diagnose(game: GameSignatureFacts?, certificate: String? = "aa", hashes: Set<String>? = ["aa"],
                          certificateTeam: String? = "ABCDE12345") -> SigningDiagnosis {
        SigningDiagnosis.make(appIdentifier: "dev.nxpocketapple.app", appTeam: "ABCDE12345", appSigned: appSigned,
                              profileTeams: ["ABCDE12345"], profileCertificateHashes: hashes,
                              certificateSHA256: certificate, certificateTeam: certificateTeam, game: game)
    }

    func testAGameThatAgreesWithTheAppLeavesNothingToBlame() {
        XCTAssertEqual(diagnose(game: game()).verdict, .nothingFound)
    }

    func testACertificateTheAppsProfileDoesNotListIsTheFirstThingSaid() {
        let verdict = diagnose(game: game(), certificate: "bb")
        XCTAssertEqual(verdict.verdict, .certificateNotInProfile)
        XCTAssertTrue(verdict.lines.contains { $0.contains("NOT in the app's profile") })
    }

    func testAnotherTeamsCertificate() {
        XCTAssertEqual(diagnose(game: game(), certificateTeam: "ZZZZZZZZZZ").verdict, .teamMismatch)
    }

    /// The case the FlareStore install had: the game copied a shared profile's `application-identifier`.
    func testAGameClaimingAnotherApplicationIdentifierThanTheApp() {
        let result = diagnose(game: game(applicationIdentifier: "ABCDE12345.app.teal6595.ocelot3201"))
        XCTAssertEqual(result.verdict, .applicationIdentifierMismatch)
        XCTAssertTrue(result.lines.contains { $0.contains("application-identifier is not the app's") })
    }

    func testAGameClaimingRightsTheAppDoesNotHave() {
        let result = diagnose(game: game(keys: ["application-identifier", "get-task-allow", "aps-environment", "com.apple.developer.healthkit"]))
        XCTAssertEqual(result.verdict, .entitlementsDiffer)
        XCTAssertTrue(result.lines.contains { $0.contains("2 entitlements the app's own signature lacks") })
    }

    func testAGameSignedUnderAnotherIdentifier() {
        XCTAssertEqual(diagnose(game: game(identifier: "dev.nxpocketapple.app.Probe")).verdict, .identifierMismatch)
    }

    /// The FlareStore install of 2026-11-12, as its import log recorded it: certificate in the profile, same team, same
    /// identifier, same application-identifier, 41 entitlements on both sides, get-task-allow false, and dyld refused.
    func testEverythingAgreeingOnADistributionProfileIsSaidAsThat() {
        let signed: [String: Any] = ["application-identifier": "ABCDE12345.app.teal6595.ocelot3201", "get-task-allow": false,
                                     "keychain-access-groups": ["ABCDE12345.*"]]
        let facts = GameSignatureFacts(identifier: "dev.nxpocketapple.app", teamID: "ABCDE12345", hasCertificate: true, signerName: nil,
                                       applicationIdentifier: "ABCDE12345.app.teal6595.ocelot3201",
                                       entitlementKeys: Array(signed.keys))
        let result = SigningDiagnosis.make(appIdentifier: "dev.nxpocketapple.app", appTeam: "ABCDE12345", appSigned: signed,
                                           profileTeams: ["ABCDE12345"], profileCertificateHashes: ["aa"],
                                           certificateSHA256: "aa", certificateTeam: "ABCDE12345", game: facts,
                                           profileKind: "ad hoc (1 devices)", choice: .profile)
        XCTAssertEqual(result.verdict, .distributionProfile)
        XCTAssertTrue(result.lines.contains { $0.contains("signed for distribution") })
        // The same facts on a development signature leave nothing to blame: that is the case that loads.
        var development = signed
        development["get-task-allow"] = true
        let loads = SigningDiagnosis.make(appIdentifier: "dev.nxpocketapple.app", appTeam: "ABCDE12345", appSigned: development,
                                          profileTeams: ["ABCDE12345"], profileCertificateHashes: ["aa"],
                                          certificateSHA256: "aa", certificateTeam: "ABCDE12345", game: facts)
        XCTAssertEqual(loads.verdict, .nothingFound)
    }

    // MARK: - The two messages dyld has for a refused mapping

    /// dyld has "code signing blocked mmap()" and "file system sandbox blocked mmap()" (both are in the iPhone's own dyld).
    /// The second is the sandbox policy of the process denying `file-map-executable`, before any signature is judged.
    func testASandboxDenialIsToldApartFromACodeSigningOne() {
        let sandbox = NXPocketError(.notSigned, "dlopen refused DmGame: dlopen(/x, 0x0006): tried: '/x' (file system sandbox blocked mmap() of '/private/x')")
        let signing = NXPocketError(.notSigned, "dlopen refused DmGame: dlopen(/x, 0x0006): tried: '/x' (code signing blocked mmap() of '/private/x')")
        XCTAssertTrue(ShellHostModel.isSandboxDenial(sandbox))
        XCTAssertFalse(ShellHostModel.isSandboxDenial(signing))
        XCTAssertFalse(ShellHostModel.isSandboxDenial(NXPocketError(.engineFailed, "something else")))
        XCTAssertTrue(ShellHostModel.isCodeRefusal(sandbox))
        XCTAssertTrue(ShellHostModel.isCodeRefusal(signing))
    }

    private func sandboxDiagnosis(signed: [String: Any], certificate: String = "aa", hashes: Set<String> = ["aa"]) -> SigningDiagnosis {
        SigningDiagnosis.make(appIdentifier: "dev.nxpocketapple.app", appTeam: "ABCDE12345", appSigned: signed,
                              profileTeams: ["ABCDE12345"], profileCertificateHashes: hashes,
                              certificateSHA256: certificate, certificateTeam: "ABCDE12345",
                              game: game(applicationIdentifier: "ABCDE12345.dev.nxpocketapple.app"), sandboxDenial: true)
    }

    func testASandboxDenialOnADevelopmentAppIsNotBlamedOnTheSignature() {
        let development: [String: Any] = ["application-identifier": "ABCDE12345.dev.nxpocketapple.app", "get-task-allow": true]
        let result = sandboxDiagnosis(signed: development)
        XCTAssertEqual(result.verdict, .sandboxDenied)
        XCTAssertTrue(result.lines.contains { $0.contains("not code signing") })
        // Even a certificate the profile does not list cannot be what produced this message, so it does not become the verdict.
        XCTAssertEqual(sandboxDiagnosis(signed: development, certificate: "bb").verdict, .sandboxDenied)
    }

    func testASandboxDenialOnADistributionAppSaysDistribution() {
        let distribution: [String: Any] = ["application-identifier": "ABCDE12345.dev.nxpocketapple.app", "get-task-allow": false]
        XCTAssertEqual(sandboxDiagnosis(signed: distribution).verdict, .distributionProfile)
        XCTAssertEqual(sandboxDiagnosis(signed: distribution, certificate: "bb").verdict, .distributionProfile)
    }

    func testOnlyAReadableSignatureWithoutGetTaskAllowIsForDistribution() {
        XCTAssertTrue(SigningDiagnosis.isDistributionSigned(["get-task-allow": false]))
        XCTAssertTrue(SigningDiagnosis.isDistributionSigned([:]))
        XCTAssertFalse(SigningDiagnosis.isDistributionSigned(["get-task-allow": true]))
        XCTAssertFalse(SigningDiagnosis.isDistributionSigned(nil), "nothing is claimed about a signature that could not be read")
    }

    func testAnUnreadableSignatureIsSaidNotGuessed() {
        let result = diagnose(game: nil)
        XCTAssertEqual(result.verdict, .nothingFound)
        XCTAssertTrue(result.lines.contains { $0.contains("could not be read") })
    }

    // MARK: - The profile's kind

    func testTheKindOfProfileTellsTheStoresApart() {
        XCTAssertEqual(ProvisioningProfile.kind(of: ["ProvisionsAllDevices": true]), "enterprise")
        XCTAssertEqual(ProvisioningProfile.kind(of: ["Entitlements": ["get-task-allow": true]]), "development")
        XCTAssertEqual(ProvisioningProfile.kind(of: ["ProvisionedDevices": ["a", "b"], "Entitlements": ["get-task-allow": false]]),
                       "ad hoc (2 devices)")
        XCTAssertEqual(ProvisioningProfile.kind(of: ["Entitlements": ["get-task-allow": false]]), "App Store")
    }

    // MARK: - The record

    func testASigningRecordWithoutAChoiceMeansTheProfileAndIsNotSignedAgainForIt() throws {
        let json = #"{"certificateSHA256":"aa","identifier":"i","teamID":"T","subject":"s","signedAt":"2026-11-12T20:00:00Z","expires":"2027-11-12T20:00:00Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(SigningRecord.self, from: Data(json.utf8))
        XCTAssertNil(record.entitlements)
        let expires = Date().addingTimeInterval(86400 * 300)
        let sameChoice = SigningIdentity(identifier: "i", teamID: "T", certificateSHA256: "aa", subject: "s", expires: expires,
                                         entitlementsTag: "profile")
        XCTAssertFalse(record.needsResign(against: sameChoice))
        let otherChoice = SigningIdentity(identifier: "i", teamID: "T", certificateSHA256: "aa", subject: "s", expires: expires,
                                          entitlementsTag: "app")
        XCTAssertTrue(record.needsResign(against: otherChoice), "the app moved to the other entitlements: every game follows")
        let undecided = SigningIdentity(identifier: "i", teamID: "T", certificateSHA256: "aa", subject: "s", expires: expires)
        XCTAssertFalse(record.needsResign(against: undecided))
    }
}

/// The small fixes of the review that live in the iPhone app.
final class ReviewFixesAppTests: XCTestCase {
    func testZlibsCRCAgreesWithTheReferenceOnAnyShapeOfInput() {
        var bytes = [UInt8](repeating: 0, count: 100_003)
        var seed: UInt32 = 12345
        for index in bytes.indices { seed = seed &* 1664525 &+ 1013904223; bytes[index] = UInt8(truncatingIfNeeded: seed >> 24) }
        for length in [0, 1, 7, 8, 9, 255, 4096, 100_003] {
            let slice = Array(bytes[0..<length])
            let fast = slice.withUnsafeBytes { CRC32.finish(CRC32.update(CRC32.start, $0)) }
            let reference = slice.withUnsafeBytes { CRC32.finish(CRC32.referenceUpdate(CRC32.start, $0)) }
            XCTAssertEqual(fast, reference, "\(length) bytes")
        }
        // Fed in pieces, as an archive entry is.
        var running = CRC32.start
        for start in stride(from: 0, to: bytes.count, by: 999) {
            let piece = Array(bytes[start..<min(start + 999, bytes.count)])
            running = piece.withUnsafeBytes { CRC32.update(running, $0) }
        }
        XCTAssertEqual(CRC32.finish(running), bytes.withUnsafeBytes { CRC32.finish(CRC32.referenceUpdate(CRC32.start, $0)) })
    }

    func testOnlyWellFormedEngineVariablesAreTaken() {
        XCTAssertTrue(EngineLaunchPlan.isEngineVariable("DM_OPMODE"))
        XCTAssertTrue(EngineLaunchPlan.isEngineVariable("DM_PSO_MTL4"))
        for bad in ["DM_", "DM_has space", "DM_lower", "DM_A-B", "DM_É", "HOME", "DYLD_INSERT_LIBRARIES", "dm_x", "DM_A=B"] {
            XCTAssertFalse(EngineLaunchPlan.isEngineVariable(bad), bad)
        }
        XCTAssertTrue(EngineLaunchPlan.isEngineValue("1"))
        XCTAssertTrue(EngineLaunchPlan.isEngineValue("a path with spaces/é"))
        XCTAssertFalse(EngineLaunchPlan.isEngineValue("a\u{0}b"))
        XCTAssertFalse(EngineLaunchPlan.isEngineValue("a\rb"))
    }

    func testAnEnvFileCannotSplitTheKeyList() throws {
        let documents = FileManager.default.temporaryDirectory.appendingPathComponent("env-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: documents) }
        let game = InstalledGame(titleID: TitleID("0100111000200000")!, directory: documents.appendingPathComponent("games/0100111000200000"))
        let presets = EngineLaunchPlan.presets(game: game, documents: documents,
                                               envFileText: "DM_GOOD=1\nDM_BAD KEY=1\nDM_lower=2\nHOME=/x\nDM_ALSO_GOOD=two words\n")
        XCTAssertEqual(presets.map(\.key), ["DM_GOOD", "DM_ALSO_GOOD"])
    }

    func testWhatAKilledSigningLeftInTmpIsRemoved() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tmp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["nxpocket-AAAA.p12", "nxpocket-BBBB-entitlements.plist", "keep-me.p12", "nxpocket-notes.txt", "other.plist"] {
            try Data("x".utf8).write(to: folder.appendingPathComponent(name))
        }
        XCTAssertEqual(SigningLeftovers.clean(in: folder), ["nxpocket-AAAA.p12", "nxpocket-BBBB-entitlements.plist"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(),
                       ["keep-me.p12", "nxpocket-notes.txt", "other.plist"], "only this app's two kinds of file go")
    }
}

/// The increased memory limit is what the app's signature carries, not what its profile could grant.
final class IncreasedLimitTests: XCTestCase {
    private let key = "com.apple.developer.kernel.increased-memory-limit"

    func testTheSignatureDecidesAndTheProfileOnlyAnswersWhenTheSignatureCannotBeRead() {
        // The store trimmed the app's entitlements: the profile still grants the limit, the app does not get it.
        XCTAssertFalse(MemoryBudget.hasIncreasedLimit(signed: ["get-task-allow": false], profile: [key: true]))
        // Signed with it.
        XCTAssertTrue(MemoryBudget.hasIncreasedLimit(signed: [key: true], profile: [:]))
        // No signature to read: the profile is all there is.
        XCTAssertTrue(MemoryBudget.hasIncreasedLimit(signed: nil, profile: [key: true]))
        XCTAssertFalse(MemoryBudget.hasIncreasedLimit(signed: nil, profile: [:]))
        // Present but false is not active (it used to count as active for being non-nil).
        XCTAssertFalse(MemoryBudget.hasIncreasedLimit(signed: [key: false], profile: [key: true]))
    }

    func testTheLogLineSaysWhereTheAnswerCameFrom() {
        let line = MemoryBudget.summaryLine
        XCTAssertTrue(line.hasPrefix("memory: increased limit "))
        XCTAssertTrue(line.contains("in the app's signature:"))
        XCTAssertTrue(line.contains("granted by its profile:"))
    }
}
