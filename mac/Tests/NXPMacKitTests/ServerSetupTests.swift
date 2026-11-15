import NXPocketSFTP
import XCTest

@testable import NXPMacModel

@MainActor
final class ServerSetupTests: XCTestCase {
    func testTheFormIsReadyOnlyWithAServerAUserAndWhatSignsIn() {
        let flow = ServerSetupFlow()
        XCTAssertFalse(flow.canConnect)
        flow.host = "nas.local"
        flow.user = "player"
        XCTAssertFalse(flow.canConnect, "no password yet")
        flow.password = "secret"
        XCTAssertTrue(flow.canConnect)
        flow.port = "70000"
        XCTAssertFalse(flow.canConnect, "a port that is not one")
        flow.port = "2222"
        XCTAssertTrue(flow.canConnect)
        flow.auth = .key
        XCTAssertFalse(flow.canConnect, "a key is chosen from a file")
        flow.privateKey = "-----BEGIN OPENSSH PRIVATE KEY-----\n…"
        XCTAssertTrue(flow.canConnect)
    }

    func testWhatSignsInGoesToTheKeychainAsOneSecretAndNeverIntoTheSettings() throws {
        let flow = ServerSetupFlow()
        flow.host = " nas.local "
        flow.port = "2222"
        flow.user = "player"
        flow.password = "p@ss"
        XCTAssertEqual(flow.config(folder: "/volume1/builds"), SFTPConfig(host: "nas.local", port: 2222, user: "player", hostKey: nil, folder: "/volume1/builds"))
        let secret = flow.credential().secret
        XCTAssertEqual(SFTPCredential.decode(secret)?.password, "p@ss")
        let data = try JSONEncoder().encode(LauncherSettings())
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("p@ss"))
    }

    func testSettingsSavedByAnEarlierVersionStillLoadAndHaveNoServer() throws {
        let old = #"{"engineRoot":"","gameFolder":"/games","serverHost":"nas.local","serverPort":22,"serverUser":"me","serverFolder":"/b","serverKey":"/k"}"#
        let settings = try JSONDecoder().decode(LauncherSettings.self, from: Data(old.utf8))
        XCTAssertEqual(settings.gameFolder, "/games")
        XCTAssertNil(settings.server, "a server of the old kind has no key to trust: it is set up again")
    }

    func testAServerSavedInTheSettingsComesBack() throws {
        var settings = LauncherSettings()
        settings.server = SFTPConfig(host: "nas.local", port: 22, user: "me", hostKey: String(repeating: "a", count: 64), folder: "/b")
        settings.serverName = "NAS"
        let back = try JSONDecoder().decode(LauncherSettings.self, from: try JSONEncoder().encode(settings))
        XCTAssertEqual(back.server, settings.server)
        XCTAssertEqual(back.serverName, "NAS")
    }
}
