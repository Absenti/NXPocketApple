import CryptoKit
import Foundation

/// How a segment's server is trusted: by the hash of its key (the Mac) or by the system's judgement of its certificate (a web server).
public enum SegmentTrust: Equatable, Sendable {
    case system
    case pinned(String)

    public var token: String {
        switch self {
        case .system: return "system"
        case .pinned(let pin): return "pin:" + pin
        }
    }

    public init?(token: String) {
        if token == "system" { self = .system }
        else if token.hasPrefix("pin:"), FileDigest.isSHA256(String(token.dropFirst(4))) { self = .pinned(String(token.dropFirst(4))) }
        else { return nil }
    }
}

/// One piece of a file, asked for as a request of its own: bytes `first ..< first + length` of a file `total` bytes long.
public struct SegmentRequest: Sendable {
    /// Names the segment for good: the same one after the app was stopped and started again, which is how a segment that finished
    /// while the app was away is found again.
    public var key: String
    /// The request for the whole file, with the source's address and credentials. The range is added by the transport.
    public var request: URLRequest
    public var first: UInt64
    public var length: UInt64
    public var total: UInt64
    public var trust: SegmentTrust

    public init(key: String, request: URLRequest, first: UInt64, length: UInt64, total: UInt64, trust: SegmentTrust) {
        self.key = key
        self.request = request
        self.first = first
        self.length = length
        self.total = total
        self.trust = trust
    }
}

/// Fetches segments in a way that goes on while the app is not running: the system's background transfer service
/// (`BackgroundTransfers`). A stand-in in tests.
public protocol SegmentTransport: Sendable {
    /// Starts the segment, unless it is already on disk or already under way. Returns at once.
    func enqueue(_ segment: SegmentRequest) async throws
    /// The file holding the segment, once it is whole and has been checked against what was asked for. The caller owns the file and
    /// deletes it. Throws the source's error (`PackageSourceError`) when the server refused or the transfer failed.
    func completion(of key: String) async throws -> URL
    /// Stops the segments that have not finished. What already finished stays, to be used when the download is resumed.
    func cancel(keys: [String]) async
}

/// A source whose files can be fetched as ranges by the system's transfer service: the Mac and a web server (their requests are plain
/// HTTPS with an `Authorization` header). An SFTP connection is not one: it does not survive the app being suspended.
public protocol BackgroundReadable: PackageSource {
    /// The request for one file, from its start, and how its server is trusted.
    func segmentBase(titleID: String, revision: String, path: String) throws -> (request: URLRequest, trust: SegmentTrust)
}

/// A source whose big files come over the system's background transfer service, in segments, so a download goes on while the app is in
/// another app's shadow, or not running. Everything the downloader checks is unchanged: this only hands it the same bytes through
/// `read`, which is the one call it makes.
///
/// A file is cut at multiples of `segmentBytes`, and the next few segments are always already asked for, so the service has work
/// while the app sleeps. The app is woken when the service has no more, reads the segments that finished, and asks for more.
/// A resume that lands inside a segment reads that segment from its start and skips what is already on disk.
public final class SegmentedSource: PackageSource, @unchecked Sendable {
    /// 32 MiB: small enough that progress moves and a cut costs little, large enough that thousands of requests are not made for a game.
    public static let defaultSegmentBytes: UInt64 = 32 << 20
    /// How many segments are asked for ahead of the one being read.
    public static let defaultWindow = 24

    private let inner: BackgroundReadable
    private let transport: SegmentTransport
    private let segmentBytes: UInt64
    private let window: Int
    private let smallestFile: UInt64
    private let lock = NSLock()
    private var sizes: [String: [String: UInt64]] = [:]

    public var sourceID: String { inner.sourceID }

    /// Files up to `smallestFile` bytes are read the ordinary way: they are over before the app could be left.
    public init(inner: BackgroundReadable, transport: SegmentTransport, segmentBytes: UInt64 = SegmentedSource.defaultSegmentBytes,
                window: Int = SegmentedSource.defaultWindow, smallestFile: UInt64 = 4 << 20) {
        self.inner = inner
        self.transport = transport
        self.segmentBytes = max(segmentBytes, 1)
        self.window = max(window, 1)
        self.smallestFile = smallestFile
    }

    public func games() async throws -> [RemoteGame] { try await inner.games() }
    public func listing(titleID: String) async throws -> RemotePackageListing { try await inner.listing(titleID: titleID) }
    public func icon(titleID: String) async throws -> Data? { try await inner.icon(titleID: titleID) }

    public func read(titleID: String, revision: String, path: String, offset: UInt64) async throws -> RemoteBody {
        guard let size = try await fileSize(titleID: titleID, revision: revision, path: path), size > smallestFile else {
            return try await inner.read(titleID: titleID, revision: revision, path: path, offset: offset)
        }
        guard offset < size else { return RemoteBody(offset: offset, length: 0, chunks: AsyncThrowingStream { $0.finish() }) }
        let (request, trust) = try inner.segmentBase(titleID: titleID, revision: revision, path: path)
        let reader = SegmentReader(transport: transport, request: request, trust: trust, size: size, offset: offset,
                                   segmentBytes: segmentBytes, window: window,
                                   keyPrefix: Self.keyPrefix(sourceID: inner.sourceID, titleID: titleID, revision: revision, path: path))
        return RemoteBody(offset: offset, length: size - offset, chunks: AsyncThrowingStream(unfolding: { try await reader.next() }))
    }

    /// The size the source lists for the file, nil for a file it does not list (`package.json`, read before the listing is trusted).
    private func fileSize(titleID: String, revision: String, path: String) async throws -> UInt64? {
        let cacheKey = "\(titleID)|\(revision)"
        if let known = lock.withLock({ sizes[cacheKey] }) { return known[path] }
        let listing = try await inner.listing(titleID: titleID)
        guard listing.revision == revision else { throw PackageSourceError.changed }
        let table = Dictionary(listing.files.compactMap { $0.size >= 0 ? ($0.path, UInt64($0.size)) : nil }, uniquingKeysWith: { first, _ in first })
        lock.withLock { sizes[cacheKey] = table }
        return table[path]
    }

    /// `<source>-<title>-<revision>-<path hash>`: a segment's name is this and its index. A key is a file name.
    static func keyPrefix(sourceID: String, titleID: String, revision: String, path: String) -> String {
        let pathHash = FileDigest.sha256(of: Data(path.utf8)).prefix(10)
        let source = String(sourceID.unicodeScalars.map { scalar in
            scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == "-") ? Character(scalar) : "_"
        })
        return "\(source)-\(titleID.uppercased())-\(revision.prefix(12))-\(pathHash)"
    }

    /// Reads one file's segments in order, keeping the next few asked for. A class: the stream's closure and the cancellation share it.
    private final class SegmentReader: @unchecked Sendable {
        let transport: SegmentTransport
        let request: URLRequest
        let trust: SegmentTrust
        let size: UInt64
        let segmentBytes: UInt64
        let window: Int
        let keyPrefix: String
        let count: Int
        var index: Int
        var asked: Int
        /// Bytes of the first segment that are already on disk and are not handed over again.
        var skip: UInt64
        var handle: FileHandle?
        var currentFile: URL?
        let lock = NSLock()

        init(transport: SegmentTransport, request: URLRequest, trust: SegmentTrust, size: UInt64, offset: UInt64, segmentBytes: UInt64,
             window: Int, keyPrefix: String) {
            self.transport = transport
            self.request = request
            self.trust = trust
            self.size = size
            self.segmentBytes = segmentBytes
            self.window = window
            self.keyPrefix = keyPrefix
            count = Int((size + segmentBytes - 1) / segmentBytes)
            index = Int(offset / segmentBytes)
            asked = index
            skip = offset - UInt64(index) * segmentBytes
        }

        deinit {
            try? handle?.close()
            if let currentFile { try? FileManager.default.removeItem(at: currentFile) }
            // A download that is paused or dropped stops what it asked for and has not read. What finished stays for the resume.
            let keys = (index..<asked).map { "\(keyPrefix)-\($0)" }
            guard !keys.isEmpty else { return }
            let transport = transport
            Task { await transport.cancel(keys: keys) }
        }

        func key(_ index: Int) -> String { "\(keyPrefix)-\(index)" }

        func segment(_ index: Int) -> SegmentRequest {
            let first = UInt64(index) * segmentBytes
            return SegmentRequest(key: key(index), request: request, first: first, length: min(segmentBytes, size - first), total: size, trust: trust)
        }

        func next() async throws -> Data? {
            while true {
                if let handle {
                    if let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { return chunk }
                    try? handle.close()
                    self.handle = nil
                    if let currentFile { try? FileManager.default.removeItem(at: currentFile) }
                    currentFile = nil
                    index += 1
                    continue
                }
                guard index < count else { return nil }
                while asked < min(count, index + window) {
                    try await transport.enqueue(segment(asked))
                    asked += 1
                }
                try Task.checkCancellation()
                let url = try await transport.completion(of: key(index))
                let expected = segment(index).length
                let held = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? nil
                guard held == expected else {
                    try? FileManager.default.removeItem(at: url)
                    throw PackageSourceError.malformed("a part of the file is \(held.map(String.init) ?? "missing"), not \(expected) bytes long")
                }
                let opened = try FileHandle(forReadingFrom: url)
                currentFile = url
                if skip > 0 { try opened.seek(toOffset: skip); skip = 0 }
                handle = opened
            }
        }
    }
}
