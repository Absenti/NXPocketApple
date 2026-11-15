import Darwin
import Foundation
import XCTest

import NXPMacModel
import NXPocketKit

/// The launcher's own start of the server, as the app does it at every launch with Sharing on: these crashed the release build
/// (not the debug one) the second time the app was opened, when a port had been kept, so they are worth running in release too:
/// `swift test -c release -Xswiftc -enable-testing --filter AppModelSharingTests`.
@MainActor
final class AppModelSharingTests: XCTestCase {
    private var folder: URL!
    private var suite = ""
    private var held: [Int32] = []
    private var models: [AppModel] = []

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("nxpocket-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        suite = "nxpocket-model-\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        for model in models { model.settings.value.shareEnabled = false }
        for model in models { try await wait("stopped") { model.sharing == .off } }
        models = []
        held.forEach { close($0) }
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }

    private func model(enabled: Bool, keptPort: Int) -> AppModel {
        let defaults = UserDefaults(suiteName: suite)!
        let store = SettingsStore(defaults: defaults)
        var settings = LauncherSettings()
        settings.shareEnabled = enabled
        settings.sharePort = keptPort
        settings.checkUpdates = false
        settings.outputFolder = folder.appendingPathComponent("built").path
        store.value = settings
        let model = AppModel(settings: store, sharingKeyFolder: folder.appendingPathComponent("keys"), advertiseSharing: false)
        models.append(model)
        return model
    }

    private func wait(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition(), what)
    }

    /// A port nobody has, found by asking for one and giving it back.
    private func freePort() -> Int { occupy(keep: false) }

    /// A port somebody has: this test, until it ends.
    private func busyPort() -> Int { occupy(keep: true) }

    private func occupy(keep: Bool) -> Int {
        let descriptor = socket(AF_INET6, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in6()
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_addr = in6addr_any
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, length) } }
        if keep { Darwin.listen(descriptor, 1) }
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }
        let port = Int(UInt16(bigEndian: address.sin6_port))
        if keep { held.append(descriptor) } else { close(descriptor) }
        return port
    }

    func testNothingListensUntilSharingIsTurnedOn() async throws {
        let model = model(enabled: false, keptPort: 0)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(model.sharing, .off)
        model.settings.value.shareEnabled = true
        try await wait("listening") { if case .listening = model.sharing { return true }; return false }
    }

    func testTheFirstStartChoosesAPortAndKeepsIt() async throws {
        let model = model(enabled: true, keptPort: 0)
        try await wait("listening") { if case .listening = model.sharing { return true }; return false }
        guard case .listening(let port) = model.sharing else { return XCTFail("not listening") }
        XCTAssertEqual(model.settings.value.sharePort, Int(port), "the port is kept for the next launch")
        XCTAssertFalse(model.sharingFingerprint.isEmpty)
    }

    func testTheNextLaunchListensOnTheKeptPort() async throws {
        let kept = freePort()
        let model = model(enabled: true, keptPort: kept)
        try await wait("listening") { if case .listening = model.sharing { return true }; return false }
        XCTAssertEqual(model.sharing, .listening(port: UInt16(kept)))
        XCTAssertFalse(model.sharingFingerprint.isEmpty)
    }

    func testAKeptPortThatIsTakenGivesWayToAnotherAndKeepsThat() async throws {
        let kept = busyPort()
        let model = model(enabled: true, keptPort: kept)
        try await wait("listening") { if case .listening = model.sharing { return true }; return false }
        guard case .listening(let port) = model.sharing else { return XCTFail("not listening") }
        XCTAssertNotEqual(Int(port), kept)
        XCTAssertEqual(model.settings.value.sharePort, Int(port))
    }
}
