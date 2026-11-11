import XCTest

@testable import NXPocketKit

/// The certificate reader, exercised on DER built here: the shapes a real Apple certificate has (a version, a
/// serial, an issuer, a validity, a subject with a common name and an organizational unit) and the ones it does not.
final class X509Tests: XCTestCase {
    func testReadsTheSubjectTeamAndValidity() throws {
        let der = DERFixture.certificate(commonName: "Apple Development: Example (ABCDE12345)",
                                         team: "ABCDE12345",
                                         notBefore: "240101000000Z", notAfter: "270101000000Z")
        let certificate = try XCTUnwrap(X509Certificate.parse(der: der))
        XCTAssertEqual(certificate.commonName, "Apple Development: Example (ABCDE12345)")
        XCTAssertEqual(certificate.organizationalUnit, "ABCDE12345")
        XCTAssertEqual(certificate.notBefore, DERFixture.date(2024, 1, 1))
        XCTAssertEqual(certificate.notAfter, DERFixture.date(2027, 1, 1))
        XCTAssertEqual(certificate.sha256, FileDigest.sha256(of: der))
    }

    func testReadsAGeneralizedTime() throws {
        let der = DERFixture.certificate(notAfter: "20500101000000Z", generalized: true)
        let certificate = try XCTUnwrap(X509Certificate.parse(der: der))
        XCTAssertEqual(certificate.notAfter, DERFixture.date(2050, 1, 1))
    }

    func testReadsATwoDigitYearInTheNineteenHundreds() throws {
        let der = DERFixture.certificate(notAfter: "990101000000Z")
        XCTAssertEqual(X509Certificate.parse(der: der)?.notAfter, DERFixture.date(1999, 1, 1))
    }

    func testRefusesSomethingThatIsNotACertificate() {
        XCTAssertNil(X509Certificate.parse(der: Data("not a certificate".utf8)))
        XCTAssertNil(X509Certificate.parse(der: Data()))
        XCTAssertNil(X509Certificate.parse(der: Data([0x30, 0x03, 0x02, 0x01, 0x01])))
    }

    func testATruncatedCertificateDoesNotTrap() {
        let der = DERFixture.certificate()
        for cut in stride(from: 1, to: der.count, by: 7) {
            _ = X509Certificate.parse(der: der.prefix(cut))
        }
    }
}

/// A DER writer for the tests: enough of a certificate to exercise the reader, and nothing that pretends to be one.
enum DERFixture {
    static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: components)!
    }

    static func certificate(commonName: String = "Test",
                            team: String = "ABCDE12345",
                            notBefore: String = "240101000000Z",
                            notAfter: String = "270101000000Z",
                            generalized: Bool = false) -> Data {
        let name = sequence([
            set([sequence([oid([0x55, 0x04, 0x03]), utf8(commonName)])]),
            set([sequence([oid([0x55, 0x04, 0x0B]), utf8(team)])])
        ])
        let validity = sequence([time(notBefore, generalized: generalized), time(notAfter, generalized: generalized)])
        let tbs = sequence([
            explicit(0, integer(2)),
            integer(0x1234),
            sequence([oid([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B]), null()]),
            name,
            validity,
            name,
            bitString(Data(repeating: 0xAB, count: 8))
        ])
        return sequence([tbs,
                         sequence([oid([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B]), null()]),
                         bitString(Data(repeating: 0xCD, count: 16))])
    }

    static func sequence(_ items: [Data]) -> Data { tag(0x30, items.reduce(Data(), +)) }
    static func set(_ items: [Data]) -> Data { tag(0x31, items.reduce(Data(), +)) }
    static func integer(_ value: Int) -> Data { tag(0x02, Data([UInt8(value & 0xFF)])) }
    static func null() -> Data { tag(0x05, Data()) }
    static func oid(_ bytes: [UInt8]) -> Data { tag(0x06, Data(bytes)) }
    static func utf8(_ text: String) -> Data { tag(0x0C, Data(text.utf8)) }
    static func bitString(_ data: Data) -> Data { tag(0x03, Data([0x00]) + data) }

    static func time(_ text: String, generalized: Bool) -> Data {
        tag(generalized ? 0x18 : 0x17, Data(text.utf8))
    }

    static func explicit(_ number: UInt8, _ content: Data) -> Data { tag(0xA0 | number, content) }

    static func tag(_ tag: UInt8, _ content: Data) -> Data {
        var data = Data([tag])
        if content.count < 0x80 {
            data.append(UInt8(content.count))
        } else {
            var length = content.count
            var bytes: [UInt8] = []
            while length > 0 {
                bytes.insert(UInt8(length & 0xFF), at: 0)
                length >>= 8
            }
            data.append(0x80 | UInt8(bytes.count))
            data.append(contentsOf: bytes)
        }
        data.append(content)
        return data
    }
}
