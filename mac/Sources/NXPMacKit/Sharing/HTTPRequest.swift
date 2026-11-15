import Foundation
import NXPocketKit

/// A request as the server reads it: a method, a path already cut into segments and decoded once, and the few headers it
/// looks at. Nothing else of what arrived is kept.
struct HTTPRequest: Equatable {
    var method: String
    var segments: [String]
    var headers: [String: String]
    var body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

enum HTTPParseResult: Equatable {
    case incomplete
    case request(HTTPRequest, consumed: Int)
    /// A copy of saves is coming: the head only (its body is read by the server, to a file, not held), how long the body is,
    /// and how many bytes of the buffer the head took.
    case upload(HTTPRequest, length: Int64, consumed: Int)
    case failure(status: Int)
}

/// The smallest HTTP/1.1 reader that serves this API, and no more: this is the part of the launcher that faces the
/// network, so everything it does not need is refused rather than handled. No query, no fragment, no chunked bodies, no
/// upgrade, no folded or repeated headers that matter, no body but a small one on a pairing request, and a copy of saves
/// on `PUT /v1/saves/<title ID>`, the one request that has a long body, whose length must be announced.
enum HTTPParser {
    static let maxLine = 2048
    static let maxHeaderBytes = 8192
    static let maxHeaders = 64
    static let maxBody = 2048
    static let methods: Set<String> = ["GET", "HEAD", "POST", "PUT"]
    /// Headers that may appear once. A repeated one is how a proxy and a server come to read a request differently.
    static let single: Set<String> = ["authorization", "range", "content-length", "content-type", "host"]
    static let refused: Set<String> = ["transfer-encoding", "expect", "upgrade", "te", "trailer"]

    static func parse(_ buffer: Data) -> HTTPParseResult {
        let terminator = Data("\r\n\r\n".utf8)
        guard let end = buffer.range(of: terminator) else {
            return buffer.count > maxHeaderBytes ? .failure(status: 431) : .incomplete
        }
        guard end.lowerBound <= maxHeaderBytes else { return .failure(status: 431) }
        guard let head = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else { return .failure(status: 400) }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst()
        guard requestLine.utf8.count <= maxLine else { return .failure(status: 414) }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return .failure(status: 400) }
        let method = String(parts[0])
        guard methods.contains(method) else { return .failure(status: 405) }
        guard parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else { return .failure(status: 505) }
        guard let segments = decode(target: String(parts[1])) else { return .failure(status: 400) }

        guard lines.count <= maxHeaders else { return .failure(status: 431) }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex, !line.hasPrefix(" "), !line.hasPrefix("\t") else {
                return .failure(status: 400)
            }
            let name = line[..<colon].lowercased()
            guard name.unicodeScalars.allSatisfy({ isToken($0) }) else { return .failure(status: 400) }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            guard !refused.contains(name) else { return .failure(status: 400) }
            if single.contains(name), headers[name] != nil { return .failure(status: 400) }
            // Only the first of the others is kept; they are never looked at.
            if headers[name] == nil { headers[name] = value }
        }
        if let connection = headers["connection"]?.lowercased(), connection.contains("upgrade") { return .failure(status: 400) }

        if method == "PUT" {
            // Nothing else is ever put: any other path is refused before its body is looked at.
            guard segments.count == 3, segments[0] == "v1", segments[1] == "saves" else { return .failure(status: 405) }
            guard let declared = headers["content-length"], declared.allSatisfy(\.isNumber), let number = Int64(declared), number >= 1 else {
                return .failure(status: 411)
            }
            guard number <= SaveUpload.maxBytes else { return .failure(status: 413) }
            return .upload(HTTPRequest(method: method, segments: segments, headers: headers, body: Data()), length: number,
                           consumed: end.upperBound - buffer.startIndex)
        }
        var length = 0
        if let declared = headers["content-length"] {
            guard let number = Int(declared), number >= 0, declared.allSatisfy(\.isNumber) else { return .failure(status: 400) }
            guard number <= maxBody else { return .failure(status: 413) }
            length = number
        }
        if method != "POST", length > 0 { return .failure(status: 400) }
        let bodyStart = end.upperBound
        guard buffer.endIndex - bodyStart >= length else { return .incomplete }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + length))
        return .request(HTTPRequest(method: method, segments: segments, headers: headers, body: body),
                        consumed: bodyStart - buffer.startIndex + length)
    }

    /// `/a/b%20c` → `["a", "b c"]`: split on `/` first, then each piece decoded once, so an encoded slash can never make
    /// a new segment and a double-encoded name stays encoded. Nil for a target with a query or fragment, a bad escape, a
    /// NUL, a slash, a backslash or a control character in a segment.
    static func decode(target: String) -> [String]? {
        guard target.hasPrefix("/"), target.utf8.count <= maxLine, !target.contains("?"), !target.contains("#") else { return nil }
        var segments: [String] = []
        for piece in target.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            guard isValidEscaping(String(piece)), let decoded = String(piece).removingPercentEncoding else { return nil }
            guard !decoded.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || $0 == "/" || $0 == "\\" }) else { return nil }
            segments.append(decoded)
        }
        return segments
    }

    /// `removingPercentEncoding` returns nil for a bad escape, and that is all it checks: this also refuses a `%` that is
    /// not followed by two hex digits, which some versions of Foundation let through.
    private static func isValidEscaping(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        var index = 0
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "%") {
                guard index + 2 < bytes.count, hex(bytes[index + 1]), hex(bytes[index + 2]) else { return false }
                index += 3
            } else {
                index += 1
            }
        }
        return true
    }

    private static func hex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }

    private static func isToken(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && (scalar.properties.isAlphabetic || (48...57).contains(scalar.value) || "!#$%&'*+-.^_`|~".unicodeScalars.contains(scalar))
    }

    /// What a `Range` header asks for. Only `bytes=N-` and `bytes=N-M` are honoured; anything else is read as no range.
    enum Range: Equatable {
        case whole
        case from(UInt64, through: UInt64?)
        case invalid
    }

    static func range(_ header: String?) -> Range {
        guard let header else { return .whole }
        guard header.hasPrefix("bytes="), !header.contains(",") else { return .whole }
        let spec = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard spec.count == 2, let first = UInt64(spec[0]) else { return .whole }
        if spec[1].isEmpty { return .from(first, through: nil) }
        guard let last = UInt64(spec[1]), last >= first else { return .invalid }
        return .from(first, through: last)
    }
}
