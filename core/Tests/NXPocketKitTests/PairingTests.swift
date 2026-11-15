import XCTest

@testable import NXPocketKit

final class PairingAndAddressTests: XCTestCase {
    // MARK: the code

    func testACodeIsSixDigits() {
        for _ in 0..<200 {
            let code = PairingProof.makeCode()
            XCTAssertEqual(code.count, 7)
            XCTAssertEqual(code[code.index(code.startIndex, offsetBy: 3)], "-")
            XCTAssertNotNil(PairingProof.normalise(code))
            XCTAssertTrue(code.filter { $0 != "-" }.allSatisfy(\.isNumber))
        }
        XCTAssertGreaterThan(Set((0..<50).map { _ in PairingProof.makeCode() }).count, 40, "they are not repeated")
    }

    func testATypedCodeIsForgivenWhatAPersonGetsWrong() {
        XCTAssertEqual(PairingProof.normalise("123-456"), "123456")
        XCTAssertEqual(PairingProof.normalise("123456"), "123456")
        XCTAssertEqual(PairingProof.normalise(" 123 456 "), "123456")
        XCTAssertEqual(PairingProof.normalise("12\u{2013}3456"), "123456", "an en dash a phone keyboard made")
        XCTAssertEqual(PairingProof.normalise("O0l-1I1"), "001111", "O is 0, I and l are 1")
        XCTAssertNil(PairingProof.normalise("12345"), "too short")
        XCTAssertNil(PairingProof.normalise("1234567"), "too long")
        XCTAssertNil(PairingProof.normalise("12345a"))
        XCTAssertNil(PairingProof.normalise("12345!"))
        XCTAssertNil(PairingProof.normalise(""))
    }

    // MARK: the proofs

    func testTheProofsDependOnEveryInput() throws {
        let key = try XCTUnwrap(PairingProof.key(code: "123-456", pin: "pin"))
        let proof = PairingProof.clientProof(key: key, pin: "pin", nonce: "n", name: "Phone")
        XCTAssertTrue(PairingProof.isValid(proof, key: key, role: "c", pin: "pin", nonce: "n", subject: "Phone"))
        XCTAssertFalse(PairingProof.isValid(proof, key: key, role: "c", pin: "other", nonce: "n", subject: "Phone"), "bound to the key seen")
        XCTAssertFalse(PairingProof.isValid(proof, key: key, role: "c", pin: "pin", nonce: "m", subject: "Phone"))
        XCTAssertFalse(PairingProof.isValid(proof, key: key, role: "c", pin: "pin", nonce: "n", subject: "Other"))
        let other = try XCTUnwrap(PairingProof.key(code: "123-457", pin: "pin"))
        XCTAssertFalse(PairingProof.isValid(proof, key: other, role: "c", pin: "pin", nonce: "n", subject: "Phone"), "another code")
        let rebound = try XCTUnwrap(PairingProof.key(code: "123-456", pin: "another pin"))
        XCTAssertFalse(PairingProof.isValid(proof, key: rebound, role: "c", pin: "pin", nonce: "n", subject: "Phone"))
        XCTAssertFalse(PairingProof.isValid("zz", key: key, role: "c", pin: "pin", nonce: "n", subject: "Phone"))
        XCTAssertFalse(PairingProof.isValid("", key: key, role: "c", pin: "pin", nonce: "n", subject: "Phone"))
    }

    func testAFieldCannotBeMovedAcrossAnotherInAProof() throws {
        let key = try XCTUnwrap(PairingProof.key(code: "123-456", pin: "p"))
        // With length-prefixed fields, "ab"+"c" and "a"+"bc" are different messages.
        XCTAssertNotEqual(PairingProof.clientProof(key: key, pin: "p", nonce: "ab", name: "c"),
                          PairingProof.clientProof(key: key, pin: "p", nonce: "a", name: "bc"))
    }

    func testTheKeyIsTheSameForTheSameCodeInAnySpelling() throws {
        let one = try XCTUnwrap(PairingProof.key(code: "123 456", pin: "p"))
        let two = try XCTUnwrap(PairingProof.key(code: "123456", pin: "p"))
        XCTAssertEqual(PairingProof.clientProof(key: one, pin: "p", nonce: "n", name: "x"), PairingProof.clientProof(key: two, pin: "p", nonce: "n", name: "x"))
        XCTAssertNil(PairingProof.key(code: "nope", pin: "p"))
    }

    // MARK: the QR code

    func testTheQRKeyIsBoundToTheSecretAndTheKeySeen() throws {
        let secret = PairingProof.makeSecret()
        XCTAssertTrue(PairingProof.isSecret(secret))
        let key = try XCTUnwrap(PairingProof.key(secret: secret, pin: "pin"))
        let proof = PairingProof.clientProof(key: key, pin: "pin", nonce: "n", name: "Phone")
        XCTAssertTrue(PairingProof.isValid(proof, key: key, role: "c", pin: "pin", nonce: "n", subject: "Phone"))
        let rebound = try XCTUnwrap(PairingProof.key(secret: secret, pin: "other"))
        XCTAssertFalse(PairingProof.isValid(proof, key: rebound, role: "c", pin: "pin", nonce: "n", subject: "Phone"))
        let another = try XCTUnwrap(PairingProof.key(secret: PairingProof.makeSecret(), pin: "pin"))
        XCTAssertFalse(PairingProof.isValid(proof, key: another, role: "c", pin: "pin", nonce: "n", subject: "Phone"))
        XCTAssertNil(PairingProof.key(secret: "short", pin: "pin"))
        XCTAssertNil(PairingProof.key(secret: String(repeating: "g", count: 32), pin: "pin"))
        XCTAssertGreaterThan(Set((0..<20).map { _ in PairingProof.makeSecret() }).count, 19)
    }

    func testALinkSaysWhatTheQRCodeSaysAndNothingElseIsBelieved() throws {
        let pin = String(repeating: "ab", count: 32)
        let secret = PairingProof.makeSecret()
        let link = PairLink(address: "Momos-Mac.local", port: 49217, pin: pin, secret: secret, name: "Momo's Mac")
        let url = try XCTUnwrap(link.url)
        XCTAssertEqual(PairLink(url: url), link, "what is shown is what is read")

        func parsed(_ query: String, host: String = "pair", scheme: String = "nxpocket") -> PairLink? {
            URL(string: "\(scheme)://\(host)?\(query)").flatMap(PairLink.init(url:))
        }
        let good = "h=mac.local&p=1234&k=\(pin)&s=\(secret)&n=Mac"
        XCTAssertNotNil(parsed(good))
        XCTAssertNil(parsed(good, host: "play"), "another action")
        XCTAssertNil(parsed(good, scheme: "https"))
        XCTAssertNil(parsed("h=mac.local&p=0&k=\(pin)&s=\(secret)"), "port")
        XCTAssertNil(parsed("h=mac.local&p=70000&k=\(pin)&s=\(secret)"))
        XCTAssertNil(parsed("h=mac.local&p=1234&k=zz&s=\(secret)"), "key")
        XCTAssertNil(parsed("h=mac.local&p=1234&k=\(pin)&s=1234"), "secret")
        XCTAssertNil(parsed("p=1234&k=\(pin)&s=\(secret)"), "no address")
        XCTAssertNil(parsed("h=a/b&p=1234&k=\(pin)&s=\(secret)"), "an address cannot add a path")
        XCTAssertNil(parsed("h=a%40b&p=1234&k=\(pin)&s=\(secret)"), "nor a user")
        XCTAssertNil(parsed("h=&p=1234&k=\(pin)&s=\(secret)"))
        let long = String(repeating: "x", count: 500)
        XCTAssertEqual(parsed("h=mac.local&p=1234&k=\(pin)&s=\(secret)&n=\(long)")?.name.count, 64, "a name is cut")
    }

    // MARK: the number to compare

    func testTheNumberDependsOnTheKeyAndBothNonces() {
        let a = String(repeating: "1a", count: 16), b = String(repeating: "2b", count: 16)
        let number = PairingProof.number(pin: "pin", phoneNonce: a, macNonce: b)
        XCTAssertEqual(number.count, 7)
        XCTAssertEqual(number[number.index(number.startIndex, offsetBy: 3)], " ")
        XCTAssertTrue(number.filter { $0 != " " }.allSatisfy(\.isNumber))
        XCTAssertEqual(number, PairingProof.number(pin: "pin", phoneNonce: a, macNonce: b))
        XCTAssertNotEqual(number, PairingProof.number(pin: "pin of a relay", phoneNonce: a, macNonce: b), "a relay has another key")
        XCTAssertNotEqual(number, PairingProof.number(pin: "pin", phoneNonce: b, macNonce: a), "the nonces are not interchangeable")
        XCTAssertNotEqual(number, PairingProof.number(pin: "pin", phoneNonce: a, macNonce: a))
    }

    func testACommitmentHoldsOnlyTheNonceItWasMadeFrom() {
        let nonce = PairingProof.nonce()
        let commit = PairingProof.commit(nonce: nonce, name: "Phone")
        XCTAssertTrue(FileDigest.isSHA256(commit))
        XCTAssertEqual(commit, PairingProof.commit(nonce: nonce, name: "Phone"))
        XCTAssertNotEqual(commit, PairingProof.commit(nonce: PairingProof.nonce(), name: "Phone"))
        XCTAssertNotEqual(commit, PairingProof.commit(nonce: nonce, name: "Other"), "the name is committed to as well")
    }

    func testAPinIsShownInGroupsOfFour() {
        XCTAssertEqual(TLSPin.display(String(repeating: "ab12", count: 16)), Array(repeating: "ab12", count: 8).joined(separator: "-"))
    }

    // MARK: addresses

    func testWhichAddressesAreOnTheLocalNetwork() {
        for local in ["127.0.0.1", "10.0.0.5", "10.255.255.255", "172.16.0.1", "172.31.255.1", "192.168.1.20", "169.254.3.4", "::1",
                      "fe80::1", "fe80::1%en0", "fd12:3456::1", "fc00::1", "::ffff:192.168.1.5", "[fe80::2]"] {
            XCTAssertTrue(LocalNetworkAddress.isLocal(local), local)
        }
        for remote in ["8.8.8.8", "1.1.1.1", "172.15.0.1", "172.32.0.1", "100.64.0.1", "100.100.1.1", "192.169.1.1", "11.0.0.1", "2001:db8::1",
                       "2606:4700::1", "::ffff:8.8.8.8", "", "example.com", "192.168.1", "192.168.1.300", "fe00::1"] {
            XCTAssertFalse(LocalNetworkAddress.isLocal(remote), remote)
        }
    }

    func testATypedAddressIsReadOrRefused() throws {
        func read(_ text: String) -> String? { LocalNetworkAddress.parse(text, defaultPort: 49217).map { "\($0.host)|\($0.port)" } }
        XCTAssertEqual(read("MacBook.local"), "MacBook.local|49217")
        XCTAssertEqual(read("MacBook.local:5000"), "MacBook.local|5000")
        XCTAssertEqual(read("192.168.1.5:49300"), "192.168.1.5|49300")
        XCTAssertEqual(read("  192.168.1.5  "), "192.168.1.5|49217")
        XCTAssertEqual(read("[fe80::1%en0]:49300"), "fe80::1%en0|49300")
        XCTAssertEqual(read("fe80::1"), "fe80::1|49217")
        for bad in ["", "host:0", "host:99999", "host:abc", "ho st", "http://host", "user@host", "host/path", "[::1", "a:b:c", ":5000", "host:5000:1"] {
            XCTAssertNil(read(bad), bad)
        }
    }

    // MARK: requests and icons

    func testAPathNameCanNeverAddASegmentAQueryOrAFragment() throws {
        let request = try PinnedHTTPSSource.makeRequest(host: "127.0.0.1", port: 4000,
                                                        segments: ["v1", "games", "A", "R", "files", "a b?x=1#frag", "..", "%2e", "é"], token: "t")
        let url = try XCTUnwrap(request.url).absoluteString
        XCTAssertEqual(url, "https://127.0.0.1:4000/v1/games/A/R/files/a%20b%3Fx%3D1%23frag/../%252e/%C3%A9",
                       "each name is encoded on its own; `..` stays a name the server will not match")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer t")
        XCTAssertNil(try PinnedHTTPSSource.makeRequest(host: "127.0.0.1", port: 1, segments: ["v1"], token: nil).value(forHTTPHeaderField: "Authorization"))
    }

    func testOnlyASmallPNGIsAnIcon() {
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13]) + Data("IHDR".utf8)
        func header(_ width: UInt32, _ height: UInt32) -> Data {
            var data = png
            for value in [width, height] { data.append(contentsOf: withUnsafeBytes(of: value.bigEndian) { Array($0) }) }
            return data + Data(count: 100)
        }
        XCTAssertTrue(PNGHeader.isAcceptableIcon(header(512, 512)))
        XCTAssertFalse(PNGHeader.isAcceptableIcon(header(0, 512)))
        XCTAssertFalse(PNGHeader.isAcceptableIcon(header(1025, 10)), "a header that promises a huge image is not decoded")
        XCTAssertFalse(PNGHeader.isAcceptableIcon(header(1_000_000, 1_000_000)))
        png[0] = 0
        XCTAssertFalse(PNGHeader.isAcceptableIcon(header(10, 10)))
        XCTAssertFalse(PNGHeader.isAcceptableIcon(Data(count: SharingLimits.iconBytes + 1)))
        XCTAssertFalse(PNGHeader.isAcceptableIcon(Data()))
    }

    func testAContentRangeIsReadStrictly() throws {
        func range(_ value: String) -> String? {
            let response = HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 206, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Range": value])!
            return PinnedHTTPSSource.contentRange(response).map { "\($0.first)-\($0.last)/\($0.total)" }
        }
        XCTAssertEqual(range("bytes 100-199/1000"), "100-199/1000")
        for bad in ["bytes 100-99/1000", "bytes 100-1000/1000", "bytes */1000", "items 1-2/3", "bytes 1-2", "bytes a-b/c", ""] {
            XCTAssertNil(range(bad), bad)
        }
    }
}
