import CryptoKit
import Foundation
import XCTest

@testable import NXPocketSFTP

/// A real OpenSSH server, run as the current user on a free port of the loopback with its own host key and one authorised
/// client key, so the SFTP client is tested against the software NAS boxes and seedboxes run, not against a copy of itself.
/// Without a password to check (that needs root), only key authentication can be exercised here.
final class SSHDHarness {
    let directory: URL
    let port: Int
    let user = NSUserName()
    let hostKeyPin: String
    let clientKey: String
    private let process: Process

    static func start(in directory: URL) throws -> SSHDHarness {
        guard FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd"), FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh-keygen"),
              FileManager.default.isExecutableFile(atPath: "/usr/libexec/sftp-server") else {
            throw XCTSkip("OpenSSH's sshd, ssh-keygen and sftp-server are not on this machine")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func keygen(_ name: String) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            process.arguments = ["-q", "-t", "ed25519", "-N", "", "-f", directory.appendingPathComponent(name).path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw XCTSkip("ssh-keygen failed") }
        }
        try keygen("host")
        try keygen("client")
        let authorised = directory.appendingPathComponent("authorized")
        try FileManager.default.copyItem(at: directory.appendingPathComponent("client.pub"), to: authorised)
        for file in ["host", "client", "authorized"] { chmod(directory.appendingPathComponent(file).path, 0o600) }

        let port = try freePort()
        let config = """
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(directory.appendingPathComponent("host").path)
        AuthorizedKeysFile \(authorised.path)
        PubkeyAuthentication yes
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        UsePAM no
        StrictModes no
        PidFile \(directory.appendingPathComponent("sshd.pid").path)
        Subsystem sftp /usr/libexec/sftp-server
        LogLevel ERROR
        """
        let configURL = directory.appendingPathComponent("sshd_config")
        try config.write(to: configURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        process.arguments = ["-D", "-f", configURL.path]
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        for _ in 0..<100 {
            if try accepts(port) { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard try accepts(port) else { process.terminate(); throw XCTSkip("sshd did not start here") }

        let hostPublic = try String(contentsOf: directory.appendingPathComponent("host.pub"), encoding: .utf8)
        let blob = Data(base64Encoded: String(hostPublic.split(separator: " ")[1]))!
        let pin = SHA256.hash(data: blob).map { String(format: "%02x", $0) }.joined()
        let key = try String(contentsOf: directory.appendingPathComponent("client"), encoding: .utf8)
        return SSHDHarness(directory: directory, port: port, hostKeyPin: pin, clientKey: key, process: process)
    }

    private init(directory: URL, port: Int, hostKeyPin: String, clientKey: String, process: Process) {
        self.directory = directory
        self.port = port
        self.hostKeyPin = hostKeyPin
        self.clientKey = clientKey
        self.process = process
    }

    func stop() { process.terminate(); process.waitUntilExit() }

    /// A key the server has not authorised.
    func strangerKey() throws -> String {
        let folder = directory.appendingPathComponent("stranger", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-q", "-t", "ed25519", "-N", "", "-f", folder.appendingPathComponent("k").path]
        try process.run()
        process.waitUntilExit()
        return try String(contentsOf: folder.appendingPathComponent("k"), encoding: .utf8)
    }

    private static func freePort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, length) } }
        guard bound == 0 else { throw XCTSkip("no free port") }
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private static func accepts(_ port: Int) throws -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = UInt16(port).bigEndian
        return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
    }
}
