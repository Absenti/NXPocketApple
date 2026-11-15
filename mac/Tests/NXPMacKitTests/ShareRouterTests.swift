import XCTest
import NXPocketKit

@testable import NXPMacKit

/// The server's rules without a socket: what the parser refuses, what the router answers, who is let in and for how long.
final class ShareRouterTests: XCTestCase {
    private var workspace: URL!
    private var built: URL!
    private var devices: PairedDevices!
    private var library: SharedLibrary!
    private var router: ShareRouter!
    private var token = ""
    private var revision = ""
    private let titleID = ShareFixture.titleID
    private let pin = "pin-of-the-real-mac"

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory.appendingPathComponent("nxpocket-router-\(UUID().uuidString)", isDirectory: true)
        built = workspace.appendingPathComponent("built", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try ShareFixture.build(in: built, scratch: workspace, aoc: ["0.img": 2000])
        devices = PairedDevices(folder: workspace.appendingPathComponent("keys"))
        library = SharedLibrary(folder: built, cacheLife: 30, busy: { [] })
        router = ShareRouter(library: library, devices: devices, pairing: PairingSessions(pin: pin), limiter: RateLimiter(), pin: pin, name: "Test Mac")
        token = try devices.add(name: "Phone").token
        revision = try XCTUnwrap(library.game(titleID: titleID)).revision
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: workspace) }

    private func request(_ line: String, headers: [String] = [], token: String? = nil, body: String = "") -> HTTPRequest? {
        var lines = [line, "Host: x"] + headers
        if let token { lines.append("Authorization: Bearer \(token)") }
        let raw = lines.joined(separator: "\r\n") + "\r\n\r\n" + body
        guard case .request(let parsed, _) = HTTPParser.parse(Data(raw.utf8)) else { return nil }
        return parsed
    }

    private func status(_ target: String, method: String = "GET", token: String? = nil, headers: [String] = [], peer: String = "192.168.1.20") throws -> Int {
        let parsed = try XCTUnwrap(request("\(method) \(target) HTTP/1.1", headers: headers, token: token), target)
        let response = router.respond(to: parsed, peer: peer)
        if case .file(let file, _, _) = response.body { file.close() }
        return response.status
    }

    private func filePath(_ path: String) -> String { "/v1/games/\(titleID)/\(revision)/files/\(path)" }

    // MARK: the parser

    func testTheParserRefusesWhatTheServerDoesNotNeed() {
        let long = String(repeating: "a", count: 3000)
        let many = (0..<70).map { "X-\($0): 1" }.joined(separator: "\r\n")
        let cases: [(String, Int)] = [
            ("GET /v1/\(long) HTTP/1.1\r\nHost: x\r\n\r\n", 414),
            ("GET /v1/hello HTTP/1.1\r\nHost: x\r\nX-Big: \(String(repeating: "b", count: 9000))\r\n\r\n", 431),
            ("GET /v1/hello HTTP/1.1\r\nHost: x\r\n\(many)\r\n\r\n", 431),
            ("DELETE /v1/games HTTP/1.1\r\nHost: x\r\n\r\n", 405),
            ("PUT /v1/games HTTP/1.1\r\nHost: x\r\n\r\n", 405),
            ("GET /v1/hello HTTP/2.0\r\nHost: x\r\n\r\n", 505),
            ("GET /v1/hello?x=1 HTTP/1.1\r\nHost: x\r\n\r\n", 400),
            ("GET /v1/hello#top HTTP/1.1\r\nHost: x\r\n\r\n", 400),
            ("GET /v1/%zz HTTP/1.1\r\nHost: x\r\n\r\n", 400),
            ("GET /v1/%2Fetc HTTP/1.1\r\nHost: x\r\n\r\n", 400),
            ("GET /v1/%5Cwindows HTTP/1.1\r\nHost: x\r\n\r\n", 400),
            ("GET /v1/a%00b HTTP/1.1\r\nHost: x\r\n\r\n", 400),
            ("GET /v1/a%0Ab HTTP/1.1\r\nHost: x\r\n\r\n", 400),
            ("GET /v1/% HTTP/1.1\r\nHost: x\r\n\r\n", 400),
            ("GET http://x/v1/hello HTTP/1.1\r\nHost: x\r\n\r\n", 400),
            ("GET /v1/hello HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer a\r\nAuthorization: Bearer b\r\n\r\n", 400),
            ("GET /v1/hello HTTP/1.1\r\nHost: x\r\nRange: bytes=0-\r\nRange: bytes=1-\r\n\r\n", 400),
            ("GET /v1/hello HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n", 400),
            ("GET /v1/hello HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\n\r\n", 400),
            ("GET /v1/hello HTTP/1.1\r\nHost: x\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n", 400),
            ("GET /v1/hello HTTP/1.1\r\nHost: x\r\nX-A: 1\r\n folded\r\n\r\n", 400),
            ("GET /v1/hello HTTP/1.1\r\nHost: x\r\nno colon here\r\n\r\n", 400),
            ("GET /v1/hello HTTP/1.1\r\nHost: x\r\nBad Name: 1\r\n\r\n", 400),
            ("GET /v1/hello HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\n\r\nbody", 400),
            ("POST /v1/pair HTTP/1.1\r\nHost: x\r\nContent-Length: 999999\r\n\r\n", 413),
            ("POST /v1/pair HTTP/1.1\r\nHost: x\r\nContent-Length: -1\r\n\r\n", 400),
            ("POST /v1/pair HTTP/1.1\r\nHost: x\r\nContent-Length: 1x\r\n\r\n", 400),
            ("GET /v1/hello\r\nHost: x\r\n\r\n", 400)
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(HTTPParser.parse(Data(raw.utf8)), .failure(status: expected), String(raw.prefix(60)).debugDescription)
        }
    }

    func testTheParserWaitsForTheRestOfARequest() {
        XCTAssertEqual(HTTPParser.parse(Data("GET /v1/hello HTT".utf8)), .incomplete)
        XCTAssertEqual(HTTPParser.parse(Data("POST /v1/pair HTTP/1.1\r\nContent-Length: 10\r\n\r\n12345".utf8)), .incomplete)
        XCTAssertEqual(HTTPParser.parse(Data(String(repeating: "a", count: 9000).utf8)), .failure(status: 431), "no end of headers in 8 KB")
    }

    func testAPathIsDecodedOnceAndSegmentBySegment() {
        XCTAssertEqual(HTTPParser.decode(target: "/v1/games/%41%42"), ["v1", "games", "AB"])
        XCTAssertEqual(HTTPParser.decode(target: "/a/b%20c/d"), ["a", "b c", "d"])
        XCTAssertEqual(HTTPParser.decode(target: "/%252e%252e/x"), ["%2e%2e", "x"], "a double-encoded name stays encoded")
        XCTAssertEqual(HTTPParser.decode(target: "/%2e%2e/x"), ["..", "x"], "decoded, and then a name nothing matches")
        XCTAssertEqual(HTTPParser.decode(target: "/caf%C3%A9"), ["caf\u{E9}"])
        XCTAssertNil(HTTPParser.decode(target: "/%C3%28"), "bytes that are not UTF-8")
    }

    func testRangeHeaders() {
        XCTAssertEqual(HTTPParser.range(nil), .whole)
        XCTAssertEqual(HTTPParser.range("bytes=100-"), .from(100, through: nil))
        XCTAssertEqual(HTTPParser.range("bytes=100-199"), .from(100, through: 199))
        XCTAssertEqual(HTTPParser.range("bytes=200-100"), .invalid)
        XCTAssertEqual(HTTPParser.range("bytes=0-1,5-9"), .whole, "several ranges are read as none")
        XCTAssertEqual(HTTPParser.range("bytes=-500"), .whole, "a suffix range is read as none")
        XCTAssertEqual(HTTPParser.range("items=1-"), .whole)
    }

    // MARK: who gets in

    func testOnlyHelloAndPairNeedNoToken() throws {
        XCTAssertEqual(try status("/v1/hello"), 200)
        let everything = ["/v1/games", "/v1/games/\(titleID)", "/v1/games/\(titleID)/icon", filePath("package.json"), filePath("romfs.img")]
        for target in everything {
            XCTAssertEqual(try status(target, peer: "10.9.0.\(target.count)"), 401, target)
            XCTAssertEqual(try status(target, token: String(repeating: "f", count: 64), peer: "10.0.0.\(target.count)"), 401, target)
            XCTAssertEqual(try status(target, token: token, peer: "10.1.0.\(target.count)"), 200, target)
        }
        XCTAssertEqual(try status("/v1/games", method: "POST", token: token, peer: "10.8.0.1"), 405, "there is no verb that writes")
        XCTAssertEqual(try status("/v1/games", method: "HEAD", token: token, peer: "10.8.0.2"), 200)
    }

    func testARevokedTokenAnswersLikeAnyOther() throws {
        let device = try XCTUnwrap(devices.all.first)
        devices.revoke(id: device.id)
        XCTAssertEqual(try status("/v1/games", token: token), 401)
    }

    func testATokenUnusedForNinetyDaysIsNoLongerGood() throws {
        let later = Date().addingTimeInterval(PairedDevices.idleLimit + 60)
        XCTAssertNil(devices.authenticate(token, now: later))
        XCTAssertTrue(devices.all.isEmpty, "and the entry goes")
        let fresh = try devices.add(name: "New", now: Date()).token
        XCTAssertNotNil(devices.authenticate(fresh, now: Date().addingTimeInterval(PairedDevices.idleLimit - 60)))
    }

    func testFiveWrongTokensFromOneAddressBlockItForAMinute() throws {
        let now = Date()
        for _ in 0..<5 {
            let parsed = try XCTUnwrap(request("GET /v1/games HTTP/1.1", token: String(repeating: "0", count: 64)))
            XCTAssertEqual(router.respond(to: parsed, peer: "192.168.1.50", now: now).status, 401)
        }
        let good = try XCTUnwrap(request("GET /v1/games HTTP/1.1", token: token))
        XCTAssertEqual(router.respond(to: good, peer: "192.168.1.50", now: now.addingTimeInterval(1)).status, 429, "even with the right token")
        XCTAssertEqual(router.respond(to: good, peer: "192.168.1.51", now: now.addingTimeInterval(1)).status, 200, "another address is not blocked")
        XCTAssertEqual(router.respond(to: good, peer: "192.168.1.50", now: now.addingTimeInterval(61)).status, 200, "a minute later it is")
    }

    func testTheConnectionGateCapsEachAddressAndTheTotal() {
        let gate = ConnectionGate()
        for _ in 0..<ConnectionGate.perAddress { XCTAssertTrue(gate.admit("10.0.0.1")) }
        XCTAssertFalse(gate.admit("10.0.0.1"), "four from one address")
        XCTAssertTrue(gate.admit("10.0.0.2"))
        gate.release("10.0.0.1")
        XCTAssertTrue(gate.admit("10.0.0.1"))
        var address = 10
        while gate.active < ConnectionGate.total { _ = gate.admit("10.0.1.\(address)"); address += 1 }
        XCTAssertFalse(gate.admit("10.0.9.9"), "sixteen in all")
    }

    // MARK: pairing at the router

    private func pairRequest(code: String, pin proofPin: String, name: String = "Phone", nonce: String = String(repeating: "ab", count: 16)) throws -> HTTPRequest {
        let key = try XCTUnwrap(PairingProof.key(code: code, pin: proofPin))
        let body = try JSONSerialization.data(withJSONObject: ["name": name, "nonce": nonce,
                                                               "proof": PairingProof.clientProof(key: key, pin: proofPin, nonce: nonce, name: name)])
        let text = String(decoding: body, as: UTF8.self)
        return try XCTUnwrap(request("POST /v1/pair HTTP/1.1", headers: ["Content-Length: \(body.count)"], body: text))
    }

    func testAPairingThroughARelayWithAnotherKeyFails() throws {
        let offer = try XCTUnwrap(router.pairing.begin())
        // The phone saw the relay's key, so its proof is bound to that, not to the Mac's.
        let response = router.respond(to: try pairRequest(code: offer.code, pin: "pin-of-a-relay"), peer: "192.168.1.9")
        XCTAssertEqual(response.status, 401)
        XCTAssertEqual(devices.all.count, 1, "no phone was added (the one from setUp)")
        let right = router.respond(to: try pairRequest(code: offer.code, pin: pin), peer: "192.168.1.9")
        XCTAssertEqual(right.status, 200, "the real phone can still pair: one wrong proof does not burn the code")
    }

    func testThePairingAnswerProvesTheMacKnowsTheCode() throws {
        let offer = try XCTUnwrap(router.pairing.begin())
        let nonce = String(repeating: "cd", count: 16)
        let response = router.respond(to: try pairRequest(code: offer.code, pin: pin, nonce: nonce), peer: "192.168.1.9")
        guard case .data(let data) = response.body, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String, let proof = json["proof"] as? String else { return XCTFail("no token") }
        let key = try XCTUnwrap(PairingProof.key(code: offer.code, pin: pin))
        XCTAssertTrue(PairingProof.isValid(proof, key: key, role: "s", pin: pin, nonce: nonce, subject: token))
        XCTAssertFalse(PairingProof.isValid(proof, key: key, role: "s", pin: pin, nonce: nonce, subject: token + "0"))
        XCTAssertFalse(PairingProof.isValid(proof, key: key, role: "c", pin: pin, nonce: nonce, subject: token), "a server proof is not a client proof")
    }

    func testACodeExpiresAfterTwoMinutes() throws {
        let offer = try XCTUnwrap(router.pairing.begin(now: Date()))
        let late = Date().addingTimeInterval(PairingSessions.lifetime + 1)
        let response = router.respond(to: try pairRequest(code: offer.code, pin: pin), peer: "192.168.1.9", now: late)
        XCTAssertEqual(response.status, 401)
    }

    func testTenPairingAttemptsAMinuteInAll() throws {
        let now = Date()
        for index in 0..<RateLimiter.pairingPerMinute {
            let response = router.respond(to: try pairRequest(code: "123-456", pin: pin), peer: "192.168.1.\(index + 100)", now: now)
            XCTAssertEqual(response.status, 401)
        }
        let response = router.respond(to: try pairRequest(code: "123-456", pin: pin), peer: "192.168.1.200", now: now)
        XCTAssertEqual(response.status, 429)
    }

    func testAMalformedPairingRequestIsRefused() throws {
        _ = router.pairing.begin()
        let body = "{\"name\":\"x\"}"
        let parsed = try XCTUnwrap(request("POST /v1/pair HTTP/1.1", headers: ["Content-Length: \(body.utf8.count)"], body: body))
        XCTAssertEqual(router.respond(to: parsed, peer: "192.168.1.9").status, 400)
    }

    // MARK: pairing by QR code and by number

    private func post(_ path: String, _ object: [String: Any], peer: String = "192.168.1.9", now: Date = Date()) throws -> ShareResponse {
        let body = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        let parsed = try XCTUnwrap(request("POST /v1/\(path) HTTP/1.1", headers: ["Content-Length: \(body.utf8.count)"], body: body))
        return router.respond(to: parsed, peer: peer, now: now)
    }

    private func json(_ response: ShareResponse) -> [String: Any] {
        guard case .data(let data) = response.body else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func testTheQRSecretPairsLikeTheCodeDoes() throws {
        let offer = try XCTUnwrap(router.pairing.begin())
        let key = try XCTUnwrap(PairingProof.key(secret: offer.secret, pin: pin))
        let nonce = String(repeating: "ef", count: 16)
        let response = try post("pair", ["name": "Phone", "nonce": nonce, "proof": PairingProof.clientProof(key: key, pin: pin, nonce: nonce, name: "Phone")])
        XCTAssertEqual(response.status, 200)
        let answer = json(response)
        let token = try XCTUnwrap(answer["token"] as? String)
        XCTAssertTrue(PairingProof.isValid(try XCTUnwrap(answer["proof"] as? String), key: key, role: "s", pin: pin, nonce: nonce, subject: token),
                      "the answer is proved with the key the phone used")
        XCTAssertNil(router.pairing.current, "one pairing closes the window")
    }

    func testAQRSecretFromAnotherWindowIsRefused() throws {
        let old = try XCTUnwrap(router.pairing.begin())
        _ = router.pairing.begin()
        let key = try XCTUnwrap(PairingProof.key(secret: old.secret, pin: pin))
        let nonce = String(repeating: "ef", count: 16)
        let response = try post("pair", ["name": "Phone", "nonce": nonce, "proof": PairingProof.clientProof(key: key, pin: pin, nonce: nonce, name: "Phone")])
        XCTAssertEqual(response.status, 401)
    }

    /// The phone's side of the number comparison, step by step.
    private struct Phone {
        var nonce = PairingProof.nonce()
        var name = "Phone"
        var commit: String { PairingProof.commit(nonce: nonce, name: name) }
    }

    func testANumberPairingNeedsBothThePhonesSameAndTheMacsAllow() throws {
        _ = router.pairing.begin()
        let phone = Phone()
        let requested = try post("pair/request", ["name": phone.name, "commit": phone.commit])
        XCTAssertEqual(requested.status, 200)
        let macNonce = try XCTUnwrap(json(requested)["nonce"] as? String)
        XCTAssertNil(router.pairing.request?.number, "no number before the phone revealed its nonce")
        XCTAssertEqual(router.pairing.request?.name, "Phone")

        router.pairing.approve()
        XCTAssertNil(router.pairing.request?.number, "Allow does nothing before there is a number to compare")
        XCTAssertEqual(try post("pair/confirm", ["commit": phone.commit]).status, 401, "nothing to confirm before the reveal")

        XCTAssertEqual(try post("pair/reveal", ["commit": phone.commit, "nonce": phone.nonce]).status, 200)
        let expected = PairingProof.number(pin: pin, phoneNonce: phone.nonce, macNonce: macNonce)
        XCTAssertEqual(router.pairing.request?.number, expected, "the Mac shows what the phone will compute")

        let waiting = try post("pair/confirm", ["commit": phone.commit])
        XCTAssertEqual(json(waiting)["state"] as? String, "waiting", "the phone said same; the Mac has not allowed")
        XCTAssertNil(json(waiting)["token"])

        router.pairing.approve()
        let approved = try post("pair/confirm", ["commit": phone.commit])
        XCTAssertEqual(json(approved)["state"] as? String, "approved")
        let token = try XCTUnwrap(json(approved)["token"] as? String)
        XCTAssertNotNil(devices.authenticate(token, now: Date()))
        XCTAssertNil(router.pairing.current, "one pairing closes the window")
        XCTAssertEqual(try post("pair/confirm", ["commit": phone.commit]).status, 401, "a token is handed over once")
    }

    func testRefusingANumberPairingIssuesNothing() throws {
        _ = router.pairing.begin()
        let phone = Phone()
        let macNonce = try XCTUnwrap(json(try post("pair/request", ["name": phone.name, "commit": phone.commit]))["nonce"] as? String)
        _ = macNonce
        _ = try post("pair/reveal", ["commit": phone.commit, "nonce": phone.nonce])
        router.pairing.deny()
        XCTAssertEqual(try post("pair/confirm", ["commit": phone.commit]).status, 403)
        XCTAssertEqual(devices.all.count, 1, "no phone was added (the one from setUp)")
        XCTAssertNil(router.pairing.request)
        XCTAssertNotNil(router.pairing.current, "the window stays open for another try")
    }

    func testANumberPairingNeedsAnOpenWindow() throws {
        let phone = Phone()
        XCTAssertEqual(try post("pair/request", ["name": phone.name, "commit": phone.commit]).status, 401)
        _ = router.pairing.begin(now: Date())
        let late = Date().addingTimeInterval(PairingSessions.lifetime + 1)
        XCTAssertEqual(try post("pair/request", ["name": phone.name, "commit": phone.commit], now: late).status, 401)
    }

    func testARevealThatBreaksThePromiseBurnsTheRequest() throws {
        _ = router.pairing.begin()
        let phone = Phone()
        _ = try post("pair/request", ["name": phone.name, "commit": phone.commit])
        XCTAssertEqual(try post("pair/reveal", ["commit": phone.commit, "nonce": PairingProof.nonce()]).status, 401, "another nonce than the one promised")
        XCTAssertNil(router.pairing.request, "and nothing is left to allow")
        XCTAssertEqual(try post("pair/reveal", ["commit": phone.commit, "nonce": phone.nonce]).status, 401)
    }

    func testOnlyOnePhoneAsksAtATime() throws {
        _ = router.pairing.begin()
        let first = Phone(), second = Phone(name: "Other")
        XCTAssertEqual(try post("pair/request", ["name": first.name, "commit": first.commit], peer: "192.168.1.9").status, 200)
        XCTAssertEqual(try post("pair/request", ["name": second.name, "commit": second.commit], peer: "192.168.1.10").status, 423)
        XCTAssertEqual(router.pairing.request?.name, "Phone", "the first one stays on the screen")
        let again = Phone()
        XCTAssertEqual(try post("pair/request", ["name": again.name, "commit": again.commit], peer: "192.168.1.9").status, 200, "the same phone may start over")
    }

    func testPollingForTheMacsAnswerDoesNotUseUpThePairingAllowance() throws {
        _ = router.pairing.begin()
        let phone = Phone()
        _ = try post("pair/request", ["name": phone.name, "commit": phone.commit])
        _ = try post("pair/reveal", ["commit": phone.commit, "nonce": phone.nonce])
        let now = Date()
        for second in 0..<(RateLimiter.pairingPerMinute * 3) {
            let response = try post("pair/confirm", ["commit": phone.commit], now: now.addingTimeInterval(Double(second) * 0.5))
            XCTAssertEqual(json(response)["state"] as? String, "waiting", "poll \(second)")
        }
    }

    func testCancellingARequestClearsIt() throws {
        _ = router.pairing.begin()
        let phone = Phone()
        _ = try post("pair/request", ["name": phone.name, "commit": phone.commit])
        XCTAssertEqual(try post("pair/cancel", ["commit": phone.commit]).status, 200)
        XCTAssertNil(router.pairing.request)
        XCTAssertEqual(try post("pair/reveal", ["commit": phone.commit, "nonce": phone.nonce]).status, 401)
    }

    func testTheComparisonStepsRefuseGetsAndGarbage() throws {
        _ = router.pairing.begin()
        let get = try XCTUnwrap(request("GET /v1/pair/request HTTP/1.1"))
        XCTAssertEqual(router.respond(to: get, peer: "192.168.1.9").status, 405)
        XCTAssertEqual(try post("pair/request", ["name": "x", "commit": "nope"]).status, 400)
        XCTAssertEqual(try post("pair/request", ["commit": String(repeating: "a", count: 64)]).status, 400, "a name is needed")
        XCTAssertEqual(try post("pair/other", ["commit": String(repeating: "a", count: 64)]).status, 405, "not a step: the Mac only reads, like on any other path")
    }

    // MARK: staying inside the package

    func testNothingButTheListedFilesAnswersWith200() throws {
        for hidden in ["../../prod.keys", "../prod.keys", "%2e%2e/prod.keys", ".signing.json", ".complete", "save/progress.dat", "save",
                       "DmGame\(titleID).framework/../../../../etc/passwd", "DmGame\(titleID).framework", "aoc", "aoc/", "/etc/passwd",
                       "romfs.img.partial", ".DS_Store", "DmGame\(titleID).framework/nope", "PACKAGE.JSON", "package.json/"] {
            XCTAssertEqual(try status(filePath(hidden), token: token, peer: "10.2.0.\(hidden.count)"), 404, hidden)
        }
        XCTAssertEqual(try status(filePath("package.json"), token: token), 200)
        XCTAssertEqual(try status(filePath("aoc/0.img"), token: token), 200)
        XCTAssertEqual(try status(filePath("DmGame\(titleID).framework/DmGame"), token: token), 200)
    }

    func testAnUpdateOrAMadeUpTitleIDIsNotAGame() throws {
        for id in ["0100111000200800", "0100111000201000", "nope", "0000000000000000", "0100111000200000/../0100111000200000"] {
            XCTAssertEqual(try status("/v1/games/\(id)", token: token, peer: "10.3.0.\(id.count)"), 404, id)
        }
        let badRevision = "/v1/games/\(titleID)/not-a-revision/files/package.json"
        XCTAssertEqual(try status(badRevision, token: token), 404)
    }

    func testARevisionThatIsNotTheCurrentOneIs409() throws {
        let old = String(repeating: "1", count: 64)
        XCTAssertEqual(try status("/v1/games/\(titleID)/\(old)/files/romfs.img", token: token), 409)
    }

    func testRangesAnswerWithTheRightHeaders() throws {
        let size = try XCTUnwrap(library.game(titleID: titleID)?.files["romfs.img"])
        func answer(_ range: String?, method: String = "GET") throws -> ShareResponse {
            let headers = range.map { ["Range: \($0)"] } ?? []
            let response = router.respond(to: try XCTUnwrap(request("\(method) \(filePath("romfs.img")) HTTP/1.1", headers: headers, token: token)), peer: "10.4.0.1")
            if case .file(let file, _, _) = response.body { file.close() }
            return response
        }
        let whole = try answer(nil)
        XCTAssertEqual(whole.status, 200)
        if case .file(_, let offset, let length) = whole.body { XCTAssertEqual(offset, 0); XCTAssertEqual(length, size) }

        let tail = try answer("bytes=1000-")
        XCTAssertEqual(tail.status, 206)
        XCTAssertEqual(tail.headers.first { $0.0 == "Content-Range" }?.1, "bytes 1000-\(size - 1)/\(size)")
        if case .file(_, let offset, let length) = tail.body { XCTAssertEqual(offset, 1000); XCTAssertEqual(length, size - 1000) }

        let middle = try answer("bytes=10-19")
        XCTAssertEqual(middle.headers.first { $0.0 == "Content-Range" }?.1, "bytes 10-19/\(size)")
        if case .file(_, _, let length) = middle.body { XCTAssertEqual(length, 10) }

        let past = try answer("bytes=\(size)-")
        XCTAssertEqual(past.status, 416)
        XCTAssertEqual(past.headers.first { $0.0 == "Content-Range" }?.1, "bytes */\(size)")
        XCTAssertEqual(try answer("bytes=9-3").status, 416)

        let head = try answer(nil, method: "HEAD")
        XCTAssertEqual(head.status, 200)
        XCTAssertEqual(head.headLength, size)
        if case .none = head.body {} else { XCTFail("HEAD sends no body") }
    }

    func testTheListingMarksAGameBeingBuilt() throws {
        let busy = SharedLibrary(folder: built, cacheLife: 30, busy: { [ShareFixture.titleID] })
        XCTAssertEqual(busy.listing().map(\.busy), [true])
        XCTAssertEqual(library.listing().map(\.busy), [false])
    }

    // MARK: the list of paired phones

    func testTheOldestPhoneGoesWhenTheListIsFull() throws {
        let store = PairedDevices(folder: workspace.appendingPathComponent("many"))
        for index in 0..<PairedDevices.maxDevices {
            _ = try store.add(name: "Phone \(index)", now: Date().addingTimeInterval(Double(index)))
        }
        _ = try store.add(name: "Newest", now: Date().addingTimeInterval(1000))
        XCTAssertEqual(store.all.count, PairedDevices.maxDevices)
        XCTAssertFalse(store.all.map(\.name).contains("Phone 0"))
        XCTAssertTrue(store.all.map(\.name).contains("Newest"))
    }

    func testThePairedPhonesComeBackAfterARestartAndOnlyAsHashes() throws {
        let folder = workspace.appendingPathComponent("persist")
        let store = PairedDevices(folder: folder)
        let (device, secret) = try store.add(name: "Kept")
        let reloaded = PairedDevices(folder: folder)
        XCTAssertEqual(reloaded.all.map(\.id), [device.id])
        XCTAssertEqual(reloaded.authenticate(secret)?.id, device.id)
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(PairedDevices.fileName).path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        reloaded.removeAll()
        XCTAssertTrue(PairedDevices(folder: folder).all.isEmpty)
    }
}

import NXPMacModel

final class SharingSettingsTests: XCTestCase {
    func testSharingIsOffForSettingsSavedBeforeItExisted() throws {
        let old = try JSONDecoder().decode(LauncherSettings.self, from: Data(#"{"gameFolder":"/g","outputFolder":"/built","autoBackup":false}"#.utf8))
        XCTAssertFalse(old.shareEnabled, "an update never turns a network feature on")
        XCTAssertEqual(old.shareFolder, "")
        XCTAssertEqual(old.sharePort, 0)
        XCTAssertEqual(old.gameFolder, "/g")
        XCTAssertEqual(old.shareURL.path, "/built", "the shared folder defaults to where games are built")
    }

    func testTheSharingChoicesSurviveASave() throws {
        var settings = LauncherSettings()
        settings.shareEnabled = true
        settings.shareFolder = "/Users/me/Shared"
        settings.sharePort = 49217
        let back = try JSONDecoder().decode(LauncherSettings.self, from: try JSONEncoder().encode(settings))
        XCTAssertEqual(back, settings)
        XCTAssertEqual(back.shareURL.path, "/Users/me/Shared")
        XCTAssertFalse(LauncherSettings().shareEnabled)
    }
}

final class StaleProfileTests: XCTestCase {
    func testTheEnginesRefusalNamesTheFolderToPutAside() {
        let reason = "cached provisional profile describes v0, but inputs select v65536. Preserving the existing profile at /Users/me/Documents/decomp/switch_games/south_park/010043600B6A6000_build/profile. Use --profile-out with a new empty folder to survey this update, or explicitly select an available registered version with --package. Refusing to silently pack an older version"
        XCTAssertEqual(AppModel.staleProfileFolder(in: reason)?.path, "/Users/me/Documents/decomp/switch_games/south_park/010043600B6A6000_build/profile")
        XCTAssertNil(AppModel.staleProfileFolder(in: "the engine exited with 1"))
        XCTAssertNil(AppModel.staleProfileFolder(in: "cached provisional profile; Preserving the existing profile at relative/path. Use --profile-out"))
    }
}
