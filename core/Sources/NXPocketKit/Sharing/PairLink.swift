import Foundation

/// What the QR code on the Mac says, as a link the iPhone's own camera opens in the app:
/// `nxpocket://pair?h=<host>&p=<port>&k=<key>&s=<secret>&n=<name>`.
///
/// It carries the Mac's key (`k`, the pin) and a one-time secret (`s`), so scanning it is the pairing's trust: the phone
/// connects only to a server presenting that key, and proves it knows the secret. The secret is good for the one open pairing
/// window, like the typed code, and the link is worthless once the window closes.
public struct PairLink: Equatable, Sendable {
    /// The scheme the app registers (`GameLink.scheme` in the app).
    public static let scheme = "nxpocket"
    public static let host = "pair"

    public var address: String
    public var port: Int
    public var pin: String
    public var secret: String
    public var name: String

    public init(address: String, port: Int, pin: String, secret: String, name: String) {
        self.address = address
        self.port = port
        self.pin = pin
        self.secret = secret
        self.name = name
    }

    public var url: URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.queryItems = [
            URLQueryItem(name: "h", value: address), URLQueryItem(name: "p", value: String(port)),
            URLQueryItem(name: "k", value: pin), URLQueryItem(name: "s", value: secret),
            URLQueryItem(name: "n", value: name)
        ]
        return components.url
    }

    /// A link is only believed when every field is what it should be: whatever opens the app can send it anything.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, url.host?.lowercased() == Self.host,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let address = value("h"), (1...253).contains(address.utf8.count),
              !address.contains(where: { $0.isWhitespace || "/?#@[]%".contains($0) }),
              let port = value("p").flatMap({ Int($0) }), (1...65535).contains(port),
              let pin = value("k"), FileDigest.isSHA256(pin),
              let secret = value("s")?.lowercased(), PairingProof.isSecret(secret) else { return nil }
        self.init(address: address, port: port, pin: pin, secret: secret,
                  name: RemoteListing.text(value("n") ?? address, limit: 64))
    }
}
