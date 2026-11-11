import Foundation

/// The few fields of an X.509 certificate this project needs: the subject's common name and organizational unit
/// (the Apple team), the validity window, and the digest of the DER.
///
/// iOS has no public `SecCertificateCopyValues`, so the DER is walked here. Only the tags a certificate actually
/// uses are understood; anything else is skipped rather than guessed at.
public struct X509Certificate: Equatable, Sendable {
    public var commonName: String?
    public var organizationalUnit: String?
    public var notBefore: Date?
    public var notAfter: Date?
    public var sha256: String

    /// `2.5.4.3` (commonName) and `2.5.4.11` (organizationalUnitName), content octets only.
    static let commonNameOID: [UInt8] = [0x55, 0x04, 0x03]
    static let organizationalUnitOID: [UInt8] = [0x55, 0x04, 0x0B]

    public static func parse(der: Data) -> X509Certificate? {
        let top = TLVs(der)
        guard let certificate = top.children.first, certificate.tag == 0x30,
              let tbs = certificate.children.first, tbs.tag == 0x30 else { return nil }

        var fields = tbs.children
        if fields.first?.tag == 0xA0 { fields.removeFirst() }   // the explicit version
        guard fields.count >= 6 else { return nil }
        let validity = fields[3]
        let subject = fields[4]
        guard validity.tag == 0x30 else { return nil }

        let times = validity.children
        let notBefore = times.count > 0 ? time(times[0]) : nil
        let notAfter = times.count > 1 ? time(times[1]) : nil

        return X509Certificate(commonName: lookup(commonNameOID, in: subject),
                               organizationalUnit: lookup(organizationalUnitOID, in: subject),
                               notBefore: notBefore, notAfter: notAfter,
                               sha256: FileDigest.sha256(of: der))
    }

    static func lookup(_ oid: [UInt8], in name: TLV) -> String? {
        var found: String?
        walk(name) { attribute in
            guard found == nil, attribute.tag == 0x30, attribute.children.count == 2,
                  attribute.children[0].tag == 0x06,
                  [UInt8](attribute.children[0].content) == oid else { return }
            found = String(data: attribute.children[1].content, encoding: .utf8)
        }
        return found
    }

    /// Every TLV at any depth, so a name can be read without hard-coding its nesting.
    static func walk(_ node: TLV, visit: (TLV) -> Void) {
        for child in node.children {
            visit(child)
            walk(child, visit: visit)
        }
    }

    static func time(_ node: TLV) -> Date? {
        guard let text = String(data: node.content, encoding: .ascii) else { return nil }
        let digits = text.filter(\.isNumber)
        switch node.tag {
        case 0x17 where digits.count >= 12:   // UTCTime: YYMMDDHHMMSSZ
            let year = Int(digits.prefix(2)) ?? 0
            return date(year: year >= 50 ? 1900 + year : 2000 + year, digits: String(digits.dropFirst(2)))
        case 0x18 where digits.count >= 14:   // GeneralizedTime: YYYYMMDDHHMMSSZ
            return date(year: Int(digits.prefix(4)) ?? 0, digits: String(digits.dropFirst(4)))
        default:
            return nil
        }
    }

    private static func date(year: Int, digits: String) -> Date? {
        let numbers = digits.prefix(10).map { Int(String($0)) }
        guard numbers.count == 10, numbers.allSatisfy({ $0 != nil }) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = numbers[0]! * 10 + numbers[1]!
        components.day = numbers[2]! * 10 + numbers[3]!
        components.hour = numbers[4]! * 10 + numbers[5]!
        components.minute = numbers[6]! * 10 + numbers[7]!
        components.second = numbers[8]! * 10 + numbers[9]!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: components)
    }
}

/// One DER tag-length-value, with its children already parsed when its content is itself a list of them.
public struct TLV: Sendable {
    public var tag: UInt8
    public var content: Data
    public var children: [TLV]

    init(tag: UInt8, content: Data, children: [TLV]) {
        self.tag = tag
        self.content = content
        self.children = children
    }
}

/// A flat DER reader: `TLVs(data)` gives the elements of `data`, each with its own children filled in.
public struct TLVs {
    public var elements: [TLV]

    public init(_ data: Data) {
        elements = TLVs.parse(data)
    }

    public var children: [TLV] { elements }

    static func isConstructed(_ tag: UInt8) -> Bool { tag & 0x20 != 0 }

    /// Deeper than any certificate nests. A forged one nested further is read no deeper, rather than recursing until
    /// the stack runs out.
    static let maximumDepth = 32

    static func parse(_ data: Data, depth: Int = 0) -> [TLV] {
        var result: [TLV] = []
        var index = data.startIndex
        let end = data.endIndex
        while index < end {
            guard let (tlv, next) = parseOne(data, at: index, depth: depth) else { break }
            result.append(tlv)
            index = next
        }
        return result
    }

    static func parseOne(_ data: Data, at start: Data.Index, depth: Int = 0) -> (TLV, Data.Index)? {
        guard start < data.endIndex else { return nil }
        let tag = data[start]
        var index = start + 1
        guard index < data.endIndex else { return nil }
        var length = Int(data[index])
        index += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count > 0, count <= 4, index + count <= data.endIndex else { return nil }
            length = 0
            for _ in 0..<count {
                length = length << 8 | Int(data[index])
                index += 1
            }
        }
        guard length >= 0, index + length <= data.endIndex else { return nil }
        let content = data[index..<(index + length)]
        let children = isConstructed(tag) && depth < maximumDepth ? parse(content, depth: depth + 1) : []
        return (TLV(tag: tag, content: Data(content), children: children), index + length)
    }
}
