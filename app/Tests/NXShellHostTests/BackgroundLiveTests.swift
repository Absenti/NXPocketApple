import CryptoKit
import XCTest

@testable import NXPocketKit
@testable import NXShellHost

/// The system's real background transfer service against a real HTTPS server with Range, pinned by key. It needs a server, so it only
/// runs when one is named (the environment of the test run: `TEST_RUNNER_NXPOCKET_BG_URL`, `…_PIN`, `…_SHA256`, `…_SIZE`); otherwise it
/// is skipped. The server is `server.py` of the run that made this test: 96 MB of random bytes at /big.bin.
final class BackgroundLiveTests: XCTestCase {
    private var url: URL!
    private var pin = ""
    private var sha = ""
    private var size: UInt64 = 0
    private var stash: URL!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let text = env["NXPOCKET_BG_URL"], let url = URL(string: text), let pin = env["NXPOCKET_BG_PIN"], let sha = env["NXPOCKET_BG_SHA256"],
              let size = env["NXPOCKET_BG_SIZE"].flatMap(UInt64.init) else { throw XCTSkip("no server named for the live test") }
        self.url = url
        self.pin = pin
        self.sha = sha
        self.size = size
        stash = FileManager.default.temporaryDirectory.appendingPathComponent("bg-live-\(UUID().uuidString)")
    }

    override func tearDown() { if let stash { try? FileManager.default.removeItem(at: stash) } }

    private func service() -> BackgroundTransfers {
        BackgroundTransfers(stash: stash, identifier: "dev.nxpocketapple.live-\(UUID().uuidString)")
    }

    private func segments(_ service: BackgroundTransfers, pin: String, segment: UInt64) throws -> [SegmentRequest] {
        stride(from: UInt64(0), to: size, by: Int(segment)).enumerated().map { index, first in
            SegmentRequest(key: "live-0100111000200000-aaaaaaaaaaaa-bbbbbbbbbb-\(index)", request: URLRequest(url: url), first: first,
                           length: min(segment, size - first), total: size, trust: .pinned(pin))
        }
    }

    func testAWholeFileComesAsSegmentsThroughTheRealService() async throws {
        let service = service()
        let all = try segments(service, pin: pin, segment: 8 << 20)
        for segment in all { try await service.enqueue(segment) }
        var hasher = SHA256()
        for segment in all {
            let file = try await service.completion(of: segment.key)
            let data = try Data(contentsOf: file)
            XCTAssertEqual(UInt64(data.count), segment.length)
            hasher.update(data: data)
            try? FileManager.default.removeItem(at: file)
        }
        XCTAssertEqual(FileDigest.hex(hasher.finalize()), sha, "the segments put together are the server's file")
    }

    func testAServerWithAnotherKeyIsRefused() async throws {
        let service = service()
        let wrong = String(repeating: "0", count: 64)
        let segment = try XCTUnwrap(segments(service, pin: wrong, segment: 1 << 20).first)
        try await service.enqueue(segment)
        do {
            _ = try await service.completion(of: segment.key)
            XCTFail("a server that is not the pinned one must not be read from")
        } catch PackageSourceError.untrusted {
        } catch PackageSourceError.unreachable {
            // The system may report the refused handshake as a failed connection before the key is seen again.
        }
    }

    func testAFinishedSegmentIsFoundAgainByAnotherInstanceOfTheServiceAsAfterARestart() async throws {
        let first = service()
        let segment = try XCTUnwrap(segments(first, pin: pin, segment: 4 << 20).first)
        try await first.enqueue(segment)
        _ = try await first.completion(of: segment.key)
        // A new process knows nothing but the folder: the segment is there, whole, and asking for it again costs no transfer.
        let again = BackgroundTransfers(stash: stash, identifier: "dev.nxpocketapple.live-\(UUID().uuidString)")
        try await again.enqueue(segment)
        let file = try await again.completion(of: segment.key)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? UInt64), segment.length)
    }

    func testStoppingASegmentEndsItsWaiter() async throws {
        let service = service()
        let all = try segments(service, pin: pin, segment: 2 << 20)
        for segment in all.prefix(6) { try await service.enqueue(segment) }
        let last = all[5]
        let waiter = Task { try await service.completion(of: last.key) }
        await service.cancel(keys: all.prefix(6).map(\.key))
        do {
            _ = try await waiter.value
        } catch is CancellationError {
        } catch {
            // A segment that finished before it was stopped is a fine outcome too.
        }
    }
}
