import Foundation

/// Which addresses count as "on this network", and how a typed `host:port` is read.
public enum LocalNetworkAddress {
    /// Loopback, link-local, private (RFC 1918) and unique-local (`fc00::/7`) addresses, in IPv4 or IPv6 text. Anything
    /// else (a public address, the carrier-grade `100.64.0.0/10` a VPN such as Tailscale uses) is not local: remote
    /// access is out of scope, and the server drops such a peer before it speaks.
    public static func isLocal(_ address: String) -> Bool {
        var text = address
        if let zone = text.firstIndex(of: "%") { text = String(text[..<zone]) }
        if text.hasPrefix("[") && text.hasSuffix("]") { text = String(text.dropFirst().dropLast()) }
        if let v4 = ipv4(text) { return isLocal(v4: v4) }
        if let v6 = ipv6(text) { return isLocal(v6: v6) }
        return false
    }

    static func ipv4(_ text: String) -> [UInt8]? {
        var address = in_addr()
        guard inet_pton(AF_INET, text, &address) == 1 else { return nil }
        return withUnsafeBytes(of: address) { Array($0) }
    }

    static func ipv6(_ text: String) -> [UInt8]? {
        var address = in6_addr()
        guard inet_pton(AF_INET6, text, &address) == 1 else { return nil }
        return withUnsafeBytes(of: address) { Array($0) }
    }

    static func isLocal(v4 b: [UInt8]) -> Bool {
        switch (b[0], b[1]) {
        case (127, _), (10, _), (169, 254), (192, 168): return true
        case (172, 16...31): return true
        default: return false
        }
    }

    static func isLocal(v6 b: [UInt8]) -> Bool {
        if b.dropLast().allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }       // ::1
        if b[0] == 0xFE && (b[1] & 0xC0) == 0x80 { return true }                     // fe80::/10
        if (b[0] & 0xFE) == 0xFC { return true }                                      // fc00::/7
        // ::ffff:a.b.c.d is an IPv4 peer seen through a dual-stack socket.
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF { return isLocal(v4: Array(b[12..<16])) }
        return false
    }

    /// `host`, `host:port`, `1.2.3.4:port`, `[fe80::1%en0]:port`. The port defaults to `defaultPort`.
    public static func parse(_ typed: String, defaultPort: Int) -> (host: String, port: Int)? {
        let text = typed.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.count <= 255, !text.contains("/"), !text.contains("@"), !text.contains(" ") else { return nil }
        func port(_ value: Substring) -> Int? {
            guard let number = Int(value), (1...65_535).contains(number) else { return nil }
            return number
        }
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return nil }
            let host = String(text[text.index(after: text.startIndex)..<close])
            guard ipv6(host.split(separator: "%").first.map(String.init) ?? host) != nil else { return nil }
            let rest = text[text.index(after: close)...]
            if rest.isEmpty { return (host, defaultPort) }
            guard rest.hasPrefix(":"), let value = port(rest.dropFirst()) else { return nil }
            return (host, value)
        }
        if ipv6(text) != nil { return (text, defaultPort) }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 2, let host = parts.first, !host.isEmpty,
              host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
        if parts.count == 2 {
            guard let value = port(parts[1]) else { return nil }
            return (String(host), value)
        }
        return (String(host), defaultPort)
    }
}
